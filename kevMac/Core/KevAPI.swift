import Foundation

// MARK: - /v1/systemone response (mirrors kev.serve, which follows TypeSafe's contract)

struct Usage: Codable, Equatable {
    var inputTokens: Int
    var outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
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

    enum CodingKeys: String, CodingKey {
        case model, answers, usage
        case latencyMs = "latency_ms"
    }
}
