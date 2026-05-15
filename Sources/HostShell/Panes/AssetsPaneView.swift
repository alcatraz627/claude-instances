import SwiftUI
import HostKernel

/// File list with hover rows, size + mtime, open-with action.
struct AssetsPaneView: View {
    let content: AssetsContent
    var onOpen: ((AssetsContent.Item) -> Void)? = nil
    @Environment(\.design) var design

    var body: some View {
        if content.items.isEmpty {
            EmptyPaneText("No assets.")
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

    private func row(_ item: AssetsContent.Item) -> some View {
        HStack(alignment: .center, spacing: design.space(DesignTokens.Space.s)) {
            Image(systemName: iconName(for: item.openWith))
                .font(design.font(DesignTokens.FontSize.label + 2))
                .foregroundStyle(DesignTokens.TextColor.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(design.font(DesignTokens.FontSize.body, weight: .medium))
                    .foregroundStyle(DesignTokens.TextColor.primary)
                    .lineLimit(1)
                Text(item.path)
                    .font(design.font(DesignTokens.FontSize.caption, monospaced: true))
                    .foregroundStyle(DesignTokens.TextColor.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let bytes = item.sizeBytes {
                    Text(humanBytes(bytes))
                        .font(design.font(DesignTokens.FontSize.caption, monospaced: true))
                        .foregroundStyle(DesignTokens.TextColor.secondary)
                }
                if let mtime = item.mtime {
                    Text(mtime.split(separator: "T").first.map(String.init) ?? mtime)
                        .font(design.font(DesignTokens.FontSize.caption))
                        .foregroundStyle(DesignTokens.TextColor.tertiary)
                }
            }
            Button("Open") { onOpen?(item) }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, design.space(DesignTokens.Space.m))
        .padding(.vertical, design.space(DesignTokens.Space.s))
    }

    private func iconName(for openWith: AssetsContent.Item.OpenWith?) -> String {
        switch openWith {
        case .browser: return "globe"
        case .vscode:  return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .auto, nil: return "doc"
        }
    }

    private func humanBytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }
}
