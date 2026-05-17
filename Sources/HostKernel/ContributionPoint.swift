import Foundation

/// Closed enum of every place a plugin can attach. New contribution points
/// require a host change — plugins cannot invent them. Phase 2 ships only
/// declarations: actual routing is wired in surface-specific phases.
public enum ContributionPoint: String, CaseIterable, Sendable {
    case commands             = "commands"
    case dashboardPane        = "dashboard.pane"
    case settingsSection      = "settings.section"
    case eventSubscriptions   = "event.subscriptions"
    case hotkey               = "hotkey"
    case menubarItem          = "menubar.item"
    case statusbarBadge       = "statusbar.badge"
    case quickAction          = "quick-action"
    case floater              = "floater"
    case notificationHandler  = "notification.handler"

    /// Surfaces marked stubbed are valid in manifests but the host warns
    /// (not errors) and does not render them in V1 of V2.
    public var isShipped: Bool {
        switch self {
        case .commands, .dashboardPane, .settingsSection,
             .eventSubscriptions, .hotkey,
             .menubarItem, .statusbarBadge:    // Phase 12
            return true
        case .quickAction, .floater, .notificationHandler:
            return false
        }
    }
}

// MARK: - Command

/// Argv-style command. `argv` items pass through `Process` directly; the host
/// never shell-interprets. `$pluginDir` expands to the plugin's filesystem path
/// before exec.
public struct CommandExec: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case script, native, internalKind = "internal"
    }
    public let kind: Kind
    public let argv: [String]?
    public let handler: String?       // native: method name

    public init(kind: Kind, argv: [String]? = nil, handler: String? = nil) {
        self.kind = kind
        self.argv = argv
        self.handler = handler
    }
}

public struct CommandConfirm: Codable, Sendable, Equatable {
    public let message: String
    public let destructive: Bool

    public init(message: String, destructive: Bool = false) {
        self.message = message
        self.destructive = destructive
    }
}

public struct Command: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let description: String?
    public let exec: CommandExec
    public let confirm: CommandConfirm?
    public let argsSchema: [ArgSpec]?

    public struct ArgSpec: Codable, Sendable, Equatable {
        public let name: String
        public let type: String
        public let required: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, exec, confirm
        case argsSchema = "args_schema"
    }
}

// MARK: - Dashboard pane

/// A pane stack the plugin contributes to the dashboard. Pane kinds are a
/// closed enum; `source` is a tagged string parsed by the surface router.
public struct DashboardPane: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let section: String?
    public let icon: String?
    public let accent: String?
    public let panes: [PaneSpec]
}

public struct PaneSpec: Codable, Sendable, Equatable {
    public let kind: String           // pane kind (see PaneKind enum, validated separately)
    public let source: String         // "fetch:..." | "event:..." | "native:..." | "static:..."
    public let label: String?
    public let refresh: RefreshOverride?

    public struct RefreshOverride: Codable, Sendable, Equatable {
        public let pollSeconds: Int?
        public let onFsChange: [String]?

        enum CodingKeys: String, CodingKey {
            case pollSeconds = "poll_seconds"
            case onFsChange  = "on_fs_change"
        }
    }
}

/// Known pane kinds. Unknown kinds in a manifest produce a warning and
/// the pane renders as an error state at runtime.
public enum PaneKind: String, CaseIterable, Sendable {
    case summary, table, schedule, assets, log, custom
}

// MARK: - Settings section

public struct SettingsSection: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let schema: String        // path to JSON Schema (relative)
    public let view: String?         // "auto" or path/method
    public let viewMethod: String?

    enum CodingKeys: String, CodingKey {
        case id, title, schema, view
        case viewMethod = "view_method"
    }
}

// MARK: - Event subscription

public struct EventSubscription: Codable, Sendable, Equatable {
    public let event: String
    public let handler: String?         // script: path
    public let handlerMethod: String?   // native: method name
    public let debounceMs: Int?

    enum CodingKeys: String, CodingKey {
        case event, handler
        case handlerMethod = "handler_method"
        case debounceMs    = "debounce_ms"
    }
}

// MARK: - Hotkey

public struct Hotkey: Codable, Sendable, Equatable {
    public let id: String
    public let command: String          // command id this binds to
    public let args: [String: AnyCodable]?
    public let defaultBinding: String?  // e.g. "cmd+1", "ctrl+opt+a"; nil = unbound
    public let scope: Scope
    public let title: String?

    public enum Scope: String, Codable, Sendable {
        case global, dashboard, menuOpen = "menu-open"
    }

    enum CodingKeys: String, CodingKey {
        case id, command, args, scope, title
        case defaultBinding = "default_binding"
    }
}

// MARK: - Menubar item (stubbed surface in V1 of V2)

public struct MenubarItem: Codable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let titleSource: String?
    public let submenu: [SubmenuEntry]?

    public struct SubmenuEntry: Codable, Sendable, Equatable {
        public let kind: String         // command | separator | link | static | dynamic
        public let command: String?
        public let label: String?
        public let url: String?
        public let source: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, title, submenu
        case titleSource = "title_source"
    }
}

// MARK: - Statusbar badge (stubbed)

public struct StatusbarBadge: Codable, Sendable, Equatable {
    public let id: String
    public let source: String
    public let fallback: Fallback?
    public let render: Render?
    public let backgroundActive: Bool?

    public struct Fallback: Codable, Sendable, Equatable {
        public let source: String
        public let pollSeconds: Int?
        enum CodingKeys: String, CodingKey { case source; case pollSeconds = "poll_seconds" }
    }

    public struct Render: Codable, Sendable, Equatable {
        public let kind: String
        public let format: String?
        public let toneByValue: [String: String]?
        enum CodingKeys: String, CodingKey {
            case kind, format
            case toneByValue = "tone_by_value"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, source, fallback, render
        case backgroundActive = "background_active"
    }
}

// MARK: - Stubbed-surface placeholders (kept minimal in V1)

public struct QuickAction: Codable, Sendable, Equatable {
    public let id: String
    public let command: String
    public let title: String?
}

public struct Floater: Codable, Sendable, Equatable {
    public let id: String
    public let source: String
}

public struct NotificationHandler: Codable, Sendable, Equatable {
    public let id: String
    public let event: String
    public let title: String?
}

// MARK: - AnyCodable (a tiny escape hatch for Hotkey.args and similar)

/// Minimal type-erased Codable for free-form JSON values. Only used where the
/// schema legitimately allows arbitrary user-supplied values (hotkey args,
/// command args, settings values). We do not want a general-purpose AnyCodable
/// proliferating through the kernel.
///
/// `@unchecked Sendable` because the underlying `Any` may hold non-Sendable
/// types in principle, but in practice we only decode JSON primitives + arrays
/// + dicts of the same, all of which are Sendable.
public struct AnyCodable: Codable, @unchecked Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = NSNull()
        } else if let b = try? c.decode(Bool.self) {
            self.value = b
        } else if let i = try? c.decode(Int.self) {
            self.value = i
        } else if let d = try? c.decode(Double.self) {
            self.value = d
        } else if let s = try? c.decode(String.self) {
            self.value = s
        } else if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr.map(\.value)
        } else if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "AnyCodable could not decode value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyCodable.init))
        case let d as [String: Any]: try c.encode(d.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: c.codingPath,
                debugDescription: "AnyCodable cannot encode \(type(of: value))"))
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        guard let a = try? JSONEncoder().encode(lhs),
              let b = try? JSONEncoder().encode(rhs) else { return false }
        return a == b
    }
}
