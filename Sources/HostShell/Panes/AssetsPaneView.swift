import SwiftUI
import HostKernel

/// File list with open-with action. `default` opens via macOS `open(1)`.
struct AssetsPaneView: View {
    let content: AssetsContent
    var onOpen: ((AssetsContent.Item) -> Void)? = nil

    var body: some View {
        if content.items.isEmpty {
            EmptyPaneText("No assets.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(content.items.enumerated()), id: \.offset) { idx, item in
                    row(item)
                    if idx < content.items.count - 1 { Divider().opacity(0.5) }
                }
            }
        }
    }

    private func row(_ item: AssetsContent.Item) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName(for: item.openWith))
                .font(.system(size: 14))
                .foregroundStyle(Palette.dim)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(item.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let bytes = item.sizeBytes {
                    Text(humanBytes(bytes))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                }
                if let mtime = item.mtime {
                    Text(mtime.split(separator: "T").first.map(String.init) ?? mtime)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.tertiary)
                }
            }
            Button("Open") { onOpen?(item) }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(n))
    }
}
