// Bar.swift
// BarDelegate — status item, menu construction, action handlers.
// (split from claude-instances-bar.swift — one module, same binary)

import AppKit
import Foundation
import SwiftUI

final class BarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var scanTimer: Timer?

    // Public so DashboardController can read cached data
    private(set) var cachedData: ScanResult?
    private var lastScanError = false
    private var theMenu: NSMenu!
    private var dashboardController: DashboardController?

    /// Tick counter for quick/full scan alternation.
    /// Quick scan (~90ms) runs every 5s. Full scan (~185ms) runs every 6th tick (30s).
    private var scanTick: Int = 0
    private let fullScanInterval: Int = 6

    /// Warning threshold for rate limit indicators (persisted via UserDefaults).
    // Two usage zones drive both the rate bars' colour and the menu-bar icon flag.
    // A cap isn't something to avoid (hitting it is fine), so these are "highlight
    // when you cross into this zone", not "a limit". warn ≤ danger.
    private let thresholdKey = "rateLimitWarningThreshold"
    private var warningThreshold: Int {
        get { UserDefaults.standard.integer(forKey: thresholdKey) }
        set { UserDefaults.standard.set(newValue, forKey: thresholdKey) }
    }
    private let dangerKey = "rateLimitDangerThreshold"
    private var dangerThreshold: Int {
        get { UserDefaults.standard.integer(forKey: dangerKey) }
        set { UserDefaults.standard.set(newValue, forKey: dangerKey) }
    }
    /// A limit whose window resets within this many minutes lights a small
    /// light-blue "resets soon" dot on its badge row. Default 30 (Settings-tunable).
    private let resetSoonKey = "rateLimitResetSoonMinutes"
    private var resetSoonMinutes: Int {
        get { let v = UserDefaults.standard.integer(forKey: resetSoonKey); return v > 0 ? v : 30 }
        set { UserDefaults.standard.set(newValue, forKey: resetSoonKey) }
    }
    /// Claude logo, loaded once and drawn into the composited badge image each
    /// tick (avoids re-reading the file on every updateButton()).
    private var barIcon: NSImage?
    /// The severity colour for a usage percentage, by zone (warn / danger).
    private func zoneColor(forUsage pct: Int) -> NSColor {
        if pct >= dangerThreshold  { return PaletteStore.shared.color(for: .warnHigh) }
        if pct >= warningThreshold { return PaletteStore.shared.color(for: .warnMid) }
        return PaletteStore.shared.color(for: .successHigh)
    }

    /// Refresh cadence — interval (seconds) at which the scan timer fires.
    /// 0 means "paused"; UI exposes presets via the Refresh submenu.
    /// Persisted via UserDefaults so it survives restarts.
    private let refreshIntervalKey = "scanRefreshInterval"
    private static let refreshPresets: [Double] = [1, 2, 5, 10, 30, 60]
    private var refreshInterval: Double {
        get {
            let v = UserDefaults.standard.double(forKey: refreshIntervalKey)
            return v > 0 ? v : 5.0
        }
        set { UserDefaults.standard.set(newValue, forKey: refreshIntervalKey) }
    }
    private var refreshPaused: Bool {
        get { UserDefaults.standard.bool(forKey: refreshIntervalKey + ".paused") }
        set { UserDefaults.standard.set(newValue, forKey: refreshIntervalKey + ".paused") }
    }
    private var lastScanAt: Date?

    // Live-updating menu rows. Keyed by pid so refreshData() can find them
    // and call update() when the menu is open. Cleared on menuDidClose
    // because the menu rebuilds from scratch on next open.
    private var runningRows: [Int: (NSMenuItem, LiveRowView)] = [:]
    private var menuIsOpen = false

    // ── App lifecycle ────────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ note: Notification) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        dlog("─── claude-instances-bar starting ───")
        dlog("pid=\(myPID) macOS=\(osVer) log=\(debugLog)")

        // Register UserDefaults defaults (doesn't write — just provides fallbacks)
        UserDefaults.standard.register(defaults: [thresholdKey: 70, dangerKey: 90, resetSoonKey: 30])

        // Apply persisted appearance preference (System / Light / Dark).
        // Affects the dashboard window's chrome. Menu material adapts via OS.
        applyAppearancePref(loadAppearancePref())

        // Kill any other instances of ourselves (dedupe on launch)
        killOtherInstances(myPID: myPID)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        theMenu                  = NSMenu()
        theMenu.autoenablesItems = false
        theMenu.delegate         = self
        statusItem.menu          = theMenu

        // Hover detection for the usage-preview popover. A tracking area on the
        // status button doesn't deliver to a non-view owner, and global
        // mouse-moved monitors are flaky over the menu bar — so poll the cursor
        // against the status item's screen frame a few times a second. The test
        // is trivial (a frame contains-point), so 5 Hz is negligible.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkHover()
        }

        // Initial scan
        refreshData()

        // Background timer — scan at user-selected cadence (or paused)
        restartScanTimer()

        // When the Settings tab mutates a palette token, immediately refresh
        // open menu rows + the bar button (in case it cared about a color).
        NotificationCenter.default.addObserver(
            forName: PaletteStore.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshLiveRows()
            self?.updateButton()
        }

        // Menu-behavior changes — density / default tab / time format /
        // refresh cadence / warn threshold / row visibility — all funnel
        // through this notification. Side effects:
        //   - invalidate the DateFormatter cache (time-format may have flipped)
        //   - rebuild the scan timer (cadence may have changed)
        //   - refresh the visible menu rows (any of: density, row toggles,
        //     warning threshold, etc.)
        NotificationCenter.default.addObserver(
            forName: .menuBehaviorDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            invalidateTimeFormatterCache()
            self?.restartScanTimer()
            self?.refreshLiveRows()
            self?.updateButton()
        }
    }

    /// (Re)start the periodic scan timer using the current `refreshInterval`.
    /// Call after the user changes cadence via the Refresh submenu.
    private func restartScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil

        if refreshPaused {
            dlog("scan timer paused (no auto-refresh)")
            return
        }

        let interval = refreshInterval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
        RunLoop.current.add(t, forMode: .common)
        scanTimer = t
        dlog("scan timer started — interval=\(interval)s (full every \(fullScanInterval) ticks)")
    }

    func applicationWillTerminate(_ note: Notification) {
        scanTimer?.invalidate()
        dlog("terminating")
    }

    // ── Dedupe: kill older instances ─────────────────────────────────────────

    private func killOtherInstances(myPID: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "claude-instances-bar"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pids = output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        var killed = 0
        for pid in pids where pid != myPID {
            kill(pid, SIGTERM)
            killed += 1
        }
        if killed > 0 {
            dlog("dedupe: killed \(killed) stale instance(s)")
            // Brief pause to let stale NSStatusItems clean up
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // ── Data refresh ─────────────────────────────────────────────────────────

    private func refreshData() {
        scanTick += 1
        let isFullScan = (scanTick % fullScanInterval == 0) || cachedData == nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runScanner(quick: !isFullScan)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let r = result {
                    if isFullScan {
                        // Full scan — replace everything
                        self.cachedData = r
                    } else if let existing = self.cachedData {
                        // Quick scan — merge live data + fresh limits into existing cached result.
                        // CRITICAL: also merge per-instance enrichment fields
                        // (git_branch / git_modified / last_prompt) from the
                        // previous full scan, since --quick mode emits empty
                        // values for those. Without this merge, every quick
                        // tick wipes branch/modified/prompt off the screen.
                        let prevByPid = Dictionary(uniqueKeysWithValues:
                            existing.live.map { ($0.pid, $0) })
                        let mergedLive = r.live.map { (newInst: LiveInstance) -> LiveInstance in
                            guard let prev = prevByPid[newInst.pid] else { return newInst }
                            return newInst.preservingEnrichment(from: prev)
                        }
                        self.cachedData = ScanResult(
                            live: mergedLive,
                            history: existing.history,
                            recentEvents: existing.recentEvents,
                            deepEvents: existing.deepEvents,
                            limits: r.limits ?? existing.limits,
                            aggregates: existing.aggregates,
                            liveCount: r.liveCount
                        )
                    } else {
                        self.cachedData = r
                    }
                    self.lastScanError = false
                    self.lastScanAt    = Date()
                } else {
                    self.lastScanError = true
                }
                self.updateButton()
                // Push fresh data to dashboard if open
                self.dashboardController?.updateData(self.cachedData)
                // Live-update the open menu's per-instance rows. Only does
                // work when menuIsOpen=true; cheap no-op otherwise.
                self.refreshLiveRows()
            }
        }
    }

    // ── Menu bar button ──────────────────────────────────────────────────────

    /// One badge row = a limit's identity letter + its usage % + a "resets
    /// soon" flag. Letter colour is the limit's fixed identity (W red, 5
    /// orange, F teal); the % is severity-tinted by the same zones the
    /// dropdown bars use, so a glance reads *which* limit and *how bad* at once.
    private struct BadgeRow {
        let letter: String
        let identity: NSColor
        let pct: Int
        let resetsSoon: Bool
    }

    /// True iff this window's reset countdown is within the user's threshold.
    private func resetsSoon(_ resetsAt: String?) -> Bool {
        guard let secs = rateLimitResetSeconds(resetsAt) else { return false }
        return secs <= Double(resetSoonMinutes * 60)
    }

    private func updateButton() {
        guard let btn = statusItem.button else { return }

        let liveCount = cachedData?.liveCount ?? 0
        let hasPerm = cachedData?.recentEvents?.suffix(3).contains { $0.event == "PermissionRequest" } ?? false
        let countText = hasPerm ? "⚠ \(liveCount)" : (liveCount > 0 ? "\(liveCount)" : "–")

        // One row per limit window we actually have data for. Order W → 5
        // (Fable would slot in first as F, teal, once it exists in the feed).
        var rows: [BadgeRow] = []
        if let limits = cachedData?.limits {
            if let w = limits.week {
                rows.append(BadgeRow(letter: "W", identity: .systemRed,
                                     pct: Int(w.pct), resetsSoon: resetsSoon(limits.resetsAtWeekly)))
            }
            if let f = limits.fiveH {
                rows.append(BadgeRow(letter: "5", identity: .systemOrange,
                                     pct: Int(f.pct), resetsSoon: resetsSoon(limits.resetsAt)))
            }
        }

        // Status items are single-line, so the whole badge is drawn as one
        // multi-colour NSImage (isTemplate=false keeps the per-letter hues).
        btn.image = composeBadgeImage(count: countText, rows: rows)
        btn.imagePosition = .imageOnly
        btn.title = ""
        btn.attributedTitle = NSAttributedString(string: "")
        btn.alphaValue = liveCount == 0 ? 0.5 : 1.0   // dim when idle
    }

    /// Draw the claude icon + live count + up-to-3 stacked limit rows into a
    /// single NSImage sized to the menu-bar height. Rows auto-fit vertically so
    /// 2 rows read comfortably now and a 3rd (Fable) fits without changes.
    private func composeBadgeImage(count: String, rows: [BadgeRow]) -> NSImage {
        let barH = NSStatusBar.system.thickness            // ~22pt
        let iconSize: CGFloat = 16

        if barIcon == nil, let img = NSImage(contentsOfFile: iconPath) {
            img.size = NSSize(width: iconSize, height: iconSize)
            img.isTemplate = false
            barIcon = img
        }
        let icon = barIcon

        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let countStr = NSAttributedString(string: count, attributes: [
            .font: countFont, .foregroundColor: NSColor.labelColor,
        ])
        let countW = ceil(countStr.size().width)

        // Row metrics auto-fit the row count into the bar height.
        let n = max(rows.count, 1)
        let lineH = min(11, (barH - 3) / CGFloat(n))
        let rowFontSize = max(6, lineH - 1.8)
        let letterFont = NSFont.monospacedDigitSystemFont(ofSize: rowFontSize, weight: .bold)
        let pctFont    = NSFont.monospacedDigitSystemFont(ofSize: rowFontSize, weight: .semibold)
        let dotDia: CGFloat = 4

        // Pre-build each row's attributed string + measure the widest.
        var rowStrings: [(str: NSAttributedString, dot: Bool)] = []
        var rowsW: CGFloat = 0
        for r in rows {
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: r.letter, attributes: [
                .font: letterFont, .foregroundColor: r.identity]))
            s.append(NSAttributedString(string: " \(r.pct)%", attributes: [
                .font: pctFont, .foregroundColor: zoneColor(forUsage: r.pct)]))
            var w = ceil(s.size().width)
            if r.resetsSoon { w += dotDia + 2 }
            rowsW = max(rowsW, w)
            rowStrings.append((s, r.resetsSoon))
        }

        let padL: CGFloat = 2, gapIcon: CGFloat = 3, gapRows: CGFloat = 6, padR: CGFloat = 3
        let iconW: CGFloat = icon != nil ? iconSize : 0
        let totalW = padL + iconW + (iconW > 0 ? gapIcon : 0) + countW
                   + (rows.isEmpty ? 0 : gapRows + rowsW) + padR
        let dotColor = NSColor(calibratedRed: 0.35, green: 0.70, blue: 1.0, alpha: 1)

        let img = NSImage(size: NSSize(width: totalW, height: barH), flipped: false) { _ in
            var x = padL
            if let icon = icon {
                icon.draw(in: NSRect(x: x, y: (barH - iconSize) / 2, width: iconSize, height: iconSize))
                x += iconW + gapIcon
            }
            // Count, vertically centred.
            countStr.draw(at: NSPoint(x: x, y: (barH - countStr.size().height) / 2))
            x += countW

            if !rowStrings.isEmpty {
                x += gapRows
                let blockH = CGFloat(rowStrings.count) * lineH
                let startY = (barH - blockH) / 2
                for (i, row) in rowStrings.enumerated() {
                    // Row 0 on top → highest y (origin is bottom-left).
                    let rowY = startY + CGFloat(rowStrings.count - 1 - i) * lineH
                    row.str.draw(at: NSPoint(x: x, y: rowY + (lineH - row.str.size().height) / 2))
                    if row.dot {
                        let sw = ceil(row.str.size().width)
                        let d = NSRect(x: x + sw + 2, y: rowY + (lineH - dotDia) / 2,
                                       width: dotDia, height: dotDia)
                        dotColor.setFill()
                        NSBezierPath(ovalIn: d).fill()
                    }
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    // ── NSMenuDelegate ───────────────────────────────────────────────────────

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        runningRows.removeAll()  // start fresh; populateMenuItems re-stores
        populateMenuItems(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        hideUsagePopover()   // the dropdown supersedes the hover preview
        // First scan tick after open is the next scheduled fire — kick one
        // off immediately so the user sees freshest possible data without
        // waiting up to `refreshInterval` seconds.
        if !refreshPaused { refreshData() }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // The view-based items hold strong refs we can release; the menu is
        // about to be torn down anyway, but eager cleanup keeps things tidy.
        runningRows.removeAll()
    }

    /// Iterate the live-row views and re-render each from current cachedData.
    /// Called by refreshData() when `menuIsOpen` is true so users see metrics
    /// tick (elapsed, ctx %, tokens, cost, mem) without closing the menu.
    private func refreshLiveRows() {
        guard menuIsOpen, let live = cachedData?.live else { return }
        // Build a quick lookup so we don't re-iterate per row.
        let byPid = Dictionary(uniqueKeysWithValues: live.map { ($0.pid, $0) })
        for (pid, pair) in runningRows {
            guard let inst = byPid[pid] else { continue }
            let leaf = liveRowLeaf(inst)
            let fullPath = liveRowFullPath(inst)
            let stateStr = inst.sessionState?.state ?? "idle"
            let stateDetail = inst.sessionState?.detail ?? ""
            let stateIcon = liveRowStateIcons[stateStr] ?? ""
            pair.1.update(with: inst,
                          leaf: leaf,
                          fullPath: fullPath,
                          stateIcon: stateIcon,
                          stateStr: stateStr,
                          stateDetail: stateDetail,
                          home: home)
        }
    }

    // Helpers shared by the live-section builder and refreshLiveRows.
    // SF Symbol names per session state. Empty for idle. Used by LiveRowView
    // to render tintable images instead of emoji — gives the palette real
    // coverage of the state glyphs and keeps baselines aligned to the
    // system font.
    private let liveRowStateSymbols: [String: String] = [
        "thinking":    "brain",
        "responding":  "pencil.tip",
        "tool_use":    "wrench.adjustable",
        "tool_result": "checkmark.circle",
        "idle":        "",
    ]
    /// Legacy emoji map — kept for `state-detail` line which uses the icon
    /// inline with attributedString text. The header chip uses the SF Symbol.
    private let liveRowStateIcons: [String: String] = [
        "thinking":    "💭",
        "responding":  "✍️",
        "tool_use":    "🔧",
        "tool_result": "⚙️",
        "idle":        "",
    ]
    private func liveRowLeaf(_ inst: LiveInstance) -> String {
        if let tt = inst.tabTitle, !tt.isEmpty { return tt }
        if let cwd = inst.cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return inst.cwdShort ?? "(unknown)"
    }
    private func liveRowFullPath(_ inst: LiveInstance) -> String? {
        guard let cwd = inst.cwd, !cwd.isEmpty else { return nil }
        return cwd.replacingOccurrences(of: home, with: "~")
    }

    // ── Menu construction ────────────────────────────────────────────────────

    private func populateMenuItems(_ menu: NSMenu) {
        menu.minimumWidth = 340

        guard let data = cachedData else {
            addDim(menu, "Scanning…")
            menu.addItem(.separator())
            addAction(menu, "Quit", #selector(NSApplication.terminate(_:)), icon: "power")
            return
        }

        // ── Stale data warning ───────────────────────────────────────────────
        if lastScanError {
            addColored(menu, "  ⚠  Scanner error — showing stale data", color: .systemRed, size: 12)
            menu.addItem(.separator())
        }

        // ── Rate limits (top — most urgent info) ────────────────────────────
        addRateLimitsSection(menu, data)

        // ── Usage stats (today/week aggregates) ─────────────────────────────
        addUsageStatsSection(menu, data)

        // ── Live instances ───────────────────────────────────────────────────
        addLiveInstancesSection(menu, data)

        // ── Events ───────────────────────────────────────────────────────────
        addEventsSection(menu, data)

        // ── History ──────────────────────────────────────────────────────────
        addHistorySection(menu, data)

        // ── Actions ──────────────────────────────────────────────────────────
        addActionsSection(menu, data)
    }

    // ── Shared usage-bar row (dropdown AND hover popover use this) ───────────

    /// One usage bar row: label + track/fill bar + percent + reset countdown, on
    /// fixed 326×20 frames so 5h/7d columns align. Pure view construction with no
    /// menu coupling, so the hover popover reuses it verbatim (one source of truth).
    private func makeBarRow(_ label: String, pct: Int, color: NSColor, countdown: String?) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 326, height: 20))
        func text(_ s: String, _ font: NSFont, _ c: NSColor, _ x: CGFloat, _ w: CGFloat) {
            let t = NSTextField(labelWithString: s)
            t.font = font; t.textColor = c
            t.frame = NSRect(x: x, y: 2, width: w, height: 15)
            v.addSubview(t)
        }
        text(label, BarFont.monoBody, .secondaryLabelColor, 14, 44)
        let trackW: CGFloat = 96
        let track = NSView(frame: NSRect(x: 60, y: 7, width: trackW, height: 6))
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.45).cgColor
        track.layer?.cornerRadius = 3
        let f = CGFloat(min(100, max(0, pct))) / 100.0
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: max(3, trackW * f), height: 6))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = color.cgColor
        fill.layer?.cornerRadius = 3
        track.addSubview(fill)
        v.addSubview(track)
        text("\(pct)%", BarFont.monoBody, color, 166, 42)
        if let cd = countdown {
            text("resets ~\(cd)", BarFont.monoCaption, .tertiaryLabelColor, 214, 108)
        }
        return v
    }

    // ── Hover usage popover (ask #2) ─────────────────────────────────────────
    //
    // A non-clickable, translucent preview of the top usage section — the same
    // bar rows as the dropdown, plus the read-only "Usage zones" line — shown
    // when the mouse hovers the menu-bar icon (and the menu itself isn't open).
    // Duplicates the menu's material via an NSVisualEffectView(.menu).

    private var usagePopover: NSPopover?
    private var hoverCloseWork: DispatchWorkItem?
    private var hoverTimer: Timer?
    private var hoverInside = false

    /// Builds the popover content: the shared bar rows stacked over the zones
    /// line, inside a menu-material vibrancy view. Returns nil when there's no
    /// limit data (nothing to preview).
    private func makeUsagePopoverController() -> NSViewController? {
        guard let limits = cachedData?.limits,
              limits.fiveH != nil || limits.week != nil else { return nil }

        let rowW: CGFloat = 326, padX: CGFloat = 12, padTop: CGFloat = 10, padBot: CGFloat = 8
        let rowH: CGFloat = 20, gap: CGFloat = 2, zonesH: CGFloat = 16, zonesGap: CGFloat = 4

        var rows: [NSView] = []       // [5h, 7d] in dropdown order (5h on top)
        if let five = limits.fiveH {
            let p = Int(five.pct)
            rows.append(makeBarRow("⏱ 5h", pct: p, color: zoneColor(forUsage: p),
                                   countdown: rateLimitCountdown(limits.resetsAt)))
        }
        if let week = limits.week {
            let p = Int(week.pct)
            rows.append(makeBarRow("📅 7d", pct: p, color: zoneColor(forUsage: p),
                                   countdown: rateLimitCountdown(limits.resetsAtWeekly)))
        }

        let zones = NSTextField(labelWithString:
            " ⚙ Usage zones · warn ≥\(warningThreshold)% · danger ≥\(dangerThreshold)%")
        zones.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        zones.textColor = .secondaryLabelColor

        let contentW = rowW + padX * 2
        let contentH = padTop + CGFloat(rows.count) * (rowH + gap) + zonesGap + zonesH + padBot

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        fx.material = .menu
        fx.blendingMode = .behindWindow
        fx.state = .active

        // Bottom-up frames (non-flipped): zones at the bottom, rows above it with
        // 5h on top. Reversed so rows[0] (5h) lands at the highest y.
        var y = padBot
        zones.frame = NSRect(x: padX + 14, y: y, width: rowW - 14, height: zonesH)
        fx.addSubview(zones)
        y += zonesH + zonesGap
        for row in rows.reversed() {
            row.setFrameOrigin(NSPoint(x: padX, y: y))
            fx.addSubview(row)
            y += rowH + gap
        }

        let vc = NSViewController()
        vc.view = fx
        return vc
    }

    /// Called on every mouse-moved event. Shows the popover when the cursor
    /// enters the status item's screen rect, hides it (after a short grace
    /// delay) when it leaves. Cheap frame test; no per-event allocation.
    private func checkHover() {
        guard let btn = statusItem.button, let win = btn.window else { return }
        let screenRect = win.convertToScreen(btn.convert(btn.bounds, to: nil))
        let inside = screenRect.contains(NSEvent.mouseLocation)
        if inside && !hoverInside {
            hoverInside = true
            hoverCloseWork?.cancel(); hoverCloseWork = nil
            if !menuIsOpen { showUsagePopover() }
        } else if !inside && hoverInside {
            hoverInside = false
            let work = DispatchWorkItem { [weak self] in self?.hideUsagePopover() }
            hoverCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    private func showUsagePopover() {
        guard let btn = statusItem.button, let vc = makeUsagePopoverController() else { return }
        let pop = usagePopover ?? NSPopover()
        pop.contentViewController = vc
        pop.contentSize = vc.view.frame.size
        pop.behavior = .applicationDefined   // dismissal is hover-driven, not click
        pop.animates = false
        usagePopover = pop
        if !pop.isShown {
            pop.show(relativeTo: btn.bounds, of: btn, preferredEdge: .maxY)
        }
    }

    private func hideUsagePopover() {
        usagePopover?.performClose(nil)
        usagePopover = nil
    }

    // ── Section: Rate Limits ─────────────────────────────────────────────────

    private func addRateLimitsSection(_ menu: NSMenu, _ data: ScanResult) {
        guard let limits = data.limits else { return }
        guard limits.fiveH != nil || limits.week != nil else { return }

        // One bar row: label + bracketed bar + percent + reset countdown. The
        // filled run carries the severity colour, the empty run is dim, and the
        // countdown is muted — so the row reads at a glance without a wash of
        // competing colour.
        // A drawn bar row (track + fill as real views) on fixed frames so 5h and
        // 7d align crisply — no ASCII bars. Colour comes from the usage zones, so
        // the bars and the menu-bar icon flag the same thresholds.
        func addBarItem(_ label: String, pct: Int, color: NSColor, countdown: String?) {
            let item = NSMenuItem()
            item.view = self.makeBarRow(label, pct: pct, color: color, countdown: countdown)
            menu.addItem(item)
        }

        if let fiveH = limits.fiveH {
            let r5 = Int(fiveH.pct)
            addBarItem("⏱ 5h", pct: r5, color: zoneColor(forUsage: r5), countdown: rateLimitCountdown(limits.resetsAt))
        }
        if let week = limits.week {
            let r7 = Int(week.pct)
            addBarItem("📅 7d", pct: r7, color: zoneColor(forUsage: r7), countdown: rateLimitCountdown(limits.resetsAtWeekly))
        }

        // Usage zones — two sliders (warn / danger) that flag the menu-bar icon.
        // Reframed from the old single "Warning at N%": a cap is not a wall.
        let thresholdItem = NSMenuItem()
        thresholdItem.attributedTitle = NSAttributedString(
            string: " ⚙ Usage zones · warn ≥\(warningThreshold)% · danger ≥\(dangerThreshold)%",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])

        let subMenu = NSMenu()
        let note = NSMenuItem()
        note.attributedTitle = NSAttributedString(
            string: "  The menu-bar icon flags usage that crosses a zone.\n  Hitting a cap is fine; these are signals, not limits.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
        note.isEnabled = false
        subMenu.addItem(note)
        subMenu.addItem(.separator())

        func zoneSlider(_ title: String, value: Int, tag: Int, labelTag: Int) -> NSMenuItem {
            let item = NSMenuItem()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 248, height: 30))
            let label = NSTextField(labelWithString: "\(title) \(value)%")
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 14, y: 5, width: 92, height: 18)
            label.tag = labelTag
            let slider = NSSlider(value: Double(value), minValue: 50, maxValue: 100,
                                  target: self, action: #selector(thresholdSliderChanged(_:)))
            slider.frame = NSRect(x: 110, y: 5, width: 122, height: 18)
            slider.isContinuous = true
            slider.numberOfTickMarks = 11
            slider.allowsTickMarkValuesOnly = true
            slider.tag = tag
            container.addSubview(label)
            container.addSubview(slider)
            item.view = container
            return item
        }
        subMenu.addItem(zoneSlider("Warn ≥",   value: warningThreshold, tag: 1, labelTag: 101))
        subMenu.addItem(zoneSlider("Danger ≥", value: dangerThreshold,  tag: 2, labelTag: 102))

        thresholdItem.submenu = subMenu
        menu.addItem(thresholdItem)

        menu.addItem(.separator())
    }

    // ── Section: Usage Stats (inline today/week aggregates) ────────────────

    private func addUsageStatsSection(_ menu: NSMenu, _ data: ScanResult) {
        guard let agg = data.aggregates else { return }
        let today = agg.today
        let week = agg.week

        // Only show if we have data
        let todaySessions = today?.sessions ?? 0
        let weekSessions = week?.sessions ?? 0
        guard todaySessions > 0 || weekSessions > 0 else { return }

        // A columned row so Today and Week align their stats on one tab stop.
        func buildUsageRow(label: String, icon: String, period: AggregatesPeriod?, showModels: Bool) -> NSMenuItem {
            let labelCell = seg(" \(icon) \(label)", BarFont.title, .labelColor)
            let statsCell = NSMutableAttributedString()
            if let p = period {
                var stats: [String] = []
                if let s = p.sessions, s > 0 { stats.append("\(s) sess") }
                if let t = p.turns, t > 0 { stats.append("\(fmtTokens(t)) turns") }
                if let c = p.costUsd, c > 0 { stats.append(fmtCost(c)) }
                statsCell.append(seg(stats.joined(separator: " · "), BarFont.monoBody, .secondaryLabelColor))
            }
            // Model badges (Today only), in identity colour.
            if showModels, let breakdown = agg.modelBreakdown, !breakdown.isEmpty {
                var added = 0
                for entry in breakdown.sorted(by: { $0.value > $1.value }) {
                    let m = modelDisplay(entry.key)
                    guard m.label != "?" else { continue }
                    statsCell.append(seg(added == 0 ? "   " : " ", BarFont.monoCaption, .secondaryLabelColor))
                    statsCell.append(seg("\(m.badge)\(entry.value)", BarFont.monoCaption, m.color))
                    added += 1
                }
            }
            let item = NSMenuItem()
            item.attributedTitle = columned([labelCell, statsCell], stops: [82])
            item.isEnabled = false
            return item
        }

        if todaySessions > 0 {
            menu.addItem(buildUsageRow(label: "Today", icon: "📊", period: today, showModels: true))
        }
        if weekSessions > 0 && weekSessions != todaySessions {
            menu.addItem(buildUsageRow(label: "Week", icon: "📈", period: week, showModels: false))
        }

        menu.addItem(.separator())
    }

    // ── Section: Live Instances ──────────────────────────────────────────────

    private func addLiveInstancesSection(_ menu: NSMenu, _ data: ScanResult) {
        let live = data.live

        if live.isEmpty {
            let item = NSMenuItem()
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: "  No live instances", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            item.attributedTitle = attr
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            return
        }

        // Section header with aggregate stats — cumulative cost included
        // so the user has burn-rate awareness without expanding any session.
        let totalRss  = live.compactMap { Int($0.statusline?.rssMb ?? "0") }.reduce(0, +)
        let totalOut  = live.compactMap { $0.outputTokens }.reduce(0, +)
        let totalCost = live.compactMap { $0.costUsd }.reduce(0.0, +)
        var headerParts = ["\(live.count) live"]
        if totalRss  > 0  { headerParts.append("\(totalRss) MB") }
        if totalOut  > 0  { headerParts.append("↑\(fmtTokens(totalOut))") }
        if totalCost > 0  { headerParts.append(fmtCost(totalCost)) }
        addSectionHeader(menu, headerParts.joined(separator: "  ·  "), icon: "sparkles")

        for (idx, inst) in live.enumerated() {
            // Build the live-updating row view. All visual content
            // (header / tab title / full path / state detail / last prompt /
            // metrics / compaction warn / focus file / mcp-down) lives inside
            // ONE NSMenuItem.view so the labels can mutate in place while the
            // menu is open. AppKit doesn't redraw attributedTitle of an open
            // standard menu item — the view-based approach is the workaround.
            let leaf = liveRowLeaf(inst)
            let fullPath = liveRowFullPath(inst)
            let stateStr = inst.sessionState?.state ?? "idle"
            let stateDetail = inst.sessionState?.detail ?? ""
            let stateIcon = liveRowStateIcons[stateStr] ?? ""

            // Generous initial height so the first render isn't clipped
            // even if our setFrameSize() in update() lands a frame too late.
            // update() resizes to actual content immediately after.
            let rowView = LiveRowView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
            rowView.update(with: inst,
                           leaf: leaf,
                           fullPath: fullPath,
                           stateIcon: stateIcon,
                           stateStr: stateStr,
                           stateDetail: stateDetail,
                           home: home)

            let row = NSMenuItem()
            row.view = rowView
            row.representedObject = inst.cwd
            row.target = self
            row.isEnabled = true
            menu.addItem(row)

            // Track this view so refreshLiveRows() can find it on the next
            // scan tick and call update() on it.
            runningRows[inst.pid] = (row, rowView)

            // Submenu — attached to the single view-based item.
            // Order matches user mental model: "where do I want to go look at
            // this work?" — Finder, Terminal, VSCode are the primary trio,
            // followed by inspect actions (transcript, copy PID), and the
            // destructive Terminate is isolated by a separator.
            let submenu = NSMenu()

            // 1. Open in Finder
            if let cwdPath = inst.cwd, !cwdPath.isEmpty {
                let finderItem = NSMenuItem(title: "Open in Finder", action: #selector(openInFinder(_:)), keyEquivalent: keybindFor(.openInFinder))
                finderItem.keyEquivalentModifierMask = []
                finderItem.target = self
                finderItem.representedObject = cwdPath
                setIcon(finderItem, "folder")
                submenu.addItem(finderItem)
            }

            // 2. Open in Terminal (Ghostty — focuses existing tab if found,
            //    otherwise spawns a new one. Same handler as the previous
            //    "Focus Terminal" entry; renamed to match the verb pattern.)
            let terminalItem = NSMenuItem(title: "Open in Terminal (Ghostty)",
                                          action: #selector(focusInstance(_:)),
                                          keyEquivalent: keybindFor(.openInTerminal))
            terminalItem.keyEquivalentModifierMask = []
            terminalItem.target = self
            terminalItem.representedObject = inst.cwd
            setIcon(terminalItem, "terminal")
            submenu.addItem(terminalItem)

            // 3. Open in VSCode
            if let cwdPath = inst.cwd, !cwdPath.isEmpty {
                let vscodeItem = NSMenuItem(title: "Open in VSCode",
                                            action: #selector(openInVSCode(_:)),
                                            keyEquivalent: keybindFor(.openInVSCode))
                vscodeItem.keyEquivalentModifierMask = []
                vscodeItem.target = self
                vscodeItem.representedObject = cwdPath
                setIcon(vscodeItem, "chevron.left.forwardslash.chevron.right")
                submenu.addItem(vscodeItem)
            }

            submenu.addItem(.separator())

            if let sid = inst.sessionId, !sid.isEmpty {
                let detailItem = NSMenuItem(title: "View Transcript", action: #selector(openDetail(_:)), keyEquivalent: keybindFor(.viewTranscript))
                detailItem.keyEquivalentModifierMask = []
                detailItem.target = self
                detailItem.representedObject = ["pid": inst.pid, "sessionId": sid] as [String: Any]
                setIcon(detailItem, "doc.text.magnifyingglass")
                submenu.addItem(detailItem)
            }

            let copyItem = NSMenuItem(title: "Copy PID (\(inst.pid))", action: #selector(copyPID(_:)), keyEquivalent: keybindFor(.copyPID))
            copyItem.keyEquivalentModifierMask = []
            copyItem.target = self
            copyItem.representedObject = inst.pid
            setIcon(copyItem, "doc.on.clipboard")
            submenu.addItem(copyItem)

            if let cwd = inst.cwd, !cwd.isEmpty {
                let copyDir = NSMenuItem(title: "Copy Directory Path", action: #selector(copyDirPath(_:)), keyEquivalent: "")
                copyDir.target = self
                copyDir.representedObject = cwd
                setIcon(copyDir, "folder")
                submenu.addItem(copyDir)
            }
            if let rid = inst.resumeId, !rid.isEmpty {
                let copyResume = NSMenuItem(title: "Copy Resume Command", action: #selector(copyResumeCmd(_:)), keyEquivalent: "")
                copyResume.target = self
                copyResume.representedObject = rid
                setIcon(copyResume, "terminal")
                submenu.addItem(copyResume)
            }

            submenu.addItem(.separator())

            let termItem = NSMenuItem(title: "Terminate", action: #selector(terminateInstance(_:)), keyEquivalent: keybindFor(.terminate))
            termItem.keyEquivalentModifierMask = []
            termItem.target = self
            termItem.representedObject = inst.pid
            termItem.attributedTitle = NSAttributedString(string: "Terminate", attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: 13),
            ])
            setIcon(termItem, "xmark.circle")
            submenu.addItem(termItem)

            row.submenu = submenu

            if idx < live.count - 1 {
                menu.addItem(.separator())
            }
        }
        menu.addItem(.separator())
    }

    // ── Section: Events ──────────────────────────────────────────────────────

    private let eventIcons: [String: String] = [
        "SessionStart": "▶", "Stop": "■", "PermissionRequest": "⚠",
        "PostCompact": "⟳", "PreCompact": "⟲", "SubagentStart": "↳",
        "SubagentStop": "↲", "Notification": "🔔", "PostToolUse": "🔧",
    ]
    private let eventColors: [String: NSColor] = [
        "SessionStart": menuGreen, "Stop": .systemRed,
        "PermissionRequest": .systemOrange, "PostCompact": .systemBlue,
        "PreCompact": .systemBlue, "SubagentStart": .systemPurple,
        "SubagentStop": .systemPurple, "Notification": menuYellow,
        "PostToolUse": menuTeal,
    ]

    private func formatEventItem(_ evt: Event) -> NSAttributedString {
        let icon = eventIcons[evt.event] ?? "·"
        let color = eventColors[evt.event] ?? .secondaryLabelColor
        var ts = evt.ts
        if ts.contains("T") {
            ts = String(ts.split(separator: "T").last?.prefix(5) ?? "?")
        }

        // Model badge
        let m = modelDisplay(evt.model)
        let modelBadge = evt.model != nil ? "\(m.badge) " : ""

        // Event name + tool detail
        var evtName = evt.event
        if evt.event == "PostToolUse", let tool = evt.tool, !tool.isEmpty {
            evtName = tool
        }
        if evtName.count > 14 { evtName = String(evtName.prefix(14)) }

        // Title or project
        var context = ""
        if let tt = evt.tabTitle, !tt.isEmpty {
            context = tt.count > 16 ? "…" + tt.suffix(15) : tt
        } else if let proj = evt.project, !proj.isEmpty {
            context = proj.count > 16 ? "…" + proj.suffix(15) : proj
        }

        // Columned so glyph | time | name | context line up across rows whether
        // or not a model badge is present (the old fixed-padding misaligned them).
        let glyphCell = NSMutableAttributedString()
        glyphCell.append(seg("  \(icon)", BarFont.body, color))
        if !modelBadge.isEmpty { glyphCell.append(seg(" \(m.badge)", BarFont.monoCaption, m.color)) }
        let cells: [NSAttributedString] = [
            glyphCell,
            seg(ts, BarFont.monoCaption, .tertiaryLabelColor),
            seg(evtName, BarFont.monoCaption, color),
            seg(context, BarFont.caption, .secondaryLabelColor),
        ]
        return columned(cells, stops: [42, 86, 190])
    }

    private func addEventsSection(_ menu: NSMenu, _ data: ScanResult) {
        guard let events = data.recentEvents, !events.isEmpty else { return }
        let deep = data.deepEvents ?? []
        let total = max(events.count, deep.count)

        // Collapsed to one row + submenu — keeps the menu short; recent activity
        // is one hover away.
        let head = NSMenuItem()
        head.attributedTitle = NSAttributedString(string: "  Recent Events (\(total))", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        setIcon(head, "list.bullet")

        let sub = NSMenu()
        for evt in events.suffix(12).reversed() {
            let s = NSMenuItem(); s.attributedTitle = formatEventItem(evt); s.isEnabled = false; sub.addItem(s)
        }
        if deep.count > events.count {
            sub.addItem(.separator())
            for evt in deep.suffix(30).reversed() {
                let s = NSMenuItem(); s.attributedTitle = formatEventItem(evt); s.isEnabled = false; sub.addItem(s)
            }
        }
        head.submenu = sub
        menu.addItem(head)
        menu.addItem(.separator())
    }

    // ── Section: History ─────────────────────────────────────────────────────

    private func addHistorySection(_ menu: NSMenu, _ data: ScanResult) {
        let history = data.history
        if history.isEmpty { return }

        // Collapsed to one row + submenu; rows column-aligned (no leftPad).
        let head = NSMenuItem()
        head.attributedTitle = NSAttributedString(string: "  History (\(history.count))", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        setIcon(head, "clock.arrow.circlepath")

        let sub = NSMenu()
        for sess in history.prefix(14) {
            let m = modelDisplay(sess.model)
            let rel = relativeTime(sess.modified)
            let label = sess.sessionId.hasPrefix("agent-") ? "↳ agent" : sess.project
            let sz = fmtSize(sess.sizeKb)
            let costStr = sess.costUsd.map { fmtCost($0) } ?? "–"
            let cells: [NSAttributedString] = [
                row(seg("  \(m.badge) ", BarFont.body, m.color),
                    seg(tailTruncate(label, 22), BarFont.body, .labelColor)),
                seg("\(sess.turns)t", BarFont.monoCaption, .secondaryLabelColor),
                seg(sz, BarFont.monoCaption, .secondaryLabelColor),
                seg(costStr, BarFont.monoCaption, costColor),
                seg(rel, BarFont.monoCaption, .tertiaryLabelColor),
            ]
            let item = NSMenuItem()
            item.attributedTitle = columned(cells, stops: [196, 240, 290, 338])
            item.action = #selector(resumeHistorySession(_:))
            item.target = self
            item.representedObject = ["sessionId": sess.sessionId, "project": sess.project] as [String: String]
            item.isEnabled = true
            sub.addItem(item)
        }
        if history.count > 14 {
            let more = NSMenuItem()
            more.attributedTitle = NSAttributedString(string: "  … and \(history.count - 14) more (open Dashboard)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            more.isEnabled = false
            sub.addItem(more)
        }
        head.submenu = sub
        menu.addItem(head)
        menu.addItem(.separator())
    }

    // ── Section: Actions ─────────────────────────────────────────────────────

    private func addActionsSection(_ menu: NSMenu, _ data: ScanResult) {
        addAction(menu, "New Session", #selector(newSession), icon: "plus.circle", key: "n")
        addAction(menu, "Dashboard", #selector(openDashboard), icon: "rectangle.3.group", key: "d")
        addAction(menu, "Sessions (phone)", #selector(openHubIndex), icon: "iphone")
        addRefreshMenu(menu)

        if data.live.count > 0 {
            menu.addItem(.separator())
            let termAll = NSMenuItem(title: "Terminate All (\(data.live.count))",
                                     action: #selector(terminateAll), keyEquivalent: "")
            termAll.target = self
            termAll.attributedTitle = NSAttributedString(
                string: "  Terminate All (\(data.live.count))",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: 13),
                ])
            setIcon(termAll, "xmark.circle")
            menu.addItem(termAll)
        }

        menu.addItem(.separator())
        addAction(menu, "Quit Widget", #selector(NSApplication.terminate(_:)), icon: "power")

        // Footer: data freshness — surfaces staleness when cadence is long
        // or paused. Without this, paused refresh has no visible indicator.
        let ageStr: String = {
            guard let t = lastScanAt else { return "never" }
            let s = Int(Date().timeIntervalSince(t))
            if s < 60 { return "\(s)s ago" }
            if s < 3600 { return "\(s/60)m ago" }
            return "\(s/3600)h ago"
        }()
        let cadenceTag = refreshPaused ? "paused" :
                         (refreshInterval < 1 ? String(format: "%.1fs", refreshInterval)
                                              : "\(Int(refreshInterval))s")
        let footer = "  Updated \(ageStr) · refresh: \(cadenceTag)"
        let footerColor: NSColor = refreshPaused ? .systemOrange : .tertiaryLabelColor
        addColored(menu, footer, color: footerColor, size: 10)
    }

    // ── Refresh submenu (manual + cadence picker) ────────────────────────────

    private func addRefreshMenu(_ menu: NSMenu) {
        // One-click refresh. Cadence + last-scan age ride along inline so the
        // common action is a single click, not a dive into a submenu.
        let cadenceLabel: String
        if refreshPaused {
            cadenceLabel = "paused"
        } else {
            cadenceLabel = refreshInterval < 1 ? String(format: "%.1fs", refreshInterval) : "\(Int(refreshInterval))s"
        }
        let agePart: String
        if let t = lastScanAt {
            agePart = "  ·  \(Int(Date().timeIntervalSince(t)))s ago"
        } else {
            agePart = ""
        }

        let now = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction), keyEquivalent: "r")
        now.target = self
        now.attributedTitle = NSAttributedString(
            string: "  Refresh Now    \(cadenceLabel)\(agePart)",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        setIcon(now, "arrow.clockwise")
        menu.addItem(now)

        // Cadence + pause demote to a secondary submenu — out of the way of the
        // one-click refresh, still a single hover from the presets.
        let cadence = NSMenuItem(title: "Auto-refresh", action: nil, keyEquivalent: "")
        cadence.attributedTitle = NSAttributedString(
            string: "  Auto-refresh interval",
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.secondaryLabelColor])
        setIcon(cadence, "timer")

        let sub = NSMenu()
        for preset in Self.refreshPresets {
            let label = preset < 1 ? String(format: "%.1f seconds", preset) :
                        preset == 1 ? "1 second" :
                                      "\(Int(preset)) seconds"
            let mi = NSMenuItem(title: label,
                                action: #selector(setRefreshInterval(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = preset
            mi.state = (!refreshPaused && abs(refreshInterval - preset) < 0.01) ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let pause = NSMenuItem(title: "Paused",
                               action: #selector(togglePause(_:)),
                               keyEquivalent: "")
        pause.target = self
        pause.state = refreshPaused ? .on : .off
        sub.addItem(pause)

        cadence.submenu = sub
        menu.addItem(cadence)
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Double else { return }
        refreshInterval = interval
        refreshPaused = false
        dlog("user set refresh interval to \(interval)s")
        restartScanTimer()
        refreshData()
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        refreshPaused.toggle()
        dlog("refresh \(refreshPaused ? "paused" : "resumed")")
        restartScanTimer()
        if !refreshPaused { refreshData() }
    }

    // ── Action handlers ──────────────────────────────────────────────────────

    @objc private func focusInstance(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? String, !cwd.isEmpty else {
            activateGhostty()
            return
        }
        dlog("focus: cwd=\(cwd)")
        focusGhosttyTab(forCwd: cwd)
    }

    @objc private func terminateInstance(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int else { return }
        dlog("terminate: pid=\(pid)")
        kill(Int32(pid), SIGTERM)

        // After 3 seconds, force-kill if still alive
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if kill(Int32(pid), 0) == 0 {
                dlog("force-killing pid=\(pid)")
                kill(Int32(pid), SIGKILL)
            }
        }
    }

    @objc private func copyPID(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(pid)", forType: .string)
        dlog("copied PID \(pid)")
    }

    @objc private func copyDirPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        dlog("copied dir path: \(path)")
    }

    @objc private func copyResumeCmd(_ sender: NSMenuItem) {
        guard let rid = sender.representedObject as? String, !rid.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude --resume \(rid)", forType: .string)
        dlog("copied resume command for \(rid)")
    }

    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        dlog("open in Finder: \(path)")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc private func openInVSCode(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty else { return }
        dlog("open in VSCode: \(path)")
        // Try the `code` CLI first (works when "Shell Command: Install 'code'
        // command in PATH" was run from VSCode). Fall back to opening with
        // the .app bundle, which works as long as VSCode is installed.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["code", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return }
        } catch {
            dwarn("`code` CLI not on PATH (\(fmtErr(error))); falling back to NSWorkspace")
        }
        let url = URL(fileURLWithPath: path)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let vscodeBundleURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        NSWorkspace.shared.open([url], withApplicationAt: vscodeBundleURL,
                                configuration: cfg) { _, err in
            if let err = err { derr("VSCode open failed: \(fmtErr(err))") }
        }
    }

    @objc private func openDetail(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let sid = info["sessionId"] as? String else { return }
        dlog("detail (hub): sid=\(sid)")
        openHubTranscript(sessionId: sid)
    }

    /// Open the device-spanning session index. When Tailscale is up it also drops
    /// the phone URL on the clipboard, so opening it on your phone is one paste.
    @objc private func openHubIndex() {
        DispatchQueue.global(qos: .userInitiated).async {
            let host = ensureHubRunning()
            if host != "127.0.0.1" {
                let phoneURL = "http://\(host):\(hubPort)/"
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(phoneURL, forType: .string)
                }
                dlog("hub phone URL copied: \(phoneURL)")
            }
            openURLPreferChrome("http://127.0.0.1:\(hubPort)/")
        }
    }

    @objc private func openDashboard() {
        dlog("opening native dashboard")
        if dashboardController == nil {
            dashboardController = DashboardController()
        }
        dashboardController?.showOrFront(data: cachedData, barDelegate: self)
    }

    @objc private func newSession() {
        dlog("new session — activating Ghostty")
        activateGhostty()
    }

    @objc private func terminateAll() {
        dlog("terminate all")
        guard let data = cachedData else { return }
        for inst in data.live {
            kill(Int32(inst.pid), SIGTERM)
        }
        // Force-kill survivors after 3s
        let pids = data.live.map { $0.pid }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            for pid in pids {
                if kill(Int32(pid), 0) == 0 {
                    kill(Int32(pid), SIGKILL)
                }
            }
        }
    }

    @objc private func refreshAction() {
        dlog("manual refresh (forced full)")
        scanTick = fullScanInterval - 1  // Next tick will be a full scan
        refreshData()
    }

    @objc private func thresholdSliderChanged(_ sender: NSSlider) {
        let v = Int(sender.doubleValue)
        let isDanger = sender.tag == 2
        // Keep the zones ordered: warn ≤ danger.
        if isDanger {
            dangerThreshold = max(v, warningThreshold)
        } else {
            warningThreshold = min(v, dangerThreshold)
        }
        let shown = isDanger ? dangerThreshold : warningThreshold
        let prefix = isDanger ? "Danger ≥" : "Warn ≥"
        let labelTag = isDanger ? 102 : 101
        if let container = sender.superview,
           let label = container.subviews.first(where: { $0.tag == labelTag }) as? NSTextField {
            label.stringValue = "\(prefix) \(shown)%"
        }
        dlog("zone changed: warn ≥\(warningThreshold)% danger ≥\(dangerThreshold)%")
        updateButton()
    }

    @objc private func resumeHistorySession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let sid = info["sessionId"] else { return }
        dlog("resume history: \(sid)")
        resumeSession(sessionId: sid, cwd: nil)
    }

    // ── Menu item helpers ────────────────────────────────────────────────────

    private func addDim(_ menu: NSMenu, _ title: String) {
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12),
        ])
        i.isEnabled = false
        menu.addItem(i)
    }

    /// Add a multi-line, character-wrapping dim row to the menu.
    /// Uses a view-based NSMenuItem (NSTextField with usesSingleLineMode=false)
    /// because NSMenuItem.attributedTitle does not honor lineBreakMode for
    /// width-based wrapping — it just lets the menu grow horizontally instead.
    /// Used for the full-cwd row under each instance and the focus-file row,
    /// where path length should never trigger an ellipsis.
    private func addWrappingDim(_ menu: NSMenu, _ text: String,
                                color: NSColor = .tertiaryLabelColor,
                                size: CGFloat = 11) {
        let item = NSMenuItem()
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        label.textColor = color
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.preferredMaxLayoutWidth = 320
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
        item.view = container
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addDimMono(_ menu: NSMenu, _ title: String, size: CGFloat = 12) {
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
        ])
        i.isEnabled = false
        menu.addItem(i)
    }

    private func addColored(_ menu: NSMenu, _ title: String, color: NSColor, size: CGFloat = 13) {
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: size),
        ])
        i.isEnabled = false
        menu.addItem(i)
    }

    private func addSectionHeader(_ menu: NSMenu, _ title: String, icon: String) {
        // A quiet, tracked, uppercase label reads as a section divider rather
        // than competing with the content rows for attention.
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: "  \(title)", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.6,
        ])
        setIcon(i, icon)
        i.isEnabled = false
        menu.addItem(i)
    }

    @discardableResult
    private func addAction(_ menu: NSMenu, _ title: String, _ sel: Selector,
                           icon: String? = nil, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.attributedTitle = NSAttributedString(string: "  \(title)", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
        ])
        i.target = self
        i.isEnabled = true
        if let icon = icon { setIcon(i, icon) }
        menu.addItem(i)
        return i
    }

    private func setIcon(_ item: NSMenuItem, _ symbol: String) {
        if var img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            img = img.withSymbolConfiguration(cfg) ?? img
            img.isTemplate = true
            item.image = img
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Native Dashboard (SwiftUI + NSPanel)
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Observable data source (bridges cached scan data → SwiftUI) ─────────────

/// One active transcript HTTP server. Discovered by scanning
/// `/tmp/claude-widget-*.server` for files whose PID is still alive.
