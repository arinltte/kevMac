import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var kevManager: KevManager?

    func applicationWillTerminate(_ aNotification: Notification) {
        kevManager?.stopServer()
        // Failsafe: ensure port 8009 is freed when the app quits
        let killTask = Process()
        killTask.launchPath = "/bin/sh"
        killTask.arguments = ["-c", "lsof -ti:8009 | xargs kill -9 2>/dev/null || true"]
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
                        kevManager.startServer()
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
