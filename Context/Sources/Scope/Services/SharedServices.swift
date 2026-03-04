import Foundation

/// Holds app-level services that should be shared across all windows.
@MainActor
final class SharedServices {
    static let shared = SharedServices()

    let appSettings: AppSettings
    let claudeService: ClaudeService

    private init() {
        self.appSettings = AppSettings()
        self.claudeService = ClaudeService()
    }
}
