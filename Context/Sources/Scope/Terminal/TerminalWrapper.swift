import SwiftUI
import SwiftTerm
import AppKit

// MARK: - Focusable Terminal Subclass

/// Subclass that claims keyboard focus via AppKit lifecycle hooks,
/// adds file drag-and-drop (inserts path as text), and Cmd+V image paste.
final class FocusableTerminalView: LocalProcessTerminalView {

    /// Whether this terminal is the currently visible/active tab.
    /// Guards focus-claiming so hidden terminals in a ZStack don't steal input.
    var isActiveTab: Bool = true

    /// Fired once when the frame settles at a non-zero size (no changes for 150ms).
    var onFrameStabilized: (() -> Void)?
    private var frameDebounceWork: DispatchWorkItem?
    private var didFireFrameStabilized = false

    /// Allow transparency so the window's vibrancy material shows through.
    override var isOpaque: Bool { false }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        // Register for file drag-and-drop (matches Terminal.app / iTerm2)
        registerForDraggedTypes([.fileURL])

        guard isActiveTab else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActiveTab else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: - Safe Layout Guards

    override func getWindowSize() -> winsize {
        let f = self.frame
        let w = max(1, min(f.width, 65535))
        let h = max(1, min(f.height, 65535))
        let cols = max(1, min(terminal.cols, Int(UInt16.max)))
        let rows = max(1, min(terminal.rows, Int(UInt16.max)))
        return winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: UInt16(w),
            ws_ypixel: UInt16(h)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize.width > 0 && newSize.height > 0 else { return }
        super.setFrameSize(newSize)

        // Debounce: fire onFrameStabilized once the frame stops changing
        guard !didFireFrameStabilized, onFrameStabilized != nil else { return }
        frameDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.didFireFrameStabilized else { return }
            self.didFireFrameStabilized = true
            self.onFrameStabilized?()
            self.onFrameStabilized = nil
        }
        frameDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - File Drag-and-Drop (NSDraggingDestination)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return false
        }

        // Insert each file path as text, space-separated (matches Terminal.app)
        let paths = urls.map { escapedPath($0.path) }
        let text = paths.joined(separator: " ")
        send(txt: text)
        return true
    }

    /// Shell-escape a file path (wrap in single quotes, escape inner quotes).
    private func escapedPath(_ path: String) -> String {
        if path.rangeOfCharacter(from: .init(charactersIn: " '\"\\()&|;<>$!#")) != nil {
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return path
    }

    // MARK: - Cmd+V Image Paste

    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general

        // Check for image data on the clipboard (e.g. screenshots via Cmd+Shift+4)
        if let imgData = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
            if let path = saveClipboardImage(imgData) {
                send(txt: escapedPath(path))
                return
            }
        }

        // Fall through to normal text paste
        super.paste(sender)
    }

    /// Save clipboard image data to a temp file and return the path.
    private func saveClipboardImage(_ data: Data) -> String? {
        // Convert TIFF to PNG for smaller file and broader compatibility
        guard let rep = NSBitmapImageRep(data: data),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        let fileName = "clipboard-\(Int(Date().timeIntervalSince1970)).png"
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scope-paste", isDirectory: true)

        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileURL = tempDir.appendingPathComponent(fileName)
        do {
            try pngData.write(to: fileURL)
            return fileURL.path
        } catch {
            return nil
        }
    }
}

// MARK: - SwiftUI Wrapper

struct TerminalWrapper: NSViewRepresentable {
    typealias NSViewType = FocusableTerminalView

    let initialDirectory: String
    let initialCommand: String?
    let isActive: Bool
    @Binding var sendCommand: String?
    var onShellStarted: ((pid_t) -> Void)?

    // MARK: - Coordinator

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var parent: TerminalWrapper
        weak var terminalView: FocusableTerminalView?
        var mouseMonitor: Any?
        var pendingCommand: String?

        init(_ parent: TerminalWrapper) {
            self.parent = parent
        }

        deinit {
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        // MARK: LocalProcessTerminalViewDelegate

        func processTerminated(source: TerminalView, exitCode: Int32?) {}
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        // MARK: Focus monitor

        /// Re-claim focus when clicking the terminal after SwiftUI
        /// steals it (e.g. user clicked a GUI button then clicks back).
        func installClickFocusMonitor(for terminal: FocusableTerminalView) {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak terminal] event in
                guard let terminal = terminal,
                      terminal.isActiveTab,
                      let window = terminal.window,
                      event.window === window else {
                    return event
                }
                let location = terminal.convert(event.locationInWindow, from: nil)
                if terminal.bounds.contains(location) {
                    DispatchQueue.main.async {
                        window.makeFirstResponder(terminal)
                    }
                }
                return event
            }
        }

        // MARK: Shell management

        func startShell(in directory: String?) {
            guard let terminalView else { return }
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            // Remove Claude Code nesting guard so `claude` can be launched
            // from the embedded terminal without "nested session" errors.
            env.removeValue(forKey: "CLAUDECODE")
            env.removeValue(forKey: "CLAUDE_CODE")
            let envStrings = env.map { "\($0.key)=\($0.value)" }

            // Use "-zsh" as execName for proper login shell convention.
            let execName = "-" + URL(fileURLWithPath: shell).lastPathComponent

            terminalView.startProcess(
                executable: shell,
                args: [],
                environment: envStrings,
                execName: execName,
                currentDirectory: directory?.isEmpty == false ? directory : nil
            )

            // Report the shell PID so the agent monitor can track child processes
            let pid = terminalView.process.shellPid
            if pid > 0 {
                parent.onShellStarted?(pid)
            }
        }

        func sendText(_ text: String) {
            terminalView?.send(txt: text)
        }

        /// Send the pending initial command, then nudge the terminal frame
        /// so SwiftTerm updates the PTY winsize via ioctl — the kernel then
        /// delivers SIGWINCH to Claude Code's actual foreground process group.
        func sendPendingCommand() {
            guard let command = pendingCommand else { return }
            pendingCommand = nil

            // Small delay for shell prompt readiness after frame stabilization
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let tv = self.terminalView else { return }
                self.sendText(command + "\n")

                // After Claude Code has started, nudge the frame to trigger a
                // real PTY resize (ioctl TIOCSWINSZ → kernel SIGWINCH).
                for delay in [1.5, 3.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tv] in
                        guard let tv else { return }
                        let size = tv.frame.size
                        guard size.width > 1 else { return }
                        tv.setFrameSize(NSSize(width: size.width - 1, height: size.height))
                        tv.setFrameSize(size)
                    }
                }
            }
        }
    }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: NSViewRepresentableContext<TerminalWrapper>) -> FocusableTerminalView {
        let terminal = FocusableTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeForegroundColor = .white

        terminal.processDelegate = context.coordinator
        context.coordinator.terminalView = terminal

        context.coordinator.startShell(in: initialDirectory)
        context.coordinator.installClickFocusMonitor(for: terminal)
        TerminalTracker.shared.register(terminal)

        // Wait for the terminal frame to stabilize (NSSplitView divider
        // positioning) before sending the initial command so Claude Code
        // reads the correct $COLUMNS at launch.
        if let command = initialCommand, !command.isEmpty {
            context.coordinator.pendingCommand = command
            terminal.onFrameStabilized = { [weak coordinator = context.coordinator] in
                coordinator?.sendPendingCommand()
            }
        }

        return terminal
    }

    func updateNSView(_ nsView: FocusableTerminalView, context: NSViewRepresentableContext<TerminalWrapper>) {
        let wasActive = nsView.isActiveTab
        nsView.isActiveTab = isActive

        // Claim focus when this tab becomes active
        if isActive && !wasActive, let window = nsView.window {
            DispatchQueue.main.async {
                window.makeFirstResponder(nsView)
            }
        }

        if let command = sendCommand {
            context.coordinator.sendText(command + "\n")
            DispatchQueue.main.async {
                sendCommand = nil
            }
        }
    }
}
