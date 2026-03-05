import Foundation
import AppKit
import Combine

@MainActor
class SystemNotificationService: NSObject, ObservableObject {
    private var settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    // MARK: - Observers

    func observeClaudeExitNotifications() {
        NotificationCenter.default.publisher(for: .claudeProcessDidExit)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.settings.notifyOnClaudeDone else { return }
                self.sendNotification(title: "Claude Finished", body: "Claude Code session has completed")
            }
            .store(in: &cancellables)
    }

    func observeNeedsAttentionNotifications() {
        NotificationCenter.default.publisher(for: .tasksNeedAttention)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                let projectName = notification.userInfo?["projectName"] as? String
                let body = projectName != nil
                    ? "\(projectName!) has tasks waiting for your input"
                    : "Tasks are waiting for your input"
                self.sendNotification(title: "Needs Attention", body: body)
            }
            .store(in: &cancellables)
    }

    /// Poll for notification request files written by ScopeMCP hook binary.
    func observeHookNotifications() {
        let notifyDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Scope/notifications", isDirectory: true)
        try? FileManager.default.createDirectory(at: notifyDir, withIntermediateDirectories: true)

        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: notifyDir, includingPropertiesForKeys: nil
                ) else { return }
                for file in files where file.pathExtension == "json" {
                    if let data = try? Data(contentsOf: file),
                       let info = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                        let title = info["title"] ?? "Needs Attention"
                        let body = info["body"] ?? ""
                        let subtitle = info["subtitle"]
                        self.sendNotification(title: title, body: body, subtitle: subtitle)
                    }
                    try? FileManager.default.removeItem(at: file)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Send Notification

    private func sendNotification(title: String, body: String, subtitle: String? = nil) {
        // Use osascript to display notification — works without Developer ID signing.
        // AppleScript uses double quotes; escape any in the text.
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        if let subtitle, !subtitle.isEmpty {
            script += " subtitle \"\(esc(subtitle))\""
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()

        // Also refresh task views
        NotificationCenter.default.post(name: .tasksDidChange, object: nil)
    }
}
