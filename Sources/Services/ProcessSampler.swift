import AppKit
import Darwin

/// One app (or standalone process) and the CPU it used during the last sample window.
struct AppUsage: Identifiable, Equatable {
    /// Stable grouping key: bundle identifier, executable path, or process name.
    let id: String
    let name: String
    /// The process to quit for this group (the owning app's main pid).
    let pid: pid_t
    let bundleID: String?
    /// Percent of one core (100 = one full core).
    var cpu: Double
    /// Owned by another user (e.g. root); shown as informational only.
    let isSystem: Bool
}

/// Reads cumulative CPU time for every readable process with `proc_pid_rusage` and converts the
/// deltas between two calls into a percentage of one core, grouping helper processes under their app.
final class ProcessSampler {
    private struct Previous { let cpuNs: UInt64; let start: UInt64 }

    private var previous: [pid_t: Previous] = [:]
    private var lastSample: UInt64 = 0
    private let numer: UInt64
    private let denom: UInt64
    private let myUID = getuid()
    /// Processes younger than this are ignored to avoid launch spikes.
    private let minimumAgeNs: UInt64 = 10_000_000_000

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(max(tb.numer, 1))
        denom = UInt64(max(tb.denom, 1))
    }

    /// Forget the baseline so the next sample only primes it (used after sleep).
    func reset() {
        previous = [:]
        lastSample = 0
    }

    /// Mach ticks to nanoseconds (rusage times are reported in Mach ticks on Apple Silicon).
    private func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks.multipliedReportingOverflow(by: numer).partialValue / denom
    }

    /// Returns per-app usage, or nil when this call only established a baseline.
    func sample() -> [AppUsage]? {
        let now = mach_absolute_time()
        let wallNs = lastSample == 0 ? 0 : nanoseconds(now &- lastSample)
        lastSample = now

        let running = NSWorkspace.shared.runningApplications
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in running { appsByPID[app.processIdentifier] = app }
        // Outermost bundles first, so nested helper .apps resolve to the main app.
        let bundles: [(path: String, app: NSRunningApplication)] = running.compactMap { app in
            guard app.activationPolicy == .regular, let path = app.bundleURL?.path else { return nil }
            return (path + "/", app)
        }.sorted { $0.path.count < $1.path.count }

        var groups: [String: AppUsage] = [:]
        var next: [pid_t: Previous] = [:]

        for pid in Self.allPIDs() where pid > 0 {
            guard let info = Self.rusage(pid) else { continue }
            let cpuNs = nanoseconds(info.ri_user_time &+ info.ri_system_time)
            let start = info.ri_proc_start_abstime
            next[pid] = Previous(cpuNs: cpuNs, start: start)

            guard wallNs > 0, let prev = previous[pid], prev.start == start, cpuNs >= prev.cpuNs,
                  now > start, nanoseconds(now - start) >= minimumAgeNs else { continue }
            let cpu = Double(cpuNs - prev.cpuNs) / Double(wallNs) * 100

            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let hasBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size
            let path = Self.path(pid)

            // Resolve the owning app: itself, the bundle it lives in, or its app parent.
            var owner = appsByPID[pid].flatMap { $0.activationPolicy == .regular ? $0 : nil }
            if owner == nil, let path { owner = bundles.first { path.hasPrefix($0.path) }?.app }
            if owner == nil, hasBSD, appsByPID[pid] != nil,
               let parent = appsByPID[pid_t(bsd.pbi_ppid)], parent.activationPolicy == .regular {
                owner = parent
            }

            let key: String
            let usage: AppUsage
            if let owner {
                key = owner.bundleIdentifier ?? "pid:\(owner.processIdentifier)"
                usage = AppUsage(id: key, name: owner.localizedName ?? "App \(owner.processIdentifier)",
                                 pid: owner.processIdentifier, bundleID: owner.bundleIdentifier,
                                 cpu: cpu, isSystem: false)
            } else {
                let name = appsByPID[pid]?.localizedName ?? Self.name(pid)
                key = appsByPID[pid]?.bundleIdentifier ?? path ?? name
                usage = AppUsage(id: key, name: name, pid: pid, bundleID: appsByPID[pid]?.bundleIdentifier,
                                 cpu: cpu, isSystem: hasBSD && bsd.pbi_uid != myUID)
            }
            if groups[key] != nil { groups[key]?.cpu += cpu } else { groups[key] = usage }
        }

        previous = next
        return wallNs > 0 ? Array(groups.values) : nil
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)))
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? info : nil
    }

    private static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func name(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "Process \(pid)" }
        return String(cString: buffer)
    }
}
