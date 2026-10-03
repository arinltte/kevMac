import SwiftUI

struct MainView: View {
    @EnvironmentObject var kevManager: KevManager
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var setupManager: SetupManager

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
            kevManager.removeRetiredModelCachesIfNeeded()
            kevManager.refreshStorageInfo()
            launchEngine()
        }
        .onChange(of: appSettings.selectedModel) { _, newModel in
            // Switching models restarts the engine on the new selection
            kevManager.startServer(model: newModel)
        }
    }

    // MARK: - Engine launch (update first, then serve — pins need the kev-1.0 engine)

    private func launchEngine() {
        // Every install from before this release is frozen on a pre-1.0 engine snapshot:
        // no MLX backend, silent 8,192-token truncation, no @revision pins. Update it once
        // on launch — the pin the server passes is gated on the stamp, but the MLX speedup
        // and the honest 65,536-token limit need the update anyway.
        if setupManager.needsEngineUpdate {
            kevManager.stopServer()
            setupManager.updateEngine { _ in
                kevManager.startServer(model: appSettings.selectedModel)
            }
        } else {
            kevManager.startServer(model: appSettings.selectedModel)
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
                        Text(pickerLabel(for: model))
                    }
                    .help(pickerHelp(for: model))
                }
            }

            Section("Downloaded models") {
                let downloaded = kevManager.downloadedModels
                if downloaded.isEmpty {
                    Text("No model weights in the cache yet.")
                } else {
                    ForEach(downloaded) { model in
                        Button {
                            kevManager.removeDownloadedModel(model)
                        } label: {
                            Label(
                                "Remove \(model.displayName) — \(KevModel.formatBytes(kevManager.storage[model] ?? model.storageSize(inBaseDir: kevManager.baseDir)))",
                                systemImage: model == kevManager.currentModel ? "lock" : "trash"
                            )
                        }
                        .disabled(model == kevManager.currentModel)
                        .help(model == kevManager.currentModel
                              ? "This model is being served — switch models before removing it."
                              : "Remove the unused weights from ~/.kevMac/Cache to free disk space.")
                    }
                    Text("Removing a model you no longer use frees its disk space. Only the served model is protected.")
                        .font(.system(size: 10))
                }
            }

            Section {
                Text(pickerFooter)
                    .font(.system(size: 10))
            }
        } label: {
            Label("Model: \(appSettings.selectedModel.displayName)", systemImage: "cpu")
        }
        .help("Choose the decision model")
    }

    /// One row of the model list: download state, size, and the experimental/RAM notes.
    /// Every model is selectable — the big sizes are marked experimental instead of hidden,
    /// because they still load (weights map lazily) and a user with the RAM should have them.
    private func pickerLabel(for model: KevModel) -> String {
        var parts = [model.displayName]
        if model.isExperimental { parts.append("experimental") }
        let downloaded = model.isDownloaded(inBaseDir: kevManager.baseDir, pinned: kevManager.engineSupportsPins)
        parts.append(downloaded ? "downloaded" : "\(model.sizeHint) to download")
        if !model.fitsInRAM {
            parts.append("\(model.recommendedRAMGB)+ GB Mac recommended")
        }
        return parts.joined(separator: " — ")
    }

    private func pickerHelp(for model: KevModel) -> String {
        var help = "\(model.base.replacingOccurrences(of: "Qwen/", with: "")) · \(model.accuracyHint) · \(model.memoryHint)"
        if model.isExperimental {
            help += " — experimental: serving this size on a Mac is unmeasured upstream"
        }
        if !model.fitsInRAM {
            help += ". This Mac has \(KevModel.physicalRAMGB) GB: the model will load but serve very slowly by swapping"
        }
        return help
    }

    /// Live from the engine's /v1/models card when serving (the proof MLX is active), with
    /// the card's static hints as the fallback.
    private var pickerFooter: String {
        if let info = kevManager.engineInfo {
            var parts = ["\(info.run ?? appSettings.selectedModel.pinnedRun) · \(info.backend ?? "?") · \(info.dtype ?? "?")"]
            if let temperature = info.temperature { parts.append(String(format: "T %.2f", temperature)) }
            if let maxState = info.maxStateTokens { parts.append("≤\(maxState) tokens") }
            if let cache = info.prefixCache, (cache.hits ?? 0) + (cache.misses ?? 0) > 0 {
                parts.append("prefix cache: \(cache.hits ?? 0) hits")
            }
            parts.append("validated to \(appSettings.selectedModel.validatedContextTokens) tokens")
            return parts.joined(separator: " · ")
        }
        return "\(appSettings.selectedModel.displayName) — \(appSettings.selectedModel.base.replacingOccurrences(of: "Qwen/", with: "")) · \(appSettings.selectedModel.accuracyHint) · \(appSettings.selectedModel.memoryHint) · validated to \(appSettings.selectedModel.validatedContextTokens) tokens"
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

            // Kev 1.0 serves up to 65,536 tokens but only 27B's accuracy is validated that
            // far (the cards say the smaller sizes hold only to 8,192) — and a repeated
            // document hits the prefix cache, which is what makes "edit questions → Analyze
            // again" cheap.
            Text("Accuracy validated to \(appSettings.selectedModel.validatedContextTokens) tokens for \(appSettings.selectedModel.displayName). Re-analyzing the same document is ~5× faster (prefix cache).")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.8))
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
