import AppKit
import SwiftUI

/// Owns the dashboard NSPanel. NSPanel is the right primitive for a status-icon-driven
/// dashboard: lightweight, non-key-activating by default, can be shown/hidden without
/// participating in normal window cycling. The SwiftUI root lives inside an
/// NSHostingController so plugin views compose naturally in later phases.
final class DashboardController {
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel() -> NSPanel {
        let root = DashboardRootView()
        let hosting = NSHostingController(rootView: root)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "claude-instances V2"
        panel.contentViewController = hosting
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        return panel
    }
}
