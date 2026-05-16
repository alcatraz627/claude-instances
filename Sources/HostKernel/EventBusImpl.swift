import Foundation

/// Replaces the Phase-4 stub EventBus. Backed by NotificationCenter so
/// subscriber callbacks run on the main queue (matching the host's UI
/// expectations). Publish is fire-and-forget, non-blocking.
///
/// Topic namespace conventions (from architecture §5.1):
///   - `host.*`   — host-emitted lifecycle (startup, shutdown, tick.minute)
///   - `claude.*` — Claude session events (Phase 8+ wiring)
///   - `<plugin-id>.*` — plugin-published; only the publisher can emit
public final class EventBus: @unchecked Sendable {
    public struct Event: Sendable {
        public let topic: String
        public let payload: [String: AnyCodable]
        public let seq: UInt64
        public let ts: Date
    }

    public typealias Token = NSObjectProtocol

    private let nc = NotificationCenter()
    private let seqLock = NSLock()
    private var seq: UInt64 = 0

    public init() {}

    /// Emit an event. Returns immediately; subscriber callbacks fire on the
    /// main queue via NotificationCenter.
    public func publish(_ topic: String, _ payload: [String: AnyCodable] = [:]) {
        seqLock.lock()
        seq += 1
        let s = seq
        seqLock.unlock()
        let event = Event(topic: topic, payload: payload, seq: s, ts: Date())
        nc.post(name: Self.notifName(for: topic), object: event)
    }

    /// Subscribe to a topic. Returned token must be passed to `unsubscribe`
    /// (or retained for the lifetime of the subscription).
    @discardableResult
    public func subscribe(_ topic: String, handler: @escaping (Event) -> Void) -> Token {
        nc.addObserver(forName: Self.notifName(for: topic),
                       object: nil, queue: .main) { note in
            if let ev = note.object as? Event { handler(ev) }
        }
    }

    public func unsubscribe(_ token: Token) {
        nc.removeObserver(token)
    }

    private static func notifName(for topic: String) -> Notification.Name {
        Notification.Name("ci.bus.\(topic)")
    }
}

// MARK: - Standard host-emitted topics

public enum HostTopics {
    public static let startup       = "host.startup"
    public static let shutdown      = "host.shutdown"
    public static let tickMinute    = "host.tick.minute"
    public static let tickFiveSec   = "host.tick.5s"
    public static let appearChange  = "host.appearance.change"
    public static let pluginEnabled = "host.plugin.enabled"
    public static let pluginDisabled = "host.plugin.disabled"
}
