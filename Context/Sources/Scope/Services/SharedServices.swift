import Foundation

/// Holds app-level services that should be shared across all windows.
///
/// `ProjectWindowView` previously created fresh instances of `AppSettings`,
/// `BriefingService`, and `ClaudeService` for every project window. These are
/// app-level (not project-specific) and waste memory when duplicated.
@MainActor
final class SharedServices {
    static let shared = SharedServices()

    let appSettings: AppSettings
    let briefingService: BriefingService
    let claudeService: ClaudeService

    private init() {
        // These are created once and reused across all project windows.
        // The main ContextApp window also creates its own instances via @StateObject,
        // but project windows now share these instead of making duplicates.
        self.appSettings = AppSettings()
        self.briefingService = BriefingService()
        self.claudeService = ClaudeService()
    }
}
