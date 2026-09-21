import SwiftUI
import Combine

class AppSettings: ObservableObject {
    @Published var appTheme: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .default {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme") }
    }

    /// The selected kev model — persisted; the engine serves whichever model is chosen.
    @Published var selectedModel: KevModel = KevModel(rawValue: UserDefaults.standard.string(forKey: KevModel.storageKey) ?? "") ?? .defaultModel {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: KevModel.storageKey) }
    }
}
