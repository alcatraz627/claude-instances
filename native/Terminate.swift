import Foundation

/// When a process started, in seconds since 1970, from the kernel. nil if the
/// pid does not exist.
func processStartTime(_ pid: Int32) -> Double? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
}

/// Is this pid still the process the scan saw? A pid is reused once its process
/// exits, and the scan can be a minute old, so a bare pid can name a stranger.
func isSameProcess(_ pid: Int32, startedAt expected: Double?) -> Bool {
    guard let expected, let actual = processStartTime(pid) else { return false }
    return abs(actual - expected) <= 2
}

/// End sessions: SIGTERM now, SIGKILL after `grace` seconds for any still
/// running. Each signal goes only to a pid whose start time still matches what
/// the scan recorded. Returns the pids that were signalled; `done` runs after
/// the SIGKILL pass.
@discardableResult
func terminateSessions(_ targets: [(pid: Int32, startedAt: Double?)], grace: TimeInterval = 3,
                       done: (() -> Void)? = nil) -> [Int32] {
    let live = targets.filter { isSameProcess($0.pid, startedAt: $0.startedAt) }
    for t in live { kill(t.pid, SIGTERM) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
        for t in live where isSameProcess(t.pid, startedAt: t.startedAt) {
            kill(t.pid, SIGKILL)
        }
        done?()
    }
    return live.map(\.pid)
}
