// Bar.swift
// BarDelegate — status item, menu construction, action handlers.
// (split from claude-instances-bar.swift — one module, same binary)

import AppKit
import Foundation
import SwiftUI
import IOKit.pwr_mgt

final class BarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var scanTimer: Timer?

    // Public so DashboardController can read cached data
    private(set) var cachedData: ScanResult?
    private var lastScanError = false
    private var theMenu: NSMenu!
    private var dashboardController: DashboardController?
    private var settingsController: SettingsWindowController?

    /// Keep Awake: holds an IOKit power assertion so the SYSTEM stays awake
    /// while remote (claude.ai) sessions run — the display may still sleep
    /// and the screen may still lock. Persisted so it survives bar restarts.
    private let keepAwakeKey = "keepAwakeEnabled"
    private var keepAwakeOn = false

    // Kanban board server state — nil until the first probe answers.
    private var kanbanUp: Bool?
    private var kanbanBusy = false
    private var sbSnapshot = SBSnapshot()
    /// The second menu bar icon: the agent-policy panel (PolicyPanel.swift).
    private var policyController: PolicyStatusController?
    private var systemTimerTick: Timer?
    private var keepAwakeAssertionID: IOPMAssertionID = 0

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

        // Re-arm Keep Awake if it was on when the bar last exited — the
        // assertion dies with the process, the preference should not.
        if UserDefaults.standard.bool(forKey: keepAwakeKey) {
            setKeepAwake(true)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        theMenu                  = NSMenu()
        theMenu.autoenablesItems = false
        theMenu.delegate         = self
        statusItem.menu          = theMenu

        // The agent-policy panel lives in this process, on its own icon, so it is
        // one click away without being another app to keep running.
        policyController = PolicyStatusController(
            liveDirs: { [weak self] in (self?.cachedData?.live ?? []).compactMap { $0.cwd } },
            requestSystemRefresh: { [weak self] in self?.refreshSnapshot() })
        if let store = policyController?.store {
            store.startSystemTimer = { [weak self] k, until in self?.startSystemTimer(k, until: until) }
            store.cancelSystemTimer = { [weak self] k in self?.cancelSystemTimer(k) }
            store.endSystemTimerNow = { [weak self] k in self?.endSystemTimerNow(k) }
        }
        systemTimerTick = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.fireDueSystemTimers()
        }
        // One probe shortly after launch, so the System tab has rows before the
        // first open instead of loading while the owner watches.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshSnapshot() }
        if CommandLine.arguments.contains("--open-policy") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.policyController?.show()
            }
        }

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

        // Badge composition is user-configurable (Settings → Menu Bar Badge).
        let showCount    = UserDefaults.standard.object(forKey: "ui.badge.showCount")    as? Bool ?? true
        let showRows     = UserDefaults.standard.object(forKey: "ui.badge.showRows")     as? Bool ?? true
        let showPermWarn = UserDefaults.standard.object(forKey: "ui.badge.showPermWarn") as? Bool ?? true

        let liveCount = cachedData?.liveCount ?? 0
        let hasPerm = showPermWarn && (cachedData?.recentEvents?.suffix(3).contains { $0.event == "PermissionRequest" } ?? false)
        let countText: String = {
            if !showCount { return hasPerm ? "⚠" : "" }
            return hasPerm ? "⚠ \(liveCount)" : (liveCount > 0 ? "\(liveCount)" : "–")
        }()

        // One row per limit window we actually have data for. Order W → 5
        // (Fable would slot in first as F, teal, once it exists in the feed).
        var rows: [BadgeRow] = []
        if showRows, let limits = cachedData?.limits {
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
        refreshSnapshot()
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
        addAction(menu, "Settings…", #selector(openSettings), icon: "gearshape", key: ",")
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

        // Cadence and pause live in the Switchboard — this stays a pure action.
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        refreshPaused.toggle()
        dlog("refresh \(refreshPaused ? "paused" : "resumed")")
        restartScanTimer()
        if !refreshPaused { refreshData() }
        refreshSwitchboard()
    }

    // ── Keep Awake (prevent idle system sleep) ───────────────────────────────

    /// Toggle the power assertion that keeps the machine from idle-sleeping.
    /// PreventUserIdleSystemSleep is deliberate: the display sleeps and the
    /// screen locks as normal, but the system (and its network) stays up, so
    /// running Claude sessions keep their remote connection on battery.
    private func setKeepAwake(_ on: Bool) {
        if on {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "claude-instances: keep system awake for remote sessions" as CFString,
                &id)
            if rc == kIOReturnSuccess {
                keepAwakeAssertionID = id
                keepAwakeOn = true
                dlog("keep-awake ON (assertion \(id))")
            } else {
                keepAwakeOn = false
                dlog("keep-awake assertion FAILED rc=\(rc)")
            }
        } else {
            if keepAwakeAssertionID != 0 {
                IOPMAssertionRelease(keepAwakeAssertionID)
                keepAwakeAssertionID = 0
            }
            keepAwakeOn = false
            dlog("keep-awake OFF")
        }
        UserDefaults.standard.set(keepAwakeOn, forKey: keepAwakeKey)
    }

    @objc private func toggleKeepAwake(_ sender: NSMenuItem) {
        setKeepAwake(!keepAwakeOn)
        refreshSwitchboard()
    }

    // ── Switchboard ──────────────────────────────────────────────────────────
    // Every on/off the widget owns, on one rail, grouped by the question each
    // group answers: what is not protecting me, what is up, what is this costing,
    // what is this session doing. A click may restore a protection, never remove
    // one; suppressing a permission prompt is the single exception and it asks.

    enum SBBadge {
        case on(NSColor)
        case off
        case count(Int, NSColor)
        case ok

        var text: String {
            switch self {
            case .on:              return "on"
            case .off:             return "off"
            case .count(let n, _): return "\(n)"
            case .ok:              return "ok"
            }
        }
        /// nil renders the hollow form, which is what "nothing engaged" should look like.
        var tint: NSColor? {
            switch self {
            case .on(let c):       return c
            case .off:             return nil
            case .count(_, let c): return c
            case .ok:              return nil
            }
        }
    }

    struct SBRow {
        let label: String
        let badge: SBBadge
        let note: String
        var enabled: Bool = true
        var onClick: (() -> Void)? = nil
        var submenu: (() -> NSMenu)? = nil
        var tip: String = ""
        /// Shown as a separate row beneath this one while the service is up. It
        /// is its own menu item, so opening the link cannot reach the toggle.
        var link: String? = nil
    }

    /// Everything the switchboard renders, read once per rebuild. Service probes
    /// are slow, so they refresh off the main thread and land here.
    struct SBSnapshot {
        var muted: [MutedGuard] = []
        var approvals: [PushApproval] = []
        var prompts: [SettingsFlag: Bool] = [:]
        var thinking = false
        var effort = "unknown"
        var boardSync = false
        var hubReachable: Bool? = nil
        /// Separate from hubReachable: the advertised (phone) address can be dead
        /// while localhost still serves, and the link should follow what works.
        var hubLocal: Bool? = nil
        var hubHost: String? = nil
        var brokerUp: Bool? = nil
        var decisionPages: String? = nil
        /// nil when the warden institution is not installed (no row shown).
        var wardenRunning: Bool? = nil
        /// usage-gate standdown; display-only, self-clears on quota reset.
        var wardenGated = false
        /// The stand-down threshold the gate actually uses (policy ops.usage_gate_pct).
        var wardenGatePct = 90
        var jobsTotal = 0
        var jobsFailing = 0
        /// Other processes holding the Mac awake right now (codex, caffeinate…).
        var awakeHolders: [String] = []
        /// The owner's launchd jobs (lib/jobs.py list) and saved wake-on-LAN devices.
        var jobs: [[String: Any]] = []
        var wolTargets: [[String: Any]] = []
    }

    /// Refresh the slow half off the main thread. The menu renders whatever the
    /// last snapshot held and never blocks on a probe.
    private func refreshSnapshot(completion: (() -> Void)? = nil) {
        let liveIDs = Set((cachedData?.live ?? []).compactMap { $0.sessionId })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var s = SBSnapshot()
            s.muted = Guards.muted()
            s.approvals = PushApprovals.armed(liveSessionIDs: liveIDs)
            for f in SettingsFlag.allCases { s.prompts[f] = Settings.bool(f) }
            s.thinking = s.prompts[.alwaysThinking] ?? false
            s.effort = Settings.effortLevel()
            s.boardSync = BoardSync.enabled()
            s.hubHost = Services.hubAdvertisedHost()
            s.hubLocal = Services.probeHTTP("http://127.0.0.1:5400/healthz")
            if let h = s.hubHost {
                s.hubReachable = Services.probeHTTP("http://\(h):5400/healthz")
            } else {
                s.hubReachable = s.hubLocal
            }
            s.brokerUp = Services.shell("/bin/zsh", ["-lc", "claude-ipc daemon status 2>/dev/null"])
                .contains("up")
            s.decisionPages = Services.pm2Status("decision-pages")
            s.wardenRunning = Warden.installed() ? Warden.running() : nil
            if s.wardenRunning == true {
                s.wardenGated = Warden.gated()
                let pct = PolicyCLI.run(["get", "ops.usage_gate_pct"]).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let n = Int(pct) { s.wardenGatePct = n }
            }
            let kanban = Services.probeHTTP("http://127.0.0.1:5106/api/boards")
            let jobs = Services.shell("/bin/zsh", ["-lc",
                "launchctl list 2>/dev/null | grep -c alcatraz; launchctl list 2>/dev/null | awk '$2 != 0 && /alcatraz/' | wc -l"])
            let nums = jobs.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            s.jobsTotal = nums.first ?? 0
            s.jobsFailing = nums.count > 1 ? nums[1] : 0
            // Who else blocks sleep: pmset's per-process list, minus the OS's own
            // display-on assertion and this app. A caffeinate is named by the
            // process it runs for, so "node" rather than "caffeinate".
            var holders: [String] = []
            let asserts = Services.shell("/usr/bin/pmset", ["-g", "assertions"]).split(separator: "\n").map(String.init)
            for (i, line) in asserts.enumerated() {
                guard line.contains("PreventUserIdleSystemSleep") || line.contains("PreventSystemSleep"),
                      let open = line.range(of: "("), let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
                else { continue }
                var name = String(line[open.upperBound..<close.lowerBound])
                // macOS's own daemons (powerd, bluetoothd, runningboardd…) are
                // not something the owner started; only tools and apps are listed.
                if name == "claude-instances-bar" || (name.hasSuffix("d") && name == name.lowercased()
                    && !name.contains("-") && name.count > 4) { continue }
                if name == "caffeinate", i + 1 < asserts.count,
                   let behalf = asserts[i + 1].range(of: "on behalf of '") {
                    let rest = asserts[i + 1][behalf.upperBound...]
                    name = (String(rest.prefix { $0 != "'" }) as NSString).lastPathComponent
                } else if name == "caffeinate" {
                    name = "claude"   // Claude Code's rolling caffeinate carries no "on behalf of"
                }
                if !holders.contains(name) { holders.append(name) }
            }
            s.awakeHolders = holders
            let lib = SwitchboardPaths.gccRoot + "/widgets/claude-instances/lib"
            func pyList(_ script: String) -> [[String: Any]] {
                let out = Services.shell("/usr/bin/env", ["python3", lib + "/" + script, "list"], timeout: 8)
                return (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]]) ?? []
            }
            s.jobs = pyList("jobs.py")
            s.wolTargets = pyList("wol.py")
            DispatchQueue.main.async {
                self?.sbSnapshot = s
                // One probe path for kanban, so the menu and the headless dump
                // can never disagree about whether it is up.
                if self?.kanbanBusy == false { self?.kanbanUp = kanban }
                self?.refreshSwitchboard()
                completion?()
            }
        }
    }

    // ── The groups ───────────────────────────────────────────────────────────

    private func sbGuardRows() -> [SBRow] {
        let s = sbSnapshot
        let stale = s.approvals.filter { !$0.sessionIsLive }
        let suppressed = SettingsFlag.allCases.filter { $0.isSuppressor && (s.prompts[$0] ?? false) }

        if s.muted.isEmpty && stale.isEmpty && suppressed.isEmpty {
            return [SBRow(label: "All armed", badge: .ok,
                          note: "no mutes, no stale approvals",
                          enabled: false,
                          tip: "No guard is muted and no push approval is left armed.")]
        }
        var rows: [SBRow] = []
        if !s.muted.isEmpty {
            rows.append(SBRow(label: "Muted guards",
                              badge: .count(s.muted.count, menuYellow),
                              note: s.muted.prefix(3).map { $0.name }.joined(separator: " · "),
                              submenu: { [weak self] in self?.sbMutedGuardsMenu() ?? NSMenu() },
                              tip: "Guards switched off machine-wide. Click one to re-arm it."))
        }
        if !suppressed.isEmpty {
            rows.append(SBRow(label: "Permission prompts",
                              badge: .count(suppressed.count, menuYellow),
                              note: "suppressed in settings.json",
                              submenu: { [weak self] in self?.sbPromptsMenu() ?? NSMenu() },
                              tip: "Confirmation prompts currently suppressed. Click one to bring it back."))
        }
        if !stale.isEmpty {
            let oldest = stale.first
            rows.append(SBRow(label: "Push approvals",
                              badge: .count(stale.count, menuYellow),
                              note: sbApprovalNote(oldest),
                              onClick: { [weak self] in
                                  stale.forEach { PushApprovals.clear($0) }
                                  self?.refreshSnapshot()
                              },
                              tip: "Push approvals armed by sessions that are no longer live. Click to revoke them."))
        }
        return rows
    }

    private func sbApprovalNote(_ a: PushApproval?) -> String {
        guard let a = a else { return "armed" }
        guard let when = a.armedAt else { return "dead session" }
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return "armed \(f.string(from: when)), dead session"
    }

    private func sbServiceRows() -> [SBRow] {
        let s = sbSnapshot
        var rows: [SBRow] = []

        let kanbanNote: String
        if kanbanBusy            { kanbanNote = "working…" }
        else if kanbanUp == nil  { kanbanNote = "probing…" }
        else if kanbanUp == true { kanbanNote = "serving :5106" }
        else                     { kanbanNote = "not running" }
        rows.append(SBRow(label: "Kanban Board",
                          badge: kanbanUp == true ? .on(menuGreen) : .off,
                          note: kanbanNote,
                          enabled: !kanbanBusy,
                          onClick: { [weak self] in self?.toggleKanban(NSMenuItem()) },
                          tip: "The kanban board server on port 5106. It stays off across reboots; this switch is where it comes back.",
                          link: kanbanUp == true ? "http://localhost:5106" : nil))

        // Reachability, not just liveness: a listener on a tailnet address that no
        // longer resolves is up and unreachable at once. That shipped undetected.
        let hubNote: String
        let hubOK = s.hubReachable == true
        if s.hubReachable == nil            { hubNote = "probing…" }
        else if hubOK                       { hubNote = "serving :5400" }
        else if s.hubHost != nil            { hubNote = "up, \(s.hubHost!) unreachable" }
        else                                { hubNote = "not running" }
        rows.append(SBRow(label: "Session Hub",
                          badge: hubOK ? .on(menuGreen) : .off,
                          note: hubNote,
                          onClick: { [weak self] in self?.sbToggleHub() },
                          tip: "The phone-facing session hub on port 5400. Restart it after Tailscale reconnects, or its advertised address goes stale.",
                          link: s.hubLocal == true ? "http://localhost:5400" : nil))

        rows.append(SBRow(label: "ipc Broker",
                          badge: s.brokerUp == true ? .on(menuGreen) : .off,
                          note: s.brokerUp == nil ? "probing…" : (s.brokerUp! ? "up" : "down"),
                          enabled: false,
                          tip: "The cross-session message broker. Read-only here: it runs under launchd."))

        if let dp = s.decisionPages {
            rows.append(SBRow(label: "Decision Pages",
                              badge: dp == "online" ? .on(menuGreen) : .off,
                              note: dp == "online" ? "serving :5197" : "pm2, \(dp)",
                              onClick: { [weak self] in
                                  Services.pm2(dp == "online" ? "stop" : "start", "decision-pages")
                                  self?.refreshSnapshot()
                              },
                              tip: "The decision-page server used for batched human feedback.",
                              link: dp == "online" ? "http://localhost:5197" : nil))
        }

        if let wr = s.wardenRunning {
            let badge: SBBadge = !wr ? .off : (s.wardenGated ? .on(menuYellow) : .on(menuGreen))
            let note = !wr ? "paused by you, deltas held"
                     : (s.wardenGated ? "standing down, usage >\(s.wardenGatePct)% (auto-resumes)" : "beats live")
            rows.append(SBRow(label: "Warden",
                              badge: badge,
                              note: note,
                              onClick: { [weak self] in
                                  Warden.set(running: !wr)
                                  self?.refreshSnapshot()
                              },
                              tip: "The session warden. Click toggles YOUR pause (a saved override that supersedes everything). The yellow standing-down state is the usage gate; it clears itself when a window reopens — no click needed. Same sentinel as `claude-warden pause`."))
        }

        return rows
    }

    private func sbSessionRows() -> [SBRow] {
        return [
            SBRow(label: "Keep Awake",
                  badge: keepAwakeOn ? .on(menuTeal) : .off,
                  note: keepAwakeOn ? "sleep blocked"
                      : (sbSnapshot.awakeHolders.isEmpty ? "system may sleep"
                         : "also held awake by " + sbSnapshot.awakeHolders.joined(separator: ", ")),
                  onClick: { [weak self] in self?.toggleKeepAwake(NSMenuItem()) },
                  tip: "Prevent idle system sleep so remote (claude.ai) sessions stay connected on battery. The display still sleeps and locks normally."),
            SBRow(label: "Board sync",
                  badge: sbSnapshot.boardSync ? .on(menuGreen) : .off,
                  note: sbSnapshot.boardSync ? "todos to kanban" : "hooks skip",
                  onClick: { [weak self] in
                      BoardSync.set(!(self?.sbSnapshot.boardSync ?? false))
                      self?.refreshSnapshot()
                  },
                  tip: "Whether session hooks sync the todo list to the kanban board."),
        ]
    }

    private func sbFeedRows() -> [SBRow] {
        let tag = refreshInterval < 1 ? String(format: "%.1fs", refreshInterval) : "\(Int(refreshInterval))s"
        return [SBRow(label: "Auto-refresh",
                      badge: refreshPaused ? .off : .on(menuGreen),
                      note: refreshPaused ? "paused, was \(tag)" : "every \(tag)",
                      onClick: { [weak self] in self?.togglePause(NSMenuItem()) },
                      tip: "Pause or resume the scan that feeds this menu.")]
    }

    // ── Drill-downs ──────────────────────────────────────────────────────────

    private func sbMutedGuardsMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let f = DateFormatter(); f.dateFormat = "d MMM"
        let rows = sbSnapshot.muted.map { g in
            SBRow(label: g.name, badge: .off,
                  note: g.mutedAt.map { "muted \(f.string(from: $0))" } ?? "muted",
                  onClick: { [weak self] in
                      Guards.rearm(g)
                      self?.refreshSnapshot()
                  },
                  tip: "Click to re-arm this guard. Muting again stays a deliberate touch in a shell.")
        }
        let column = sbLabelColumn(rows)
        for r in rows { addSBRow(m, r, labelColumn: column) }
        m.addItem(.separator())
        addSBNote(m, "Click re-arms. Muting stays a deliberate touch.")
        return m
    }

    private func sbPromptsMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        // The row reads as the PROMPT, not the skip, so "on" always means the
        // safer state and a stray click can only add friction.
        let rows = SettingsFlag.allCases.filter { $0.isSuppressor }.map { flag -> SBRow in
            let suppressed = sbSnapshot.prompts[flag] ?? false
            return SBRow(label: flag.label,
                         badge: suppressed ? .off : .on(menuGreen),
                         note: suppressed ? "suppressed" : "asks first",
                         onClick: { [weak self] in self?.sbTogglePrompt(flag, suppressed: suppressed) },
                         tip: suppressed ? "Click to bring this confirmation back."
                                         : "This prompt is active. Suppressing it will ask for confirmation.")
        }
        let column = sbLabelColumn(rows)
        for r in rows { addSBRow(m, r, labelColumn: column) }
        m.addItem(.separator())
        addSBNote(m, "Restoring a prompt is one click. Suppressing one asks.")
        return m
    }

    /// Restoring a prompt is immediate. Suppressing one is the only place this
    /// menu can weaken a safeguard, so it goes through a modal first.
    private func sbTogglePrompt(_ flag: SettingsFlag, suppressed: Bool) {
        if suppressed {
            Settings.write(key: flag.rawValue, value: false)
            refreshSnapshot()
            return
        }
        let a = NSAlert()
        a.messageText = "Suppress the \(flag.label.lowercased())?"
        a.informativeText = "This removes a confirmation step for every session on this machine, not just this one."
        a.alertStyle = .warning
        a.addButton(withTitle: "Suppress")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Settings.write(key: flag.rawValue, value: true)
        refreshSnapshot()
    }

    private func sbToggleHub() {
        let script = SwitchboardPaths.gccRoot + "/widgets/claude-instances/lib/hub.sh"
        let up = sbSnapshot.hubReachable == true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = Services.shell("/bin/bash", [script, up ? "stop" : "restart"])
            DispatchQueue.main.async { self?.refreshSnapshot() }
        }
    }

    // ── Rendering ────────────────────────────────────────────────────────────

    /// Renders the real Switchboard to text: same snapshot, same group walk, same
    /// row builder the menu uses. The one affordance that makes these rows
    /// verifiable without a screen.
    func dumpSwitchboard() -> String {
        let sem = DispatchSemaphore(value: 0)
        refreshSnapshot { sem.signal() }
        // The refresh lands on the main queue, which this call is blocking, so
        // pump the runloop instead of sleeping on the semaphore.
        let deadline = Date().addingTimeInterval(20)
        while sem.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        let groups: [(String, [SBRow])] = [
            ("GUARDS",   sbGuardRows()),
            ("SERVICES", sbServiceRows()),
            ("SESSION",  sbSessionRows()),
            ("FEED",     sbFeedRows()),
        ]
        var out = ["SWITCHBOARD DUMP"]
        for (title, rows) in groups where !rows.isEmpty {
            out.append("\n\(title)")
            for r in rows {
                let badge = r.badge.tint == nil ? "(\(r.badge.text))" : "[\(r.badge.text)]"
                let affordance = r.submenu != nil ? "submenu" : (r.onClick != nil ? "click" : "readonly")
                out.append(String(format: "  %-20@ %-6@ %-28@ %@%@",
                                  r.label as NSString, badge as NSString,
                                  r.note as NSString, affordance as NSString,
                                  (r.enabled ? "" : " disabled") as NSString))
                if let link = r.link { out.append("      link: \(link)") }
            }
        }
        out.append("\nsnapshot: muted=\(sbSnapshot.muted.count) approvals=\(sbSnapshot.approvals.count) "
                   + "effort=\(sbSnapshot.effort) thinking=\(sbSnapshot.thinking) "
                   + "hubReachable=\(String(describing: sbSnapshot.hubReachable)) "
                   + "jobs=\(sbSnapshot.jobsTotal)/\(sbSnapshot.jobsFailing)")
        return out.joined(separator: "\n")
    }

    private func addSBNote(_ menu: NSMenu, _ text: String) {
        let i = NSMenuItem()
        i.attributedTitle = seg("  " + text, BarFont.caption, .tertiaryLabelColor)
        i.isEnabled = false
        menu.addItem(i)
    }

    /// One rail row: label, badge, consequence. Every metric derives from
    /// BarFont.scaled so the rail survives the Display Sizing multiplier.
    /// Widest label in a group, so the rail is sized by its content instead of a
    /// constant that silently clips when a label grows. "Permission prompts"
    /// already overran the old 112pt column at the default scale.
    private func sbLabelColumn(_ rows: [SBRow]) -> CGFloat {
        let widest = rows.map { r -> CGFloat in
            let f = NSTextField(labelWithString: r.label)
            f.font = BarFont.body
            return ceil(f.attributedStringValue.size().width)
        }.max() ?? BarFont.scaled(112)
        return min(max(widest + BarFont.scaled(12), BarFont.scaled(96)), BarFont.scaled(190))
    }

    private func addSBRow(_ menu: NSMenu, _ r: SBRow, labelColumn: CGFloat? = nil) {
        let padL   = BarFont.scaled(18)
        let labelW = labelColumn ?? BarFont.scaled(112)
        let badgeW = BarFont.scaled(40)
        let noteW  = BarFont.scaled(140)
        let h      = BarFont.scaled(26)
        let v = MenuRowView(frame: NSRect(x: 0, y: 0,
                                          width: padL + labelW + badgeW + noteW + BarFont.scaled(14),
                                          height: h))
        v.rowEnabled = r.enabled && (r.onClick != nil || r.submenu != nil)

        let name = NSTextField(labelWithString: r.label)
        name.font = BarFont.body
        name.textColor = r.enabled ? .labelColor : .secondaryLabelColor
        let nameH = ceil(name.attributedStringValue.size().height)
        name.frame = NSRect(x: padL, y: (h - nameH) / 2, width: labelW, height: nameH)
        v.addSubview(name)

        let badge = makeStateBadge(r.badge.text, tint: r.badge.tint)
        badge.setFrameOrigin(NSPoint(x: padL + labelW, y: (h - badge.frame.height) / 2))
        v.addSubview(badge)

        let note = NSTextField(labelWithString: r.note)
        note.font = BarFont.monoCaption
        note.textColor = .tertiaryLabelColor
        let noteH = ceil(note.attributedStringValue.size().height)
        note.frame = NSRect(x: padL + labelW + badgeW, y: (h - noteH) / 2,
                            width: noteW, height: noteH)
        v.addSubview(note)

        // The view owns the mouse, so the click is wired here. A view-based
        // NSMenuItem never sends its action.
        let item = NSMenuItem(title: r.label, action: nil, keyEquivalent: "")
        item.view = v
        item.isEnabled = r.enabled
        item.toolTip = r.tip
        if let build = r.submenu {
            item.submenu = build()
            // AppKit draws no submenu chevron on a view-based item, so the row
            // would look like a dead end. Draw it, right-aligned like the real one.
            let chev = NSTextField(labelWithString: "›")
            chev.font = NSFont.systemFont(ofSize: BarFont.scaled(13), weight: .medium)
            chev.textColor = .tertiaryLabelColor
            let cs = chev.attributedStringValue.size()
            chev.frame = NSRect(x: v.frame.width - BarFont.scaled(13),
                                y: (h - ceil(cs.height)) / 2,
                                width: ceil(cs.width) + 2, height: ceil(cs.height))
            v.addSubview(chev)
        } else if let click = r.onClick {
            v.onClick = click
        }
        menu.addItem(item)
        if let link = r.link { addSBLinkRow(menu, link, indent: padL + BarFont.scaled(10)) }
    }

    /// The service's address as its own row. Opening it closes the menu and does
    /// not touch the toggle, because the two are different menu items.
    private func addSBLinkRow(_ menu: NSMenu, _ url: String, indent: CGFloat) {
        let h = BarFont.scaled(19)
        let text = NSTextField(labelWithString: url)
        text.font = BarFont.monoCaption
        text.textColor = .linkColor
        let size = text.attributedStringValue.size()
        text.frame = NSRect(x: indent, y: (h - ceil(size.height)) / 2,
                            width: ceil(size.width), height: ceil(size.height))

        let v = MenuRowView(frame: NSRect(x: 0, y: 0,
                                          width: indent + ceil(size.width) + BarFont.scaled(20),
                                          height: h))
        v.staysOpen = false   // opening a link is a leave-the-menu action
        v.onClick = { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        v.addSubview(text)

        let item = NSMenuItem()
        item.view = v
        item.toolTip = "Open \(url) in your browser. Does not change the switch."
        menu.addItem(item)
    }

    // ── Kanban board server (pm2 "kanban", :5106) ────────────────────────────
    // The bar IS the on/off surface: no launchd, off after reboot by design.

    /// Hand the Switchboard panel a fresh set of system rows. Hops a tick
    /// because a row can trigger this from inside its own click handler.
    private func refreshSwitchboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.policyController?.store.systemGroups = self.panelSystemGroups()
        }
    }

    /// The system switches as panel rows, each carrying its own action and any
    /// running timer. Effort is left out: Claude Code sets it itself.
    func panelSystemGroups() -> [SystemGroup] {
        func convert(_ r: SBRow) -> SystemRow {
            let state: SystemRow.State
            switch r.badge {
            case .on(let c): state = .on(c)
            case .off: state = .off
            case .count(let n, let c): state = .count(n, c)
            case .ok: state = .ok
            }
            var row = SystemRow(label: r.label, state: state, note: r.note, enabled: r.enabled,
                                tip: r.tip, link: r.link, action: r.onClick, menu: r.submenu)
            if row.isSwitch && r.enabled {
                row.timerKey = r.label
                row.timer = systemTimers[r.label]
            }
            return row
        }
        let groups: [(String, [SBRow])] = [
            ("Guards",   sbGuardRows()),
            ("Services", sbServiceRows()),
            ("Session",  sbSessionRows()),
            ("Feed",     sbFeedRows()),
        ]
        var out = groups.filter { !$0.1.isEmpty }.map { SystemGroup(title: $0.0, rows: $0.1.map(convert)) }
        // The scan cadence used to live only in the dropdown's Switchboard; it
        // moved here with it, as a pick-one row in the Feed group.
        if let i = out.firstIndex(where: { $0.title == "Feed" }) {
            var cadence = SystemRow(label: "Scan every", state: .ok, note: refreshPaused ? "paused" : "")
            cadence.choices = Self.refreshPresets.map { $0 < 1 ? String(format: "%.1fs", $0) : "\(Int($0))s" }
            cadence.selected = Self.refreshPresets.firstIndex(where: { abs($0 - refreshInterval) < 0.01 }) ?? -1
            cadence.enabled = !refreshPaused
            cadence.onChoose = { [weak self] idx in
                guard let self = self, idx >= 0, idx < Self.refreshPresets.count else { return }
                self.refreshInterval = Self.refreshPresets[idx]
                self.refreshPaused = false
                dlog("user set refresh interval to \(self.refreshInterval)s")
                self.restartScanTimer()
                self.refreshData()
                self.refreshSwitchboard()
            }
            out[i] = SystemGroup(title: "Feed", rows: out[i].rows + [cadence])
        }
        if let i = out.firstIndex(where: { $0.title == "Session" }) {
            out[i] = SystemGroup(title: "Session", rows: out[i].rows + [wakeOnLANRow()])
        }
        let schedules = scheduleRows()
        if !schedules.isEmpty {
            let at = (out.firstIndex(where: { $0.title == "Services" }) ?? -1) + 1
            out.insert(SystemGroup(title: "Schedules", rows: schedules), at: at)
        }
        return out
    }

    // ── Schedules: the owner's launchd jobs ──────────────────────────────────

    private func scheduleRows() -> [SystemRow] {
        let jobs = sbSnapshot.jobs
        guard !jobs.isEmpty else { return [] }
        let lib = SwitchboardPaths.gccRoot + "/widgets/claude-instances/lib"
        func jobMenu(_ j: [String: Any]) -> () -> NSMenu {
            {
                let m = NSMenu()
                let label = j["label"] as? String ?? ""
                m.addItem(ClosureMenuItem("Run now") { [weak self] in
                    _ = Services.shell("/usr/bin/env", ["python3", lib + "/jobs.py", "run", label])
                    self?.refreshSnapshot()
                })
                if let plist = j["plist"] as? String {
                    m.addItem(ClosureMenuItem("Show plist in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)])
                    })
                }
                if let log = j["log"] as? String {
                    m.addItem(ClosureMenuItem("Open log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) })
                }
                m.addItem(.separator())
                let info = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                info.isEnabled = false
                m.addItem(info)
                return m
            }
        }
        // Always-on agents are services, not schedules: one summary row, the
        // list in its menu. Everything that runs on a clock gets its own row.
        let always = jobs.filter { ($0["schedule"] as? String) == "always running" }
        let timed = jobs.filter { ($0["schedule"] as? String) != "always running" }
        var rows: [SystemRow] = []
        // Only failing scheduled jobs earn a row of their own; the healthy
        // ones fold into one summary row, so the tab stays short.
        let healthy = timed.filter { !($0["failing"] as? Bool ?? false) }
        if !healthy.isEmpty {
            var r = SystemRow(label: "Scheduled jobs",
                              state: .count(healthy.count, menuGreen),
                              note: "last runs ok · pick one for run now, plist, log",
                              tip: "launchd jobs that run on a clock.",
                              menu: {
                                  let m = NSMenu()
                                  for j in healthy {
                                      let item = NSMenuItem(title: "\(j["name"] as? String ?? "?")  ·  \(j["schedule"] as? String ?? "")", action: nil, keyEquivalent: "")
                                      item.submenu = jobMenu(j)()
                                      m.addItem(item)
                                  }
                                  return m
                              })
            r.key = "scheduled-jobs"
            rows.append(r)
        }
        for j in timed where j["failing"] as? Bool ?? false {
            let exit = (j["last_exit"] as? NSNumber)?.intValue ?? 1
            var r = SystemRow(label: (j["name"] as? String ?? "?").capitalized,
                              state: .count(exit, menuRed),
                              note: (j["schedule"] as? String ?? "") + " · last run failed (exit \(exit))",
                              tip: j["label"] as? String ?? "",
                              menu: jobMenu(j))
            r.key = j["label"] as? String
            rows.append(r)
        }
        if !always.isEmpty {
            let down = always.filter { ($0["loaded"] as? Bool ?? false) && !($0["running"] as? Bool ?? false) }
            let running = always.filter { $0["running"] as? Bool ?? false }.count
            let unloaded = always.filter { !($0["loaded"] as? Bool ?? false) }.count
            var r = SystemRow(label: "Always-on agents",
                              state: down.isEmpty ? .count(running, menuGreen) : .count(down.count, menuRed),
                              note: (down.isEmpty ? "\(running) running" : "\(down.count) stopped")
                                  + (unloaded > 0 ? " · \(unloaded) not loaded" : ""),
                              tip: "Agents launchd keeps alive. Pick one for its actions.",
                              menu: {
                                  let m = NSMenu()
                                  for j in always {
                                      let item = NSMenuItem(title: "\(j["running"] as? Bool ?? false ? "●" : "○")  \(j["name"] as? String ?? "?")", action: nil, keyEquivalent: "")
                                      item.submenu = jobMenu(j)()
                                      m.addItem(item)
                                  }
                                  return m
                              })
            r.key = "always-on-agents"
            rows.insert(r, at: 0)
        }
        return rows
    }

    // ── Wake-on-LAN ──────────────────────────────────────────────────────────

    private func wakeOnLANRow() -> SystemRow {
        let targets = sbSnapshot.wolTargets
        let wol = SwitchboardPaths.gccRoot + "/widgets/claude-instances/lib/wol.py"
        return SystemRow(
            label: "Wake a device",
            state: targets.isEmpty ? .off : .count(targets.count, menuTeal),
            note: targets.isEmpty ? "no saved devices" : targets.compactMap { $0["name"] as? String }.joined(separator: ", "),
            tip: "Send a wake-on-LAN packet to a saved machine on the home network.",
            menu: { [weak self] in
                let m = NSMenu()
                for t in targets {
                    let name = t["name"] as? String ?? "?", mac = t["mac"] as? String ?? ""
                    let bcast = t["broadcast"] as? String ?? "255.255.255.255"
                    m.addItem(ClosureMenuItem("Wake \(name)") {
                        let r = Services.shell("/usr/bin/env", ["python3", wol, "wake", mac, bcast])
                        dlog("wol: \(name) \(r.trimmingCharacters(in: .whitespacesAndNewlines))")
                    })
                }
                if !targets.isEmpty { m.addItem(.separator()) }
                m.addItem(ClosureMenuItem("Add device…") { self?.addWakeTarget(wol) })
                if !targets.isEmpty {
                    let forget = NSMenuItem(title: "Forget", action: nil, keyEquivalent: "")
                    let sub = NSMenu()
                    for t in targets {
                        let mac = t["mac"] as? String ?? ""
                        sub.addItem(ClosureMenuItem(t["name"] as? String ?? mac) {
                            _ = Services.shell("/usr/bin/env", ["python3", wol, "remove", mac])
                            self?.refreshSnapshot()
                        })
                    }
                    forget.submenu = sub
                    m.addItem(forget)
                }
                return m
            })
    }

    private func addWakeTarget(_ wol: String) {
        let a = NSAlert()
        a.messageText = "Add a device to wake"
        a.informativeText = "Its MAC address, for example 3c:22:fb:12:34:56. The machine must have wake-on-LAN turned on."
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        name.placeholderString = "Name (e.g. Desktop PC)"
        let mac = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        mac.placeholderString = "MAC address"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        box.addSubview(name); box.addSubview(mac)
        a.accessoryView = box
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let r = Services.shell("/usr/bin/env", ["python3", wol, "add", name.stringValue, mac.stringValue])
        if r.contains("error") {
            let e = NSAlert(); e.messageText = "Not saved"; e.informativeText = r; e.runModal()
        }
        refreshSnapshot()
    }

    // ── Timed flips on system switches ───────────────────────────────────────
    // "Keep Awake for 2 hours", "Kanban off until 6 PM": flip now, flip back at
    // a time. Saved in UserDefaults so a restart does not lose one. At the due
    // time the switch is re-probed and flipped only if it is not already where
    // it should be, so a manual change in between is never undone twice.

    /// Overridden by the timer probe, so a test never touches live timers.
    var systemTimersKey = "switchboard.timers"

    var systemTimers: [String: SystemTimer] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: systemTimersKey) as? [String: [String: Any]] ?? [:]
            return raw.compactMapValues { d in
                guard let t = d["until"] as? Double, let on = d["restoreOn"] as? Bool else { return nil }
                return SystemTimer(until: Date(timeIntervalSince1970: t), restoreOn: on)
            }
        }
        set {
            let raw = newValue.mapValues { ["until": $0.until.timeIntervalSince1970, "restoreOn": $0.restoreOn] as [String: Any] }
            UserDefaults.standard.set(raw, forKey: systemTimersKey)
        }
    }

    private func systemRow(_ key: String) -> SystemRow? {
        panelSystemGroups().flatMap { $0.rows }.first { $0.timerKey == key }
    }

    /// Flip the switch now; remember to put it back at `until`.
    func startSystemTimer(_ key: String, until: Date) {
        guard let row = systemRow(key), until > Date() else { return }
        // A timer already running keeps its original restore state, so
        // re-timing never forgets where the switch started.
        let restore = systemTimers[key]?.restoreOn ?? row.isOn
        if row.isOn == restore { row.action?() }
        systemTimers[key] = SystemTimer(until: until, restoreOn: restore)
        dlog("timer: \(key) until \(until), then \(restore ? "on" : "off")")
        refreshSwitchboard()
    }

    /// Drop the timer and keep the switch as it is now.
    func cancelSystemTimer(_ key: String) {
        systemTimers[key] = nil
        refreshSwitchboard()
    }

    /// Drop the timer and put the switch back right away.
    func endSystemTimerNow(_ key: String) {
        guard let t = systemTimers[key] else { return }
        systemTimers[key] = nil
        if let row = systemRow(key), row.isOn != t.restoreOn { row.action?() }
        refreshSnapshot()
    }

    /// Headless check of the timer engine on the real Keep Awake switch, with
    /// the real power assertion read back from pmset. Leaves Keep Awake as it
    /// found it. Returns a pass/fail report.
    func probeSystemTimers() -> String {
        systemTimersKey = "switchboard.timers.probe"
        systemTimers = [:]
        var lines: [String] = [], fails = 0
        func check(_ name: String, _ ok: Bool) { lines.append("  \(ok ? "ok  " : "FAIL") \(name)"); if !ok { fails += 1 } }
        func pump(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func asserted() -> Bool {
            Services.shell("/usr/bin/pmset", ["-g", "assertions"])
                .split(separator: "\n").contains { $0.contains("pid \(getpid())(") && $0.contains("PreventUserIdleSystemSleep") }
        }
        func fire() {   // fire due timers and wait for the fresh-state pass to land
            fireDueSystemTimers()
            let deadline = Date().addingTimeInterval(25)
            while systemTimers.values.contains(where: { $0.until <= Date() }) && Date() < deadline { pump(0.1) }
            pump(0.5)
        }
        let before = keepAwakeOn
        if keepAwakeOn { setKeepAwake(false) }
        let key = "Keep Awake"

        startSystemTimer(key, until: Date().addingTimeInterval(2)); pump(0.3)
        check("on-for-a-while turns Keep Awake on", keepAwakeOn)
        check("the power assertion is really held", asserted())
        check("timer recorded to restore off", systemTimers[key]?.restoreOn == false)
        pump(2.2); fire()
        check("at the due time it turns back off", !keepAwakeOn)
        check("the power assertion is released", !asserted())
        check("the timer is gone", systemTimers[key] == nil)

        startSystemTimer(key, until: Date().addingTimeInterval(2)); pump(0.3)
        setKeepAwake(false)                       // the owner turns it off by hand
        pump(2.2); fire()
        check("a manual change in between is not flipped again", !keepAwakeOn)

        startSystemTimer(key, until: Date().addingTimeInterval(60)); pump(0.3)
        cancelSystemTimer(key); pump(0.3)
        check("cancel keeps the current state (on)", keepAwakeOn)
        check("cancel removes the timer", systemTimers[key] == nil)
        setKeepAwake(false)

        startSystemTimer(key, until: Date().addingTimeInterval(60)); pump(0.3)
        endSystemTimerNow(key); pump(0.3)
        check("end now flips it back at once", !keepAwakeOn)

        startSystemTimer(key, until: Date().addingTimeInterval(60)); pump(0.3)
        startSystemTimer(key, until: Date().addingTimeInterval(120)); pump(0.3)
        check("re-timing keeps it on and keeps the original restore state",
              keepAwakeOn && systemTimers[key]?.restoreOn == false)
        endSystemTimerNow(key); pump(0.3)

        if before != keepAwakeOn { setKeepAwake(before) }
        systemTimers = [:]
        lines.append("timer-probe: \(fails == 0 ? "all passed" : "\(fails) failed")")
        return lines.joined(separator: "\n")
    }

    /// Checked on a slow tick: fire whatever is due, against fresh state.
    private func fireDueSystemTimers() {
        let due = systemTimers.filter { $0.value.until <= Date() }
        guard !due.isEmpty else { return }
        refreshSnapshot { [weak self] in
            guard let self = self else { return }
            for (key, t) in due {
                self.systemTimers[key] = nil
                if let row = self.systemRow(key), row.isOn != t.restoreOn {
                    dlog("timer: \(key) due, turning \(t.restoreOn ? "on" : "off")")
                    row.action?()
                } else {
                    dlog("timer: \(key) due, already \(t.restoreOn ? "on" : "off")")
                }
            }
            self.refreshSnapshot()
        }
    }

    /// Fresh system rows for a headless snapshot: runs the same probe the menu
    /// does and waits for it, pumping the runloop the probe completes on.
    func panelSystemGroupsFresh() -> [SystemGroup] {
        var done = false
        refreshSnapshot { done = true }
        let deadline = Date().addingTimeInterval(20)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return panelSystemGroups()
    }

    @objc private func toggleKanban(_ sender: NSMenuItem) {
        guard !kanbanBusy else { return }
        let stopping = kanbanUp == true
        kanbanBusy = true
        refreshSwitchboard()
        dlog("kanban: \(stopping ? "stop" : "start")")
        // zsh -lc so pm2 resolves from the login PATH (GUI apps don't get it).
        let cmd = stopping
            ? "pm2 stop kanban"
            : "pm2 start kanban 2>/dev/null || pm2 start bun --name kanban -- \"$HOME/.claude/scripts/kanban/server.ts\" --port 5106"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", cmd]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        task.terminationHandler = { [weak self] _ in
            // Give the server a beat to bind or release the port, then re-probe.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let self = self else { return }
                self.kanbanBusy = false
                self.refreshSnapshot()
            }
        }
        do { try task.run() } catch {
            derr("kanban toggle failed: \(fmtErr(error))")
            kanbanBusy = false
            refreshSnapshot()
        }
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

    @objc private func openSettings() {
        dlog("opening settings window")
        if settingsController == nil {
            settingsController = SettingsWindowController(onWillOpen: { [weak self] in
                self?.theMenu.cancelTracking()
                self?.hideUsagePopover()
            })
        }
        settingsController?.show()
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
