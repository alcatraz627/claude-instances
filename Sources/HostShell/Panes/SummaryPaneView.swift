import SwiftUI
import HostKernel

/// Grid of `StatCard`-shaped tiles. Tones tint the value; `progress_pct`
/// renders a slim bar under the tile.
struct SummaryPaneView: View {
    let content: SummaryContent

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 10)]

    var body: some View {
        if content.tiles.isEmpty {
            EmptyPaneText("No data.")
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(Array(content.tiles.enumerated()), id: \.offset) { _, tile in
                    TileView(tile: tile)
                }
            }
            .padding(12)
        }
    }
}

private struct TileView: View {
    let tile: SummaryContent.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(tile.label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.dim)
                    .tracking(0.4)
                Spacer()
                if let badge = tile.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.color(for: tile.tone))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Palette.backgroundColor(for: tile.tone))
                        .clipShape(Capsule())
                }
            }
            Text(tile.value)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.color(for: tile.tone))
                .lineLimit(1)
            if let pct = tile.progressPct {
                ProgressBar(pct: pct, tone: tile.tone)
                    .padding(.top, 2)
            }
            if let trend = tile.trend {
                Text(trend)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceAlt)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.panelBorder, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct ProgressBar: View {
    let pct: Double
    let tone: Tone?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.panelBorder).frame(height: 3)
                Rectangle()
                    .fill(Palette.color(for: tone))
                    .frame(width: max(0, min(1, pct / 100)) * geo.size.width, height: 3)
            }
        }
        .frame(height: 3)
    }
}

struct EmptyPaneText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.tertiary)
            .padding(20)
            .frame(maxWidth: .infinity)
    }
}
