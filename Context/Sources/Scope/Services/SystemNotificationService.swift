import Foundation
import UserNotifications
import Combine

@MainActor
class SystemNotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private var settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        requestAuthorization()
    }

    // MARK: - Authorization

    private func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else {
            print("SystemNotificationService: skipping — no bundle identifier")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("SystemNotificationService: auth error: \(error)")
            }
            print("SystemNotificationService: authorized=\(granted)")
        }
    }

    // MARK: - Observers

    func observeClaudeExitNotifications() {
        NotificationCenter.default.publisher(for: .claudeProcessDidExit)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.settings.notifyOnClaudeDone else { return }
                self.sendClaudeFinishedNotification()
            }
            .store(in: &cancellables)
    }

    func observeNeedsAttentionNotifications() {
        NotificationCenter.default.publisher(for: .tasksNeedAttention)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                let projectName = notification.userInfo?["projectName"] as? String
                self.sendNeedsAttentionNotification(projectName: projectName)
            }
            .store(in: &cancellables)
    }

    // MARK: - Send Notifications

    private func sendClaudeFinishedNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude Finished"
        content.body = "Claude Code session has completed"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "claudeDone-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func sendNeedsAttentionNotification(projectName: String?) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Needs Attention"
        content.body = projectName != nil
            ? "\(projectName!) has tasks waiting for your input"
            : "Tasks are waiting for your input"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "needsAttention-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
