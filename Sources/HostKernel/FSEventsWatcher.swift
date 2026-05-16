import Foundation
import CoreServices

/// Thin wrapper around macOS FSEvents. Watches a list of paths and invokes
/// `onChange` on the main queue when any of them (or their descendants)
/// change. Debounce is applied by FSEvents itself via the `latency` arg.
///
/// Lifetime contract: CoreServices is given a strong reference to this
/// watcher via the retain/release callbacks on FSEventStreamContext. The
/// watcher cannot be deallocated until `stop()` (or deinit) tears the
/// stream down, which releases the reference. This avoids the dangling-
/// pointer crash if a hosting view goes away mid-callback.
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

        // CoreServices keeps its own +1 retain via retainCb. We start with
        // passRetained (which gives us a +1 we own), then balance below.
        let retainCb: CFAllocatorRetainCallBack = { info -> UnsafeRawPointer? in
            guard let info else { return nil }
            _ = Unmanaged<FSEventsWatcher>.fromOpaque(info).retain()
            return info
        }
        let releaseCb: CFAllocatorReleaseCallBack = { info in
            guard let info else { return }
            Unmanaged<FSEventsWatcher>.fromOpaque(info).release()
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: retainCb,
            release: releaseCb,
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

        // Drop the extra +1 from passRetained. CoreServices retained its
        // own via retainCb above; releasing here just balances.
        Unmanaged.passUnretained(self).release()

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)   // triggers releaseCb internally
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
