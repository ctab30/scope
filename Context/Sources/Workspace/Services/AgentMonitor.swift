import Foundation
import Combine

/// Monitors the process tree under a shell PID to detect running Claude Code agents.
///
/// Claude Code spawns background agents (Task tool) as child processes:
///   zsh (shell) → node …/claude (main) → node …/claude (agent 1), node …/claude (agent 2)
///
/// Polls `ps` every 3 seconds to detect and track these agents.
class AgentMonitor: ObservableObject {

    struct AgentInfo: Identifiable, Equatable {
        let id: Int          // PID
        let parentPid: Int
        let elapsed: String  // ps etime: [[dd-]hh:]mm:ss
        let command: String  // readable short name
        let depth: Int       // depth in tree from shell (1 = direct child)

        /// Elapsed time in seconds.
        var elapsedSeconds: Int {
            // etime: "ss", "mm:ss", "hh:mm:ss", "dd-hh:mm:ss"
            let normalized = elapsed.replacingOccurrences(of: "-", with: ":")
            let parts = normalized.split(separator: ":").compactMap { Int($0) }
            switch parts.count {
            case 1: return parts[0]
            case 2: return parts[0] * 60 + parts[1]
            case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
            case 4: return parts[0] * 86400 + parts[1] * 3600 + parts[2] * 60 + parts[3]
            default: return 0
            }
        }

        var isPotentiallyFrozen: Bool { elapsedSeconds > 180 }

        var formattedElapsed: String {
            let s = elapsedSeconds
            if s < 60 { return "\(s)s" }
            if s < 3600 { return "\(s / 60)m \(s % 60)s" }
            return "\(s / 3600)h \((s % 3600) / 60)m"
        }
    }

    @Published var agents: [AgentInfo] = []       // background agents (children of main claude)
    @Published var claudeProcess: AgentInfo? = nil // the main claude process
    @Published var isMonitoring = false

    private var timer: Timer?
    private var shellPid: pid_t = 0

    func start(shellPid: pid_t) {
        guard shellPid > 0 else { return }
        // Stop any existing polling before restarting
        timer?.invalidate()
        self.shellPid = shellPid
        isMonitoring = true
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        DispatchQueue.main.async {
            self.agents = []
            self.claudeProcess = nil
        }
    }

    // MARK: - Polling

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, self.shellPid > 0 else { return }
            let (claude, agents) = self.scan()
            DispatchQueue.main.async {
                let wasRunning = self.claudeProcess != nil
                self.claudeProcess = claude
                self.agents = agents

                // Detect claude process exit: was running, now gone
                if wasRunning && claude == nil {
                    NotificationCenter.default.post(name: .claudeProcessDidExit, object: nil)
                }
            }
        }
    }

    // MARK: - Process Tree Scanner

    private struct ProcRecord {
        let pid: Int
        let ppid: Int
        let etime: String
        let command: String
    }

    private func scan() -> (claude: AgentInfo?, agents: [AgentInfo]) {
        let records = fetchProcesses()
        guard !records.isEmpty else { return (nil, []) }

        // Build parent → children map
        var childrenOf: [Int: [Int]] = [:]
        var procMap: [Int: ProcRecord] = [:]
        for r in records {
            procMap[r.pid] = r
            childrenOf[r.ppid, default: []].append(r.pid)
        }

        // BFS from shell to find all descendants with their depth
        var descendantDepth: [Int: Int] = [:] // pid → depth from shell
        var queue: [(Int, Int)] = [(Int(shellPid), 0)]
        while !queue.isEmpty {
            let (pid, depth) = queue.removeFirst()
            for child in childrenOf[pid] ?? [] {
                guard descendantDepth[child] == nil else { continue }
                descendantDepth[child] = depth + 1
                queue.append((child, depth + 1))
            }
        }

        // Find claude processes among descendants
        var claudeDescs: [(ProcRecord, Int)] = [] // (record, depth)
        for (pid, depth) in descendantDepth {
            guard let proc = procMap[pid] else { continue }
            if isClaude(proc.command) {
                claudeDescs.append((proc, depth))
            }
        }

        guard !claudeDescs.isEmpty else { return (nil, []) }

        // Main claude = shallowest depth
        claudeDescs.sort { $0.1 < $1.1 }
        let main = claudeDescs[0]

        let claudeInfo = AgentInfo(
            id: main.0.pid,
            parentPid: main.0.ppid,
            elapsed: main.0.etime,
            command: "Claude Code",
            depth: main.1
        )

        // Agents = all other claude processes that are descendants of the main claude
        let mainPid = main.0.pid
        var agentInfos: [AgentInfo] = []

        for (proc, depth) in claudeDescs.dropFirst() {
            // Walk up from proc to see if mainPid is an ancestor
            var cursor = proc.ppid
            var isChild = false
            for _ in 0..<10 { // max 10 hops
                if cursor == mainPid { isChild = true; break }
                guard let parent = procMap[cursor] else { break }
                cursor = parent.ppid
            }
            if isChild {
                agentInfos.append(AgentInfo(
                    id: proc.pid,
                    parentPid: proc.ppid,
                    elapsed: proc.etime,
                    command: "Agent",
                    depth: depth
                ))
            }
        }

        return (claudeInfo, agentInfos)
    }

    private func fetchProcesses() -> [ProcRecord] {
        // Use sysctl to read the process table directly — no child process spawning.
        // This avoids the zombie process accumulation that Process()/ps caused.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size: Int = 0

        // First call: get buffer size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        // Second call: fill buffer
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else {
            return []
        }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        let now = Date()
        var records: [ProcRecord] = []

        for i in 0..<actualCount {
            let info = procs[i]
            let pid = Int(info.kp_proc.p_pid)
            let ppid = Int(info.kp_eproc.e_ppid)

            // Calculate elapsed time from start time
            let startSec = info.kp_proc.p_starttime.tv_sec
            let startDate = Date(timeIntervalSince1970: TimeInterval(startSec))
            let elapsed = Int(now.timeIntervalSince(startDate))
            let etime = formatEtime(elapsed)

            // p_comm is only 16 chars (e.g. "node"). For node processes that might
            // be Claude Code, we need the full command-line args via KERN_PROCARGS2
            // to check for "@anthropic", "claude-code", etc.
            let comm = withUnsafePointer(to: info.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 16) { cStr in
                    String(cString: cStr)
                }
            }

            // Only fetch full args for "node" processes (Claude Code runs as node)
            let fullCommand: String
            if comm == "node" {
                fullCommand = Self.getProcessArgs(pid: Int32(pid)) ?? comm
            } else {
                fullCommand = comm
            }

            records.append(ProcRecord(pid: pid, ppid: ppid, etime: etime, command: fullCommand))
        }

        return records
    }

    /// Read the full command-line arguments for a process using KERN_PROCARGS2.
    /// Returns the executable path + args joined by spaces, or nil on failure.
    private static func getProcessArgs(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0

        // Get buffer size
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // KERN_PROCARGS2 layout: [argc: Int32] [exec_path\0] [padding\0...] [arg0\0] [arg1\0] ...
        guard size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var offset = MemoryLayout<Int32>.size

        // Skip the exec_path (null-terminated string)
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // Skip trailing nulls after exec_path
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // Read argc arguments
        var args: [String] = []
        for _ in 0..<argc {
            guard offset < size else { break }
            let start = offset
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if let arg = String(bytes: buffer[start..<offset], encoding: .utf8) {
                args.append(arg)
            }
            offset += 1 // skip null terminator
        }

        return args.joined(separator: " ")
    }

    /// Format seconds into ps-style etime string.
    private func formatEtime(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let m = s / 60
        let h = m / 60
        if h > 0 {
            return "\(h):\(String(format: "%02d", m % 60)):\(String(format: "%02d", s % 60))"
        }
        return "\(m):\(String(format: "%02d", s % 60))"
    }

    private func isClaude(_ command: String) -> Bool {
        command.contains("claude") && (
            command.contains("@anthropic") ||
            command.contains("claude-code") ||
            command.contains("/claude ") ||
            command.hasSuffix("/claude")
        )
    }
}
