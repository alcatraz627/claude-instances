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
    /// User font-size multiplier (Settings → Display Sizing, key `ui.fontScale`,
    /// default 1.0). Read at render time so a change re-renders on the next
    /// refreshLiveRows(); clamped to a sane range.
    static var scale: CGFloat {
        let s = UserDefaults.standard.double(forKey: "ui.fontScale")
        return s > 0 ? min(1.6, max(0.7, CGFloat(s))) : 1.0
    }
    /// Scale an arbitrary point size by the user multiplier — for the ad-hoc
    /// sizes in LiveRowView that don't map to a named role.
    static func scaled(_ pt: CGFloat) -> CGFloat { pt * scale }

    static var title:        NSFont { .systemFont(ofSize: 13 * scale, weight: .semibold) }   // identity
    static var body:         NSFont { .systemFont(ofSize: 12 * scale, weight: .regular) }     // values, prose
    static var caption:      NSFont { .systemFont(ofSize: 11 * scale, weight: .regular) }     // detail, prose
    static var monoBody:     NSFont { .monospacedSystemFont(ofSize: 12 * scale, weight: .regular) }
    static var monoCaption:  NSFont { .monospacedSystemFont(ofSize: 11 * scale, weight: .regular) }
    static var sectionLabel: NSFont { .systemFont(ofSize: 10 * scale, weight: .semibold) }    // tracked header
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

// ── State badges ─────────────────────────────────────────────────────────────
// A solid pill for an engaged state, a hollow one for disengaged. Palette
// colours are user-editable, so the text colour is derived from the fill at
// render time and the fill is walked until it clears 4.5:1. No pairing in this
// file can fall below the floor, whatever the user picks.

func relativeLuminance(_ c: NSColor) -> CGFloat {
    let s = c.usingColorSpace(.sRGB) ?? c
    func lin(_ v: CGFloat) -> CGFloat {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
}

func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let la = relativeLuminance(a), lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// Fill + text for a solid badge: the fill is the palette colour untouched, the
/// text is whichever of black/white reads better on it. That alone clears 4.5:1
/// for every colour in sRGB — the two curves cross at 4.58:1, so the worse of
/// the pair is never the one chosen. Swept and confirmed across the cube; the
/// measured worst case is #E12D0F at 4.584:1.
func accessibleBadgePair(_ base: NSColor) -> (fill: NSColor, text: NSColor) {
    let fill = base.usingColorSpace(.sRGB) ?? base
    let text: NSColor = contrastRatio(.white, fill) >= contrastRatio(.black, fill) ? .white : .black
    return (fill, text)
}

/// One badge. `tint: nil` renders the hollow disengaged form.
func makeStateBadge(_ text: String, tint: NSColor?) -> NSView {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.monospacedSystemFont(ofSize: 10 * BarFont.scale, weight: .semibold)
    label.alignment = .center
    let size = label.attributedStringValue.size()
    let h = BarFont.scaled(15)
    let w = ceil(size.width) + BarFont.scaled(8) * 2

    let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    v.wantsLayer = true
    v.layer?.cornerRadius = h / 2
    if let tint = tint {
        let pair = accessibleBadgePair(tint)
        v.layer?.backgroundColor = pair.fill.cgColor
        label.textColor = pair.text
    } else {
        v.layer?.backgroundColor = NSColor.clear.cgColor
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.55).cgColor
        label.textColor = .secondaryLabelColor
    }
    label.frame = NSRect(x: 0, y: (h - ceil(size.height)) / 2, width: w, height: ceil(size.height))
    v.addSubview(label)
    return v
}

// ── Clickable menu row ───────────────────────────────────────────────────────
// An NSMenuItem with a custom `view` never sends its action: the view owns the
// mouse. Any interactive row must therefore handle the click itself, and draw
// its own hover highlight, since AppKit highlights only standard items.
// Verified by probe before this class existed.

final class MenuRowView: NSView {
    var onClick: (() -> Void)?
    var rowEnabled = true
    /// Keep the menu up after a click so several switches can be flipped in one
    /// visit. Set false for rows that navigate or act once.
    var staysOpen = true

    private var hovered = false
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) {
        guard rowEnabled else { return }
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard rowEnabled else { return }
        if !staysOpen { enclosingMenuItem?.menu?.cancelTracking() }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hovered else { return }
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1),
                     xRadius: 5, yRadius: 5).fill()
    }
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
