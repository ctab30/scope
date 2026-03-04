import Foundation

class AppSettings: ObservableObject {
    @Published var autoSnapshotSessions: Bool {
        didSet { UserDefaults.standard.set(autoSnapshotSessions, forKey: "autoSnapshotSessions") }
    }
    @Published var autoUpdateCodebaseTree: Bool {
        didSet { UserDefaults.standard.set(autoUpdateCodebaseTree, forKey: "autoUpdateCodebaseTree") }
    }
    @Published var mcpServerAutoStart: Bool {
        didSet { UserDefaults.standard.set(mcpServerAutoStart, forKey: "mcpServerAutoStart") }
    }
    @Published var instructionInjection: Bool {
        didSet { UserDefaults.standard.set(instructionInjection, forKey: "claudeMDInjection") }
    }
    @Published var snapshotDebounce: Double {
        didSet { UserDefaults.standard.set(snapshotDebounce, forKey: "snapshotDebounce") }
    }
    @Published var terminalFontSize: Double {
        didSet { UserDefaults.standard.set(terminalFontSize, forKey: "terminalFontSize") }
    }
    @Published var scrollbackLines: Int {
        didSet { UserDefaults.standard.set(scrollbackLines, forKey: "scrollbackLines") }
    }
    @Published var contextSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(contextSearchEnabled, forKey: "contextSearchEnabled") }
    }
    @Published var embeddingModel: String {
        didSet { UserDefaults.standard.set(embeddingModel, forKey: "embeddingModel") }
    }
    @Published var preferredCLI: CLIProvider {
        didSet { UserDefaults.standard.set(preferredCLI.rawValue, forKey: "preferredCLI") }
    }

    // Notifications
    @Published var notifyOnClaudeDone: Bool {
        didSet { UserDefaults.standard.set(notifyOnClaudeDone, forKey: "notifyOnClaudeDone") }
    }

    // Browser
    @Published var browserAllowedDomains: [String] {
        didSet { UserDefaults.standard.set(browserAllowedDomains, forKey: "browserAllowedDomains") }
    }
    @Published var networkBodyLimit: Int {
        didSet { UserDefaults.standard.set(networkBodyLimit, forKey: "networkBodyLimit") }
    }

    // Demo Mode
    @Published var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: "demoMode")
            DemoContent.shared.clearCache()
        }
    }

    // Updates
    @Published var checkForUpdates: Bool {
        didSet { UserDefaults.standard.set(checkForUpdates, forKey: "checkForUpdates") }
    }
    @Published var githubRepo: String {
        didSet { UserDefaults.standard.set(githubRepo, forKey: "githubRepo") }
    }

    init() {
        let defaults = UserDefaults.standard
        self.autoSnapshotSessions = defaults.object(forKey: "autoSnapshotSessions") as? Bool ?? true
        self.autoUpdateCodebaseTree = defaults.object(forKey: "autoUpdateCodebaseTree") as? Bool ?? true
        self.mcpServerAutoStart = defaults.object(forKey: "mcpServerAutoStart") as? Bool ?? true
        self.instructionInjection = defaults.object(forKey: "claudeMDInjection") as? Bool ?? true
        self.snapshotDebounce = defaults.object(forKey: "snapshotDebounce") as? Double ?? 30.0
        self.terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13.0
        self.scrollbackLines = defaults.object(forKey: "scrollbackLines") as? Int ?? 10000
        self.contextSearchEnabled = defaults.object(forKey: "contextSearchEnabled") as? Bool ?? true
        self.embeddingModel = defaults.string(forKey: "embeddingModel") ?? "openai/text-embedding-3-small"
        self.preferredCLI = CLIProvider(rawValue: defaults.string(forKey: "preferredCLI") ?? "") ?? .claude

        self.notifyOnClaudeDone = defaults.object(forKey: "notifyOnClaudeDone") as? Bool ?? true

        self.browserAllowedDomains = defaults.stringArray(forKey: "browserAllowedDomains") ?? []
        self.networkBodyLimit = defaults.object(forKey: "networkBodyLimit") as? Int ?? 51200

        self.demoMode = defaults.object(forKey: "demoMode") as? Bool ?? false
        self.checkForUpdates = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        self.githubRepo = defaults.string(forKey: "githubRepo") ?? "ctab30/scope"
    }
}
