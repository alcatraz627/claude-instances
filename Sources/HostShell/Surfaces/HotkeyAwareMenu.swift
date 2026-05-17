import AppKit

/// NSMenu subclass that processes `keyEquivalent` for items with custom
/// `view`s. Per Apple's documentation, NSMenuItem's keyEquivalent is
/// ignored when `view` is set — the framework treats view-based items as
/// fully custom and skips its own key matching. We intercept
/// `performKeyEquivalent(with:)` and fire matching items by hand.
///
/// Used by `MenubarSurface` for any submenu containing rich rows so that
/// per-row key equivalents (⌘1, ⌘2, etc.) work the way users expect.
final class HotkeyAwareMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        let cmdHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        if cmdHeld, !chars.isEmpty {
            for item in items {
                guard item.view != nil,
                      item.keyEquivalent == chars else { continue }
                if let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
                cancelTracking()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
