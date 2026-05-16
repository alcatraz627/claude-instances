import Foundation
import CoreServices

/// Thin wrapper around macOS FSEvents. Watches a list of paths and invokes
/// `onChange` on the main queue when any of them (or their descendants)
/// change. Debounce is applied by FSEvents itself via the `latency` arg.
///
/// Plugin lifecycle: PaneHolder creates one watcher per plugin (covering all
/// the manifest's `refresh.on_fs_change` paths) and stops it when the
/// contribution becomes invisible.
public final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: @Sendable (Set<String>) -> Void
    private let latencySeconds: Double

    public init(paths: [String],
                latencySeconds: Double = 0.2,
                onChange: @escaping @Sendable (Set<String>) -> Void) {
        self.paths = paths
        self.latencySeconds = latencySeconds
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let firstN = Array(paths.prefix(count))
            watcher.onChange(Set(firstN))
        }

        let cfPaths = paths.map { ($0 as NSString).expandingTildeInPath } as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents)
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latencySeconds,
            flags
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
