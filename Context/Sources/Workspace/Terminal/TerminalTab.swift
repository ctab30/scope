import Foundation
import AppKit

/// Observable model representing a single terminal tab.
///
/// Each tab stores its display title and the directory in which its shell was
/// originally started.
class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String
    @Published var needsAttention: Bool = false
    let initialDirectory: String
    let initialCommand: String?
    var shellPid: pid_t = 0
    /// Weak reference to the backing terminal view, used to match bell notifications to tabs.
    weak var terminalView: NSView?

    init(title: String = "Terminal", initialDirectory: String, initialCommand: String? = nil) {
        self.title = title
        self.initialDirectory = initialDirectory
        self.initialCommand = initialCommand
    }
}
