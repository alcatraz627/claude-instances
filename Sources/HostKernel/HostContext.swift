import Foundation

/// Services the host provides to a plugin on activation. Read-only —
/// plugins consume; mutating goes through the bus or explicit host APIs.
///
/// All members are immutable references to types whose surface area the
/// host commits to keeping stable across same-major host versions.
public struct HostContext {
    public let settings: HostSettings
    public let logger: any HostLogger
    public let bus: EventBus
    public let pluginDir: URL?

    public init(settings: HostSettings, logger: any HostLogger,
                bus: EventBus, pluginDir: URL? = nil) {
        self.settings = settings
        self.logger = logger
        self.bus = bus
        self.pluginDir = pluginDir
    }
}

// MARK: - Logger

/// Minimal logger surface for plugins. Phase 6 will swap this for a
/// per-plugin tagged logger writing into the host's JSONL event stream.
public protocol HostLogger {
    func info (_ tag: String, _ msg: String)
    func warn (_ tag: String, _ msg: String)
    func error(_ tag: String, _ msg: String)
}

/// Phase-4 stub: writes to stdout. Phase 6 replaces this with the real
/// `HostLogger` that fans out to per-plugin log files + structured events.
public struct PrintLogger: HostLogger {
    public init() {}
    public func info (_ tag: String, _ msg: String) { print("[info  \(tag)] \(msg)") }
    public func warn (_ tag: String, _ msg: String) { print("[warn  \(tag)] \(msg)") }
    public func error(_ tag: String, _ msg: String) { print("[error \(tag)] \(msg)") }
}

// MARK: - Event bus (Phase-4 stub)

/// In-process typed topic broker. The Phase-4 implementation is a no-op
/// stub so plugins can be coded against the API today; Phase 6 fills in
/// the real publish/subscribe machinery.
public struct EventBus {
    public init() {}

    /// Plugin-side: emit an event under your plugin's id prefix.
    /// Stub no-op until Phase 6.
    public func publish(_ topic: String, _ payload: [String: AnyCodable] = [:]) {
        // intentionally empty
    }
}
