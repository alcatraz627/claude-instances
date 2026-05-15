import SwiftUI
import HostKernel

/// Read-only list of scheduled jobs (cron + launchd unified). V1 of V2 does
/// not implement enable/disable mutations; the toggle is deferred per the
/// implementation plan.
struct SchedulePaneView: View {
    let content: ScheduleContent
    var onOpenLog: ((String) -> Void)? = nil

    var body: some View {
        if content.items.isEmpty {
            EmptyPaneText("No scheduled jobs.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(content.items.enumerated()), id: \.offset) { idx, item in
                    row(item)
                    if idx < content.items.count - 1 { Divider().opacity(0.5) }
                }
            }
        }
    }

    private func row(_ item: ScheduleContent.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.enabled ? Palette.ok : Palette.dim)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.id)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text)
                    Text(item.source.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Palette.panelBorder.opacity(0.5))
                        .clipShape(Capsule())
                    Spacer()
                    Text(item.when)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                }
                Text(item.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let logPath = item.logPath {
                    Button(action: { onOpenLog?(logPath) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 9))
                            Text("View log")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
