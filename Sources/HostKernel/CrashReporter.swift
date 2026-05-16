import Foundation

/// Catches Swift/ObjC exceptions and POSIX signals that would otherwise
/// crash the process silently. Writes a one-line summary to `crash.log`
/// in the host log directory so the next session can read it via
/// PlatformRegistry on bootstrap.
///
/// Signal handlers must be **async-signal-safe** — no Foundation, no
/// Logger, no String formatting via the runtime. We use `write(2)`
/// directly with pre-formatted byte buffers.
public enum CrashReporter {
    nonisolated(unsafe) private static var crashLogPath: String = ""

    public static func install(logger: HostLogger) {
        // Pre-compute the crash log path as a UTF-8 buffer that signal
        // handlers can write without runtime allocation.
        let url = HostLogPaths.baseDir.appendingPathComponent("crash.log")
        crashLogPath = url.path
        try? FileManager.default.createDirectory(
            at: HostLogPaths.baseDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: crashLogPath) {
            FileManager.default.createFile(atPath: crashLogPath, contents: nil)
        }

        // Uncaught Obj-C/Swift exceptions. Safe to use Foundation here
        // because the runtime is still alive when this fires.
        NSSetUncaughtExceptionHandler { exception in
            let line = "[\(Self.timestamp())] CRASH NSException name=\(exception.name.rawValue) reason=\(exception.reason ?? "(no reason)")"
            CrashReporter.writeRaw(line)
            CrashReporter.writeRaw("Stack: " + exception.callStackSymbols.joined(separator: " | "))
            // Don't continue; the process is in an undefined state.
        }

        // POSIX signals. Re-raise SIGDFL after logging so the system
        // crash reporter still kicks in (and macOS writes a .ips diagnostic).
        let fatal: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE]
        for sig in fatal {
            signal(sig) { signum in
                CrashReporter.signalSafeWrite(signum: signum)
                signal(signum, SIG_DFL)
                kill(getpid(), signum)
            }
        }

        logger.info("crash-reporter", "installed (NSException + 5 signals)")
    }

    /// Append a line to crash.log via Foundation (safe in exception handlers).
    private static func writeRaw(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: crashLogPath) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    /// async-signal-safe: pure write(2). The path was captured as a
    /// C string before any signal fires.
    private static func signalSafeWrite(signum: Int32) {
        let prefix = "[CRASH signal=\(signum) pid=\(getpid())]\n"
        let bytes = Array(prefix.utf8)
        let fd = open(crashLogPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = bytes.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }
        close(fd)
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Read + clear the crash log from the previous session. Called on
    /// host startup; the host logs any pre-existing crash entries to
    /// host.log so they show up in chronological order alongside the
    /// new session's events.
    @discardableResult
    public static func consumePrevious() -> String? {
        let path = HostLogPaths.baseDir.appendingPathComponent("crash.log").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty,
              let s = String(data: data, encoding: .utf8) else { return nil }
        // Truncate after reading.
        try? Data().write(to: URL(fileURLWithPath: path), options: .atomic)
        return s
    }
}
