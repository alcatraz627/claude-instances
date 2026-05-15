import SwiftUI
import HostKernel

/// Adaptive grid of stat tiles. Tiles are uniform height per row — content
/// pins to top via `.frame(maxHeight: .infinity, alignment: .top)`.
struct SummaryPaneView: View {
    let content: SummaryContent
    @Environment(\.design) var design

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: DesignTokens.Tile.minWidth,
                            maximum: DesignTokens.Tile.maxWidth),
                  spacing: design.space(DesignTokens.Space.s))]
    }

    var body: some View {
        if content.tiles.isEmpty {
            EmptyPaneText("No data.")
        } else {
            LazyVGrid(columns: columns,
                      alignment: .leading,
                      spacing: design.space(DesignTokens.Space.s)) {
                ForEach(Array(content.tiles.enumerated()), id: \.offset) { _, tile in
                    TileView(tile: tile)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(design.space(DesignTokens.Space.m))
        }
    }
}

private struct TileView: View {
    let tile: SummaryContent.Tile
    @Environment(\.design) var design

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(tile.label.uppercased())
                    .font(design.font(DesignTokens.FontSize.caption, weight: .semibold))
                    .foregroundStyle(DesignTokens.TextColor.secondary)
                    .tracking(0.4)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge = tile.badge {
                    Text(badge)
                        .font(design.font(DesignTokens.FontSize.caption,
                                          weight: .semibold,
                                          monospaced: true))
                        .foregroundStyle(DesignTokens.color(for: tile.tone))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .chipBackground(tone: tile.tone)
                }
            }
            Text(tile.value)
                .font(design.font(DesignTokens.FontSize.value, weight: .medium))
                .foregroundStyle(DesignTokens.color(for: tile.tone))
                .lineLimit(1)
            if let pct = tile.progressPct {
                ProgressBar(pct: pct, tone: tile.tone)
                    .padding(.top, 2)
            }
            if let trend = tile.trend {
                Text(trend)
                    .font(design.font(DesignTokens.FontSize.caption))
                    .foregroundStyle(DesignTokens.TextColor.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(design.space(DesignTokens.Space.s) + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: DesignTokens.Tile.minHeight)
        .background(DesignTokens.Surface.raised)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.s)
                .stroke(DesignTokens.Surface.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.s))
    }
}

private struct ProgressBar: View {
    let pct: Double
    let tone: Tone?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(DesignTokens.Surface.border).frame(height: 3)
                Rectangle()
                    .fill(DesignTokens.color(for: tone))
                    .frame(width: max(0, min(1, pct / 100)) * geo.size.width, height: 3)
            }
        }
        .frame(height: 3)
    }
}

struct EmptyPaneText: View {
    let text: String
    @Environment(\.design) var design
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(design.font(DesignTokens.FontSize.label))
            .foregroundStyle(DesignTokens.TextColor.tertiary)
            .padding(design.space(DesignTokens.Space.l))
            .frame(maxWidth: .infinity)
    }
}
