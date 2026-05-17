import AppKit
import HostKernel

/// Pure-AppKit row view used inside NSMenuItem.view for rich menubar
/// rows. Deliberately NOT a SwiftUI/NSHostingView wrapper — those have
/// caused crashes elsewhere in this codebase (FSEVENTS-001) and an
/// icon + label + subtitle layout doesn't need SwiftUI.
@MainActor
final class RichMenuRowView: NSView {
    private static let rowHeight: CGFloat = 44
    private static let rowWidth: CGFloat = 280

    private let iconView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var isHovered = false

    init(row: MenubarRow, design: ResolvedDesign) {
        super.init(frame: NSRect(x: 0, y: 0,
                                  width: Self.rowWidth, height: Self.rowHeight))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = true

        // Icon (optional)
        if let icon = row.icon,
           let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            iconView.image = img
            iconView.contentTintColor = nsColor(for: row.tone)
            iconView.imageScaling = .scaleProportionallyDown
        }
        iconView.frame = NSRect(x: 12, y: 12, width: 20, height: 20)
        addSubview(iconView)

        // Label
        labelField.stringValue = row.label
        labelField.font = NSFont.systemFont(
            ofSize: 13 * design.textScale, weight: .medium)
        labelField.textColor = nsColor(for: row.tone) ?? NSColor.labelColor
        labelField.isBordered = false
        labelField.drawsBackground = false
        labelField.isEditable = false
        labelField.lineBreakMode = .byTruncatingTail
        labelField.frame = NSRect(
            x: 40, y: row.subtitle != nil ? 22 : 12,
            width: Self.rowWidth - 56, height: 18)
        addSubview(labelField)

        // Subtitle (optional)
        if let subtitle = row.subtitle {
            subtitleField.stringValue = subtitle
            subtitleField.font = NSFont.systemFont(ofSize: 10 * design.textScale)
            subtitleField.textColor = NSColor.secondaryLabelColor
            subtitleField.isBordered = false
            subtitleField.drawsBackground = false
            subtitleField.isEditable = false
            subtitleField.lineBreakMode = .byTruncatingTail
            subtitleField.frame = NSRect(
                x: 40, y: 6, width: Self.rowWidth - 56, height: 14)
            addSubview(subtitleField)
        }

        // Hover tracking — menu items by default don't have it; we add one.
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor
            .withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
    }

    /// Forward clicks to the enclosing NSMenuItem's target/action so the
    /// row behaves like a regular menu item.
    override func mouseUp(with event: NSEvent) {
        guard let menuItem = enclosingMenuItem,
              let action = menuItem.action else { return }
        NSApp.sendAction(action, to: menuItem.target, from: menuItem)
        menuItem.menu?.cancelTracking()
    }

    // MARK: - Tone -> NSColor

    private func nsColor(for tone: Tone?) -> NSColor? {
        switch tone {
        case .ok:    return NSColor.systemGreen
        case .warn:  return NSColor.systemOrange
        case .error: return NSColor.systemRed
        case .dim:   return NSColor.secondaryLabelColor
        case .some(Tone.none), nil: return nil
        }
    }
}
