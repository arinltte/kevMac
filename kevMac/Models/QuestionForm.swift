import Foundation

// MARK: - Question types (normal-language names for the API's noul / choice / score)

enum QuestionType: String, CaseIterable, Identifiable {
    case yesNo = "Yes / No"
    case choice = "Multiple Choice"
    case rating = "Rating"

    var id: String { rawValue }

    var apiType: String {
        switch self {
        case .yesNo: return "noul"
        case .choice: return "choice"
        case .rating: return "score"
        }
    }

    var symbolName: String {
        switch self {
        case .yesNo: return "checkmark.circle"
        case .choice: return "list.bullet.rectangle"
        case .rating: return "star.fill"
        }
    }
}

struct ChoiceOption: Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var detail: String = ""
}

struct QuestionForm: Identifiable, Equatable {
    var id = UUID()
    var instructions: String = ""
    var type: QuestionType = .choice
    /// choice: named options (name + optional detail) · rating: ordered levels (name only)
    var options: [ChoiceOption] = []
    /// noul: optional meaning of the Yes answer
    var yesDetail: String = ""
    /// noul: optional meaning of the No answer
    var noDetail: String = ""
}

// MARK: - Validation

struct FormIssues: Equatable {
    var stateEmpty: Bool = false
    var perQuestion: [UUID: String] = [:]

    var isValid: Bool { !stateEmpty && perQuestion.isEmpty }
}

// MARK: - Form → JSON conversion

/// Converts the plain-text form into the kev /v1/systemone JSON contract. The user never
/// sees this JSON — it is built here and handed straight to the decision engine.
enum KevFormBuilder {
    static let modelID = "kev-latest"

    static func validate(state: String, questions: [QuestionForm]) -> FormIssues {
        var issues = FormIssues()
        issues.stateEmpty = state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for question in questions {
            if question.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.perQuestion[question.id] = "Add instructions for this question."
                continue
            }
            switch question.type {
            case .yesNo:
                break
            case .choice:
                let named = question.options.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if named.count < 2 { issues.perQuestion[question.id] = "A choice needs at least two named options." }
            case .rating:
                let levels = question.options.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if levels.count < 2 { issues.perQuestion[question.id] = "A rating needs at least two levels." }
            }
        }
        return issues
    }

    /// Question keys are stable UUIDs so answers map back to the form rows.
    static func buildRequestBody(state: String, questions: [QuestionForm]) -> [String: Any]? {
        guard validate(state: state, questions: questions).isValid else { return nil }

        var questionsDict: [String: Any] = [:]
        for question in questions {
            let key = question.id.uuidString
            switch question.type {
            case .yesNo:
                var body: [String: Any] = ["type": "noul", "instructions": question.instructions]
                var criteria: [String: Any] = [:]
                if !question.yesDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    criteria["true"] = question.yesDetail
                }
                if !question.noDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    criteria["false"] = question.noDetail
                }
                if !criteria.isEmpty { body["criteria"] = criteria }
                questionsDict[key] = body
            case .choice:
                var criteria: [String: Any] = [:]
                for option in question.options {
                    let name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { continue }
                    let detail = option.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    criteria[name] = detail.isEmpty ? NSNull() : detail
                }
                questionsDict[key] = ["type": "choice", "instructions": question.instructions, "criteria": criteria]
            case .rating:
                let levels = question.options
                    .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                questionsDict[key] = ["type": "score", "instructions": question.instructions, "criteria": levels]
            }
        }
        return ["state": state, "model": modelID, "questions": questionsDict]
    }
}

// MARK: - JSON → normal-language conversion

/// Converts a kev JSON answer back into normal language for the UI and the copy report.
enum AnswerPresenter {
    static func headline(question: QuestionForm, answer: Answer) -> String {
        switch answer.type {
        case "noul":
            return (answer.noul ?? 0) >= 0.5 ? "Yes" : "No"
        case "choice":
            let key = answer.choice ?? ""
            if let match = question.options.first(where: { $0.name == key }), !match.name.isEmpty {
                return match.name
            }
            return key.isEmpty ? "—" : key
        case "score":
            let levels = question.options.map { $0.name }.filter { !$0.isEmpty }
            guard !levels.isEmpty else { return "—" }
            let expected = answer.score ?? 0
            let nearest = min(max(Int(expected.rounded()), 0), levels.count - 1)
            return levels[nearest]
        default:
            return "—"
        }
    }

    static func caption(question: QuestionForm, answer: Answer) -> String? {
        switch answer.type {
        case "noul":
            guard let p = answer.noul else { return nil }
            return "\(percent(p))% certainty"
        case "choice":
            guard let confidence = answer.confidence else { return nil }
            return "\(percent(confidence))% confident"
        case "score":
            guard let score = answer.score else { return nil }
            let levels = question.options.map { $0.name }.filter { !$0.isEmpty }
            return levels.isEmpty ? nil : String(format: "expected %.1f of %d", score, levels.count)
        default:
            return nil
        }
    }

    static func barRows(question: QuestionForm, answer: Answer) -> [(label: String, value: Double, isWinner: Bool)] {
        guard let probabilities = answer.probabilities, !probabilities.isEmpty else { return [] }
        switch answer.type {
        case "noul":
            let p = answer.noul ?? 0
            return [("Yes", p, p >= 0.5), ("No", 1 - p, p < 0.5)]
        case "choice":
            var keys = question.options.map { $0.name }.filter { !$0.isEmpty }
            for key in probabilities.keys where !keys.contains(key) { keys.append(key) }
            let winner = answer.choice
            return keys.map { ($0, probabilities[$0] ?? 0, $0 == winner) }
        case "score":
            let levels = question.options.map { $0.name }.filter { !$0.isEmpty }
            let legend = answer.legend ?? [:]
            let count = max(levels.count, probabilities.keys.compactMap(Int.init).count)
            return (0..<count).map { index in
                let label = legend[String(index)] ?? (index < levels.count ? levels[index] : "Level \(index + 1)")
                return (label, probabilities[String(index)] ?? 0, false)
            }
        default:
            return []
        }
    }

    static func summaryLine(question: QuestionForm, answer: Answer) -> String {
        var parts = [headline(question: question, answer: answer)]
        if let caption = caption(question: question, answer: answer) {
            parts.append("(\(caption))")
        }
        if answer.type == "choice", let probabilities = answer.probabilities, !probabilities.isEmpty {
            let detail = probabilities.map { "\($0.key) \(percent($0.value))%" }.joined(separator: " / ")
            parts.append("[\(detail)]")
        }
        return "\(question.instructions) → \(parts.joined(separator: " "))"
    }

    private static func percent(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }
}

// MARK: - Presets (from the kev playground)

struct Preset: Identifiable {
    let name: String
    let blurb: String
    let state: String
    let questions: [QuestionForm]
    var id: String { name }
}

extension Preset {
    /// The three user-facing presets from the kev playground. The Isolation probe and
    /// Boundary forgery presets are developer experiments and are intentionally left out.
    static let all: [Preset] = [supportTriage, newsArticle, reviewRating]

    static let supportTriage = Preset(
        name: "Support triage",
        blurb: "One message, many isolated answers — the example from the kev playground.",
        state: "Shoes arrived two weeks late and in the wrong size. Also I see two charges on my card. What are you going to do about this?",
        questions: [
            QuestionForm(instructions: "Which team should handle this?", type: .choice, options: [
                ChoiceOption(name: "returns", detail: "Exchanges, refunds, wrong or damaged items"),
                ChoiceOption(name: "shipping", detail: "Delivery status, delays, lost packages"),
                ChoiceOption(name: "billing", detail: "Charges, invoices, payment problems"),
            ]),
            QuestionForm(instructions: "If the customer wants to return something, why?", type: .choice, options: [
                ChoiceOption(name: "wrong_size", detail: "The item doesn't fit"),
                ChoiceOption(name: "wrong_item", detail: "A different product was delivered"),
                ChoiceOption(name: "damaged", detail: "The item arrived broken or faulty"),
                ChoiceOption(name: "changed_mind", detail: "The item is fine, the customer no longer wants it"),
                ChoiceOption(name: "other", detail: "A return reason that fits none of the above"),
            ]),
            QuestionForm(instructions: "What does the customer want to happen?", type: .choice, options: [
                ChoiceOption(name: "exchange", detail: "Swap the item for a different one"),
                ChoiceOption(name: "refund", detail: "Money back"),
                ChoiceOption(name: "replacement", detail: "The same item sent again"),
                ChoiceOption(name: "information", detail: "Just an answer, no action needed"),
            ]),
            QuestionForm(instructions: "What is the customer's tone?", type: .choice, options: [
                ChoiceOption(name: "calm"), ChoiceOption(name: "frustrated"), ChoiceOption(name: "angry"),
            ]),
            QuestionForm(instructions: "Does this message require urgent human attention?", type: .yesNo),
            QuestionForm(instructions: "How frustrated is the customer?", type: .rating, options: [
                ChoiceOption(name: "Calm"), ChoiceOption(name: "Frustrated"), ChoiceOption(name: "Very angry"),
            ]),
        ]
    )

    static let newsArticle = Preset(
        name: "News article",
        blurb: "Topic of an article plus derived yes/no questions.",
        state: "Wall St. Bears Claw Back Into the Black. Reuters - Short-sellers, Wall Street's dwindling band of ultra-cynics, are seeing green again after a rough quarter for the major indexes.",
        questions: [
            QuestionForm(instructions: "What is the topic of this article?", type: .choice, options: [
                ChoiceOption(name: "world", detail: "World news: politics, international affairs"),
                ChoiceOption(name: "sports", detail: "Sports: games, athletes, teams"),
                ChoiceOption(name: "business", detail: "Business: companies, markets, economy"),
                ChoiceOption(name: "scitech", detail: "Science and technology"),
            ]),
            QuestionForm(instructions: "Is this article about sports?", type: .yesNo),
            QuestionForm(instructions: "Is this article about business?", type: .yesNo, yesDetail: "Mentions companies, markets or the economy", noDetail: "Does not"),
        ]
    )

    static let reviewRating = Preset(
        name: "Review rating",
        blurb: "Ordered rating levels, sentiment, and a recommend yes/no.",
        state: "Decent food but we waited 45 minutes for a table we had reserved, and the server forgot our drinks twice. Probably won't be back.",
        questions: [
            QuestionForm(instructions: "How many stars did this reviewer give?", type: .rating, options: [
                ChoiceOption(name: "1 star: terrible experience"),
                ChoiceOption(name: "2 stars: poor"),
                ChoiceOption(name: "3 stars: average"),
                ChoiceOption(name: "4 stars: good"),
                ChoiceOption(name: "5 stars: excellent"),
            ]),
            QuestionForm(instructions: "Would this reviewer recommend the business?", type: .yesNo, yesDetail: "Clearly positive overall", noDetail: "Negative or mixed"),
            QuestionForm(instructions: "What is the sentiment of this review?", type: .rating, options: [
                ChoiceOption(name: "very negative"),
                ChoiceOption(name: "negative"),
                ChoiceOption(name: "neutral"),
                ChoiceOption(name: "positive"),
                ChoiceOption(name: "very positive"),
            ]),
        ]
    )
}
