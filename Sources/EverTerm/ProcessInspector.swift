import Darwin
import EverTermCore
import Foundation

/// Reads name and working directory of local processes (our own children only).
enum ProcessInspector {
    /// Short process name, e.g. "zsh", "ssh", "claude".
    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Current working directory of a process, e.g. the shell after `cd`.
    static func currentDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// #18: full command line of a process, e.g. ["ssh", "-p", "2222", "host"].
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcessArguments.parse(Array(buffer.prefix(size)))
    }

    /// #18: command lines of the other processes in a job: its process group, plus everything
    /// they started (a launcher may start its connect program in a new group). At most 64.
    static func otherArguments(inJob leader: pid_t) -> [[String]] {
        var seen: Set<pid_t> = [leader]
        var queue = pids(PROC_PGRP_ONLY, leader) + pids(PROC_PPID_ONLY, leader)
        var result: [[String]] = []
        while result.count < 64, let pid = queue.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if let argv = arguments(of: pid) { result.append(argv) }
            queue += pids(PROC_PPID_ONLY, pid)
        }
        return result
    }

    /// #18: what to type for a program path: its short name when that finds it on PATH,
    /// else the full path (e.g. a tool in a private folder, started by a launcher).
    static func typedName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        let onPath = dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
        return onPath ? name : path
    }

    private static func pids(_ type: Int32, _ value: pid_t) -> [pid_t] {
        let bytes = proc_listpids(UInt32(type), UInt32(value), nil, 0)
        guard bytes > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
        let filled = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(type), UInt32(value), raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// "/Users/me/Projects/x" -> "~/Projects/x"
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
