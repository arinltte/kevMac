//
//  AboutView.swift
//  kevMac
//
//  About pane: app icon, name, version, a "Check for Update" action that queries the
//  GitHub releases API, the live decision-engine card (Kev 1.0's /v1/models: backend,
//  dtype, temperature, serving limit, prefix-cache stats) with an Update Engine action,
//  and the theme picker.
//

import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var kevManager: KevManager
    @EnvironmentObject var setupManager: SetupManager

    @State private var state: UpdateState = .idle

    var body: some View {
        VStack(spacing: 0) {
            Text("About")
                .font(.system(size: 14, weight: .semibold))

            Spacer(minLength: 8)

            // From the compiled asset catalog — the bundle path's LaunchServices icon can be
            // a stale cached one for a rebuilt app, which made About show an old logo.
            Image(nsImage: aboutIcon)
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)

            Text("kevMac")
                .font(.system(size: 13, weight: .bold))
                .padding(.top, 10)

            Text("Version \(UpdateChecker.currentVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            updateControl
                .padding(.top, 10)

            Divider().opacity(0.5)
                .padding(.vertical, 10)

            engineSection

            Spacer(minLength: 8)

            Divider().opacity(0.5)

            HStack {
                Text("Theme")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: $appSettings.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .padding(.top, 10)

            VStack(spacing: 2) {
                Text("Developed by arinltte · arinltte00@gmail.com")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .tint(appSettings.appTheme.accentColor)
                Text("All inference runs locally on your Mac. Nothing leaves your machine.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .multilineTextAlignment(.center)
            .padding(.top, 8)
        }
        .padding(14)
        .frame(width: 300, height: 560)
    }

    // MARK: - Icon (the compiled asset catalog is the source of truth)

    private var aboutIcon: NSImage {
        NSImage(named: "AppIcon")
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    // MARK: - Decision engine (the live /v1/models card + update action)

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Decision engine")
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 3) {
                engineRow("Engine", value: setupManager.installedEngineStamp.map { "kev \($0.replacingOccurrences(of: "kev-", with: ""))" } ?? "pre-1.0 snapshot")

                if let info = kevManager.engineInfo {
                    engineRow("Serving", value: info.run ?? "—")
                    engineRow("Backend", value: "\(info.backend ?? "?") · \(info.dtype ?? "?")")
                    if let temperature = info.temperature {
                        engineRow("Temperature", value: String(format: "%.2f", temperature))
                    }
                    if let released = info.releaseDate {
                        engineRow("Released", value: released)
                    }
                    if let maxState = info.maxStateTokens {
                        engineRow("Document limit", value: "\(maxState) tokens")
                    }
                    if let cache = info.prefixCache {
                        engineRow("Prefix cache", value: "\(cache.cachedStates ?? 0) cached · \(cache.hits ?? 0) hits / \(cache.misses ?? 0) misses")
                    }
                } else if kevManager.isServerReady {
                    engineRow("Serving", value: "older engine — no live card")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            engineUpdateControl
        }
    }

    private func engineRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var engineUpdateControl: some View {
        if setupManager.isUpdatingEngine {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(setupManager.engineUpdateMessage ?? "Updating the engine…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
        } else if setupManager.needsEngineUpdate {
            VStack(spacing: 4) {
                Button {
                    kevManager.stopServer()
                    setupManager.updateEngine { _ in
                        kevManager.startServer(model: kevManager.currentModel)
                        kevManager.refreshStorageInfo()
                    }
                } label: {
                    Label("Update Engine (kev 1.0 — MLX)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                Text(setupManager.engineUpdateMessage ?? "Brings the MLX backend, 65,536-token documents and pinned weights.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            Text(setupManager.installedEngineStamp.map { "Engine up to date (\($0))." } ?? "Engine not installed yet.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - App update check

    @ViewBuilder
    private var updateControl: some View {
        switch state {
        case .idle:
            Button("Check for Update") {
                Task { await check() }
            }
            .controlSize(.small)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Text("You're up to date")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case let .available(version, url):
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Update Available (v\(version))", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        case .failed:
            Button("Check failed — Try again") {
                Task { await check() }
            }
            .controlSize(.small)
        }
    }

    private func check() async {
        state = .checking
        do {
            let release = try await UpdateChecker.latestRelease()
            if UpdateChecker.isNewer(release.tagName, than: UpdateChecker.currentVersion) {
                if let url = URL(string: release.htmlURL) {
                    state = .available(version: release.tagName, url: url)
                } else {
                    state = .failed
                }
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed
        }
    }
}

// MARK: - Update state

private enum UpdateState {
    case idle
    case checking
    case upToDate
    case available(version: String, url: URL)
    case failed
}

// MARK: - GitHub release check

enum UpdateChecker {
    /// Current app version, read from the bundle ("CFBundleShortVersionString").
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1"
    }

    static let owner = "arinltte"
    static let repo = "kevMac"

    struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    static func latestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("kevMac", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Compares two semantic-version strings (ignoring a leading "v").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    private static func components(_ s: String) -> [Int] {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t.split(separator: ".").map {
            Int($0.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}
