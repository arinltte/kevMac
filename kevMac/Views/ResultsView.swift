import SwiftUI
import AppKit

struct ResultsView: View {
    @EnvironmentObject var kevManager: KevManager
    @EnvironmentObject var appSettings: AppSettings

    let questions: [QuestionForm]
    let canAnalyze: Bool
    let onAnalyze: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: analyze + engine status
            VStack(spacing: 12) {
                Button(action: onAnalyze) {
                    HStack(spacing: 6) {
                        if kevManager.isAnalyzing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(kevManager.isAnalyzing ? "Analyzing…" : "Analyze")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canAnalyze || kevManager.isAnalyzing || !kevManager.isServerReady)
                .animation(.easeOut(duration: 0.2), value: kevManager.isAnalyzing)

                statusPill
            }
            .padding(20)

            Divider().opacity(0.5)

            // Results
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = kevManager.errorMessage {
                        errorBanner(error)
                    }

                    let answered = questions.filter { kevManager.results[$0.id.uuidString] != nil }
                    if answered.isEmpty && kevManager.errorMessage == nil {
                        emptyState
                    } else {
                        ForEach(answered) { question in
                            ResultCard(
                                question: question,
                                answer: kevManager.results[question.id.uuidString]!
                            )
                        }

                        if !answered.isEmpty {
                            resultsFooter(answered)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(kevManager.isAnalyzing ? 0.5 : 1)
                .animation(.easeOut(duration: 0.25), value: kevManager.isAnalyzing)
            }
        }
    }

    // MARK: - Engine status

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if !kevManager.isServerReady && kevManager.errorMessage == nil {
                ProgressView()
                    .controlSize(.mini)
            }
            if kevManager.errorMessage != nil && kevManager.isServerReady == false {
                Button("Restart Engine") { kevManager.startServer() }
                    .font(.system(size: 10))
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: kevManager.isServerReady)
    }

    private var statusText: String {
        if kevManager.errorMessage != nil && !kevManager.isServerReady { return "Engine error" }
        if !kevManager.isServerReady { return "Starting the decision engine…" }
        if kevManager.isWarmingUp { return "Warming up…" }
        return "Engine ready"
    }

    private var statusColor: Color {
        if kevManager.errorMessage != nil && !kevManager.isServerReady { return .red }
        if kevManager.isServerReady && !kevManager.isWarmingUp { return .green }
        return .orange
    }

    // MARK: - States

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.3), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Decisions appear here")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Edit the document and questions on the left, then press Analyze (⌘↵).")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func resultsFooter(_ answered: [QuestionForm]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)
            HStack {
                if let latency = kevManager.lastLatencyMS, let usage = kevManager.lastUsage {
                    Text("\(Int(latency)) ms · \(usage.inputTokens) in / \(usage.outputTokens) out tokens")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
                Button {
                    copyReport(answered)
                } label: {
                    Label(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(copied ? .green : appSettings.appTheme.accentColor)
            }
        }
        .animation(.easeOut(duration: 0.2), value: copied)
    }

    private func copyReport(_ answered: [QuestionForm]) {
        var lines = ["kevMac — Decisions"]
        if !kevManager.analyzedState.isEmpty {
            lines.append("")
            lines.append("Message: \(kevManager.analyzedState)")
        }
        lines.append("")
        for question in answered {
            if let answer = kevManager.results[question.id.uuidString] {
                lines.append("• \(AnswerPresenter.summaryLine(question: question, answer: answer))")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Result card (JSON answer → normal text, with animated indication)

struct ResultCard: View {
    let question: QuestionForm
    let answer: Answer
    @EnvironmentObject var appSettings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.instructions)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AnswerPresenter.headline(question: question, answer: answer))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundColor(appSettings.appTheme.accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let caption = AnswerPresenter.caption(question: question, answer: answer) {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(AnswerPresenter.barRows(question: question, answer: answer).enumerated()), id: \.offset) { _, row in
                    ProbabilityBarRow(
                        label: row.label,
                        value: row.value,
                        isWinner: row.isWinner,
                        accent: appSettings.appTheme.accentColor
                    )
                }
            }
        }
        .cardBackground(appSettings.appTheme, padding: 14)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 14)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) { appeared = true }
            }
        }
    }
}

struct ProbabilityBarRow: View {
    let label: String
    let value: Double
    let isWinner: Bool
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: isWinner ? .semibold : .regular))
                .foregroundColor(isWinner ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 108, alignment: .leading)
                .help(label)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(isWinner ? accent : Color.primary.opacity(0.28))
                        .frame(width: min(geo.size.width, max(3, geo.size.width * value)))
                }
            }
            .frame(height: 6)

            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 11, weight: isWinner ? .semibold : .regular).monospacedDigit())
                .foregroundColor(isWinner ? accent : .secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .animation(barAnimation, value: value)
    }

    // Critically damped spring (no overshoot) — animates from the current on-screen
    // width on re-target, so re-analyzed results never jump
    private var barAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 1.0)
    }
}
