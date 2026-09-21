import SwiftUI

struct MainView: View {
    @EnvironmentObject var kevManager: KevManager
    @EnvironmentObject var appSettings: AppSettings

    @State private var stateText: String = ""
    @State private var questions: [QuestionForm] = []
    @State private var showAbout = false

    // Live validation — inline, not only on submit
    private var validation: FormIssues {
        KevFormBuilder.validate(state: stateText, questions: questions)
    }

    var body: some View {
        ZStack {
            AmbientThemeBackground(theme: appSettings.appTheme)
                .ignoresSafeArea()

            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 0) {
                    editorPane
                        .frame(width: geometry.size.width * 0.62, height: geometry.size.height)

                    Divider().opacity(0.5)

                    ResultsView(
                        questions: questions,
                        canAnalyze: validation.isValid,
                        onAnalyze: runAnalysis
                    )
                    .frame(width: geometry.size.width * 0.38, height: geometry.size.height)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                modelPicker

                Menu {
                    ForEach(Preset.all) { preset in
                        Button(preset.name) { loadPreset(preset) }
                    }
                } label: {
                    Label("Examples", systemImage: "square.grid.2x2")
                }
                .help("Load an example from the kev playground")

                Button {
                    showAbout.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("About kevMac")
                .popover(isPresented: $showAbout, arrowEdge: .bottom) { AboutView() }
            }
        }
        .onAppear {
            // Show the common path first: prefill with the playground's support-triage example
            if questions.isEmpty {
                loadPreset(Preset.supportTriage)
            }
            kevManager.startServer(model: appSettings.selectedModel)
        }
        .onChange(of: appSettings.selectedModel) { _, newModel in
            // Switching models restarts the engine on the new selection
            kevManager.startServer(model: newModel)
        }
    }

    // MARK: - Model picker

    private var modelPicker: some View {
        Menu {
            Section("Supported models") {
                ForEach(KevModel.allCases) { model in
                    Button {
                        appSettings.selectedModel = model
                    } label: {
                        // Already-downloaded models say so; the rest show the download size
                        Text("\(model.displayName) — \(model.isDownloaded(inBaseDir: kevManager.baseDir) ? "downloaded" : model.sizeHint + " to download")")
                    }
                }
            }
            Section {
                Text("\(appSettings.selectedModel.displayName) — \(appSettings.selectedModel.base.replacingOccurrences(of: "Qwen/", with: "")) · \(appSettings.selectedModel.accuracyHint) · serves in \(appSettings.selectedModel.needsBF16 ? "bf16" : "fp32") · \(appSettings.selectedModel.memoryHint)")
                    .font(.system(size: 10))
            }
        } label: {
            Label("Model: \(appSettings.selectedModel.displayName)", systemImage: "cpu")
        }
        .help("Choose the decision model")
    }

    // MARK: - Editor pane

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stateEditor

                HStack {
                    Label("Questions", systemImage: "questionmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(questions.count) question\(questions.count == 1 ? "" : "s")")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }

                ForEach($questions) { $question in
                    QuestionCardView(
                        question: $question,
                        issue: validation.perQuestion[question.id],
                        canRemove: questions.count > 1,
                        onRemove: {
                            guard let index = questions.firstIndex(where: { $0.id == question.id }) else { return }
                            withAnimation(.easeOut(duration: 0.2)) { questions.remove(at: index) }
                        }
                    )
                }

                addButton
            }
            .padding(20)
        }
    }

    private var stateEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Document", systemImage: "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if validation.stateEmpty {
                    Text("Required")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .transition(.opacity)
                }
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { stateText = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Clear the document")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $stateText)
                    .font(.system(size: 13))
                    .frame(height: 110)
                    .scrollContentBackground(.hidden)
                if stateText.isEmpty {
                    Text("Paste the customer message or document to evaluate…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .cardBackground(appSettings.appTheme)
    }

    private var addButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                questions.append(QuestionForm(instructions: "", type: .choice, options: [ChoiceOption(), ChoiceOption()]))
            }
        } label: {
            Label("Add Question", systemImage: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - Actions

    private func loadPreset(_ preset: Preset) {
        withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
            stateText = preset.state
            questions = preset.questions
        }
    }

    private func runAnalysis() {
        let issues = KevFormBuilder.validate(state: stateText, questions: questions)
        guard issues.isValid, let body = KevFormBuilder.buildRequestBody(state: stateText, questions: questions) else {
            return
        }
        kevManager.analyze(body: body)
    }
}
