import Foundation

// MARK: - /v1/systemone response (mirrors kev.serve, which follows TypeSafe's contract)

struct Usage: Codable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    /// Present only when the engine runs with KEV_TRUNCATE_STATES=1: the request's state
    /// token count and how much of it the model actually read.
    var stateTokens: Int?
    var stateTokensUsed: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case stateTokens = "state_tokens"
        case stateTokensUsed = "state_tokens_used"
    }
}

struct Answer: Codable, Equatable {
    var type: String
    /// noul: p(yes)
    var noul: Double?
    /// choice: the winning option key
    var choice: String?
    var confidence: Double?
    var probabilities: [String: Double]?
    /// score: expected level value
    var score: Double?
    /// score: level index → label text
    var legend: [String: String]?
}

struct SystemOneResponse: Codable {
    var model: String
    var answers: [String: Answer]
    var usage: Usage
    var latencyMs: Double?
    /// Present only when the engine runs with KEV_TRUNCATE_STATES=1: true when the document
    /// was cut to the serving limit. kevMac surfaces it as a visible truncation notice.
    var truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case model, answers, usage, truncated
        case latencyMs = "latency_ms"
    }
}

// MARK: - /v1/models (Kev 1.0: a rich engine card, not just a health check)

/// The Kev 1.0 `/v1/models` card. Everything after `name` is kev-specific and may be absent
/// on an older engine, so every field decodes optionality-tolerantly — the health check only
/// needs the 200, and the About pane shows what is there.
struct EngineCard: Codable {
    var name: String
    var description: String?
    var releaseDate: String?
    var run: String?
    var base: String?
    var lora: Bool?
    var device: String?
    var backend: String?
    var dtype: String?
    var temperature: Double?
    var maxStateTokens: Int?
    var truncateStates: Bool?
    var prefixCache: PrefixCacheStats?
    var batches: BatchStats?

    struct PrefixCacheStats: Codable {
        var size: Int?
        var minStateTokens: Int?
        var maxTokens: Int?
        var hits: Int?
        var misses: Int?
        var cachedStates: Int?
        var oomRetries: Int?

        enum CodingKeys: String, CodingKey {
            case size, hits, misses
            case minStateTokens = "min_state_tokens"
            case maxTokens = "max_tokens"
            case cachedStates = "cached_states"
            case oomRetries = "oom_retries"
        }
    }

    struct BatchStats: Codable {
        var count: Int?
        var requests: Int?
        var queued: Int?
    }

    enum CodingKeys: String, CodingKey {
        case name, description, run, base, lora, device, backend, dtype, temperature, prefixCache, batches
        case releaseDate = "release_date"
        case maxStateTokens = "max_state_tokens"
        case truncateStates = "truncate_states"
    }
}

struct ModelsResponse: Codable {
    var models: [EngineCard]
}

// MARK: - /v1/systemone/permute (Kev 1.0: the option-order stability check)

/// One re-run of a Choice question under a shuffled option order.
struct PermuteRun: Codable, Equatable {
    var order: [String]
    var probabilities: [String: Double]
    var choice: String?
    var latencyMs: Double?

    enum CodingKeys: String, CodingKey {
        case order, probabilities, choice
        case latencyMs = "latency_ms"
    }
}

struct PermuteResponse: Codable, Equatable {
    var runs: [PermuteRun]
    /// True when every shuffled order picked the same winning option.
    var argmaxStable: Bool
    /// Per option: its probability's max−min across the orders.
    var spread: [String: Double]
    var truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case runs, spread, truncated
        case argmaxStable = "argmax_stable"
    }
}

// MARK: - Error detail (Kev 1.0 refuses over-limit documents with a 422 that names the counts)

/// Parses the 422 detail `kev.serve` returns for a state over the serving limit —
/// "state is 70,000 tokens, over the 65,536-token limit (the <state> token included): …" —
/// into the document length and the limit, for a tailored message instead of the generic one.
enum OverLimitError {
    static func parse(statusCode: Int, detail: String) -> (stateTokens: Int, limit: Int)? {
        guard statusCode == 422 else { return nil }
        let pattern = #"state is ([0-9,]+) tokens, over the ([0-9,]+)-token limit"#
        guard let range = detail.range(of: pattern, options: .regularExpression) else { return nil }
        let match = detail[range]
        let numbers = match.split(whereSeparator: { $0 == " " }).compactMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        guard numbers.count == 2 else { return nil }
        return (stateTokens: numbers[0], limit: numbers[1])
    }
}
