import SwiftUI
import HostKernel

/// The Plugin Manager: lists every registered plugin, shows health pills
/// + recent stats, lets the user master-toggle enable/disable, and
/// surfaces panic-disable-all. Reads from `PlatformRegistry` (manifests +
/// warnings) and `ResourceSampler` (live metrics).
struct PluginManagerTab: View {
    @EnvironmentObject var platform: PlatformRegistry
    @EnvironmentObject var settings: HostSettingsStore
    @Environment(\.design) var design

    @State private var selectedId: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 280)
                .background(DesignTokens.Surface.header)
            Divider()
            ScrollView { detail }
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(platform.manifests, id: \.id) { manifest in
                        HoverRow {
                            row(for: manifest)
                        }
                        .background(selectedId == manifest.id
                                    ? DesignTokens.Surface.selected.opacity(0.25)
                                    : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedId = manifest.id }
                        Divider().opacity(0.4)
                    }
                }
            }
            footer
        }
    }

    private var header: some View {
        let total = platform.manifests.count
        let enabled = platform.manifests.filter { settings.settings.isPluginEnabled($0.id) }.count
        let errored = errorCount()
        return VStack(alignment: .leading, spacing: 2) {
            Text("PLUGINS")
                .font(design.font(DesignTokens.FontSize.caption, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(DesignTokens.TextColor.secondary)
            Text("\(enabled)/\(total) enabled · \(errored) errored")
                .font(design.font(DesignTokens.FontSize.caption))
                .foregroundStyle(DesignTokens.TextColor.tertiary)
        }
        .padding(design.space(DesignTokens.Space.m))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for manifest: Manifest) -> some View {
        let metrics = platform.sampler.snapshot()[manifest.id]
        let enabled = settings.settings.isPluginEnabled(manifest.id)
        let status = healthStatus(for: manifest, metrics: metrics, enabled: enabled)
        return HStack(spacing: design.space(DesignTokens.Space.s)) {
            statusDot(status)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.name)
                    .font(design.font(DesignTokens.FontSize.body, weight: .medium))
                    .foregroundStyle(DesignTokens.TextColor.primary)
                Text(statusText(status, metrics: metrics))
                    .font(design.font(DesignTokens.FontSize.caption))
                    .foregroundStyle(DesignTokens.TextColor.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, design.space(DesignTokens.Space.m))
        .padding(.vertical, design.space(DesignTokens.Space.s))
        .id(platform.samplerTick)  // re-render on sampler tick
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: design.space(DesignTokens.Space.s)) {
            Divider()
            Button(role: .destructive) {
                for m in platform.manifests {
                    settings.setPluginEnabled(m.id, false)
                }
            } label: {
                Label("Panic disable all", systemImage: "power")
                    .font(design.font(DesignTokens.FontSize.caption))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.SemanticColor.error)
        }
        .padding(design.space(DesignTokens.Space.m))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedId, let manifest = platform.manifests.first(where: { $0.id == id }) {
            detailView(manifest)
        } else {
            VStack(spacing: design.space(DesignTokens.Space.s)) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 32))
                    .foregroundStyle(DesignTokens.TextColor.tertiary)
                Text("Select a plugin")
                    .font(design.font(DesignTokens.FontSize.body))
                    .foregroundStyle(DesignTokens.TextColor.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailView(_ manifest: Manifest) -> some View {
        let metrics = platform.sampler.snapshot()[manifest.id]
        let enabled = settings.settings.isPluginEnabled(manifest.id)
        return VStack(alignment: .leading, spacing: design.space(DesignTokens.Space.l)) {
            detailHeader(manifest: manifest, enabled: enabled)
            detailIdentity(manifest)
            detailContributions(manifest)
            if let metrics { detailMetrics(metrics) }
            detailActions(manifest)
        }
        .padding(design.space(DesignTokens.Space.l))
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(platform.samplerTick)
    }

    private func detailHeader(manifest: Manifest, enabled: Bool) -> some View {
        HStack(alignment: .center, spacing: design.space(DesignTokens.Space.s)) {
            Image(systemName: manifest.icon ?? "puzzlepiece.extension")
                .font(.system(size: 24))
                .foregroundStyle(DesignTokens.SemanticColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.name)
                    .font(design.font(DesignTokens.FontSize.heroTitle, weight: .semibold))
                if let d = manifest.description {
                    Text(d)
                        .font(design.font(DesignTokens.FontSize.body))
                        .foregroundStyle(DesignTokens.TextColor.secondary)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { enabled },
                set: { settings.setPluginEnabled(manifest.id, $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private func detailIdentity(_ manifest: Manifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            kv("ID", manifest.id)
            kv("Version", manifest.version.description)
            kv("Engines", manifest.engines.claudeInstances)
            kv("Exec", manifest.exec.kind.rawValue)
            if let dir = manifest.pluginDir {
                kv("Path", dir.path, mono: true)
            }
        }
        .padding(design.space(DesignTokens.Space.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneBackground()
    }

    private func detailContributions(_ manifest: Manifest) -> some View {
        let c = manifest.contributes
        var counts: [(String, Int)] = []
        counts.append(("dashboard.pane", c.dashboardPane?.count ?? 0))
        counts.append(("commands", c.commands?.count ?? 0))
        counts.append(("settings.section", c.settingsSection?.count ?? 0))
        counts.append(("hotkey", c.hotkey?.count ?? 0))
        counts.append(("menubar.item", c.menubarItem?.count ?? 0))
        counts.append(("statusbar.badge", c.statusbarBadge?.count ?? 0))
        counts = counts.filter { $0.1 > 0 }
        return VStack(alignment: .leading, spacing: 4) {
            sectionLabel("CONTRIBUTIONS")
            if counts.isEmpty {
                Text("none")
                    .font(design.font(DesignTokens.FontSize.body))
                    .foregroundStyle(DesignTokens.TextColor.tertiary)
            } else {
                ForEach(counts, id: \.0) { kv($0.0, "\($0.1)", mono: true) }
            }
        }
        .padding(design.space(DesignTokens.Space.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneBackground()
    }

    private func detailMetrics(_ m: ResourceSampler.PluginMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("RUNTIME")
            kv("Total fetches", "\(m.totalFetches)")
            kv("Errors", "\(m.totalErrors)", tone: m.totalErrors > 0 ? Tone.error : Tone.none)
            kv("Spawns / min", "\(m.spawnsLastMinute)")
            kv("p50 latency", "\(m.p50LatencyMs)ms")
            kv("p95 latency", "\(m.p95LatencyMs)ms")
            kv("Last payload", humanBytes(m.lastPayloadBytes))
            if let last = m.lastFetchAt {
                kv("Last fetch", relative(last))
            }
            if let err = m.lastError {
                kv("Last error", err, tone: .error, mono: true)
            }
        }
        .padding(design.space(DesignTokens.Space.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .paneBackground()
    }

    private func detailActions(_ manifest: Manifest) -> some View {
        HStack(spacing: design.space(DesignTokens.Space.s)) {
            if let dir = manifest.pluginDir {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                .controlSize(.small)
            }
            Button("Open log") {
                let url = HostLogPaths.pluginLogDir().appendingPathComponent("\(manifest.id).log")
                NSWorkspace.shared.open(url)
            }
            .controlSize(.small)
            Spacer()
        }
    }

    // MARK: - Helpers

    private enum Health { case healthy, errored, disabled, idle }

    private func healthStatus(for manifest: Manifest,
                              metrics: ResourceSampler.PluginMetrics?,
                              enabled: Bool) -> Health {
        if !enabled { return .disabled }
        if let m = metrics, m.lastError != nil { return .errored }
        if let m = metrics, m.lastFetchAt != nil { return .healthy }
        return .idle
    }

    private func statusDot(_ status: Health) -> some View {
        let color: Color = {
            switch status {
            case .healthy:  return DesignTokens.SemanticColor.ok
            case .errored:  return DesignTokens.SemanticColor.error
            case .disabled: return DesignTokens.TextColor.tertiary
            case .idle:     return DesignTokens.SemanticColor.warn.opacity(0.5)
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func statusText(_ status: Health, metrics: ResourceSampler.PluginMetrics?) -> String {
        switch status {
        case .disabled: return "Disabled"
        case .errored:  return metrics?.lastError ?? "Error"
        case .healthy:
            if let last = metrics?.lastFetchAt {
                return "Healthy · fetched \(relative(last))"
            }
            return "Healthy"
        case .idle:     return "Idle"
        }
    }

    private func errorCount() -> Int {
        let metrics = platform.sampler.snapshot()
        return metrics.values.filter { $0.lastError != nil }.count
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(design.font(DesignTokens.FontSize.caption, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(DesignTokens.TextColor.secondary)
            .padding(.bottom, 2)
    }

    private func kv(_ k: String, _ v: String, tone: Tone? = nil, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: design.space(DesignTokens.Space.s)) {
            Text(k)
                .font(design.font(DesignTokens.FontSize.body))
                .foregroundStyle(DesignTokens.TextColor.secondary)
                .frame(width: 110, alignment: .leading)
            Text(v)
                .font(design.font(DesignTokens.FontSize.body, monospaced: mono))
                .foregroundStyle(DesignTokens.color(for: tone))
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private func relative(_ d: Date) -> String {
        let secs = Int(-d.timeIntervalSinceNow)
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }

    private func humanBytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }
}
