import AppKit

/// The V2 menu-bar app entrypoint.
///
/// Manual NSApplication bootstrap rather than `@main` because the SPM executable target
/// needs `LSUIElement = YES` to suppress the Dock icon, and that requires the Info.plist
/// shipped inside the .app bundle (assembled by build.sh, not by SPM).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
