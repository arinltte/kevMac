import Foundation
import Combine

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

    private var serverProcess: Process?
    private var readinessTimer: Timer?
    private var hasWarmedUp = false

    let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kevMac")
    private let port = 8009

    private var kevDir: URL { baseDir.appendingPathComponent("kev") }
    private var venvPython: URL { kevDir.appendingPathComponent(".venv/bin/python") }

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

        // The selected model must be downloaded before the engine can serve it offline
        guard model.isDownloaded(inBaseDir: baseDir) else {
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
        }

        serverProcess = Process()
        serverProcess?.executableURL = URL(fileURLWithPath: venvPython.path)
        serverProcess?.arguments = ["-m", "kev.serve", "--run", model.rawValue, "--port", String(port)]
        // `python -m kev.serve` needs the repo on sys.path — run from the engine folder
        serverProcess?.currentDirectoryURL = kevDir

        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = baseDir.appendingPathComponent("Cache").path
        // Weights are pre-downloaded into ~/.kevMac/Cache during setup — run fully offline
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        // The Qwen3.5 models serve in bf16; the Qwen3-0.6B serves in fp32 (the default)
        if model.needsBF16 { env["KEV_DTYPE"] = "bf16" }
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
                    }
                }
            }.resume()
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

    // MARK: - Model download

    /// Downloads one model's weights (adapter + its pinned base) into ~/.kevMac/Cache, then
    /// restarts the engine on it. Used when the user selects a model that isn't downloaded yet.
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

        let script = """
        import os
        import sys

        os.environ['HF_HOME'] = sys.argv[1]

        from huggingface_hub import snapshot_download

        print("Downloading \(model.rawValue) adapter and head weights...")
        adapter = snapshot_download('\(model.rawValue)')

        import torch
        meta = torch.load(os.path.join(adapter, 'head.pt'), map_location='cpu')
        base = meta.get('base', '\(model.base)')
        revision = meta.get('base_revision')

        print(f"Downloading the base model {base}...")
        if revision:
            snapshot_download(base, revision=revision)
        else:
            snapshot_download(base)

        print("Model weights downloaded successfully.")
        """

        let tempScriptPath = baseDir.appendingPathComponent("download_model.py").path
        do { try script.write(toFile: tempScriptPath, atomically: true, encoding: .utf8) } catch {
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
        request.timeoutInterval = 120

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
                completion(.failure("The engine returned an error (\(httpResponse.statusCode)). \(detail.prefix(200))"))
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
        }

        post(path: "/v1/systemone", body: body) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAnalyzing = false
                switch result {
                case .success(let response):
                    self.results = response.answers
                    self.lastLatencyMS = response.latencyMs
                    self.lastUsage = response.usage
                case .failure(let message):
                    self.errorMessage = message
                }
            }
        }
    }
}
