import Foundation

/// The host's typed representation of a plugin's `manifest.json`.
///
/// `Manifest` is the only file the host parses directly. Everything else
/// (panes, commands, events) flows through plugin code keyed by manifest
/// declarations. See `v2-architecture.md` §3.
public struct Manifest: Codable, Sendable, Equatable {
    public let manifestVersion: Int
    public let id: String
    public let name: String
    public let version: SemVerString
    public let description: String?
    public let engines: Engines
    public let icon: String?
    public let accent: String?
    public let capabilities: [String]?
    public let activation: [String]?
    public let requires: [String]?
    public let contributes: Contributes
    public let exec: Exec
    public let refresh: Refresh?
    public let limits: Limits?

    /// Where the manifest lives on disk. Set by the loader, not the decoder.
    public var pluginDir: URL?

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case id, name, version, description, engines, icon, accent
        case capabilities, activation, requires, contributes, exec, refresh, limits
    }
}

/// Wrapper that decodes a SemVer-shaped string. Keeps `Manifest.version` typed
/// without leaking the parser into every consumer.
public struct SemVerString: Codable, Sendable, Equatable, CustomStringConvertible {
    public let value: SemVer

    public init(_ value: SemVer) { self.value = value }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = SemVer(s) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "not a valid semver: \(s)")
        }
        self.value = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value.description)
    }

    public var description: String { value.description }
}

public struct Engines: Codable, Sendable, Equatable {
    public let claudeInstances: String      // semver range; parsed via SemVerRange

    enum CodingKeys: String, CodingKey {
        case claudeInstances = "claude-instances"
    }
}

public struct Exec: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case script, native, mixed
    }
    public let kind: Kind
    public let fetch: String?       // script: relative path to fetch executable
    public let action: String?      // script: relative path to actions executable
}

public struct Refresh: Codable, Sendable, Equatable {
    public let onFsChange: [String]?
    public let onEvent: [String]?
    public let pollSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case onFsChange  = "on_fs_change"
        case onEvent     = "on_event"
        case pollSeconds = "poll_seconds"
    }
}

public struct Limits: Codable, Sendable, Equatable {
    public let fetchTimeoutMs: Int?
    public let fetchHardKillMs: Int?
    public let fetchMaxPerMin: Int?
    public let maxPayloadBytes: Int?
    public let maxSubprocesses: Int?
    public let maxRssMb: Int?

    enum CodingKeys: String, CodingKey {
        case fetchTimeoutMs  = "fetch_timeout_ms"
        case fetchHardKillMs = "fetch_hard_kill_ms"
        case fetchMaxPerMin  = "fetch_max_per_min"
        case maxPayloadBytes = "max_payload_bytes"
        case maxSubprocesses = "max_subprocesses"
        case maxRssMb        = "max_rss_mb"
    }
}

/// Typed contribution payloads. CodingKeys use the dotted spelling from the
/// manifest spec (`dashboard.pane`, `event.subscriptions`). Unknown keys are
/// detected in a separate pass by the loader (see Registry); they do not
/// fail decoding.
public struct Contributes: Codable, Sendable, Equatable {
    public var commands: [Command]?
    public var dashboardPane: [DashboardPane]?
    public var settingsSection: [SettingsSection]?
    public var eventSubscriptions: [EventSubscription]?
    public var hotkey: [Hotkey]?
    public var menubarItem: [MenubarItem]?
    public var statusbarBadge: [StatusbarBadge]?
    public var quickAction: [QuickAction]?
    public var floater: [Floater]?
    public var notificationHandler: [NotificationHandler]?

    enum CodingKeys: String, CodingKey {
        case commands
        case dashboardPane       = "dashboard.pane"
        case settingsSection     = "settings.section"
        case eventSubscriptions  = "event.subscriptions"
        case hotkey
        case menubarItem         = "menubar.item"
        case statusbarBadge      = "statusbar.badge"
        case quickAction         = "quick-action"
        case floater
        case notificationHandler = "notification.handler"
    }
}

extension Manifest {
    /// Returns true if at least one contribution is present. Required by the
    /// schema; the loader rejects empty manifests with `manifest.invalid`.
    public var hasAnyContribution: Bool {
        let c = contributes
        if c.commands?.isEmpty == false { return true }
        if c.dashboardPane?.isEmpty == false { return true }
        if c.settingsSection?.isEmpty == false { return true }
        if c.eventSubscriptions?.isEmpty == false { return true }
        if c.hotkey?.isEmpty == false { return true }
        if c.menubarItem?.isEmpty == false { return true }
        if c.statusbarBadge?.isEmpty == false { return true }
        if c.quickAction?.isEmpty == false { return true }
        if c.floater?.isEmpty == false { return true }
        if c.notificationHandler?.isEmpty == false { return true }
        return false
    }
}
