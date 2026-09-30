// Bar.swift
// BarDelegate — status item, menu construction, action handlers.
// (split from claude-instances-bar.swift — one module, same binary)

import AppKit
import Foundation
import SwiftUI

final class BarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var scanTimer: Timer?

    private(set) var cachedData: ScanResult?
    private var lastScanError = false
    private var theMenu: NSMenu!
    private var settingsController: SettingsWindowController?

    /// Tick counter for quick/full scan alternation.
    /// Quick scan (~90ms) runs every 5s. Full scan (~185ms) runs every 6th tick (30s).
    private var scanTick: Int = 0
    private let fullScanInterval: Int = 6

    /// Claude logo, loaded once and drawn into the composited badge image each
    /// tick (avoids re-reading the file on every updateButton()).
    private var barIcon: NSImage?

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
                        // Quick scan: merge live data into the existing cached result.
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
                            liveCount: r.liveCount,
                            machine: r.machine
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
                // Live-update the open menu's per-instance rows. Only does
                // work when menuIsOpen=true; cheap no-op otherwise.
                self.refreshLiveRows()
            }
        }
    }

    // ── Menu bar button ──────────────────────────────────────────────────────

    private func updateButton() {
        guard let btn = statusItem.button else { return }

        // Badge composition is user-configurable (Settings → Menu Bar Badge).
        let showCount = UserDefaults.standard.object(forKey: "ui.badge.showCount") as? Bool ?? true

        let liveCount = cachedData?.liveCount ?? 0
        let countText = !showCount ? "" : (liveCount > 0 ? "\(liveCount)" : "–")

        btn.image = composeBadgeImage(count: countText)
        btn.imagePosition = .imageOnly
        btn.title = ""
        btn.attributedTitle = NSAttributedString(string: "")
        btn.alphaValue = liveCount == 0 ? 0.5 : 1.0   // dim when idle
    }

    /// Draw the claude icon + live count into one NSImage sized to the menu bar.
    private func composeBadgeImage(count: String) -> NSImage {
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

        let padL: CGFloat = 2, gapIcon: CGFloat = 3, padR: CGFloat = 3
        let iconW: CGFloat = icon != nil ? iconSize : 0
        let totalW = padL + iconW + (iconW > 0 ? gapIcon : 0) + countW + padR

        let img = NSImage(size: NSSize(width: totalW, height: barH), flipped: false) { _ in
            var x = padL
            if let icon = icon {
                icon.draw(in: NSRect(x: x, y: (barH - iconSize) / 2, width: iconSize, height: iconSize))
                x += iconW + gapIcon
            }
            countStr.draw(at: NSPoint(x: x, y: (barH - countStr.size().height) / 2))
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
            let stateStr = inst.effectiveState
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
        if let n = inst.name, !n.isEmpty { return n }
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

        // ── Live instances ───────────────────────────────────────────────────
        addLiveInstancesSection(menu, data)


        // ── History ──────────────────────────────────────────────────────────
        addHistorySection(menu, data)

        // ── Actions ──────────────────────────────────────────────────────────
        addActionsSection(menu, data)
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

        // A condition every session shares is said once, here, not on each row.
        if rowShows(.mcpDown), let mcp = data.machine?["mcp_down"], !mcp.isEmpty {
            let item = NSMenuItem()
            item.attributedTitle = NSAttributedString(string: "  ⚠ MCP down on this Mac: \(mcp)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.systemRed,
            ])
            item.isEnabled = false
            menu.addItem(item)
        }

        for (idx, inst) in live.enumerated() {
            // Build the live-updating row view. All visual content
            // (header / tab title / full path / state detail / last prompt /
            // metrics / compaction warn / focus file / mcp-down) lives inside
            // ONE NSMenuItem.view so the labels can mutate in place while the
            // menu is open. AppKit doesn't redraw attributedTitle of an open
            // standard menu item — the view-based approach is the workaround.
            let leaf = liveRowLeaf(inst)
            let fullPath = liveRowFullPath(inst)
            let stateStr = inst.effectiveState
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
        // The full list lives in the hub's session index.
        let more = NSMenuItem()
        more.attributedTitle = NSAttributedString(string: "  All sessions in the hub", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        more.action = #selector(openHubIndex)
        more.target = self
        sub.addItem(more)
        head.submenu = sub
        menu.addItem(head)
        menu.addItem(.separator())
    }

    // ── Section: Actions ─────────────────────────────────────────────────────

    private func addActionsSection(_ menu: NSMenu, _ data: ScanResult) {
        addAction(menu, "New Session", #selector(newSession), icon: "plus.circle", key: "n")
        addAction(menu, "Settings…", #selector(openSettings), icon: "gearshape", key: ",")
        addAction(menu, "Sessions (phone)", #selector(openHubIndex), icon: "iphone")
        addAction(menu, "Switchboard", #selector(openSwitchboard), icon: "slider.vertical.3")
        addRefreshMenu(menu)

        let killable = data.live.filter { $0.isClaudeInteractive }.count
        if killable > 0 {
            menu.addItem(.separator())
            let termAll = NSMenuItem(title: "Terminate All (\(killable))",
                                     action: #selector(terminateAll), keyEquivalent: "")
            termAll.target = self
            termAll.attributedTitle = NSAttributedString(
                string: "  Terminate All (\(killable))",
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

        // Cadence and pause, one level down so the common action stays one click.
        let cadence = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        cadence.attributedTitle = NSAttributedString(string: "  Refresh Every",
                                                     attributes: [.font: NSFont.systemFont(ofSize: 13)])
        setIcon(cadence, "timer")
        let sub = NSMenu()
        for (i, secs) in Self.refreshPresets.enumerated() {
            let item = NSMenuItem(title: secs < 1 ? String(format: "%.1fs", secs) : "\(Int(secs))s",
                                  action: #selector(chooseCadence(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = (!refreshPaused && abs(secs - refreshInterval) < 0.01) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let pause = NSMenuItem(title: refreshPaused ? "Resume" : "Pause",
                               action: #selector(togglePause(_:)), keyEquivalent: "")
        pause.target = self
        sub.addItem(pause)
        cadence.submenu = sub
        menu.addItem(cadence)
    }

    @objc private func chooseCadence(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < Self.refreshPresets.count else { return }
        refreshInterval = Self.refreshPresets[sender.tag]
        refreshPaused = false
        dlog("user set refresh interval to \(refreshInterval)s")
        restartScanTimer()
        refreshData()
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        refreshPaused.toggle()
        dlog("refresh \(refreshPaused ? "paused" : "resumed")")
        restartScanTimer()
        if !refreshPaused { refreshData() }
    }

    /// Switchboard is its own app now; this opens it (launching it if needed).
    @objc private func openSwitchboard() {
        let id = "io.github.alcatraz627.switchboard"
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                NSWorkspace.shared.open(URL(string: "https://github.com/alcatraz627/switchboard-mac")!)
                return
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = ["--open"]
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        } else {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("dev.switchboard.toggle"), object: nil, userInfo: nil, deliverImmediately: true)
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
        let start = cachedData?.live.first { $0.pid == pid }?.procStart
        let signalled = terminateSessions([(Int32(pid), start)])
        if signalled.isEmpty {
            dwarn(start == nil
                  ? "terminate: pid=\(pid) has no recorded start time yet; not signalled (retry after the next scan)"
                  : "terminate: pid=\(pid) is no longer the session the scan saw; not signalled")
        } else {
            dlog("terminate: pid=\(pid)")
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

    @objc private func openSettings() {
        dlog("opening settings window")
        if settingsController == nil {
            settingsController = SettingsWindowController(onWillOpen: { [weak self] in
                self?.theMenu.cancelTracking()
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
        // Interactive Claude sessions only: a bulk kill must never reach a
        // Codex daemon or headless worker, even if the scan lets one through.
        let targets = data.live.filter { $0.isClaudeInteractive }.map { (Int32($0.pid), $0.procStart) }
        let signalled = terminateSessions(targets)
        dlog("terminate all: signalled \(signalled) of \(targets.map(\.0))")
    }

    @objc private func refreshAction() {
        dlog("manual refresh (forced full)")
        scanTick = fullScanInterval - 1  // Next tick will be a full scan
        refreshData()
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
