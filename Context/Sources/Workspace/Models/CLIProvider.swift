import SwiftUI

/// CLI provider for Claude Code integration.
/// Currently only Claude Code is supported.
enum CLIProvider: String, CaseIterable, Codable, Identifiable, Hashable {
    case claude

    var id: String { rawValue }

    var displayName: String { "Claude Code" }
    var shortName: String { "Claude" }
    var iconName: String { "c.circle.fill" }
    var color: Color { .white }
    var command: String { "claude" }
    var instructionFileName: String { "CLAUDE.md" }

    /// Cached installation status. Call `CLIProvider.refreshInstallationStatus()` to update.
    private static var _installed: Bool = false

    var isInstalled: Bool { Self._installed }

    /// Check if Claude Code is available on the system PATH.
    static func refreshInstallationStatus() async {
        let result = await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["claude"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !path.isEmpty && process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
        _installed = result
    }

    // MARK: - MCP Configuration

    enum ConfigScope {
        case projectRoot(String)
        case userHome(String)
    }

    var mcpConfigScope: ConfigScope {
        .projectRoot(".mcp.json")
    }
}
