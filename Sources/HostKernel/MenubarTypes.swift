import Foundation

/// Rich row shown inside a plugin's `menubar.item` submenu when the entry's
/// `kind` is `"dynamic"`. The host renders these via a pure-AppKit NSView
/// subclass (no SwiftUI in menu items — keeps us off the C-bridge crash path).
public struct MenubarRow: Codable, Sendable, Equatable {
    public let label: String
    public let subtitle: String?
    public let icon: String?              // SF Symbol name
    public let tone: Tone?
    public let commandId: String?         // matches contributes.commands[].id
    public let commandArgs: [String: AnyCodable]?
    /// Single-character key equivalent (e.g. "1" for ⌘1). Applied when the
    /// containing menu is open. Empty/nil = no shortcut.
    public let keyEquivalent: String?

    enum CodingKeys: String, CodingKey {
        case label, subtitle, icon, tone
        case commandId      = "command_id"
        case commandArgs    = "command_args"
        case keyEquivalent  = "key_equivalent"
    }

    public init(label: String, subtitle: String? = nil,
                icon: String? = nil, tone: Tone? = nil,
                commandId: String? = nil,
                commandArgs: [String: AnyCodable]? = nil,
                keyEquivalent: String? = nil) {
        self.label = label
        self.subtitle = subtitle
        self.icon = icon
        self.tone = tone
        self.commandId = commandId
        self.commandArgs = commandArgs
        self.keyEquivalent = keyEquivalent
    }
}

/// Wire format for `statusbar.badge` content. Either text + tone OR icon-only.
/// Plugins emit this via `fetch:badge:<id>` (script) or `badgeValue(badgeId:)`
/// (native).
public struct BadgeValue: Codable, Sendable, Equatable {
    public let text: String?
    public let tone: Tone?
    public let icon: String?       // SF Symbol; rendered before text

    public init(text: String? = nil, tone: Tone? = nil, icon: String? = nil) {
        self.text = text
        self.tone = tone
        self.icon = icon
    }
}

/// JSON envelope for script-plugin menubar responses.
public struct MenubarResponse: Codable, Sendable {
    public let rows: [MenubarRow]
}
