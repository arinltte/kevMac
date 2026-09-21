import Foundation

/// The supported kev models — the Qwen3.5 family from the kev repo (0.8B / 4B / 9B)
/// plus the Qwen3-0.6B the app shipped with. Selection is dynamic: the engine serves
/// whichever model is selected, and only that model's weights are downloaded.
enum KevModel: String, CaseIterable, Identifiable {
    /// The model the app originally shipped with — kept for continuity.
    case kev06b = "jaredpalmer/kev-0.6b"
    /// The smallest current model; replaces the 0.6B on the Qwen3.5 base.
    case kev08b = "jaredpalmer/kev-0.8b"
    case kev4b = "jaredpalmer/kev-4b"
    case kev9b = "jaredpalmer/kev-9b"

    var id: String { rawValue }

    static let storageKey = "selectedModel"

    /// The default selection: the latest small model (the Qwen3.5-0.8B the 0.6B was replaced by).
    static let defaultModel: KevModel = .kev08b

    var displayName: String {
        rawValue.split(separator: "/").last.map(String.init) ?? rawValue
    }

    var base: String {
        switch self {
        case .kev06b: return "Qwen/Qwen3-0.6B-Base"
        case .kev08b: return "Qwen/Qwen3.5-0.8B-Base"
        case .kev4b: return "Qwen/Qwen3.5-4B-Base"
        case .kev9b: return "Qwen/Qwen3.5-9B-Base"
        }
    }

    /// Qwen3.5 mixes attention with Gated DeltaNet layers and serves in bf16;
    /// the Qwen3-0.6B is attention-only and serves in fp32.
    var needsBF16: Bool {
        switch self {
        case .kev06b: return false
        case .kev08b, .kev4b, .kev9b: return true
        }
    }

    /// Approximate Hub-weight download size.
    var sizeHint: String {
        switch self {
        case .kev06b: return "~1.2 GB"
        case .kev08b: return "~1.6 GB"
        case .kev4b: return "~8 GB"
        case .kev9b: return "~18 GB"
        }
    }

    /// Approximate serving memory, for the picker's guidance.
    var memoryHint: String {
        switch self {
        case .kev06b: return "~3.5 GB RAM"
        case .kev08b: return "~2 GB RAM"
        case .kev4b: return "~9 GB"
        case .kev9b: return "~19 GB"
        }
    }

    var accuracyHint: String {
        switch self {
        case .kev06b: return "0.801 in-distribution"
        case .kev08b: return "0.829 in-distribution"
        case .kev4b: return "0.877 in-distribution"
        case .kev9b: return "0.876 in-distribution"
        }
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

    /// Both the adapter and its base model must be in the cache for the engine to serve offline.
    func isDownloaded(inBaseDir baseDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: weightsCacheDir(inBaseDir: baseDir).path) &&
        FileManager.default.fileExists(atPath: baseWeightsCacheDir(inBaseDir: baseDir).path)
    }
}
