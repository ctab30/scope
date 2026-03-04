import SwiftUI
import AppKit

struct MainSplitView: View {
    @EnvironmentObject var appState: AppState
    @State private var projectPath: String = ""

    var body: some View {
        SeamlessSplitView {
            ProjectSidebarView()
        } center: {
            TerminalTabView(projectPath: $projectPath, projectId: appState.currentProject?.id ?? "")
        } trailing: {
            GUIPanelView()
        }
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
        .background(WindowConfigurator())
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

    override func drawDivider(in rect: NSRect) {
        // Draw nothing — completely invisible dividers
    }
}

// MARK: - 3-Pane Seamless Split View

struct SeamlessSplitView<Leading: View, Center: View, Trailing: View>: NSViewControllerRepresentable {
    let leading: Leading
    let center: Center
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    func makeNSViewController(context: Context) -> SeamlessSplitVC<Leading, Center, Trailing> {
        SeamlessSplitVC(leading: leading, center: center, trailing: trailing)
    }

    func updateNSViewController(_ controller: SeamlessSplitVC<Leading, Center, Trailing>, context: Context) {}
}

final class SeamlessSplitVC<L: View, C: View, T: View>: NSViewController, NSSplitViewDelegate {
    private let leadingContent: L
    private let centerContent: C
    private let trailingContent: T
    private var didSetInitialPositions = false

    init(leading: L, center: C, trailing: T) {
        self.leadingContent = leading
        self.centerContent = center
        self.trailingContent = trailing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let splitView = ClearDividerSplitView()
        splitView.isVertical = true
        splitView.delegate = self

        let leadingHost = NSHostingView(rootView: leadingContent)
        let centerHost = NSHostingView(rootView: centerContent)
        let trailingHost = NSHostingView(rootView: trailingContent)

        for host in [leadingHost, centerHost, trailingHost] {
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
        }

        splitView.addSubview(leadingHost)
        splitView.addSubview(centerHost)
        splitView.addSubview(trailingHost)

        self.view = splitView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialPositions,
              let splitView = view as? NSSplitView,
              splitView.frame.width > 100 else { return }
        didSetInitialPositions = true
        splitView.setPosition(200, ofDividerAt: 0)
        splitView.setPosition(650, ofDividerAt: 1)
    }

    // MARK: - Resize constraints

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 { return 180 }  // sidebar min
        if dividerIndex == 1 { return 580 }  // terminal min (sidebar + terminal 400)
        return proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 { return 220 }  // sidebar max
        if dividerIndex == 1 { return splitView.frame.width - 500 }  // GUI panel min 500
        return proposedMaximumPosition
    }
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
        splitView.setPosition(splitView.frame.width / 2, ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 450  // terminal min
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return splitView.frame.width - 450  // GUI panel min
    }
}

// MARK: - Window Configurator

/// Configures the hosting NSWindow for a seamless title-bar appearance.
struct WindowConfigurator: NSViewRepresentable {
    var title: String? = nil

    typealias NSViewType = NSView

    func makeNSView(context: NSViewRepresentableContext<WindowConfigurator>) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = .clear
            window.isOpaque = false
            window.styleMask.insert(.fullSizeContentView)
            if window.toolbar == nil {
                window.toolbar = NSToolbar()
            }
            window.toolbar?.showsBaselineSeparator = false
            window.titlebarSeparatorStyle = .none
            if let title {
                window.title = title
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: NSViewRepresentableContext<WindowConfigurator>) {
        DispatchQueue.main.async {
            if let title, let window = nsView.window {
                window.title = title
            }
        }
    }
}
