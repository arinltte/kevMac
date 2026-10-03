import Foundation
import Combine

/// Per-choice-question stability check state (the /v1/systemone/permute call).
enum StabilityState: Equatable {
    case checking
    case stable(PermuteResponse)
    case failed(String)
}

class KevManager: ObservableObject {
    @Published var isServerReady = false
    @Published var isWarmingUp = false
    @Published var isAnalyzing = false
    @Published var errorMessage: String?
    /// Set when the selected model's weights are not downloaded yet — the results pane
    /// offers a Download action for it.
    @Published var missingModel: KevModel?
    /// The model the engine is currently serving.
    @Published var currentModel: KevModel = .defaultModel
    @Published var isDownloadingModel = false
    /// Answers keyed by the form row's UUID string (the model never sees the key).
    @Published var results: [String: Answer] = [:]
    /// The state the current results were computed from.
    @Published var analyzedState: String = ""
    @Published var lastLatencyMS: Double?
    @Published var lastUsage: Usage?
    /// True when the engine read only the first `max_state_tokens` of the document (only a
    /// server started with KEV_TRUNCATE_STATES=1 ever truncates instead of refusing).
    @Published var lastTruncated = false
    /// The live engine card from GET /v1/models (backend, dtype, temperature, prefix-cache
    /// stats…) — nil until the engine is ready, or on a pre-1.0 engine that returns none.
    @Published var engineInfo: EngineCard?
    /// Stability-check state per question id.
    @Published var stability: [String: StabilityState] = [:]
    /// Bumped whenever the download cache changes (download or removal) so pickers refresh.
    @Published var cacheVersion = 0
    /// Bytes each downloaded model occupies, computed off the main thread.
    @Published var storage: [KevModel: Int64] = [:]

    private var serverProcess: Process?
    private var readinessTimer: Timer?
    private var hasWarmedUp = false
    /// The request body of the last analysis, kept for the per-question stability check.
    private var lastRequestBody: [String: Any]?

    let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kevMac")
    private let port = 8009

    private var kevDir: URL { baseDir.appendingPathComponent("kev") }
    private var venvPython: URL { kevDir.appendingPathComponent(".venv/bin/python") }
    private var hubDir: URL { baseDir.appendingPathComponent("Cache").appendingPathComponent("hub") }

    // MARK: - Engine stamp

    /// The engine snapshot tag stamped into `~/.kevMac/kev/.engine-tag` at extract time.
    /// Absent on the pre-1.0 snapshot this app originally fetched from `main` — those
    /// engines have no MLX backend, silently truncate at 8,192 tokens and reject `@revision`
    /// pins in `--run` (they would fall back to `runs/smoke`).
    var engineStamp: String? {
        let path = kevDir.appendingPathComponent(".engine-tag").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : tag
    }

    /// Whether the installed engine understands `--run repo@tag` (kev-1.0 added it; pins
    /// must never be passed to an older engine — it would silently serve the smoke run).
    var engineSupportsPins: Bool {
        guard let stamp = engineStamp else { return false }
        guard let version = Self.engineVersion(stamp) else { return false }
        return version >= (1, 0)
    }

    /// "kev-1.0" → (1, 0); anything else → nil.
    static func engineVersion(_ tag: String) -> (Int, Int)? {
        guard let match = tag.range(of: #"^kev-(\d+)\.(\d+)$"#, options: .regularExpression) else { return nil }
        let parts = tag[match].replacingOccurrences(of: "kev-", with: "").split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return (major, minor)
    }

    // MARK: - Server lifecycle

    /// Starts (or restarts) the engine serving the given model. Switching models kills the
    /// current engine and relaunches with the new `--run`; selecting the same running model is a no-op.
    func startServer(model: KevModel) {
        if model == currentModel, let process = serverProcess, process.isRunning { return }

        readinessTimer?.invalidate()
        serverProcess?.terminate()
        hasWarmedUp = false

        // Kill zombie SERVERS on our port — -sTCP:LISTEN targets only the listening process;
        // without it lsof also matches this app's own ESTABLISHED connections to the engine
        // and the kill -9 would terminate kevMac itself (crash on model switch)
        let killTask = Process()
        killTask.launchPath = "/bin/sh"
        killTask.arguments = ["-c", "lsof -ti:8009 -sTCP:LISTEN | xargs kill -9 2>/dev/null || true"]
        try? killTask.run()
        killTask.waitUntilExit()

        guard FileManager.default.fileExists(atPath: venvPython.path) else {
            DispatchQueue.main.async {
                self.currentModel = model
                self.isServerReady = false
                self.errorMessage = "The decision engine is not installed. Restart kevMac and run setup."
            }
            return
        }

        // The selected model must be downloaded before the engine can serve it offline.
        // The cache check follows the pin the engine will serve: a kev-1.0 engine serves
        // repo@v1.0 and needs refs/v1.0 cached; an older engine serves the moving main.
        let pinned = engineSupportsPins
        guard model.isDownloaded(inBaseDir: baseDir, pinned: pinned) else {
            DispatchQueue.main.async {
                self.currentModel = model
                self.isServerReady = false
                self.missingModel = model
                self.errorMessage = "\(model.displayName) isn't downloaded yet (\(model.sizeHint)). Download it to switch."
            }
            return
        }

        DispatchQueue.main.async {
            self.currentModel = model
            self.isServerReady = false
            self.isWarmingUp = false
            self.missingModel = nil
            self.errorMessage = nil
            self.engineInfo = nil
        }

        serverProcess = Process()
        serverProcess?.executableURL = URL(fileURLWithPath: venvPython.path)
        serverProcess?.arguments = ["-m", "kev.serve", "--run", pinned ? model.pinnedRun : model.rawValue, "--port", String(port)]
        // `python -m kev.serve` needs the repo on sys.path — run from the engine folder
        serverProcess?.currentDirectoryURL = kevDir

        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = baseDir.appendingPathComponent("Cache").path
        // Weights are pre-downloaded into ~/.kevMac/Cache during setup — run fully offline
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        // Kev 1.0 serves bf16 by default (MLX ignores the variable and is bf16 anyway);
        // kev-0.6b keeps the fp32 exactness this app used to serve it with.
        if let dtype = model.dtypeEnv { env["KEV_DTYPE"] = dtype }
        env["PATH"] = "/opt/homebrew/bin:" + (env["PATH"] ?? "")
        serverProcess?.environment = env

        let pipe = Pipe()
        serverProcess?.standardOutput = pipe
        serverProcess?.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                print("🐍 [Server] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        do {
            try serverProcess?.run()
            startHealthCheck()
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to start the decision engine: \(error.localizedDescription)"
            }
        }
    }

    private func startHealthCheck() {
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let url = URL(string: "http://127.0.0.1:\(self.port)/v1/models")!
            URLSession.shared.dataTask(with: url) { data, response, error in
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    DispatchQueue.main.async {
                        if !self.isServerReady {
                            self.isServerReady = true
                            self.warmUpIfNeeded()
                        }
                        self.refreshEngineInfo(data: data)
                    }
                }
            }.resume()
        }
    }

    /// Polls the Kev 1.0 rich model card: backend (mlx/torch), dtype, temperature, release
    /// date, serving limit and prefix-cache stats — the live truth behind the About pane.
    func refreshEngineInfo(data: Data? = nil) {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let completion: (Data?) -> Void = { data in
            guard let data = data,
                  let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data),
                  let card = decoded.models.first else { return }
            DispatchQueue.main.async { self.engineInfo = card }
        }
        if let data = data {
            completion(data)
        } else {
            URLSession.shared.dataTask(with: url) { data, _, _ in completion(data) }.resume()
        }
    }

    /// The first request compiles the kernels (seconds) — warm up in the background so the
    /// user's first real question answers fast.
    private func warmUpIfNeeded() {
        guard !hasWarmedUp else { return }
        hasWarmedUp = true
        DispatchQueue.main.async { self.isWarmingUp = true }

        let body: [String: Any] = [
            "state": "warmup",
            "model": "kev-latest",
            "questions": ["warmup": ["type": "noul", "instructions": "Is this a warm-up request?"]],
        ]
        post(path: "/v1/systemone", body: body) { [weak self] result in
            DispatchQueue.main.async {
                self?.isWarmingUp = false
                if case .failure(let message) = result {
                    self?.errorMessage = "Warm-up failed: \(message)"
                }
            }
        }
    }

    func stopServer() {
        readinessTimer?.invalidate()
        guard let process = serverProcess else { return }
        let pid = process.processIdentifier
        process.terminate()
        // SIGTERM may not finish while the engine is mid-load (before uvicorn installs its
        // signal handlers) — SIGKILL our own child so it can never outlive the app
        if pid > 0 {
            let killTask = Process()
            killTask.launchPath = "/bin/sh"
            killTask.arguments = ["-c", "kill -9 \(pid) 2>/dev/null || true"]
            try? killTask.run()
        }
        serverProcess = nil
    }

    // MARK: - Model download & removal

    /// Downloads one model's weights (checkpoint + its pinned base / tokenizer bits) into
    /// ~/.kevMac/Cache, then restarts the engine on it. Used when the user selects a model
    /// that isn't downloaded yet.
    func downloadModel(_ model: KevModel) {
        guard !isDownloadingModel else { return }

        DispatchQueue.main.async {
            self.isDownloadingModel = true
            self.errorMessage = nil
        }

        guard FileManager.default.fileExists(atPath: venvPython.path) else {
            DispatchQueue.main.async {
                self.isDownloadingModel = false
                self.errorMessage = "The decision engine is not installed. Restart kevMac and run setup."
            }
            return
        }

        let tempScriptPath = baseDir.appendingPathComponent("download_model.py").path
        do {
            try ModelDownload.script(for: model, pinned: engineSupportsPins)
                .write(toFile: tempScriptPath, atomically: true, encoding: .utf8)
        } catch {
            DispatchQueue.main.async {
                self.isDownloadingModel = false
                self.errorMessage = "Could not prepare the download: \(error.localizedDescription)"
            }
            return
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HF_HOME"] = baseDir.appendingPathComponent("Cache").path

        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", "'\(venvPython.path)' '\(tempScriptPath)' '\(baseDir.appendingPathComponent("Cache").path)'"]
        task.environment = env

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                print("⬇️ [Download] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        task.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(atPath: tempScriptPath)

            DispatchQueue.main.async {
                self?.isDownloadingModel = false
                if process.terminationStatus == 0 {
                    self?.refreshStorageInfo()
                    // Downloaded — bring the engine up on the new model
                    if let model = self?.currentModel {
                        self?.startServer(model: model)
                    }
                } else {
                    self?.errorMessage = "The download failed (exit \(process.terminationStatus)). Check the connection and try again."
                }
            }
        }

        do { try task.run() } catch {
            DispatchQueue.main.async {
                self.isDownloadingModel = false
                self.errorMessage = "Could not start the download: \(error.localizedDescription)"
            }
        }
    }

    /// The models with weights cached right now.
    var downloadedModels: [KevModel] {
        KevModel.allCases.filter { $0.isDownloaded(inBaseDir: baseDir, pinned: engineSupportsPins) }
    }

    /// Computes each downloaded model's cache footprint off the main thread and publishes it.
    func refreshStorageInfo() {
        let baseDir = self.baseDir
        DispatchQueue.global(qos: .utility).async {
            var sizes: [KevModel: Int64] = [:]
            for model in KevModel.allCases where model.isDownloaded(inBaseDir: baseDir, pinned: true) {
                sizes[model] = model.storageSize(inBaseDir: baseDir)
            }
            DispatchQueue.main.async {
                self.storage = sizes
                self.cacheVersion += 1
            }
        }
    }

    /// Removes one model's weights from the download cache — the safe cleanup path for
    /// models that are no longer used, so switching models never leaves duplicate storage
    /// behind. Refuses the model the engine is currently serving; deletes the checkpoint
    /// dir and its base dir (unless another cached kev model shares the base); only ever
    /// deletes inside `~/.kevMac/Cache/hub`.
    func removeDownloadedModel(_ model: KevModel) {
        guard model != currentModel else { return }
        let fm = FileManager.default
        let hubPath = hubDir.standardizedFileURL.path + "/"

        var doomed: [URL] = [model.weightsCacheDir(inBaseDir: baseDir)]
        if !KevModel.baseIsShared(by: model, inBaseDir: baseDir) {
            doomed.append(model.baseWeightsCacheDir(inBaseDir: baseDir))
        }
        for dir in doomed {
            let path = dir.standardizedFileURL.path
            guard path.hasPrefix(hubPath), fm.fileExists(atPath: path) else { continue }
            do {
                try fm.removeItem(at: dir)
                print("🧹 [KevManager] Removed \(path)")
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Could not remove \(model.displayName) weights: \(error.localizedDescription)"
                }
            }
        }
        refreshStorageInfo()
    }

    // MARK: - Networking

    private enum PostResult {
        case success(SystemOneResponse)
        case failure(String)
    }

    private func post(path: String, body: [String: Any], completion: @escaping (PostResult) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure("Could not build the request."))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload
        // Long documents are servable on a Mac now: a first 65k-token read takes tens of
        // seconds even on the fastest Apple Silicon (cached re-reads stay sub-second).
        request.timeoutInterval = 600

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error.localizedDescription))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure("No response from the engine."))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode), let data = data,
                  let decoded = try? JSONDecoder().decode(SystemOneResponse.self, from: data) else {
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                // Kev 1.0 refuses a document over the serving limit with a 422 that names
                // the token count and the limit — turn it into an honest, tailored message.
                if let over = OverLimitError.parse(statusCode: httpResponse.statusCode, detail: detail) {
                    completion(.failure("The document is \(over.stateTokens) tokens, over the engine's \(over.limit)-token limit. Shorten it or split it across requests."))
                } else {
                    completion(.failure("The engine returned an error (\(httpResponse.statusCode)). \(detail.prefix(200))"))
                }
                return
            }
            completion(.success(decoded))
        }.resume()
    }

    // MARK: - Analysis

    func analyze(body: [String: Any]) {
        guard !isAnalyzing else { return }

        DispatchQueue.main.async {
            self.isAnalyzing = true
            self.errorMessage = nil
            self.analyzedState = body["state"] as? String ?? ""
            self.stability = [:]
        }
        lastRequestBody = body

        post(path: "/v1/systemone", body: body) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAnalyzing = false
                switch result {
                case .success(let response):
                    self.results = response.answers
                    self.lastLatencyMS = response.latencyMs
                    self.lastUsage = response.usage
                    self.lastTruncated = response.truncated ?? false
                    self.refreshEngineInfo()
                case .failure(let message):
                    self.errorMessage = message
                }
            }
        }
    }

    // MARK: - Stability check (Kev 1.0: POST /v1/systemone/permute)

    /// Re-runs one Choice question under six shuffled option orders and reports whether the
    /// winning option survives them (upstream's own honesty check: changing option order can
    /// change an answer). Requires the last analysis's request body.
    func checkStability(questionID: String) {
        guard let request = lastRequestBody else { return }
        DispatchQueue.main.async { self.stability[questionID] = .checking }

        let body: [String: Any] = ["request": request, "question": questionID, "n_perm": 6, "seed": 0]
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/systemone/permute"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { self.stability[questionID] = .failed("Could not build the request.") }
            return
        }

        var request_ = URLRequest(url: url)
        request_.httpMethod = "POST"
        request_.setValue("application/json", forHTTPHeaderField: "content-type")
        request_.httpBody = payload
        request_.timeoutInterval = 600

        URLSession.shared.dataTask(with: request_) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard error == nil,
                      let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      let data = data,
                      let decoded = try? JSONDecoder().decode(PermuteResponse.self, from: data) else {
                    let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    self.stability[questionID] = .failed("The engine returned an error (\((response as? HTTPURLResponse)?.statusCode ?? 0)). \(detail.prefix(120))")
                    return
                }
                self.stability[questionID] = .stable(decoded)
            }
        }.resume()
    }
}
