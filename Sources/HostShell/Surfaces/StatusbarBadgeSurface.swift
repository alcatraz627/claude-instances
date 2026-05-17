import AppKit
import HostKernel

/// Manages one NSStatusItem per `statusbar.badge` contribution. Each badge
/// lives next to the main puzzle icon in the menu bar. Refreshes on a
/// poll cadence (default 30s for badges; manifests can override).
///
/// Badges are background-active surfaces — they consume resources even
/// when no dashboard is open. Per architecture §4.6, they should be
/// opt-in per badge. This V1 of V2 enables every declared badge by
/// default; future work will gate via Plugin Manager (the per-surface
/// toggle UI is already drafted).
@MainActor
final class StatusbarBadgeSurface {
    private struct LiveBadge {
        let pluginId: String
        let badgeId: String
        let statusItem: NSStatusItem
        var pollTimer: Timer?
    }

    private var badges: [String: LiveBadge] = [:]   // key = "pluginId.badgeId"
    private let platform: PlatformRegistry

    init(platform: PlatformRegistry) {
        self.platform = platform
        installAll()
    }

    deinit {
        // NSStatusItem cleanup; timers invalidate via deinit nominally
        // but be explicit to avoid late callbacks.
        for badge in badges.values {
            badge.pollTimer?.invalidate()
            NSStatusBar.system.removeStatusItem(badge.statusItem)
        }
    }

    // MARK: - Install

    func installAll() {
        for manifest in platform.manifests {
            guard platform.isEnabled(manifest.id) else { continue }
            for spec in manifest.contributes.statusbarBadge ?? [] {
                install(manifest: manifest, spec: spec)
            }
        }
    }

    func install(manifest: Manifest, spec: StatusbarBadge) {
        let key = "\(manifest.id).\(spec.id)"
        guard badges[key] == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "…"
        item.button?.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        var badge = LiveBadge(pluginId: manifest.id,
                               badgeId: spec.id,
                               statusItem: item,
                               pollTimer: nil)
        badges[key] = badge

        // First fetch + timer.
        let pollSec = TimeInterval(spec.fallback?.pollSeconds ?? 30)
        Task { @MainActor in await refresh(key: key) }
        let timer = Timer.scheduledTimer(withTimeInterval: pollSec, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh(key: key) }
        }
        badge.pollTimer = timer
        badges[key] = badge

        platform.hostLogger.info("badges",
            "installed \(manifest.id).\(spec.id) (poll \(Int(pollSec))s)")
    }

    /// Tear down badges for plugins that got disabled.
    func reconcile() {
        let enabledKeys: Set<String> = Set(
            platform.manifests
                .filter { platform.isEnabled($0.id) }
                .flatMap { manifest in
                    (manifest.contributes.statusbarBadge ?? []).map { "\(manifest.id).\($0.id)" }
                }
        )
        // Remove anything not in the enabled set.
        for key in badges.keys where !enabledKeys.contains(key) {
            if let badge = badges.removeValue(forKey: key) {
                badge.pollTimer?.invalidate()
                NSStatusBar.system.removeStatusItem(badge.statusItem)
                platform.hostLogger.info("badges", "removed \(key)")
            }
        }
        // Install anything new.
        installAll()
    }

    // MARK: - Refresh

    private func refresh(key: String) async {
        guard let badge = badges[key],
              let manifest = platform.manifests.first(where: { $0.id == badge.pluginId }),
              let spec = manifest.contributes.statusbarBadge?.first(where: { $0.id == badge.badgeId })
        else { return }

        let value = await fetchValue(manifest: manifest, spec: spec)
        applyValue(value, to: badge.statusItem, render: spec.render)
    }

    private func fetchValue(manifest: Manifest, spec: StatusbarBadge) async -> BadgeValue? {
        // Try native first (if a plugin instance is registered).
        if let plugin = platform.plugin(for: manifest) {
            if let v = try? await plugin.badgeValue(badgeId: spec.id) { return v }
        }
        // Script: parse source like "fetch:badge-args"
        guard let parsed = PaneSource(spec.source) else { return nil }
        if case .fetch(let args) = parsed,
           let fetch = manifest.exec.fetch,
           let dir = manifest.pluginDir {
            let exec = URL(fileURLWithPath: fetch, relativeTo: dir).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: exec.path) else { return nil }
            if let result = try? await ScriptExec.run(
                executable: exec, args: args, cwd: dir,
                env: ["CLAUDE_PLUGIN_ID": manifest.id,
                      "CLAUDE_HOST_VERSION": HostKernel.version],
                timeoutMs: 2000, maxPayloadBytes: 8_192),
               result.exitCode == 0,
               let v = try? JSONDecoder().decode(BadgeValue.self, from: result.stdout) {
                return v
            }
        }
        return nil
    }

    private func applyValue(_ value: BadgeValue?,
                             to item: NSStatusItem,
                             render: StatusbarBadge.Render?) {
        guard let button = item.button else { return }
        guard let value else {
            button.title = ""
            button.image = nil
            return
        }
        // Tone -> color (only applies if AppKit can colorize the title; we
        // use attributed string for that).
        let toneColor: NSColor = {
            switch value.tone {
            case .ok:    return .systemGreen
            case .warn:  return .systemOrange
            case .error: return .systemRed
            case .dim:   return .secondaryLabelColor
            default:     return .labelColor
            }
        }()
        if let text = value.text, !text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: toneColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        } else {
            button.title = ""
        }
        if let iconName = value.icon,
           let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            img.isTemplate = true
            button.image = img
        } else {
            button.image = nil
        }
    }
}
