import SwiftUI
import Combine

class AppSettings: ObservableObject {
    @Published var appTheme: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .default {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme") }
    }
}
