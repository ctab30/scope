import Foundation

/// Writes/removes the active task ID file that hook scripts read
/// to know which task to move to needs_attention.
/// File location: ~/Library/Application Support/Workspace/active-tasks/{projectId}
enum ActiveTaskTracker {
    private static var activeTasksDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Workspace/active-tasks", isDirectory: true)
    }

    static func track(taskId: Int64, projectId: String) {
        let dir = activeTasksDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(projectId)
        try? "\(taskId)".write(to: file, atomically: true, encoding: .utf8)
    }

    static func untrack(projectId: String) {
        let file = activeTasksDir.appendingPathComponent(projectId)
        try? FileManager.default.removeItem(at: file)
    }
}
