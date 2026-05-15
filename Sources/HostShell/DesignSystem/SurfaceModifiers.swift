import SwiftUI
import HostKernel

/// Reusable view modifiers that encode the host's surface conventions.
/// Plugins should reach for these before styling manually.

public extension View {
    /// A surface-1 panel (pane body, card body). Border + rounded corners.
    func paneBackground() -> some View {
        self
            .background(DesignTokens.Surface.raised)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.m)
                    .stroke(DesignTokens.Surface.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.m))
    }

    /// A surface-2 strip (pane header, section header). Visible against
    /// the page bg and against the raised pane body underneath.
    func sectionHeaderBackground() -> some View {
        self.background(DesignTokens.Surface.header)
    }

    /// A surface-1 chip (small inline pill). Use for badges, status pills.
    func chipBackground(tone: Tone?) -> some View {
        self.background(DesignTokens.chipBackground(for: tone))
            .clipShape(Capsule())
    }
}

/// Wraps a row view with a hover-tracking background. Used by every list
/// renderer (Table, Schedule, Assets, sidebar entries) so the affordance is
/// consistent. The hovered color is `Surface.hover`, the resting color is
/// transparent (the underlying pane provides the actual surface).
public struct HoverRow<Content: View>: View {
    @State private var isHovered = false
    let content: () -> Content

    public init(@ViewBuilder _ content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
            .background(isHovered ? DesignTokens.Surface.hover : Color.clear)
            .onHover { isHovered = $0 }
    }
}
