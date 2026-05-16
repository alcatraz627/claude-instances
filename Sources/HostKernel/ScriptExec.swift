import Foundation

/// Result of one script-plugin fetch.
public struct ScriptExecResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String
    public let elapsedMs: Int
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: Data, stderr: String,
                elapsedMs: Int, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.elapsedMs = elapsedMs
        self.timedOut = timedOut
    }
}

/// Runs a plugin's `fetch.sh` (or `actions.sh`) with budget enforcement.
/// Process is spawned on a background queue; stdout is captured fully;
/// stderr is captured to a tail for error pane disclosure.
public enum ScriptExec {

    /// Invoke `executable args...` with `cwd` and environment, enforcing
    /// `timeoutMs` (SIGTERM at deadline, SIGKILL 1s later if still alive)
    /// and `maxPayloadBytes` (truncates stdout at the cap).
    public static func run(
        executable: URL,
        args: [String],
        cwd: URL,
        env: [String: String] = [:],
        timeoutMs: Int = 5000,
        maxPayloadBytes: Int = 262_144   // 256 KB default; matches limits spec
    ) async throws -> ScriptExecResult {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args
        proc.currentDirectoryURL = cwd

        // Inherit the user's environment + plugin-specific overrides.
        var fullEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { fullEnv[k] = v }
        proc.environment = fullEnv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        let started = Date()
        try proc.run()

        // Timeout watchdog: sleeps the budget, then SIGTERMs (with 1s grace
        // before SIGKILL). We *don't* await its completion — we detect
        // whether it fired by checking terminationReason after waitUntilExit.
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            if Task.isCancelled { return }
            proc.terminate()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }

        // Drain stdout fully (with payload cap). `availableData` blocks
        // until at least one byte is available, OR returns empty on EOF
        // (pipe closed = child exited and let go of its end).
        var stdoutBuffer = Data()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        while true {
            let chunk = stdoutHandle.availableData
            if chunk.isEmpty { break }
            if stdoutBuffer.count + chunk.count > maxPayloadBytes {
                let remain = maxPayloadBytes - stdoutBuffer.count
                if remain > 0 { stdoutBuffer.append(chunk.prefix(remain)) }
                // Keep draining so the child doesn't block on a full pipe;
                // discard the overflow bytes.
                while !stdoutHandle.availableData.isEmpty {}
                break
            }
            stdoutBuffer.append(chunk)
        }

        proc.waitUntilExit()
        // Now cancel the watchdog (no-op if it already fired). We detect
        // "timed out" via terminationReason — `.uncaughtSignal` means the
        // process died from SIGTERM/SIGKILL, which is what our watchdog
        // sends.
        timeoutTask.cancel()
        let timedOut = (proc.terminationReason == .uncaughtSignal)

        let stderrData = try? stderrPipe.fileHandleForReading.readToEnd()
        let stderrString = (stderrData.flatMap { String(data: $0, encoding: .utf8) }) ?? ""
        let stderrTail = String(stderrString.suffix(2_000))

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        return ScriptExecResult(
            exitCode: proc.terminationStatus,
            stdout: stdoutBuffer,
            stderr: stderrTail,
            elapsedMs: elapsedMs,
            timedOut: timedOut
        )
    }
}
