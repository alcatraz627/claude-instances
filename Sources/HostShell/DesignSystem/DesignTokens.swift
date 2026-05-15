import SwiftUI
import HostKernel

/// Central design tokens for the entire host UI. **Every pane renderer reads
/// from here.** Per-pane overrides are explicitly discouraged — if a plugin
/// needs a value not in this file, file a host change rather than diverging.
///
/// Tokens are split into:
///   - Color tokens — semantic, theme-aware via NSColor system catalog
///   - Typography tokens — pt sizes that respect the user's text-size setting
///   - Spacing tokens — gap values that respect density
///   - Corner tokens — radius values (constant)
///
/// Plugins (Phase 4+) receive a typed `Design` value via HostContext.
public enum DesignTokens {

    // MARK: - Surfaces (layered backgrounds)

    public enum Surface {
        /// Layer 0 — the dashboard window's outermost background.
        public static let page = Color(nsColor: .windowBackgroundColor)

        /// Layer 1 — pane / card body. Sits visibly on top of `.page`.
        public static let raised = Color(nsColor: .controlBackgroundColor)

        /// Layer 2 — pane title bars, sticky headers, settings sections.
        /// Picked to read clearly against both `.page` and `.raised` in
        /// both light and dark modes.
        public static let header = Color(nsColor: .underPageBackgroundColor)

        /// Subtle overlay applied to interactive rows on hover.
        public static let hover = Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)

        /// Strong selection background (sidebar items, selected table rows).
        public static let selected = Color(nsColor: .selectedContentBackgroundColor)

        /// Hairline border between layers.
        public static let border = Color(nsColor: .separatorColor)
    }

    // MARK: - Text

    public enum TextColor {
        public static let primary    = Color(nsColor: .labelColor)
        public static let secondary  = Color(nsColor: .secondaryLabelColor)
        public static let tertiary   = Color(nsColor: .tertiaryLabelColor)
        public static let onSelected = Color(nsColor: .selectedMenuItemTextColor)
    }

    // MARK: - Tones (semantic, NOT auto-adapting — meaning is constant)

    public enum SemanticColor {
        public static let ok     = Color.green
        public static let warn   = Color.orange
        public static let error  = Color.red
        public static let accent = Color.accentColor
    }

    public static func color(for tone: Tone?) -> Color {
        switch tone {
        case .ok:    return SemanticColor.ok
        case .warn:  return SemanticColor.warn
        case .error: return SemanticColor.error
        case .dim:   return TextColor.secondary
        case .some(Tone.none), nil: return TextColor.primary
        }
    }

    public static func chipBackground(for tone: Tone?) -> Color {
        switch tone {
        case .ok:    return SemanticColor.ok.opacity(0.14)
        case .warn:  return SemanticColor.warn.opacity(0.14)
        case .error: return SemanticColor.error.opacity(0.14)
        case .dim, .some(Tone.none), nil: return Surface.border.opacity(0.4)
        }
    }

    // MARK: - Typography (pt sizes; multiply by user's text-size scale at render)

    public enum FontSize {
        public static let caption   = 10.0   // small label, secondary captions
        public static let label     = 11.0   // section labels, hint text
        public static let body      = 12.0   // standard body text
        public static let value     = 15.0   // headline value in a stat tile
        public static let title     = 13.0   // pane title bar
        public static let heroTitle = 20.0   // big numbers, hero values
    }

    // MARK: - Spacing (pt; multiply by density scale at render)

    public enum Space {
        public static let xs:  CGFloat = 4
        public static let s:   CGFloat = 8
        public static let m:   CGFloat = 12
        public static let l:   CGFloat = 16
        public static let xl:  CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    // MARK: - Corners (constant)

    public enum Corner {
        public static let s: CGFloat = 4
        public static let m: CGFloat = 6
        public static let l: CGFloat = 10
    }

    // MARK: - Tile sizing

    public enum Tile {
        public static let minWidth:  CGFloat = 170
        public static let maxWidth:  CGFloat = 260
        public static let minHeight: CGFloat = 78   // keeps a row of tiles uniform
    }
}

// MARK: - Resolved tokens (settings-aware)

/// A snapshot of the design tokens scaled by the current user preferences.
/// Computed once per render pass; passed into views via Environment.
public struct ResolvedDesign: Sendable {
    public let textScale: Double
    public let densityScale: Double

    public init(settings: HostSettings) {
        self.textScale = settings.appearance.textSize.scale
        self.densityScale = settings.appearance.density.scale
    }

    public func font(_ pt: Double, weight: Font.Weight = .regular, monospaced: Bool = false) -> Font {
        let size = pt * textScale
        if monospaced {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .system(size: size, weight: weight)
    }

    public func space(_ pt: CGFloat) -> CGFloat {
        pt * CGFloat(densityScale)
    }
}

private struct DesignKey: EnvironmentKey {
    static let defaultValue = ResolvedDesign(settings: HostSettings())
}

public extension EnvironmentValues {
    var design: ResolvedDesign {
        get { self[DesignKey.self] }
        set { self[DesignKey.self] = newValue }
    }
}
