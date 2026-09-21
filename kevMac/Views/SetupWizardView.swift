import SwiftUI
import AppKit

struct SetupWizardView: View {
    @ObservedObject var setupManager: SetupManager

    // Detects if the setup failed or requires user action (Wi-Fi, Homebrew, uv)
    private var hasError: Bool {
        let msg = setupManager.statusMessage
        return !setupManager.isInstalling && (msg.contains("failed") || msg.contains("required") || msg.contains("not found") || msg.contains("⚠️"))
    }

    private var buttonText: String { hasError ? "Retry Setup" : "Start Setup" }

    private var statusColor: Color {
        let msg = setupManager.statusMessage
        if msg.contains("⚠️") || msg.lowercased().contains("failed") { return .red }
        return .secondary
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 1. App mark
            if let nsImage = NSImage(named: "AppIcon") {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    .cornerRadius(24)
                    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 72, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 112, height: 112)
            }

            // 2. Title + subtitle
            VStack(spacing: 10) {
                Text("kevMac")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                Text("A local decision model for your Mac. Ask plain-text questions about any document and get calibrated answers — everything runs on your machine. This one-time setup installs everything into ~/.kevMac automatically.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .font(.title3)
                    .frame(maxWidth: 560)
            }

            // 3. What will be installed
            VStack(alignment: .leading, spacing: 10) {
                installRow(icon: "chevron.down.circle", title: "uv + Python 3.13", detail: "Managed inside ~/.kevMac — no system changes")
                installRow(icon: "cpu", title: "kev decision engine", detail: "LoRA adapter + pointer head on \(setupManager.selectedModel.base.replacingOccurrences(of: "Qwen/", with: ""))")
                installRow(icon: "arrow.down.circle", title: "\(setupManager.selectedModel.displayName) weights (\(setupManager.selectedModel.sizeHint))", detail: "Downloaded automatically — no button needed")
            }
            .padding(16)
            .frame(width: 470)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(12)

            Spacer()

            // 4. Status / action area
            VStack(spacing: 24) {
                if setupManager.isInstalling {
                    VStack(spacing: 16) {
                        ProgressView(value: setupManager.progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 450)

                        Text(setupManager.statusMessage)
                            .font(.callout)
                            .foregroundColor(statusColor)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 550, minHeight: 60)
                            .animation(.easeInOut(duration: 0.2), value: setupManager.statusMessage)
                    }
                } else {
                    VStack(spacing: 20) {
                        if hasError {
                            Text(setupManager.statusMessage)
                                .font(.callout)
                                .foregroundColor(statusColor)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 550, minHeight: 60)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(8)
                                .animation(.easeInOut(duration: 0.2), value: setupManager.statusMessage)
                        }

                        Button(action: { setupManager.runSetup() }) {
                            Text(buttonText)
                                .font(.headline)
                                .frame(width: 220, height: 20)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
            .frame(minHeight: 140) // Prevents UI jumping between button and progress

            Spacer()
        }
        .padding(48)
        .frame(minWidth: 900, minHeight: 600) // Matches MainView dimensions to prevent shrinking
    }

    private func installRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}
