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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.backgroundColor = .clear
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

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var liveMonitor: LiveSessionMonitor
    @EnvironmentObject var githubService: GitHubService
    @EnvironmentObject var contextEngine: ContextEngine
    @EnvironmentObject var devEnvironment: DevEnvironment
    @EnvironmentObject var projectAnalyzer: ProjectAnalyzer
    @EnvironmentObject var claudeService: ClaudeService

    func updateNSViewController(_ controller: SeamlessSplitVC2<Leading, Trailing>, context: Context) {
        let env = { (v: AnyView) -> AnyView in
            AnyView(v
                .environmentObject(self.appState)
                .environmentObject(self.settings)
                .environmentObject(self.liveMonitor)
                .environmentObject(self.githubService)
                .environmentObject(self.contextEngine)
                .environmentObject(self.devEnvironment)
                .environmentObject(self.projectAnalyzer)
                .environmentObject(self.claudeService))
        }
        controller.update(
            leading: env(AnyView(leading)),
            trailing: env(AnyView(trailing))
        )
    }
}

final class SeamlessSplitVC2<L: View, T: View>: NSViewController, NSSplitViewDelegate {
    private var leadingController: NSHostingController<AnyView>?
    private var trailingController: NSHostingController<AnyView>?
    private var didSetInitialPositions = false

    init(leading: L, trailing: T) {
        super.init(nibName: nil, bundle: nil)
        self.leadingController = NSHostingController(rootView: AnyView(leading))
        self.trailingController = NSHostingController(rootView: AnyView(trailing))
    }

    required init?(coder: NSCoder) { fatalError() }

    func update<LV: View, TV: View>(leading: LV, trailing: TV) {
        leadingController?.rootView = AnyView(leading)
        trailingController?.rootView = AnyView(trailing)
    }

    override func loadView() {
        let splitView = ClearDividerSplitView()
        splitView.isVertical = true
        splitView.delegate = self

        if let leadingController, let trailingController {
            addChild(leadingController)
            addChild(trailingController)
            
            leadingController.view.translatesAutoresizingMaskIntoConstraints = true
            leadingController.view.autoresizingMask = [.width, .height]
            trailingController.view.translatesAutoresizingMaskIntoConstraints = true
            trailingController.view.autoresizingMask = [.width, .height]
            
            splitView.addSubview(leadingController.view)
            splitView.addSubview(trailingController.view)
        }

        self.view = splitView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialPositions,
              let splitView = view as? NSSplitView,
              splitView.frame.width > 800 else { return } // Wait until mostly expanded
        
        didSetInitialPositions = true
        let mid = splitView.frame.width / 2
        splitView.setPosition(mid, ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, holdingPriorityForSubviewAt subviewIndex: Int) -> NSLayoutConstraint.Priority {
        return .defaultLow
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 350
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return splitView.frame.width - 350
    }
}

// MARK: - 2-Pane Vertical (Top/Bottom) Seamless Split View

struct SeamlessVSplitView2<Top: View, Bottom: View>: NSViewControllerRepresentable {
    let top: Top
    let bottom: Bottom

    init(@ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        self.top = top()
        self.bottom = bottom()
    }

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var liveMonitor: LiveSessionMonitor
    @EnvironmentObject var githubService: GitHubService
    @EnvironmentObject var contextEngine: ContextEngine
    @EnvironmentObject var devEnvironment: DevEnvironment
    @EnvironmentObject var projectAnalyzer: ProjectAnalyzer
    @EnvironmentObject var claudeService: ClaudeService

    func makeNSViewController(context: Context) -> SeamlessVSplitVC2<Top, Bottom> {
        SeamlessVSplitVC2(top: top, bottom: bottom)
    }

    func updateNSViewController(_ controller: SeamlessVSplitVC2<Top, Bottom>, context: Context) {
        let env = { (v: AnyView) -> AnyView in
            AnyView(v
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(liveMonitor)
                .environmentObject(githubService)
                .environmentObject(contextEngine)
                .environmentObject(devEnvironment)
                .environmentObject(projectAnalyzer)
                .environmentObject(claudeService))
        }
        controller.update(
            top: env(AnyView(top)),
            bottom: env(AnyView(bottom))
        )
    }
}

final class SeamlessVSplitVC2<T: View, B: View>: NSViewController, NSSplitViewDelegate {
    private var topController: NSHostingController<AnyView>?
    private var bottomController: NSHostingController<AnyView>?
    private var didSetInitialPositions = false

    init(top: T, bottom: B) {
        super.init(nibName: nil, bundle: nil)
        self.topController = NSHostingController(rootView: AnyView(top))
        self.bottomController = NSHostingController(rootView: AnyView(bottom))
    }

    required init?(coder: NSCoder) { fatalError() }

    func update<TV: View, BV: View>(top: TV, bottom: BV) {
        topController?.rootView = AnyView(top)
        bottomController?.rootView = AnyView(bottom)
    }

    override func loadView() {
        let splitView = ClearDividerSplitView()
        splitView.isVertical = false
        splitView.delegate = self

        if let topController, let bottomController {
            addChild(topController)
            addChild(bottomController)
            
            topController.view.translatesAutoresizingMaskIntoConstraints = true
            topController.view.autoresizingMask = [.width, .height]
            bottomController.view.translatesAutoresizingMaskIntoConstraints = true
            bottomController.view.autoresizingMask = [.width, .height]
            
            splitView.addSubview(topController.view)
            splitView.addSubview(bottomController.view)
        }

        self.view = splitView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialPositions,
              let splitView = view as? NSSplitView,
              splitView.frame.height > 600 else { return } // Wait until mostly open
        
        didSetInitialPositions = true
        let mid = splitView.frame.height / 2
        splitView.setPosition(mid, ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, holdingPriorityForSubviewAt subviewIndex: Int) -> NSLayoutConstraint.Priority {
        return .defaultLow
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 200
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return splitView.frame.height - 200
    }
}

// MARK: - 3-Pane Seamless Split View

struct SeamlessSplitView3<Leading: View, Center: View, Trailing: View>: NSViewControllerRepresentable {
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

    func makeNSViewController(context: Context) -> SeamlessSplitVC3<Leading, Center, Trailing> {
        SeamlessSplitVC3(leading: leading, center: center, trailing: trailing)
    }

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var liveMonitor: LiveSessionMonitor
    @EnvironmentObject var githubService: GitHubService
    @EnvironmentObject var contextEngine: ContextEngine
    @EnvironmentObject var devEnvironment: DevEnvironment
    @EnvironmentObject var projectAnalyzer: ProjectAnalyzer
    @EnvironmentObject var claudeService: ClaudeService

    func updateNSViewController(_ controller: SeamlessSplitVC3<Leading, Center, Trailing>, context: Context) {
        let env = { (v: AnyView) -> AnyView in
            AnyView(v
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(liveMonitor)
                .environmentObject(githubService)
                .environmentObject(contextEngine)
                .environmentObject(devEnvironment)
                .environmentObject(projectAnalyzer)
                .environmentObject(claudeService))
        }
        controller.update(
            leading: env(AnyView(leading)),
            center: env(AnyView(center)),
            trailing: env(AnyView(trailing))
        )
    }
}

final class SeamlessSplitVC3<L: View, C: View, T: View>: NSViewController, NSSplitViewDelegate {
    private var leadingController: NSHostingController<AnyView>?
    private var centerController: NSHostingController<AnyView>?
    private var trailingController: NSHostingController<AnyView>?
    private var didSetInitialPositions = false

    init(leading: L, center: C, trailing: T) {
        super.init(nibName: nil, bundle: nil)
        self.leadingController = NSHostingController(rootView: AnyView(leading))
        self.centerController = NSHostingController(rootView: AnyView(center))
        self.trailingController = NSHostingController(rootView: AnyView(trailing))
    }

    required init?(coder: NSCoder) { fatalError() }

    func update<LV: View, CV: View, TV: View>(leading: LV, center: CV, trailing: TV) {
        leadingController?.rootView = AnyView(leading)
        centerController?.rootView = AnyView(center)
        trailingController?.rootView = AnyView(trailing)
    }

    override func loadView() {
        let splitView = ClearDividerSplitView()
        splitView.isVertical = true
        splitView.delegate = self

        if let leadingController, let centerController, let trailingController {
            addChild(leadingController)
            addChild(centerController)
            addChild(trailingController)
            
            for controller in [leadingController, centerController, trailingController] {
                controller.view.translatesAutoresizingMaskIntoConstraints = true
                controller.view.autoresizingMask = [.width, .height]
                splitView.addSubview(controller.view)
            }
        }

        self.view = splitView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialPositions,
              let splitView = view as? NSSplitView,
              splitView.frame.width > 300 else { return }
        
        didSetInitialPositions = true
        let third = splitView.frame.width / 3
        splitView.setPosition(third, ofDividerAt: 0)
        splitView.setPosition(third * 2, ofDividerAt: 1)
    }

    func splitView(_ splitView: NSSplitView, holdingPriorityForSubviewAt subviewIndex: Int) -> NSLayoutConstraint.Priority {
        return .defaultLow
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 {
            // Terminal min width ~300
            return 300
        } else {
            // Center (task board) min width 300
            return splitView.subviews[0].frame.width + 300
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let width = splitView.frame.width
        if dividerIndex == 0 {
            // Leave room for center (300) + trailing (350)
            return width - 650
        } else {
            // Trailing panel min width 350
            return width - 350
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

// MARK: - Transparent Window Setter

/// Makes the window background transparent so .ultraThinMaterial shows through to the desktop.
/// Swaps to opaque background in fullscreen to avoid rendering issues.
struct TransparentWindowSetter: NSViewRepresentable {
    var title: String = "Workspace"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.title = title
        DispatchQueue.main.async {
            self.setupWindow(for: view, context: context)
        }
        // Retry logic in case window isn't ready immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.setupWindow(for: view, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.title = title
        if let window = nsView.window {
            window.title = title
        }
    }

    private func setupWindow(for view: NSView, context: Context) {
        guard let window = view.window else { return }
        Self.makeTransparent(window)
        window.title = title
        context.coordinator.observeFullScreen(window: window)
        context.coordinator.keepTitle(window: window)
    }

    private static func makeTransparent(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        // Add fullSizeContentView to styleMask if not present
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.hasShadow = true
    }

    final class Coordinator: NSObject {
        var title: String = ""
        private var observers: [NSObjectProtocol] = []
        private var titleObservation: NSKeyValueObservation?

        func keepTitle(window: NSWindow) {
            titleObservation = window.observe(\.title, options: [.new]) { [weak self] w, change in
                guard let self = self else { return }
                if let newTitle = change.newValue, newTitle != self.title {
                    DispatchQueue.main.async { w.title = self.title }
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

