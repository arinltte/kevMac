import Foundation
import Combine

class KevManager: ObservableObject {
    @Published var isServerReady = false
    @Published var isWarmingUp = false
    @Published var isAnalyzing = false
    @Published var errorMessage: String?
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

    func startServer() {
        if let process = serverProcess, process.isRunning { return }

        readinessTimer?.invalidate()
        serverProcess?.terminate()
        hasWarmedUp = false

        // Kill zombie servers on our port
        let killTask = Process()
        killTask.launchPath = "/bin/sh"
        killTask.arguments = ["-c", "lsof -ti:8009 | xargs kill -9 2>/dev/null || true"]
        try? killTask.run()
        killTask.waitUntilExit()

        guard FileManager.default.fileExists(atPath: venvPython.path) else {
            DispatchQueue.main.async {
                self.isServerReady = false
                self.errorMessage = "The decision engine is not installed. Restart kevMac and run setup."
            }
            return
        }

        DispatchQueue.main.async {
            self.isServerReady = false
            self.isWarmingUp = false
            self.errorMessage = nil
        }

        serverProcess = Process()
        serverProcess?.executableURL = URL(fileURLWithPath: venvPython.path)
        serverProcess?.arguments = ["-m", "kev.serve", "--run", "jaredpalmer/kev-0.6b", "--port", String(port)]
        // `python -m kev.serve` needs the repo on sys.path — run from the engine folder
        serverProcess?.currentDirectoryURL = kevDir

        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = baseDir.appendingPathComponent("Cache").path
        // Weights were pre-downloaded into ~/.kevMac/Cache during setup — run fully offline
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
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

    /// The first request compiles MPS shaders (5–10 s) — warm up in the background so the
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
        serverProcess?.terminate()
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
