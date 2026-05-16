import Foundation

/// File-backed implementation of `HostLogger`. Each instance owns a single
/// log file at `<baseDir>/<source>.log`, ring-truncated when it exceeds
/// `maxBytes`. Writes are async on a dedicated dispatch queue.
public final class FileLogger: HostLogger, @unchecked Sendable {
    public let source: String        // "host" or plugin id
    public let logFileURL: URL
    private let maxBytes: Int
    private let queue: DispatchQueue
    private let isoFormatter: ISO8601DateFormatter

    public init(source: String, baseDir: URL, maxBytes: Int = 10 * 1024 * 1024) {
        self.source = source
        self.logFileURL = baseDir.appendingPathComponent("\(source).log")
        self.maxBytes = maxBytes
        self.queue = DispatchQueue(label: "ci.logger.\(source)", qos: .utility)
        self.isoFormatter = ISO8601DateFormatter()
        self.isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try? FileManager.default.createDirectory(
            at: baseDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
    }

    public func info (_ tag: String, _ msg: String) { write("INFO ", tag, msg) }
    public func warn (_ tag: String, _ msg: String) { write("WARN ", tag, msg) }
    public func error(_ tag: String, _ msg: String) { write("ERROR", tag, msg) }

    private func write(_ level: String, _ tag: String, _ msg: String) {
        let ts = isoFormatter.string(from: Date())
        let line = "[\(ts)] \(level) \(source):\(tag) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.append(data)
            self.maybeTruncate()
        }
    }

    private func append(_ data: Data) {
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    /// Ring-buffer policy: when the file exceeds `maxBytes`, keep the
    /// trailing 80% and drop the head. Cheap O(file-size) on each
    /// truncation; acceptable because truncation happens once per 10 MB.
    private func maybeTruncate() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxBytes else { return }
        guard let handle = try? FileHandle(forReadingFrom: logFileURL) else { return }
        let skip = UInt64(size.intValue / 5)   // drop first 20%
        try? handle.seek(toOffset: skip)
        let kept = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        try? kept.write(to: logFileURL, options: .atomic)
    }
}

/// Convenience: derive the standard logs directory under the host's
/// Application Support folder.
public enum HostLogPaths {
    public static var baseDir: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        .appendingPathComponent("dev.claude-instances-v2", isDirectory: true)
        .appendingPathComponent("logs", isDirectory: true)
    }

    public static var hostLog: URL { baseDir.appendingPathComponent("host.log") }

    public static func pluginLogDir() -> URL {
        let d = baseDir.appendingPathComponent("plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
