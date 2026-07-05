// SettingsWindowController.swift
// The standalone Settings window (⌘, / the "Settings…" menu item).
//
// Hosts the SAME SettingsTabView the dashboard's Settings tab renders, so both
// surfaces show one implementation — a dedicated window is the natural home for
// prefs without opening the heavy 960×680 dashboard. The section views read/write
// UserDefaults + PaletteStore directly (no DashboardData dependency), so hosting
// them here needs no refactor.

import AppKit
import SwiftUI

// Not @MainActor: only ever invoked from main-thread menu actions, matching the
// DashboardController pattern in this codebase (AppKit calls stay on main).
final class SettingsWindowController {
    private var window: NSWindow?

    /// Called before the window is brought forward — the owner (BarDelegate)
    /// uses it to dismiss any open status menu / hover popover so they don't
    /// sit above the new window.
    private let onWillOpen: () -> Void

    init(onWillOpen: @escaping () -> Void) {
        self.onWillOpen = onWillOpen
    }

    func show() {
        onWillOpen()
        if window == nil {
            let host = NSHostingController(rootView: SettingsTabView())
            let w = NSWindow(contentViewController: host)
            w.title = "Claude Instances — Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 600, height: 680))
            window = w
        }
        // Center on the screen under the cursor (the user opened the menu there),
        // not NSScreen.main — robust when a secondary/built-in display is asleep.
        if let w = window {
            let mouse = NSEvent.mouseLocation
            let scr = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            if let vf = scr?.visibleFrame {
                w.setFrameOrigin(NSPoint(x: vf.midX - w.frame.width / 2,
                                         y: vf.midY - w.frame.height / 2))
            } else {
                w.center()
            }
        }
        // Accessory-app activation dance: an .accessory app has no key window by
        // default, so explicitly activate + key the window or it opens behind.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
