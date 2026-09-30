import Foundation

// Compiled with native/ProcessRun.swift alone. Prints how many bytes came back
// from a program that writes 256 KB, four times the pipe buffer. The test
// wraps this in a hard timeout: a helper that waits before reading never returns.
let r = try runCollecting("/bin/bash", ["-c", "head -c 262144 /dev/zero | tr '\\0' x; echo warn >&2"])
print("\(r.out.count):\(String(data: r.err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""):\(r.status)")
