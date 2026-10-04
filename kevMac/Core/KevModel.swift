import Foundation

/// The supported kev checkpoints — the Kev 1.0 family (0.8B / 4B / 9B / 27B), pinned to the
/// upstream `@v1.0` Hub tags. The Qwen3-0.6B the app originally shipped with was retired
/// upstream to "previous generation" and is removed from kevMac entirely (v0.3.0): it is no
/// longer selectable, and leftover caches from older installs are cleaned up automatically.
/// Selection is dynamic: the engine serves whichever model is selected, and only that
/// model's weights are downloaded.
enum KevModel: String, CaseIterable, Identifiable {
    /// The smallest current model; the default.
    case kev08b = "jaredpalmer/kev-0.8b"
    case kev4b = "jaredpalmer/kev-4b"
    case kev9b = "jaredpalmer/kev-9b"
    /// Kev 1.0's new full-weight checkpoint (51 GB bf16 backbone, no LoRA merge).
    case kev27b = "jaredpalmer/kev-27b"

    var id: String { rawValue }

    static let storageKey = "selectedModel"

    /// The default selection: the latest small model.
    static let defaultModel: KevModel = .kev08b

    var displayName: String {
        rawValue.split(separator: "/").last.map(String.init) ?? rawValue
    }

    var base: String {
        switch self {
        case .kev08b: return "Qwen/Qwen3.5-0.8B-Base"
        case .kev4b: return "Qwen/Qwen3.5-4B-Base"
        case .kev9b: return "Qwen/Qwen3.5-9B-Base"
        case .kev27b: return "Qwen/Qwen3.8-27B"
        }
    }

    // MARK: - Kev 1.0 pinning

    /// The Hub tag every Kev 1.0 repo carries. Passing the pin matters: upstream moved
    /// `kev-9b`'s `main` to v2 weights on 2026-09-30, and kevMac must not silently serve
    /// "whatever was cached". Only pass when the engine understands `@revision` (see
    /// `KevManager.engineSupportsPins`) — the pre-1.0 engine would reject the pin and
    /// silently fall back to `runs/smoke`.
    var pin: String? {
        switch self {
        case .kev08b, .kev4b, .kev9b, .kev27b: return "v1.0"
        }
    }

    /// The `--run` / `snapshot_download` specifier: `repo@v1.0` when pinned.
    var pinnedRun: String {
        pin.map { "\(rawValue)@\($0)" } ?? rawValue
    }

    /// True for full-weight checkpoints (kev-27b): the whole bf16 backbone ships inside the
    /// checkpoint itself (no `adapter_config.json`), so the base repo contributes only
    /// tokenizer bits at download time and the loader never reads base weights from the Hub.
    var isFullWeights: Bool {
        self == .kev27b
    }

    // MARK: - Serving metadata (Kev 1.0 cards)

    /// The dtype env the engine should be started with. Kev 1.0 serves bf16 by default on
    /// every GPU/Mac (MLX ignores the variable); the Qwen3.5 LoRA trio sets it explicitly so
    /// a pre-1.0 engine still serves bf16, and the full-weight 27B loads as stored.
    var dtypeEnv: String? {
        switch self {
        case .kev08b, .kev4b, .kev9b: return "bf16"
        case .kev27b: return nil
        }
    }

    /// Approximate Hub-weight download size.
    var sizeHint: String {
        switch self {
        case .kev08b: return "~1.6 GB"
        case .kev4b: return "~8 GB"
        case .kev9b: return "~18 GB"
        case .kev27b: return "~51 GB"
        }
    }

    /// Approximate serving memory, for the picker's guidance (Kev 1.0 cards: the 9B did not
    /// fit a 32 GB M5; the 27B is expected to need a 96–128 GB Mac and is unmeasured upstream).
    var memoryHint: String {
        switch self {
        case .kev08b: return "~2 GB RAM"
        case .kev4b: return "~9–13 GB RAM"
        case .kev9b: return "19 GB+ RAM · 48 GB+ Mac recommended"
        case .kev27b: return "51 GB+ RAM · 96–128 GB Mac expected"
        }
    }

    /// The longest document the model is *validated* for (the Kev 1.0 cards; the engine
    /// itself serves up to 65,536 tokens, but only 27B's accuracy is validated that far).
    var validatedContextTokens: Int {
        self == .kev27b ? 65_536 : 8_192
    }

    /// Kev 1.0 headline: out-of-domain accuracy (transfer-v4 locked test — the number closest
    /// to "your own questions") plus the chance-corrected breadth-v1 index.
    var accuracyHint: String {
        switch self {
        case .kev08b: return "0.697 new-source"
        case .kev4b: return "0.838 new-source"
        case .kev9b: return "0.852 new-source"
        case .kev27b: return "0.889 new-source · index 52.3"
        }
    }

    // MARK: - Experimental sizes & RAM guidance

    /// Kev 1.0's own cards leave the Mac path at these sizes unmeasured: the 9B did not fit
    /// a 32 GB M5 (the only upstream datapoint), and the 27B is expected — not yet run — to
    /// need a 96–128 GB Mac. They stay selectable and downloadable for users who want them,
    /// but the picker marks them experimental and names the RAM they realistically need.
    var isExperimental: Bool {
        switch self {
        case .kev08b, .kev4b: return false
        case .kev9b, .kev27b: return true
        }
    }

    /// The Mac this model realistically needs.
    var recommendedRAMGB: Int {
        switch self {
        case .kev08b: return 8
        case .kev4b: return 32
        case .kev9b: return 48
        case .kev27b: return 96
        }
    }

    static var physicalRAMGB: Int {
        Int((ProcessInfo.processInfo.physicalMemory + 500_000_000) / 1_000_000_000)
    }

    /// True when this Mac has the recommended physical RAM to serve the model comfortably.
    /// Below it a model still loads (weights map lazily) but serves by swapping — on a 16 GB
    /// Mac the 9B took ~155 s per request in testing — so the picker warns rather than hides.
    var fitsInRAM: Bool {
        Self.physicalRAMGB >= recommendedRAMGB
    }

    // MARK: - Weight-cache detection (HF cache naming: "/" → "--")

    func weightsCacheDir(inBaseDir baseDir: URL) -> URL {
        baseDir
            .appendingPathComponent("Cache")
            .appendingPathComponent("hub")
            .appendingPathComponent("models--" + rawValue.replacingOccurrences(of: "/", with: "--"))
    }

    func baseWeightsCacheDir(inBaseDir baseDir: URL) -> URL {
        baseDir
            .appendingPathComponent("Cache")
            .appendingPathComponent("hub")
            .appendingPathComponent("models--" + base.replacingOccurrences(of: "/", with: "--"))
    }

    /// The adapter/checkpoint snapshot must be in the cache for the engine to serve offline.
    /// For pinned models the cache must hold the exact pinned revision (`refs/v1.0`), so a
    /// pre-1.0 unpinned download never masquerades as the pinned one. `pinned` must match
    /// what the engine will serve — a pre-1.0 engine cannot serve `@v1.0` and resolves the
    /// moving `main` instead, so its downloads and checks are unpinned too.
    func isDownloaded(inBaseDir baseDir: URL, pinned: Bool = true) -> Bool {
        let weightsDir = weightsCacheDir(inBaseDir: baseDir)
        guard FileManager.default.fileExists(atPath: weightsDir.path) else { return false }
        if pinned, let pin = pin, !FileManager.default.fileExists(atPath: weightsDir.appendingPathComponent("refs/\(pin)").path) {
            return false
        }
        // A LoRA checkpoint needs its base weights cached too; a full-weight checkpoint
        // (kev-27b) carries its backbone and needs only the base's tokenizer bits.
        return FileManager.default.fileExists(atPath: baseWeightsCacheDir(inBaseDir: baseDir).path)
    }

    // MARK: - Storage accounting (unused-model cleanup)

    /// Bytes this model occupies in the download cache (checkpoint + base), for the storage
    /// manager.
    func storageSize(inBaseDir baseDir: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for dir in [weightsCacheDir(inBaseDir: baseDir), baseWeightsCacheDir(inBaseDir: baseDir)] where fm.fileExists(atPath: dir.path) {
            total += Self.directorySize(dir)
        }
        return total
    }

    /// Whether another downloaded kev model shares this model's base repo (none of the
    /// current checkpoints do, but the removal path checks rather than assumes).
    static func baseIsShared(by model: KevModel, inBaseDir baseDir: URL) -> Bool {
        KevModel.allCases.contains { other in
            other != model && other.base == model.base && other.isDownloaded(inBaseDir: baseDir)
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               size.isRegularFile == true {
                total += Int64(size.fileSize ?? 0)
            }
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
