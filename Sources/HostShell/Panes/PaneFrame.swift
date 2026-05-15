import SwiftUI
import HostKernel

/// Pane chrome: title strip + content area. Title strip uses Surface.header
/// so it remains visible against both the page bg and the pane body in
/// both color schemes. Border + corners + clip-shape come from
/// `paneBackground()`.
struct PaneFrame<Content: View>: View {
    let title: String?
    let subtitle: String?
    let fetchedAt: Date?
    let onRefresh: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.design) var design

    init(title: String? = nil, subtitle: String? = nil,
         fetchedAt: Date? = nil, onRefresh: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.fetchedAt = fetchedAt
        self.onRefresh = onRefresh
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || subtitle != nil || fetchedAt != nil {
                titleBar
                Divider()
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .paneBackground()
    }

    private var titleBar: some View {
        HStack(alignment: .center, spacing: design.space(DesignTokens.Space.s)) {
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    Text(title)
                        .font(design.font(DesignTokens.FontSize.title, weight: .semibold))
                        .foregroundStyle(DesignTokens.TextColor.primary)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(design.font(DesignTokens.FontSize.caption))
                        .foregroundStyle(DesignTokens.TextColor.secondary)
                }
            }
            Spacer()
            if let fetchedAt {
                Text(relative(fetchedAt))
                    .font(design.font(DesignTokens.FontSize.caption, monospaced: true))
                    .foregroundStyle(DesignTokens.TextColor.tertiary)
            }
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(design.font(DesignTokens.FontSize.caption))
                        .foregroundStyle(DesignTokens.TextColor.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
        .padding(.horizontal, design.space(DesignTokens.Space.m))
        .padding(.vertical, design.space(DesignTokens.Space.s))
        .sectionHeaderBackground()
    }

    private func relative(_ d: Date) -> String {
        let secs = Int(-d.timeIntervalSinceNow)
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }
}
