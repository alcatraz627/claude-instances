import SwiftUI
import HostKernel

/// Header strip + scrollable body. Rows highlight on hover via the shared
/// `HoverRow` modifier.
struct TablePaneView: View {
    let content: TableContent
    var onAction: ((TableContent.RowAction) -> Void)? = nil
    @Environment(\.design) var design

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
                            HoverRow {
                                rowView(row)
                            }
                            if idx < content.rows.count - 1 {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
                if let n = content.truncatedAt, content.hasMore == true {
                    truncatedFooter(n)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(Array(content.columns.enumerated()), id: \.offset) { _, col in
                cellView(text: col.label.uppercased(),
                         width: col.width,
                         align: col.align,
                         font: design.font(DesignTokens.FontSize.caption, weight: .semibold),
                         color: DesignTokens.TextColor.secondary,
                         tracking: 0.4)
            }
            Spacer().frame(width: design.space(DesignTokens.Space.xs))
        }
        .padding(.horizontal, design.space(DesignTokens.Space.m))
        .padding(.vertical, design.space(DesignTokens.Space.xs) + 2)
        .sectionHeaderBackground()
    }

    private func rowView(_ row: TableContent.Row) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(content.columns.enumerated()), id: \.offset) { _, col in
                cellView(text: row.cells[col.id] ?? "—",
                         width: col.width,
                         align: col.align,
                         font: design.font(DesignTokens.FontSize.body),
                         color: DesignTokens.TextColor.primary)
            }
            Spacer().frame(width: design.space(DesignTokens.Space.xs))
            if let actions = row.rowActions, !actions.isEmpty {
                rowActions(actions)
            }
        }
        .padding(.horizontal, design.space(DesignTokens.Space.m))
        .padding(.vertical, design.space(DesignTokens.Space.xs) + 2)
    }

    private func rowActions(_ actions: [TableContent.RowAction]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action: { onAction?(action) }) {
                    Text(action.label)
                        .font(design.font(DesignTokens.FontSize.caption))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(action.destructive == true
                                          ? DesignTokens.SemanticColor.error
                                          : DesignTokens.SemanticColor.accent)
                        .overlay(Capsule().stroke(
                            action.destructive == true
                              ? DesignTokens.SemanticColor.error
                              : DesignTokens.SemanticColor.accent,
                            lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func truncatedFooter(_ n: Int) -> some View {
        HStack {
            Text("Showing first \(n)…")
                .font(design.font(DesignTokens.FontSize.caption))
                .foregroundStyle(DesignTokens.TextColor.tertiary)
            Spacer()
        }
        .padding(.horizontal, design.space(DesignTokens.Space.m))
        .padding(.vertical, design.space(DesignTokens.Space.xs))
        .sectionHeaderBackground()
    }

    @ViewBuilder
    private func cellView(text: String,
                          width: TableContent.WidthSpec?,
                          align: TableContent.Column.Alignment?,
                          font: Font,
                          color: Color,
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
        case .leading:  return .leading
        case .trailing: return .trailing
        case .center:   return .center
        }
    }
}
