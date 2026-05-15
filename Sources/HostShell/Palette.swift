import SwiftUI
import HostKernel

/// The host's color palette. V1 had 17 user-tunable tokens; V2 starts with
/// the semantic subset every pane renderer needs. System colors handle
/// dark/light adaptation automatically; the explicit semantic tones
/// (`ok` / `warn` / `error`) stay constant across appearances.
public enum Palette {
    // MARK: Surface
    public static let surface     = Color(nsColor: .controlBackgroundColor)
    public static let surfaceAlt  = Color(nsColor: .alternatingContentBackgroundColors.first ?? .controlBackgroundColor)
    public static let panelBorder = Color(nsColor: .separatorColor)

    // MARK: Text
    public static let text        = Color(nsColor: .labelColor)
    public static let dim         = Color(nsColor: .secondaryLabelColor)
    public static let tertiary    = Color(nsColor: .tertiaryLabelColor)

    // MARK: Semantic tones (NOT auto-adapting; meaning is the same in any mode)
    public static let ok          = Color.green
    public static let warn        = Color.orange
    public static let error       = Color.red
    public static let accent      = Color.accentColor

    public static func color(for tone: Tone?) -> Color {
        switch tone {
        case .ok:    return ok
        case .warn:  return warn
        case .error: return error
        case .dim:   return dim
        case .some(Tone.none), nil: return text
        }
    }

    public static func backgroundColor(for tone: Tone?) -> Color {
        switch tone {
        case .ok:    return ok.opacity(0.12)
        case .warn:  return warn.opacity(0.12)
        case .error: return error.opacity(0.12)
        case .dim, .some(Tone.none), nil: return Color.clear
        }
    }
}

