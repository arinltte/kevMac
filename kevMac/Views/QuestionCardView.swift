import SwiftUI

struct QuestionCardView: View {
    @Binding var question: QuestionForm
    let issue: String?
    let canRemove: Bool
    let onRemove: () -> Void
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: type picker + remove
            HStack(spacing: 8) {
                Image(systemName: question.type.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(appSettings.appTheme.accentColor)
                Picker("", selection: $question.type) {
                    ForEach(QuestionType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)

                Spacer()

                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(!canRemove)
                .help(canRemove ? "Remove this question" : "At least one question is required")
            }

            // Instructions
            VStack(alignment: .leading, spacing: 4) {
                Text("Question")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $question.instructions)
                        .font(.system(size: 13))
                        .frame(height: 52)
                        .scrollContentBackground(.hidden)
                    if question.instructions.isEmpty {
                        Text("What should the model decide?")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            }

            // Type-specific editor
            switch question.type {
            case .yesNo: yesNoEditor
            case .choice: choiceEditor
            case .rating: ratingEditor
            }

            // Inline validation
            if let issue = issue {
                Label(issue, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .transition(.opacity)
            }
        }
        .cardBackground(appSettings.appTheme)
        .animation(.easeOut(duration: 0.2), value: question.type)
        .onChange(of: question.type) { _, newType in
            // Switching to a type that needs options: make sure the minimum is met
            if newType != .yesNo && question.options.count < 2 {
                question.options = [ChoiceOption(), ChoiceOption()]
            }
        }
    }

    // MARK: - Multiple choice

    private var choiceEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Options")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("The model scores each option")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            ForEach($question.options) { $option in
                optionRow($option)
            }

            addOptionButton(title: "Add Option", help: "Add another choice")
        }
    }

    private func optionRow(_ option: Binding<ChoiceOption>) -> some View {
        HStack(spacing: 8) {
            TextField("Name", text: option.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 140)

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 18)

            TextField("Description (optional)", text: option.detail)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            removeRowButton(id: option.wrappedValue.id, help: "Remove this option")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Rating

    private var ratingEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Levels (ordered)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("From worst to best")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            ForEach($question.options) { $option in
                levelRow($option)
            }

            addOptionButton(title: "Add Level", help: "Add another level")
        }
    }

    private func levelRow(_ option: Binding<ChoiceOption>) -> some View {
        HStack(spacing: 8) {
            if let index = question.options.firstIndex(where: { $0.id == option.wrappedValue.id }) {
                Text("\(index + 1).")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(appSettings.appTheme.accentColor)
                    .frame(width: 22, alignment: .trailing)
            }

            TextField("Level \(question.options.count)", text: option.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            removeRowButton(id: option.wrappedValue.id, help: "Remove this level")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Yes / No

    private var yesNoEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What the answers mean (optional)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.thumbsup.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    TextField("Yes means…", text: $question.yesDetail)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

                HStack(spacing: 6) {
                    Image(systemName: "hand.thumbsdown.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    TextField("No means…", text: $question.noDetail)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    // MARK: - Row helpers

    private func removeRowButton(id: UUID, help: String) -> some View {
        Button {
            guard let index = question.options.firstIndex(where: { $0.id == id }) else { return }
            // Removal is animated so the list reflows smoothly
            withAnimation(.easeOut(duration: 0.2)) { question.options.remove(at: index) }
        } label: {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(question.options.count <= 2)
        .help(help)
    }

    private func addOptionButton(title: String, help: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { question.options.append(ChoiceOption()) }
        } label: {
            Label(title, systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundColor(appSettings.appTheme.accentColor)
        .disabled(question.options.count >= 255)
        .help(help)
    }
}
