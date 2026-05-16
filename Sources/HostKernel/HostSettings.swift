import Foundation

/// User-controllable host preferences. Persisted to
/// `~/Library/Application Support/dev.claude-instances-v2/state.json`
/// under the top-level `"appearance"` key. Plugins consume a read-only
/// snapshot of this via `HostContext.settings` (Phase 4+); the host
/// rebroadcasts changes via the event bus topic `host.appearance.change`.
public struct HostSettings: Codable, Sendable, Equatable {
    public var appearance: Appearance
    public var plugins: [String: PluginState]
    /// Per-plugin user-set settings values, keyed by plugin id then by
    /// JSON-Schema property name. Each leaf is a JSON scalar held in
    /// AnyCodable so we can serialize back to state.json.
    public var pluginSettings: [String: [String: AnyCodable]]

    public init(appearance: Appearance = .init(),
                plugins: [String: PluginState] = [:],
                pluginSettings: [String: [String: AnyCodable]] = [:]) {
        self.appearance = appearance
        self.plugins = plugins
        self.pluginSettings = pluginSettings
    }

    /// Per-plugin user-controlled state. Absent = default enabled.
    public struct PluginState: Codable, Sendable, Equatable {
        public var enabled: Bool

        public init(enabled: Bool = true) {
            self.enabled = enabled
        }
    }

    /// True if the plugin is enabled (default true if no record exists).
    public func isPluginEnabled(_ id: String) -> Bool {
        plugins[id]?.enabled ?? true
    }

    public struct Appearance: Codable, Sendable, Equatable {
        public var colorScheme: ColorScheme
        public var textSize: TextSize
        public var density: Density

        public init(
            colorScheme: ColorScheme = .system,
            textSize: TextSize = .medium,
            density: Density = .comfortable
        ) {
            self.colorScheme = colorScheme
            self.textSize = textSize
            self.density = density
        }

        enum CodingKeys: String, CodingKey {
            case colorScheme = "color_scheme"
            case textSize    = "text_size"
            case density
        }
    }

    public enum ColorScheme: String, Codable, Sendable, CaseIterable {
        case system, light, dark
    }

    public enum TextSize: String, Codable, Sendable, CaseIterable {
        case extraSmall = "extra_small"
        case small
        case medium
        case large
        case extraLarge = "extra_large"

        /// Multiplier applied to every typography token. 1.0 = medium.
        /// Larger gaps at the high end so "L" / "XL" feel meaningfully
        /// bigger to users who want bigger UI.
        public var scale: Double {
            switch self {
            case .extraSmall: return 0.85
            case .small:      return 0.93
            case .medium:     return 1.00
            case .large:      return 1.22
            case .extraLarge: return 1.50
            }
        }
    }

    public enum Density: String, Codable, Sendable, CaseIterable {
        case compact, comfortable, spacious

        /// Multiplier applied to spacing tokens. 1.0 = comfortable.
        public var scale: Double {
            switch self {
            case .compact:    return 0.85
            case .comfortable: return 1.00
            case .spacious:   return 1.20
            }
        }
    }
}

/// Where host-managed state lives. The full state.json may carry more
/// top-level keys (per-plugin enabled flags, per-plugin settings) — this
/// type just covers the host's own preferences. Renamed from `HostSettingsStore`
/// to avoid shadowing the SwiftUI ObservableObject of the same role in HostShell.
public enum HostSettingsPersistence {
    /// Application Support directory for V2. Created on first write.
    public static var stateFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("dev.claude-instances-v2", isDirectory: true)
        return base.appendingPathComponent("state.json")
    }

    /// Load settings from disk. Returns defaults if the file is missing
    /// or malformed. Errors are swallowed deliberately — the host always
    /// boots, never refuses to start because state.json was bad.
    public static func load() -> HostSettings {
        guard let data = try? Data(contentsOf: stateFileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return HostSettings() }

        let appearance: HostSettings.Appearance
        if let appearanceDict = raw["appearance"] as? [String: Any],
           let appearanceData = try? JSONSerialization.data(withJSONObject: appearanceDict),
           let decoded = try? JSONDecoder().decode(HostSettings.Appearance.self, from: appearanceData) {
            appearance = decoded
        } else {
            appearance = .init()
        }

        var plugins: [String: HostSettings.PluginState] = [:]
        if let pluginsDict = raw["plugins"] as? [String: Any],
           let pluginsData = try? JSONSerialization.data(withJSONObject: pluginsDict),
           let decoded = try? JSONDecoder().decode([String: HostSettings.PluginState].self,
                                                    from: pluginsData) {
            plugins = decoded
        }

        var pluginSettings: [String: [String: AnyCodable]] = [:]
        if let ps = raw["plugin_settings"] as? [String: Any],
           let psData = try? JSONSerialization.data(withJSONObject: ps),
           let decoded = try? JSONDecoder().decode([String: [String: AnyCodable]].self,
                                                    from: psData) {
            pluginSettings = decoded
        }
        return HostSettings(appearance: appearance,
                            plugins: plugins,
                            pluginSettings: pluginSettings)
    }

    /// Persist under top-level keys "appearance" and "plugins". Preserves
    /// any other top-level keys already present in state.json (so future
    /// host extensions don't clobber user data).
    public static func save(_ settings: HostSettings) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stateFileURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: stateFileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        let appearanceData = try JSONEncoder().encode(settings.appearance)
        root["appearance"] = try JSONSerialization.jsonObject(with: appearanceData)

        let pluginsData = try JSONEncoder().encode(settings.plugins)
        root["plugins"] = try JSONSerialization.jsonObject(with: pluginsData)

        let psData = try JSONEncoder().encode(settings.pluginSettings)
        root["plugin_settings"] = try JSONSerialization.jsonObject(with: psData)

        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: stateFileURL, options: [.atomic])
    }
}
