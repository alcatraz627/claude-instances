import SwiftUI
import HostKernel

/// The chrome every pane shares: title bar, optional subtitle, refresh
/// indicator, and an error overlay when content failed. The actual content
/// renderer is injected as a generic view.
struct PaneFrame<Content: View>: View {
    let title: String?
    let subtitle: String?
    let fetchedAt: Date?
    let onRefresh: (() -> Void)?
    @ViewBuilder let content: () -> Content

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
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        if let title { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text) }
                        if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.dim) }
                    }
                    Spacer()
                    if let fetchedAt {
                        Text(relative(fetchedAt))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.tertiary)
                    }
                    if let onRefresh {
                        Button(action: onRefresh) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.dim)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Palette.surfaceAlt)
                Divider()
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.panelBorder, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func relative(_ d: Date) -> String {
        let secs = Int(-d.timeIntervalSinceNow)
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }
}
