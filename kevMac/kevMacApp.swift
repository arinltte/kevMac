import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var kevManager: KevManager?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Route SIGTERM (e.g. `kill` from Terminal) into the normal termination path so the
        // engine never outlives the app — a raw SIGTERM would otherwise skip
        // applicationWillTerminate entirely
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        kevManager?.stopServer()
        // Failsafe: ensure port 8009 is freed when the app quits — -sTCP:LISTEN targets only
        // the listening engine, not this app's own connections to it
        let killTask = Process()
        killTask.launchPath = "/bin/sh"
        killTask.arguments = ["-c", "lsof -ti:8009 -sTCP:LISTEN | xargs kill -9 2>/dev/null || true"]
        try? killTask.run()
    }
}

@main
struct kevMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var setupManager = SetupManager()
    @StateObject var kevManager = KevManager()
    @StateObject var appSettings = AppSettings()

    var body: some Scene {
        WindowGroup("kevMac") {
            #if arch(arm64)
            if setupManager.isSetupComplete {
                MainView()
                    .environmentObject(kevManager)
                    .environmentObject(appSettings)
                    .onAppear {
                        appDelegate.kevManager = kevManager
                        kevManager.startServer(model: appSettings.selectedModel)
                    }
            } else {
                SetupWizardView(setupManager: setupManager)
            }
            #else
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.red)
                Text("Unsupported Architecture")
                    .font(.title2.weight(.semibold))
                Text("kevMac requires an Apple Silicon (M1 or later) processor.")
                    .foregroundColor(.secondary)
            }
            .frame(width: 420, height: 280)
            #endif
        }
        .windowResizability(.contentSize)
    }
}
