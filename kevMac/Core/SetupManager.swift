import Foundation
import Combine

class SetupManager: ObservableObject {
    @Published var isSetupComplete = false
    @Published var isInstalling = false
    @Published var statusMessage = "Ready for setup."
    @Published var progress: Double = 0.0
    /// Engine-update state (the auto-check on launch surfaces these in the About pane).
    @Published var isUpdatingEngine = false
    @Published var engineUpdateMessage: String?

    /// Everything the app installs lives in this dedicated folder.
    let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kevMac")

    var kevDir: URL { baseDir.appendingPathComponent("kev") }
    var venvPython: URL { kevDir.appendingPathComponent(".venv/bin/python") }
    var cacheDir: URL { baseDir.appendingPathComponent("Cache") }
    var tempDir: URL { baseDir.appendingPathComponent("Temp") }

    /// The engine release kevMac pins. Kev 1.0 is the release that brings the MLX backend
    /// for Apple Silicon (the Qwen3.5 hybrid checkpoints finally run fast), 65,536-token
    /// documents with honest refusals, `@revision` pins and the rich `/v1/models` card.
    /// Pinning the tarball to the tag (not `main`) means every install gets the same engine
    /// — the pre-1.0 snapshot this app used to fetch silently truncated documents at
    /// 8,192 tokens and crawls on the reference DeltaNet kernels.
    static let engineTag = "kev-1.0"
    static let engineTarballURL = "https://github.com/jaredpalmer/kev/archive/refs/tags/\(engineTag).tar.gz"

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

    /// The installed engine's stamp (nil on the pre-1.0 snapshot, which was never stamped).
    var installedEngineStamp: String? {
        let path = kevDir.appendingPathComponent(".engine-tag").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : tag
    }

    /// True when the engine is installed but frozen on an older snapshot — every install
    /// from before this release is (the engine used to be fetched once from `main` and
    /// never again). MainView auto-updates once on launch; the About pane offers it too.
    var needsEngineUpdate: Bool {
        FileManager.default.fileExists(atPath: venvPython.path) &&
        FileManager.default.fileExists(atPath: kevDir.appendingPathComponent("kev").path) &&
        installedEngineStamp != Self.engineTag
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

                // 4. Fetch the kev engine, pinned to the kev-1.0 release (curl ships with
                //    macOS — no git required). A fresh install is stamped right away; an
                //    existing pre-1.0 snapshot is replaced so no install is left frozen.
                if !FileManager.default.fileExists(atPath: kevDir.appendingPathComponent("kev").path) {
                    await updateStatus("Fetching the kev \(Self.engineTag) decision engine...", progress: 0.2)
                    try await fetchEngine()
                } else if installedEngineStamp != Self.engineTag {
                    await updateStatus("Updating the decision engine to kev \(Self.engineTag)...", progress: 0.2)
                    try await fetchEngine(replaceExisting: true)
                }

                // 5. Python 3.13 — pinned explicitly, because torch ships no wheels for 3.14
                await updateStatus("Installing Python 3.13 (managed in ~/.kevMac/Python)...", progress: 0.3)
                try await runShellCommand("'\(uvPath!)' python install 3.13", extraEnv: uvEnvironment)

                // 6. Virtual environment + dependencies (skips the 3.14 torch error automatically)
                if !FileManager.default.fileExists(atPath: venvPython.path) {
                    await updateStatus("Creating the Python environment...", progress: 0.4)
                    try await runShellCommand("cd '\(kevDir.path)' && '\(uvPath!)' venv --python 3.13", extraEnv: uvEnvironment)
                }

                await updateStatus("Installing the engine dependencies (this may take a few minutes)...", progress: 0.5)
                try await runShellCommand("cd '\(kevDir.path)' && '\(uvPath!)' sync --extra serve", extraEnv: uvEnvironment)

                // 7. Model weights for the selected model — downloaded automatically, no
                //    button needed. A fresh install always has the kev-1.0 engine, so the
                //    download is pinned to @v1.0 exactly as the server will request it.
                await updateStatus("Downloading the \(selectedModel.displayName) weights (\(selectedModel.sizeHint), base model included)...", progress: 0.7)
                try await downloadModel(selectedModel, pinned: true)

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

    // MARK: - Engine update (the path every existing install takes once)

    /// Replaces the engine snapshot with the pinned kev-1.0 tarball and re-syncs the
    /// dependencies — existing virtual environments would not otherwise pick up `mlx-lm`,
    /// and the MLX backend is the whole point of the update. The Python interpreter, the
    /// virtual environment and the downloaded model weights are all preserved; the engine
    /// process must be restarted by the caller afterwards.
    func updateEngine(completion: ((Bool) -> Void)? = nil) {
        guard !isUpdatingEngine else { return }
        isUpdatingEngine = true
        engineUpdateMessage = nil
        print("🚀 [SetupManager] Updating the engine to \(Self.engineTag)...")

        Task {
            do {
                guard let uvPath = ensureUVInstalled() else {
                    throw NSError(domain: "SetupError", code: 1, userInfo: [NSLocalizedDescriptionKey: "uv was not found. Run setup again to reinstall."])
                }
                if !(await isInternetAvailable()) {
                    throw NSError(domain: "SetupError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Internet connection required."])
                }

                await setEngineUpdateMessage("Stopping the engine…")
                // Only the listening engine process — never this app's own connections to it
                try? await runShellCommand("lsof -ti:8009 -sTCP:LISTEN | xargs kill -9 2>/dev/null || true")

                await setEngineUpdateMessage("Fetching the kev \(Self.engineTag) engine…")
                try await fetchEngine(replaceExisting: true)

                await setEngineUpdateMessage("Updating the engine dependencies (this may take a few minutes)…")
                try await runShellCommand("cd '\(kevDir.path)' && '\(uvPath)' sync --extra serve", extraEnv: uvEnvironment)

                await setEngineUpdateMessage("Engine updated to \(Self.engineTag).")
                DispatchQueue.main.async {
                    self.isUpdatingEngine = false
                    self.engineUpdateMessage = "Engine updated to \(Self.engineTag)."
                    completion?(true)
                }
            } catch {
                print("❌ [SetupManager] Engine update failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isUpdatingEngine = false
                    self.engineUpdateMessage = "Update failed — \(error.localizedDescription)"
                    completion?(false)
                }
            }
        }
    }

    /// Downloads the pinned engine tarball and swaps the engine directory's contents,
    /// preserving the virtual environment. Stamps `.engine-tag` on success.
    private func fetchEngine(replaceExisting: Bool = false) async throws {
        let tarball = baseDir.appendingPathComponent("kev.tar.gz")
        let extractDir = tempDir.appendingPathComponent("kev-engine")

        if replaceExisting {
            try? FileManager.default.removeItem(at: extractDir)
            try? FileManager.default.removeItem(at: tarball)
        }
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        try await runShellCommand("curl -L --fail --silent --show-error \(Self.engineTarballURL) -o '\(tarball.path)'")
        // --strip-components 1 drops the kev-kev-1.0/ folder level, extracting straight into the temp dir
        try await runShellCommand("tar -xzf '\(tarball.path)' -C '\(extractDir.path)' --strip-components 1")

        if replaceExisting {
            // Clear the engine dir except the virtual environment, then move the new
            // snapshot in — stale modules from the old snapshot must not linger.
            try await runShellCommand("cd '\(kevDir.path)' && find . -mindepth 1 -maxdepth 1 ! -name '.venv' -exec rm -rf {} +")
        }
        // cp -R copies dotfiles too (mv would skip them in a glob)
        try await runShellCommand("cp -R '\(extractDir.path)/.' '\(kevDir.path)/'")
        try await runShellCommand("printf '%s' '\(Self.engineTag)' > '\(kevDir.appendingPathComponent(".engine-tag").path)'")

        try? FileManager.default.removeItem(at: extractDir)
        try? FileManager.default.removeItem(at: tarball)
    }

    private func setEngineUpdateMessage(_ message: String) async {
        await MainActor.run { self.engineUpdateMessage = message }
    }

    // MARK: - Model weights

    /// Pre-downloads the selected model's checkpoint and its pinned base into ~/.kevMac/Cache,
    /// so the decision engine starts fully offline and no button press is ever needed.
    /// `pinned` must match what the engine will serve (see ModelDownload).
    private func downloadModel(_ model: KevModel, pinned: Bool) async throws {
        let tempScriptPath = baseDir.appendingPathComponent("download_model.py").path
        try ModelDownload.script(for: model, pinned: pinned).write(toFile: tempScriptPath, atomically: true, encoding: .utf8)
        try await runShellCommand("'\(venvPython.path)' '\(tempScriptPath)' '\(baseDir.appendingPathComponent("Cache").path)'", extraEnv: ["HF_HOME": baseDir.appendingPathComponent("Cache").path])
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
