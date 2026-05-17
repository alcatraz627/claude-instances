import AppKit

/// Owns the main `NSStatusItem`. Phase 12 delegates menu population to
/// `MenubarSurface` — this controller just owns the icon and exposes
/// the menu so surfaces can install items into it.
@MainActor
final class StatusBarController {
    let statusItem: NSStatusItem
    let menu: NSMenu

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "puzzlepiece.extension.fill",
                accessibilityDescription: "claude-instances V2"
            )
            button.image?.isTemplate = true
        }
        menu = NSMenu()
        statusItem.menu = menu
    }
}
