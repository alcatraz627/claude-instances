// DesignKit.swift
// The dropdown's shared design system: one type scale, segment + columned text
// builders, and truncation rules. Sections feed these instead of hand-rolling
// NSAttributedString math and `leftPad` alignment, so spacing and alignment are
// defined once. See docs/dropdown-redesign.md and ~/.claude/conventions/visual-design.md.

import AppKit
import Foundation

// ── Type scale ───────────────────────────────────────────────────────────────
// Three roles separated by size + weight (not colour). Prose uses the system
// font; columnar / numeric content uses the monospaced one so digits line up.

enum BarFont {
    static let title        = NSFont.systemFont(ofSize: 13, weight: .semibold)   // identity
    static let body         = NSFont.systemFont(ofSize: 12, weight: .regular)    // values, prose
    static let caption      = NSFont.systemFont(ofSize: 11, weight: .regular)    // detail, prose
    static let monoBody     = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let monoCaption  = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let sectionLabel = NSFont.systemFont(ofSize: 10, weight: .semibold)   // tracked header
}

// ── Segment builder ──────────────────────────────────────────────────────────
// A row is a sequence of styled text segments. `seg` makes one; `row`
// concatenates them. Replaces ad-hoc NSMutableAttributedString assembly.

func seg(_ text: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if kern != 0 { attrs[.kern] = kern }
    return NSAttributedString(string: text, attributes: attrs)
}

func row(_ parts: NSAttributedString...) -> NSMutableAttributedString {
    let m = NSMutableAttributedString()
    for p in parts { m.append(p) }
    return m
}

// A dim "·" between chips, the menu's standard separator.
func dot(_ color: NSColor = .quaternaryLabelColor) -> NSAttributedString {
    seg("  ·  ", BarFont.monoBody, color)
}

// ── Columned rows (real alignment, not leftPad) ──────────────────────────────
// Tab stops give true column alignment regardless of content width — the fix for
// the menu's hand-padded columns. Pass each cell and the x-position (pt) of each
// column; cell 0 sits at the row origin, cells 1..n at their tab stop.

func columned(_ cells: [NSAttributedString], stops: [CGFloat],
              align: [NSTextAlignment] = []) -> NSAttributedString {
    let ps = NSMutableParagraphStyle()
    ps.tabStops = stops.enumerated().map { i, x in
        NSTextTab(textAlignment: i < align.count ? align[i] : .left, location: x)
    }
    ps.defaultTabInterval = 0
    let m = NSMutableAttributedString()
    for (i, cell) in cells.enumerated() {
        if i > 0 { m.append(NSAttributedString(string: "\t")) }
        m.append(cell)
    }
    m.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: m.length))
    return m
}

// ── Truncation (one rule per field kind) ─────────────────────────────────────
// Identifiers tail-truncate; paths middle-truncate (keep the meaningful ends);
// prose line-clamps in the label (see clampLines). Lengths are character counts.

func tailTruncate(_ s: String, _ maxChars: Int) -> String {
    s.count <= maxChars ? s : String(s.prefix(max(0, maxChars - 1))) + "…"
}

func middleTruncate(_ s: String, _ maxChars: Int) -> String {
    guard s.count > maxChars else { return s }
    guard maxChars > 3 else { return String(s.prefix(maxChars)) }
    let keep = maxChars - 1                 // room for the ellipsis
    let head = (keep + 1) / 2
    let tail = keep - head
    return String(s.prefix(head)) + "…" + String(s.suffix(tail))
}

// Configure a label to clamp prose to N lines with a tail ellipsis.
func clampLines(_ label: NSTextField, _ lines: Int) {
    label.maximumNumberOfLines = lines
    label.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
}

// ── Severity scale (one closed green→amber→red, shared by every health signal) ─
// Returns the palette token so callers stay tunable; `severityColor` resolves it.

func severityToken(forPercent pct: Int, healthyHigh: Bool = true) -> PaletteToken {
    // healthyHigh=true: high is good (ctx remaining). false: high is bad (usage).
    let danger = healthyHigh ? pct < 30 : pct >= 90
    let caution = healthyHigh ? pct < 60 : pct >= 70
    if danger { return .warnHigh }
    if caution { return .warnMid }
    return .successHigh
}

func severityColor(forPercent pct: Int, healthyHigh: Bool = true) -> NSColor {
    PaletteStore.shared.color(for: severityToken(forPercent: pct, healthyHigh: healthyHigh))
}
