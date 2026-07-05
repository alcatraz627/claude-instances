// LiveRowView.swift
// The live-updating per-instance menu row (NSView).
// (split from claude-instances-bar.swift — one module, same binary)

import AppKit
import Foundation
import SwiftUI

final class LiveRowView: NSView {
    private let stack = NSStackView()

    /// Maps each label to the palette token it draws its primary color from.
    /// Populated as labels are added via addLine(_:token:). Used by:
    ///   - hover detection: mouseEntered → look up token → fire onHoverToken
    ///   - reverse highlight: when `highlightedToken` is set, the matching
    ///     label gets a translucent accent-tinted background.
    private var tokenForLabel: [NSTextField: PaletteToken] = [:]

    /// Fired when the mouse enters/exits a token-tagged label. Receives the
    /// token under the cursor, or nil when the cursor leaves all tagged
    /// regions. Set externally (e.g. by the Settings preview).
    var onHoverToken: ((PaletteToken?) -> Void)?

    /// When set, the label corresponding to this token paints a translucent
    /// accent background — used by the Settings UI to telegraph "this row
    /// → this part of the row". Set via setHighlightedToken below.
    private var highlightedToken: PaletteToken?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func setupUI() {
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            // 20pt leading: matches the leading inset AppKit uses for
            // standard NSMenuItems (which start their title ~20pt in from
            // the cell edge, after the icon/checkmark column). Pre-pad
            // here so per-label whitespace prefixes aren't needed.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
    }

    /// Critical for view-based menu items: AppKit asks the view for its
    /// preferred size to lay out the NSMenuItem. Without this override
    /// the menu uses our init frame (360×80) and clips rows that would
    /// have rendered below 80px — which is most of them.
    override var intrinsicContentSize: NSSize {
        let s = stack.fittingSize
        return NSSize(width: max(s.width + 42, 340),
                      height: s.height + 8)
    }

    /// Replace rendered content with attributed strings derived from the
    /// current `LiveInstance`. Called both at first render (in menuNeedsUpdate)
    /// and on every scan tick while the menu is held open.
    func update(with inst: LiveInstance,
                leaf: String,
                fullPath: String?,
                stateIcon: String,
                stateStr: String,
                stateDetail: String,
                home: String) {
        // Tear down old labels.
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        // Indent is now controlled entirely by the stack's leading-edge
        // constraint (configured once in setupUI). Per-label whitespace
        // prefixes have been removed — they caused the "different left
        // padding on each line" inconsistency you saw.
        //
        // Font size scheme (3 sizes, was 4):
        //   13pt — header (model + leaf + elapsed)
        //   12pt — metrics row (data values)
        //   11pt — everything else (path, prompt, warnings)
        // Bold only on the model badge. All other rows use regular weight.
        //
        // Color scheme:
        //   badge color : per-model (orange/blue/teal)
        //   leaf        : labelColor (white in dark mode)
        //   elapsed     : tertiaryLabelColor (dim, was loud coral)
        //   ↳ subagent  : subagentColor (mint-cyan — replaces garish purple)
        //   ⎇ branch    : menuTeal (subtle, distinguishes from subagent)
        //   * modified  : menuRed if ≥20 else menuYellow (was pure red)
        //   ctx %       : menuRed <30 / yellow <60 / green ≥60
        //   turns       : tertiaryLabel (ambient count, gray)
        //   🔧 tools    : tertiaryLabel (was orange — too loud)
        //   ↑ tokens    : tokensColor (green, always)
        //   $ cost      : costColor (amber, always — was value-stepped)
        //   MB memory   : memColor (sky blue, always — was value-stepped)
        //   t/s speed   : tertiaryLabel
        //   warnings    : menuRed (softer than systemRed)
        //   state       : menuTeal

        // Reset token mapping at the start of each update — labels are
        // re-created from scratch below.
        tokenForLabel.removeAll()

        // Apply user density preference (compact / cozy / comfortable).
        // Read from UserDefaults on each render so changes propagate the
        // moment the user picks a different option in Settings.
        stack.spacing = densitySpacing()

        // Header is built as a horizontal stack of per-chunk labels — each
        // chunk gets its own NSTextField so it can be individually tagged
        // with a palette token. Hover + reverse-highlight then work for
        // each: model badge, leaf+elapsed, ↳N subagent, ⎇branch, *N modified.
        let m = modelDisplay(inst.model)
        let elapsed = inst.elapsed?.trimmingCharacters(in: .whitespaces) ?? "?"
        let modelToken: PaletteToken? = {
            switch inst.model {
            case "opus":   return .modelOpus
            case "sonnet": return .modelSonnet
            case "haiku":  return .modelHaiku
            default:       return nil
            }
        }()

        let headerRow = makeInlineRow()
        // 1. Model badge (the diamond/dot/circle glyph) — taggable per model
        appendChip(to: headerRow, text: m.badge, token: modelToken, attrs: [
            .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(13), weight: .bold),
            .foregroundColor: m.color,
        ])
        // State icon — shown alongside the badge when not idle. Now renders
        // as a tinted SF Symbol (NSTextAttachment) instead of an emoji,
        // so the `state.active` palette token actually colors the glyph
        // and baselines align cleanly with the system font.
        // (Previous emoji rendering forced .firstBaseline → .centerY
        // workarounds; the symbol path doesn't have that problem.)
        if !stateIcon.isEmpty,
           let symbolName = stateSymbolName(for: stateStr),
           let symbolAttr = symbolAttributedString(
               name: symbolName,
               pointSize: 11,
               tint: PaletteStore.shared.color(for: .stateActive)) {
            appendChip(to: headerRow, attr: symbolAttr, token: .stateActive)
        }
        // 2. Leaf + elapsed — visually one cluster, no individual token (
        //    structural). Bundled into a single label so spacing is tight.
        let leafElapsed = NSMutableAttributedString()
        leafElapsed.append(NSAttributedString(string: leaf, attributes: [
            .font: NSFont.systemFont(ofSize: BarFont.scaled(13), weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]))
        leafElapsed.append(NSAttributedString(string: "  \(elapsed)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(11), weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        appendChip(to: headerRow, attr: leafElapsed, token: nil)

        // 3. Subagent badge ↳N
        if let subs = inst.subagentCount, subs > 0 {
            appendChip(to: headerRow, text: "↳\(subs)", token: .accentSubagent, attrs: [
                .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(11), weight: .medium),
                .foregroundColor: subagentColor,
            ])
        }
        // Permission-mode badge — single-letter chip in plan or auto modes.
        // Default mode emits no badge (the absence-of-chip IS the indicator).
        // Tokens: permissionPlan (amber) vs permissionAuto (soft red — auto
        // bypasses edit confirmation, which is the safety-relevant signal).
        if let pm = inst.permissionMode, !pm.isEmpty {
            let permLetter: String?
            let permTok: PaletteToken?
            switch pm {
            case "plan":
                permLetter = "P"; permTok = .permissionPlan
            case "auto", "acceptEdits", "auto-accept", "auto-accept-edits":
                permLetter = "A"; permTok = .permissionAuto
            default:
                permLetter = nil; permTok = nil
            }
            if let l = permLetter, let t = permTok {
                appendChip(to: headerRow, text: l, token: t, attrs: [
                    .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(11), weight: .bold),
                    .foregroundColor: PaletteStore.shared.color(for: t),
                ])
            }
        }

        // 4. Branch badge ⎇<name>
        if let br = inst.gitBranch, !br.isEmpty {
            appendChip(to: headerRow, text: "⎇\(br)", token: .accentBranch, attrs: [
                .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(11), weight: .medium),
                .foregroundColor: menuTeal,
            ])
            // 5. Modified file count *N — token depends on severity (warnMid <20 / warnHigh ≥20)
            if let mod = inst.gitModified, mod > 0 {
                let modToken: PaletteToken = mod >= 20 ? .warnHigh : .warnMid
                let mc: NSColor = mod >= 20 ? menuRed : menuYellow
                appendChip(to: headerRow, text: "*\(mod)", token: modToken, attrs: [
                    .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(11), weight: .medium),
                    .foregroundColor: mc,
                ])
            }
        }
        stack.addArrangedSubview(headerRow)

        // Tab title (when distinct from leaf). Tagged with modelToken so it
        // counts as part of the "identity" cluster for hover purposes.
        if rowShows(.tabTitle), let tab = inst.tabTitle, !tab.isEmpty, tab != leaf {
            addLine(NSAttributedString(string: "⌥ \(tab)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(11), weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]), token: modelToken)
        }

        // Full cwd path — middle-truncated to one line (full path on hover).
        // Keeps the meaningful ends without the multi-line wall paths used to be.
        // Tagged with accentBranch (path + branch are the "location" cluster).
        if rowShows(.fullPath), let path = fullPath, path != leaf {
            addLine(NSAttributedString(string: middleTruncate(path, 46), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(11), weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]), token: .accentBranch, tooltip: path)
        }

        // State detail (only when not idle). No emoji here — the header chip
        // already carries the one tinted SF-Symbol state glyph (unified).
        if rowShows(.stateDetail), stateStr != "idle", !stateDetail.isEmpty {
            addLine(NSAttributedString(string: "\(stateStr): \(stateDetail)", attributes: [
                .font: NSFont.systemFont(ofSize: BarFont.scaled(11)),
                .foregroundColor: menuTeal,
            ]), token: .stateActive)
        }

        // Last user prompt — tagged with stateActive (it's a recency signal)
        if rowShows(.lastPrompt), let lp = inst.lastPrompt, !lp.isEmpty {
            addLine(NSAttributedString(string: "❯ \(lp)", attributes: [
                .font: NSFont.systemFont(ofSize: BarFont.scaled(11)),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]), token: .stateActive)
        }

        // Last tool ran — context for idle sessions ("where did I leave
        // off?"). Suppressed if the session has been idle >5min so it
        // doesn't linger as stale debt indefinitely.
        if rowShows(.lastTool), let lt = inst.lastTool, lt.name.count > 0 {
            let ago = lt.agoSeconds ?? 0
            // Only suppress when idle AND older than 5 min — active sessions
            // benefit from seeing the tool even at age 0 (just ran).
            let suppressBecauseStale = (stateStr == "idle") && (ago > 300)
            if !suppressBecauseStale {
                let agoStr = formatAgo(seconds: ago)
                let targetStr: String = {
                    guard let t = lt.target, !t.isEmpty else { return "" }
                    var s = t
                    if let cwd = inst.cwd, !cwd.isEmpty { s = s.replacingOccurrences(of: cwd, with: ".") }
                    s = s.replacingOccurrences(of: home, with: "~")
                    if s.count > 50 { s = "…" + s.suffix(49) }
                    return s
                }()
                let line = targetStr.isEmpty
                    ? "last: \(lt.name) · \(agoStr) ago"
                    : "last: \(lt.name) \(targetStr) · \(agoStr) ago"
                // Tagged with stateActive (recency hint, like last prompt).
                addLine(NSAttributedString(string: line, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(11), weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]), token: .stateActive)
            }
        }

        // Metrics row — per-token labels in a horizontal stack so each
        // value chunk gets individual hover coverage.
        let metFont = NSFont.monospacedSystemFont(ofSize: BarFont.scaled(12), weight: .regular)
        let metricsRow = makeInlineRow()

        // ctx % — value-stepped color; token mirrors the severity bucket so
        // hovering "warn.high" highlights ctx <30, "warn.mid" → ctx <60,
        // "success.high" → ctx ≥60.
        if let ctx = inst.statusline?.ctxRemaining, !ctx.isEmpty, ctx != "0" {
            let n = Int(ctx) ?? 0
            let (c, ctxToken): (NSColor, PaletteToken) =
                n < 30 ? (menuRed,    .warnHigh)    :
                n < 60 ? (menuYellow, .warnMid)     :
                         (menuGreen,  .successHigh)
            // A short bar beside ctx %, same green→amber→red severity scale as
            // the top rate bars — so context budget reads at a glance.
            appendBar(to: metricsRow, fraction: CGFloat(n) / 100.0, color: c)
            appendChip(to: metricsRow, text: "ctx \(ctx)%", token: ctxToken, attrs: [
                .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(12), weight: .medium),
                .foregroundColor: c,
            ])
        }
        // Remaining metrics: each its own chip with its own token.
        // Order matches the previous attributedString version.
        struct Chip { let text: String; let color: NSColor; let token: PaletteToken? }
        var chips: [Chip] = []
        if let t = inst.turns, t > 0 {
            chips.append(Chip(text: "\(t)t", color: turnsColor, token: .metricTurns))
        }
        if let tc = inst.toolCalls, tc > 0 {
            chips.append(Chip(text: "🔧\(tc)", color: toolsColor, token: .metricTools))
        }
        if let o = inst.outputTokens, o > 0 {
            chips.append(Chip(text: "↑\(fmtTokens(o))", color: tokensColor, token: .metricTokens))
        }
        if let c = inst.costUsd, c > 0 {
            chips.append(Chip(text: fmtCost(c), color: costColor, token: .metricCost))
        }
        if let rss = inst.statusline?.rssMb, rss != "0", !rss.isEmpty {
            chips.append(Chip(text: "\(rss)MB", color: memColor, token: .metricMemory))
        }
        if let ts = inst.statusline?.tokSpeed, !ts.isEmpty, ts != "0" {
            chips.append(Chip(text: "\(ts)t/s", color: speedColor, token: .metricSpeed))
        }
        for (i, chip) in chips.enumerated() {
            if i > 0 || metricsRow.arrangedSubviews.count > 0 {
                // Add a dim "·" separator BETWEEN chips (not before the first).
                appendChip(to: metricsRow, text: "·", token: nil, attrs: [
                    .font: metFont,
                    .foregroundColor: NSColor.quaternaryLabelColor,
                ])
            }
            appendChip(to: metricsRow, text: chip.text, token: chip.token, attrs: [
                .font: metFont,
                .foregroundColor: chip.color,
            ])
        }
        stack.addArrangedSubview(metricsRow)

        // Compaction-soon warning (soft red)
        if rowShows(.compactionWarn),
           let ctxStr = inst.statusline?.ctxRemaining,
           let n = Int(ctxStr), n > 0 && n < 15 {
            addLine(NSAttributedString(string: "⚠ Context low (\(n)%) — compaction imminent", attributes: [
                .font: NSFont.systemFont(ofSize: BarFont.scaled(11)),
                .foregroundColor: menuRed,
            ]), token: .warnHigh)
        }

        // Focus file — "what is being worked on right now". Middle-truncated to
        // one line (full path on hover), same as the cwd path.
        if rowShows(.focusFile), let focus = inst.statusline?.focusFile, !focus.isEmpty {
            var disp = focus
            if let cwd = inst.cwd, !cwd.isEmpty { disp = disp.replacingOccurrences(of: cwd, with: ".") }
            disp = disp.replacingOccurrences(of: home, with: "~")
            addLine(NSAttributedString(string: "📄 \(middleTruncate(disp, 46))", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: BarFont.scaled(11), weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]), token: .stateActive, tooltip: disp)
        }

        // MCP-down warning (soft red)
        if rowShows(.mcpDown), let mcp = inst.statusline?.mcpDown, !mcp.isEmpty {
            addLine(NSAttributedString(string: "⚠ MCP down: \(mcp)", attributes: [
                .font: NSFont.systemFont(ofSize: BarFont.scaled(11)),
                .foregroundColor: menuRed,
            ]), token: .warnHigh)
        }

        // CRITICAL: NSMenuItem.view uses self.frame.size to lay out the
        // menu row. It IGNORES intrinsicContentSize. So we must explicitly
        // resize self after the labels are laid out — otherwise the init
        // frame (360×80) wins, Auto Layout squeezes the inner stack to fit
        // 80px, and the bottom labels get clipped. With many rows that
        // looks like "header is missing" because the header is at the top
        // of the squeezed-into-80px stack, but rendered ABOVE the visible
        // 80px bound (negative y inside the menu cell).
        stack.layoutSubtreeIfNeeded()
        let needed = stack.fittingSize
        // Padding totals = 20 leading + 22 trailing + 4 top + 4 bottom.
        let h = max(needed.height + 8,  22)
        let w = max(needed.width + 42, 340)
        if frame.size.width != w || frame.size.height != h {
            setFrameSize(NSSize(width: w, height: h))
            invalidateIntrinsicContentSize()
        }

        // Re-apply the reverse-highlight (in case update() rebuilt labels
        // while a row was hovered in the Settings palette table).
        applyHighlightedToken()
    }

    /// Called by the Settings UI to highlight the label whose token matches.
    /// Sets a translucent accent background on the matching label(s). Nil to
    /// clear. Used to telegraph "this palette row → this part of the row."
    func setHighlightedToken(_ token: PaletteToken?) {
        guard highlightedToken != token else { return }
        highlightedToken = token
        applyHighlightedToken()
    }

    private func applyHighlightedToken() {
        let highlight = highlightedToken
        // CGColor route via the label's backing layer so we don't trigger
        // NSTextField's drawsBackground-toggle-induced intrinsic-size shift.
        // drawsBackground is set ONCE at label creation; here we only swap
        // backgroundColor (no size change). NSAnimationContext fades it.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            for (label, tok) in tokenForLabel {
                let isHit = (tok == highlight)
                label.backgroundColor = isHit
                    ? NSColor.controlAccentColor.withAlphaComponent(0.14)
                    : .clear
                label.needsDisplay = true
            }
        }
    }

    // ── Hover tracking ───────────────────────────────────────────────────
    //
    // One tracking area covering the whole view; on mouseMoved, hit-test
    // against each tagged label's frame (in our coordinate space) and fire
    // onHoverToken when the token under the cursor changes. Avoids the
    // overhead of N tracking areas (one per label) — single area, fast
    // lookup, debounced by tracking the last reported token.

    private var lastHoverToken: PaletteToken?
    private var rootTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let prev = rootTrackingArea { removeTrackingArea(prev) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        rootTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { handleHover(event) }
    override func mouseMoved(with event: NSEvent)   { handleHover(event) }
    override func mouseExited(with event: NSEvent) {
        if lastHoverToken != nil {
            lastHoverToken = nil
            onHoverToken?(nil)
        }
    }

    private func handleHover(_ event: NSEvent) {
        guard onHoverToken != nil else { return }
        let pt = convert(event.locationInWindow, from: nil)
        var hit: PaletteToken?
        for (label, tok) in tokenForLabel {
            // Convert label's frame (in stack's coords) to ours.
            let f = label.convert(label.bounds, to: self)
            if f.contains(pt) { hit = tok; break }
        }
        if hit != lastHoverToken {
            lastHoverToken = hit
            onHoverToken?(hit)
        }
    }

    /// Maps a session state to the SF Symbol used in the header chip.
    /// Returns nil for idle or unknown states.
    private func stateSymbolName(for state: String) -> String? {
        switch state {
        case "thinking":    return "brain"
        case "responding":  return "pencil.tip"
        case "tool_use":    return "wrench.adjustable"
        case "tool_result": return "checkmark.circle"
        default:            return nil
        }
    }

    /// Build an attributed string containing a single tinted SF Symbol.
    /// Used for the state-icon chip in the header — embedding the symbol as
    /// an NSTextAttachment lets it flow inline with adjacent text chips
    /// while picking up the tint color (which an emoji glyph cannot).
    /// Returns nil if the symbol name doesn't exist on this macOS version.
    private func symbolAttributedString(name: String,
                                        pointSize: CGFloat,
                                        tint: NSColor) -> NSAttributedString? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(.init(paletteColors: [tint]))
        let tinted = img.withSymbolConfiguration(config) ?? img
        let attachment = NSTextAttachment()
        attachment.image = tinted
        // Nudge the image's baseline so it center-aligns with adjacent text.
        attachment.bounds = NSRect(x: 0, y: -2, width: pointSize + 4, height: pointSize + 2)
        return NSAttributedString(attachment: attachment)
    }

    /// Build a horizontal NSStackView for inline chip composition (header
    /// row, metrics row). Each "chip" inside is its own NSTextField, tagged
    /// with its own palette token via `appendChip`.
    /// `.centerY` alignment + required vertical hugging keeps the row's
    /// intrinsic height at exactly the tallest chip — no baseline-padding
    /// gap that .firstBaseline introduces.
    private func makeInlineRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.distribution = .gravityAreas
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setContentHuggingPriority(.required, for: .vertical)
        row.setContentCompressionResistancePriority(.required, for: .vertical)
        return row
    }

    /// Append a single inline chip (an NSTextField) to a horizontal row.
    /// Same drawsBackground=true-always semantics as addLine() so hover
    /// highlight doesn't shift intrinsic size.
    private func appendChip(to row: NSStackView,
                            text: String? = nil,
                            attr: NSAttributedString? = nil,
                            token: PaletteToken? = nil,
                            attrs: [NSAttributedString.Key: Any]? = nil) {
        let labelAttr: NSAttributedString
        if let attr = attr {
            labelAttr = attr
        } else if let t = text {
            labelAttr = NSAttributedString(string: t, attributes: attrs ?? [:])
        } else {
            return
        }
        let label = NSTextField(labelWithAttributedString: labelAttr)
        if let t = token { tokenForLabel[label] = t }
        label.usesSingleLineMode = true
        label.lineBreakMode = .byClipping
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = true
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        row.addArrangedSubview(label)
    }

    /// Append a small progress bar chip (track + severity-coloured fill) to a
    /// horizontal row. Fraction is clamped to 0…1.
    private func appendBar(to row: NSStackView, fraction: CGFloat, color: NSColor) {
        let w: CGFloat = 28, h: CGFloat = 5
        let f = max(0, min(1, fraction))
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.5).cgColor
        bar.layer?.cornerRadius = h / 2
        bar.translatesAutoresizingMaskIntoConstraints = false
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: max(h, w * f), height: h))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = color.cgColor
        fill.layer?.cornerRadius = h / 2
        fill.autoresizingMask = [.maxXMargin]
        bar.addSubview(fill)
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: w),
            bar.heightAnchor.constraint(equalToConstant: h),
        ])
        bar.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(bar)
    }

    private func addLine(_ attr: NSAttributedString,
                         wrapMode: NSLineBreakMode = .byWordWrapping,
                         token: PaletteToken? = nil,
                         tooltip: String? = nil) {
        let label = NSTextField(labelWithAttributedString: attr)
        label.toolTip = tooltip
        if let t = token { tokenForLabel[label] = t }
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        // ALWAYS draw a background — initially .clear. The hover-highlight
        // path only swaps the color, never toggles drawsBackground, so the
        // label's intrinsic size never changes when highlight enters/exits.
        // (Toggling drawsBackground at runtime caused layout shift.)
        label.drawsBackground = true
        label.backgroundColor = .clear
        label.lineBreakMode = wrapMode
        label.preferredMaxLayoutWidth = 320
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        // Set vertical content hugging high so empty/short labels don't
        // expand to swallow vertical space the stack reserves for siblings.
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(label)
    }
}

// ─── SwiftUI bridge for LiveRowView ──────────────────────────────────────────
//
// Wraps the existing `LiveRowView` NSView so SwiftUI views (e.g. the
// Settings tab's palette-preview pane) can render exactly the same DOM as
// the live menu. Single renderer, zero drift — the preview IS what the
// menu shows.
//
// Re-renders whenever `inst` or `paletteVersion` changes (the latter lets
// the parent force a re-paint when palette tokens change via UserDefaults).

struct LiveRowViewRepresentable: NSViewRepresentable {
    let inst: LiveInstance
    let home: String
    var paletteVersion: Int = 0  // bumped to force updateNSView
    var highlightedToken: PaletteToken? = nil  // reverse: row hover → preview highlight
    var onHoverToken: ((PaletteToken?) -> Void)? = nil  // forward: preview hover → row highlight

    func makeNSView(context: Context) -> LiveRowView {
        let v = LiveRowView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        v.onHoverToken = onHoverToken
        applyUpdate(to: v)
        return v
    }

    func updateNSView(_ v: LiveRowView, context: Context) {
        v.onHoverToken = onHoverToken
        applyUpdate(to: v)
        v.setHighlightedToken(highlightedToken)
    }

    private func applyUpdate(to v: LiveRowView) {
        let leaf: String = {
            if let tt = inst.tabTitle, !tt.isEmpty { return tt }
            if let cwd = inst.cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
            return inst.cwdShort ?? "(unknown)"
        }()
        let fullPath: String? = {
            guard let cwd = inst.cwd, !cwd.isEmpty else { return nil }
            return cwd.replacingOccurrences(of: home, with: "~")
        }()
        let stateStr = inst.sessionState?.state ?? "idle"
        let stateDetail = inst.sessionState?.detail ?? ""
        let stateIcons: [String: String] = [
            "thinking": "💭", "responding": "✍️", "tool_use": "🔧",
            "tool_result": "⚙️", "idle": "",
        ]
        v.update(with: inst,
                 leaf: leaf,
                 fullPath: fullPath,
                 stateIcon: stateIcons[stateStr] ?? "",
                 stateStr: stateStr,
                 stateDetail: stateDetail,
                 home: home)
    }
}

// ─── Bar Delegate ────────────────────────────────────────────────────────────

