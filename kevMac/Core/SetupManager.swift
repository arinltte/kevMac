import Foundation
import Combine

class SetupManager: ObservableObject {
    @Published var isSetupComplete = false
    @Published var isInstalling = false
    @Published var statusMessage = "Ready for setup."
    @Published var progress: Double = 0.0

    /// Everything the app installs lives in this dedicated folder.
    let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kevMac")

    var kevDir: URL { baseDir.appendingPathComponent("kev") }
    var venvPython: URL { kevDir.appendingPathComponent(".venv/bin/python") }
    var cacheDir: URL { baseDir.appendingPathComponent("Cache") }

    /// The model selection persists in UserDefaults; setup checks and downloads whatever model is selected.
    var selectedModel: KevModel {
        KevModel(rawValue: UserDefaults.standard.string(forKey: KevModel.storageKey) ?? "") ?? .defaultModel
    }

    init() {
        checkIfAlreadyInstalled()
    }

    // MARK: - Detection

    private func checkIfAlreadyInstalled() {
        let model = selectedModel
        let kevPackage = kevDir.appendingPathComponent("kev").path

        if FileManager.default.fileExists(atPath: venvPython.path),
           FileManager.default.fileExists(atPath: kevPackage),
           model.isDownloaded(inBaseDir: baseDir) {
            print("🚀 [SetupManager] Existing installation found (\(model.displayName)). Skipping setup.")
            isSetupComplete = true
        }
    }

    private func isInternetAvailable() async -> Bool {
        let url = URL(string: "https://huggingface.co")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Setup

    func runSetup() {
        isInstalling = true
        print("🚀 [SetupManager] Starting setup process...")

        Task {
            // 1. Internet
            if !(await isInternetAvailable()) {
                await fail("⚠️ Internet connection required.\n\nPlease connect to Wi-Fi and press 'Retry Setup'.")
                return
            }

            // 2. uv — install via Homebrew if missing
            await updateStatus("Checking for uv (Python package manager)...", progress: 0.05)
            var uvPath = ensureUVInstalled()
            if uvPath == nil {
                guard let brewPath = ensureHomebrewInstalled() else {
                    await fail("⚠️ Neither uv nor Homebrew was found.\n\nPlease install uv via Terminal, then restart kevMac:\n\nbrew install uv")
                    return
                }
                await updateStatus("Installing uv via Homebrew...", progress: 0.08)
                do {
                    try await runShellCommand("\(brewPath) install uv")
                } catch {
                    await fail("⚠️ Could not install uv.\n\n\(error.localizedDescription)")
                    return
                }
                guard let installed = ensureUVInstalled() else {
                    await fail("⚠️ uv was installed but could not be found. Please restart kevMac.")
                    return
                }
                uvPath = installed
            }

            do {
                // 3. Directories — everything lives inside ~/.kevMac
                await updateStatus("Preparing the kevMac folder (~/.kevMac)...", progress: 0.12)
                for dir in ["kev", "Cache", "Temp", "Python", "uv-cache"] {
                    let path = baseDir.appendingPathComponent(dir)
                    if !FileManager.default.fileExists(atPath: path.path) {
                        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                    }
                }

                // 4. Fetch the kev engine (curl ships with macOS — no git required)
                if !FileManager.default.fileExists(atPath: kevDir.appendingPathComponent("kev").path) {
                    await updateStatus("Fetching the kev decision engine...", progress: 0.2)
                    let tarball = baseDir.appendingPathComponent("kev.tar.gz")
                    try await runShellCommand("curl -L --fail --silent --show-error https://github.com/jaredpalmer/kev/archive/refs/heads/main.tar.gz -o '\(tarball.path)'")
                    // --strip-components 1 drops the kev-main/ folder level, extracting straight into kev/
                    try await runShellCommand("tar -xzf '\(tarball.path)' -C '\(kevDir.path)' --strip-components 1")
                    try? FileManager.default.removeItem(at: tarball)
                }

                // 5. Python 3.13 — pinned explicitly, because torch ships no wheels for 3.14
                await updateStatus("Installing Python 3.13 (managed in ~/.kevMac/Python)...", progress: 0.3)
                try await runShellCommand("'\(uvPath!)' python install 3.13", extraEnv: uvEnvironment)

                // 6. Virtual environment + dependencies (skips the 3.14 torch error automatically)
                if !FileManager.default.fileExists(atPath: venvPython.path) {
                    await updateStatus("Creating the Python environment...", progress: 0.4)
                    try await runShellCommand("cd '\(kevDir.path)' && '\(uvPath!)' venv --python 3.13", extraEnv: uvEnvironment)
                }

                await updateStatus("Installing the decision engine dependencies (this may take a few minutes)...", progress: 0.5)
                try await runShellCommand("cd '\(kevDir.path)' && '\(uvPath!)' sync --extra serve", extraEnv: uvEnvironment)

                // 7. Model weights for the selected model — downloaded automatically, no button needed
                await updateStatus("Downloading the \(selectedModel.displayName) weights (\(selectedModel.sizeHint), base model included)...", progress: 0.7)
                try await downloadModel(selectedModel)

                await updateStatus("Setup Complete!", progress: 1.0)
                DispatchQueue.main.async {
                    self.isSetupComplete = true
                    self.isInstalling = false
                }
            } catch {
                print("❌ [SetupManager] FATAL ERROR: \(error.localizedDescription)")
                await fail("⚠️ Setup failed.\n\nPlease ensure you have a stable internet connection and try again.\n\nError: \(error.localizedDescription)")
            }
        }
    }

    /// Pre-downloads the selected model's adapter and its pinned Qwen base into ~/.kevMac/Cache,
    /// so the decision engine starts fully offline and no button press is ever needed.
    private func downloadModel(_ model: KevModel) async throws {
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
        try script.write(toFile: tempScriptPath, atomically: true, encoding: .utf8)
        try await runShellCommand("'\(venvPython.path)' '\(tempScriptPath)' '\(cacheDir.path)'", extraEnv: ["HF_HOME": cacheDir.path])
        try? FileManager.default.removeItem(atPath: tempScriptPath)
    }

    // MARK: - Helpers

    private var uvEnvironment: [String: String] {
        [
            "UV_PYTHON_INSTALL_DIR": baseDir.appendingPathComponent("Python").path,
            "UV_CACHE_DIR": baseDir.appendingPathComponent("uv-cache").path,
        ]
    }

    private func ensureUVInstalled() -> String? {
        let uvPaths = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        for path in uvPaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private func ensureHomebrewInstalled() -> String? {
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in brewPaths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private func fail(_ message: String) async {
        await updateStatus(message, progress: 0.0)
        DispatchQueue.main.async { self.isInstalling = false }
    }

    private func updateStatus(_ msg: String, progress: Double) async {
        await MainActor.run {
            self.statusMessage = msg
            self.progress = progress
        }
    }

    private func runShellCommand(_ command: String, extraEnv: [String: String] = [:]) async throws {
        print("▶️ [EXEC] Running command: \(command)")

        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.launchPath = "/bin/zsh"
            task.arguments = ["-c", command]

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            for (key, value) in extraEnv { env[key] = value }
            task.environment = env

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                    print("   [STDOUT] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                    print("   [STDERR] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }

            task.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    print("✅ [EXEC] Command succeeded.")
                    continuation.resume()
                } else {
                    let errorMsg = "Command exited with status \(process.terminationStatus)."
                    print("❌ [EXEC] \(errorMsg)")
                    continuation.resume(throwing: NSError(domain: "SetupError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMsg]))
                }
            }

            do { try task.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
