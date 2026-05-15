import SwiftUI
import HostKernel

/// Header row + scrollable body. Cell widths honor manifest `width` (fixed
/// points or `flex` for remaining space). Row actions render as chips on
/// the trailing edge.
struct TablePaneView: View {
    let content: TableContent
    var onAction: ((TableContent.RowAction) -> Void)? = nil

    var body: some View {
        if content.rows.isEmpty {
            EmptyPaneText(content.empty ?? "No items.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(content.rows.enumerated()), id: \.offset) { idx, row in
                            rowView(row, index: idx)
                            if idx < content.rows.count - 1 {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
                if let n = content.truncatedAt, content.hasMore == true {
                    HStack {
                        Text("Showing first \(n)…")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Palette.surfaceAlt)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(Array(content.columns.enumerated()), id: \.offset) { _, col in
                cellView(text: col.label.uppercased(), width: col.width, align: col.align,
                         font: .system(size: 9, weight: .semibold),
                         color: Palette.dim, tracking: 0.4)
            }
            // reserve slot for row actions
            Spacer().frame(width: 6)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Palette.surfaceAlt)
    }

    private func rowView(_ row: TableContent.Row, index: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(content.columns.enumerated()), id: \.offset) { _, col in
                cellView(text: row.cells[col.id] ?? "—", width: col.width, align: col.align,
                         font: .system(size: 11, design: .default), color: Palette.text)
            }
            Spacer().frame(width: 6)
            if let actions = row.rowActions, !actions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button(action: { onAction?(action) }) {
                            Text(action.label)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .foregroundStyle(action.destructive == true ? Palette.error : Palette.accent)
                                .overlay(Capsule().stroke(
                                    action.destructive == true ? Palette.error : Palette.accent,
                                    lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(index.isMultiple(of: 2) ? Palette.surface : Palette.surfaceAlt.opacity(0.5))
    }

    @ViewBuilder
    private func cellView(text: String, width: TableContent.WidthSpec?,
                          align: TableContent.Column.Alignment?,
                          font: Font, color: Color,
                          tracking: CGFloat = 0) -> some View {
        let textView = Text(text)
            .font(font)
            .foregroundStyle(color)
            .tracking(tracking)
            .lineLimit(1)
            .frame(maxWidth: .infinity,
                   alignment: alignment(for: align ?? .leading))

        switch width {
        case .fixed(let w)?:
            textView.frame(width: w, alignment: alignment(for: align ?? .leading))
        case .flex?, nil:
            textView
        }
    }

    private func alignment(for a: TableContent.Column.Alignment) -> Alignment {
        switch a {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }
}
