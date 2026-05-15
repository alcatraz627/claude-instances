import SwiftUI
import HostKernel

/// Read-only cron + launchd unified list. Hover-highlighted rows.
struct SchedulePaneView: View {
    let content: ScheduleContent
    var onOpenLog: ((String) -> Void)? = nil
    @Environment(\.design) var design

    var body: some View {
        if content.items.isEmpty {
            EmptyPaneText("No scheduled jobs.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(content.items.enumerated()), id: \.offset) { idx, item in
                    HoverRow { row(item) }
                    if idx < content.items.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func row(_ item: ScheduleContent.Item) -> some View {
        HStack(alignment: .top, spacing: design.space(DesignTokens.Space.s)) {
            Circle()
                .fill(item.enabled
                      ? DesignTokens.SemanticColor.ok
                      : DesignTokens.TextColor.tertiary)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.id)
                        .font(design.font(DesignTokens.FontSize.body, weight: .medium))
                        .foregroundStyle(DesignTokens.TextColor.primary)
                    Text(item.source.uppercased())
                        .font(design.font(DesignTokens.FontSize.caption,
                                          weight: .semibold,
                                          monospaced: true))
                        .foregroundStyle(DesignTokens.TextColor.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(DesignTokens.Surface.border.opacity(0.5))
                        .clipShape(Capsule())
                    Spacer()
                    Text(item.when)
                        .font(design.font(DesignTokens.FontSize.body))
                        .foregroundStyle(DesignTokens.TextColor.secondary)
                }
                Text(item.command)
                    .font(design.font(DesignTokens.FontSize.caption, monospaced: true))
                    .foregroundStyle(DesignTokens.TextColor.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let logPath = item.logPath {
                    Button(action: { onOpenLog?(logPath) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text")
                                .font(design.font(DesignTokens.FontSize.caption))
                            Text("View log")
                                .font(design.font(DesignTokens.FontSize.caption))
                        }
                        .foregroundStyle(DesignTokens.SemanticColor.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, design.space(DesignTokens.Space.m))
        .padding(.vertical, design.space(DesignTokens.Space.s))
    }
}
