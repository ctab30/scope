import SwiftUI
import AppKit

struct MainSplitView: View {
    @EnvironmentObject var appState: AppState
    @State private var projectPath: String = ""
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ProjectSidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
                .navigationTitle("Workspace")
        } detail: {
            SeamlessSplitView2 {
                TerminalTabView(projectPath: $projectPath, projectId: appState.currentProject?.id ?? "")
                    .padding(.leading, 12)
            } trailing: {
                GUIPanelView()
            }
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
        }
        .background(TransparentWindowSetter())
        .onChange(of: appState.currentProject) { _, project in
            if let project = project {
                projectPath = project.path
            }
        }
    }
}

// MARK: - NSSplitView subclass that draws nothing for dividers

final class ClearDividerSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { .clear }

    override func drawDivider(in rect: NSRect) {}
}

// MARK: - 2-Pane Seamless Split View

struct SeamlessSplitView2<Leading: View, Trailing: View>: NSViewControllerRepresentable {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    func makeNSViewController(context: Context) -> SeamlessSplitVC2<Leading, Trailing> {
        SeamlessSplitVC2(leading: leading, trailing: trailing)
    }

    func updateNSViewController(_ controller: SeamlessSplitVC2<Leading, Trailing>, context: Context) {}
}

final class SeamlessSplitVC2<L: View, T: View>: NSViewController, NSSplitViewDelegate {
    private let leadingContent: L
    private let trailingContent: T
    private var didSetInitialPositions = false

    init(leading: L, trailing: T) {
        self.leadingContent = leading
        self.trailingContent = trailing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let splitView = ClearDividerSplitView()
        splitView.isVertical = true
        splitView.delegate = self

        let leadingHost = NSHostingView(rootView: leadingContent)
        let trailingHost = NSHostingView(rootView: trailingContent)

        for host in [leadingHost, trailingHost] {
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
        }

        splitView.addSubview(leadingHost)
        splitView.addSubview(trailingHost)

        self.view = splitView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialPositions,
              let splitView = view as? NSSplitView,
              splitView.frame.width > 100 else { return }
        didSetInitialPositions = true
        // Start balanced — roughly equal split
        splitView.setPosition(splitView.frame.width / 2, ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Panel can't grow beyond 50/50 — divider stays at or right of center
        return splitView.frame.width / 2
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Panel min width 550
        return splitView.frame.width - 550
    }
}

// MARK: - Transparent Window Setter

/// Makes the window background transparent so .ultraThinMaterial shows through to the desktop.
/// Swaps to opaque background in fullscreen to avoid rendering issues.
struct TransparentWindowSetter: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            Self.makeTransparent(window)
            window.title = "Workspace"
            context.coordinator.observeFullScreen(window: window)
            context.coordinator.keepTitle(window: window, title: "Workspace")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func makeTransparent(_ window: NSWindow) {
        window.backgroundColor = .clear
        window.isOpaque = false
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }

    final class Coordinator: NSObject {
        private var observers: [NSObjectProtocol] = []

        private var titleObservation: NSKeyValueObservation?

        /// KVO on window.title — reset to "Workspace" whenever SwiftUI changes it
        func keepTitle(window: NSWindow, title: String) {
            titleObservation = window.observe(\.title, options: [.new]) { w, change in
                if let newTitle = change.newValue, newTitle != title {
                    DispatchQueue.main.async { w.title = title }
                }
            }
        }

        func observeFullScreen(window: NSWindow) {
            let nc = NotificationCenter.default
            // Entering fullscreen: restore normal titlebar before animation
            let willEnter = nc.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window, queue: .main
            ) { notification in
                guard let w = notification.object as? NSWindow else { return }
                w.titlebarAppearsTransparent = false
                w.titlebarSeparatorStyle = .automatic
            }
            // Before exit animation: set transparent early so animation is clean
            let willExit = nc.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: window, queue: .main
            ) { notification in
                guard let w = notification.object as? NSWindow else { return }
                TransparentWindowSetter.makeTransparent(w)
            }
            // After exit animation: safety re-apply in case macOS overrode during animation
            let didExit = nc.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window, queue: .main
            ) { notification in
                guard let w = notification.object as? NSWindow else { return }
                TransparentWindowSetter.makeTransparent(w)
            }
            observers = [willEnter, willExit, didExit]
        }

        deinit {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }
}

// MARK: - Window Configurator (for project windows only)

struct WindowConfigurator: NSViewRepresentable {
    var title: String? = nil
    typealias NSViewType = NSView

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if let title { window.title = title }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let title, let window = nsView.window {
                window.title = title
            }
        }
    }
}
