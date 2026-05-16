import SwiftUI
import HostKernel

/// Dashboard layout: sidebar + content scroller. Phase 4 swaps the
/// demo entries for registry-driven `dashboard.pane` contributions. Plugins
/// supply the render content; `PaneRenderer` paints it through the design
/// system the user controls in Settings.
struct DashboardSurface: View {
    let onTitleChange: (String) -> Void

    @EnvironmentObject var store: HostSettingsStore
    @EnvironmentObject var platform: PlatformRegistry
    @Environment(\.design) var design

    @State private var selection: String? = nil

    private var disabledPluginIds: Set<String> {
        Set(store.settings.plugins.compactMap { $0.value.enabled ? nil : $0.key })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            // .id(selection) forces SwiftUI to tear down the old detail
            // tree and build the new one atomically. Without this the old
            // pane stays visible while the new ContributionView initializes
            // — the "tab change page lag" the user reported.
            detail
                .id(selection ?? "_none")
                .frame(minWidth: 520)
                .background(DesignTokens.Surface.page)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if selection == nil {
                selection = platform.dashboardSections(disabledIds: disabledPluginIds)
                    .flatMap { $0.items }
                    .first?.1.id
            }
            pushTitle(for: selection)
        }
        .onChange(of: selection) { newSel in
            platform.hostLogger.info("user.action", "sidebar.select \(newSel ?? "(none)")")
            pushTitle(for: newSel)
        }
    }

    /// Compute the human page name for the current selection and bridge
    /// it up to the NSPanel via the host-supplied callback. SwiftUI's
    /// .navigationTitle doesn't reach NSPanel chrome.
    private func pushTitle(for id: String?) {
        guard let id else { onTitleChange(""); return }
        switch id {
        case "settings": onTitleChange("Settings")
        case "plugins":  onTitleChange("Plugins")
        default:
            if let pair = findContribution(by: id) {
                onTitleChange(pair.1.title)
            } else {
                onTitleChange("")
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(platform.dashboardSections(disabledIds: disabledPluginIds),
                    id: \.section) { group in
                Section(group.section) {
                    ForEach(group.items, id: \.1.id) { _, contribution in
                        NavigationLink(value: contribution.id) {
                            Label(contribution.title,
                                  systemImage: contribution.icon ?? "rectangle")
                        }
                    }
                }
            }
            Section("System") {
                NavigationLink(value: "plugins") {
                    Label("Plugins", systemImage: "puzzlepiece.extension")
                }
                NavigationLink(value: "settings") {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }
            if platform.bootstrapped == false {
                Section("Status") {
                    Text("Loading plugins…")
                        .font(design.font(DesignTokens.FontSize.caption))
                        .foregroundStyle(DesignTokens.TextColor.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case "settings":
            SettingsTab()
        case "plugins":
            PluginManagerTab()
        case let id? where id != "settings":
            if let pair = findContribution(by: id) {
                ContributionView(manifest: pair.0, contribution: pair.1)
            } else {
                fallback("No contribution found for id \(id).")
            }
        default:
            fallback("Pick something from the sidebar.")
        }
    }

    private func findContribution(by id: String) -> (Manifest, DashboardPane)? {
        for group in platform.dashboardSections() {
            for (manifest, contribution) in group.items where contribution.id == id {
                return (manifest, contribution)
            }
        }
        return nil
    }

    private func fallback(_ message: String) -> some View {
        VStack(spacing: design.space(DesignTokens.Space.s)) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 32))
                .foregroundStyle(DesignTokens.TextColor.tertiary)
            Text(message)
                .font(design.font(DesignTokens.FontSize.body))
                .foregroundStyle(DesignTokens.TextColor.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renders a single `dashboard.pane` contribution: stacks all its declared
/// panes vertically, each routed through `PaneRenderer`. Pane content is
/// fetched lazily from the plugin's `render(_:)` method via an async task.
private struct ContributionView: View {
    let manifest: Manifest
    let contribution: DashboardPane

    @EnvironmentObject var platform: PlatformRegistry
    @Environment(\.design) var design

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: design.space(DesignTokens.Space.m)) {
                ForEach(Array(contribution.panes.enumerated()), id: \.offset) { idx, spec in
                    PaneHolder(manifest: manifest, contribution: contribution,
                                spec: spec, index: idx)
                }
            }
            .padding(design.space(DesignTokens.Space.l))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One pane within a contribution. Owns the async render lifecycle —
/// kicks off `plugin.render(source)` on appear and holds the resulting
/// `PaneContent` in @State.
private struct PaneHolder: View {
    let manifest: Manifest
    let contribution: DashboardPane
    let spec: PaneSpec
    let index: Int

    @EnvironmentObject var platform: PlatformRegistry
    @EnvironmentObject var store: HostSettingsStore
    @State private var content: PaneContent? = nil
    @State private var fetchedAt: Date? = nil

    private var paneTitle: String? {
        index == 0 ? contribution.title : spec.label
    }

    private var paneSubtitle: String? {
        index == 0 ? contribution.subtitle : nil
    }

    var body: some View {
        Group {
            if let content {
                PaneRenderer(content: content,
                             title: paneTitle,
                             subtitle: paneSubtitle,
                             fetchedAt: fetchedAt,
                             onRefresh: { Task { await refresh() } })
            } else {
                skeleton
            }
        }
        .task(id: spec.source) {
            await refresh()
        }
        // FSEvents watchers live on PlatformRegistry now; they publish
        // "<plugin-id>.fs-change" to the bus on every change. SwiftUI's
        // .onReceive owns the subscription lifetime, so PaneHolder going
        // away cleanly tears down the receiver — no more dangling
        // self-capture from a CoreServices callback (the Phase-6 crash).
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("ci.bus.\(manifest.id).fs-change"))) { _ in
            Task { @MainActor in await refresh() }
        }
    }

    /// Skeleton shown instantly when a pane is selected, before the first
    /// fetch returns. Pane chrome + dim placeholder tiles — looks like the
    /// real shape without pretending to be real data.
    private var skeleton: some View {
        PaneRenderer(
            content: .summary(SummaryContent(tiles: [
                .init(label: " ", value: "—", tone: .dim),
                .init(label: " ", value: "—", tone: .dim),
                .init(label: " ", value: "—", tone: .dim)
            ])),
            title: paneTitle,
            subtitle: "loading…",
            fetchedAt: nil)
    }

    // FSEvents watchers live on PlatformRegistry now; PaneHolder no
    // longer creates one (was the source of the Phase-6 EXC_BAD_ACCESS
    // when CoreServices fired the callback after the SwiftUI view + its
    // @State storage had been torn down).

    // MARK: - Refresh

    @MainActor
    private func refresh() async {
        guard let source = PaneSource(spec.source) else {
            content = .error(PluginError(
                .fetchSchemaViolation,
                "Plugin '\(manifest.id)': unparseable source string '\(spec.source)'"))
            fetchedAt = Date()
            return
        }
        do {
            switch source {
            case .native(let method):
                content = try await renderNative(method: method)
            case .fetch(let args):
                content = await renderFetch(args: args)
            case .event:
                content = .error(PluginError(
                    .eventUnknownTopic,
                    "Event sources are wired in Phase 6 (got '\(spec.source)')"))
            case .staticData(let json):
                content = renderStatic(json: json)
            }
        } catch {
            content = .error(PluginError(
                .nativeMethodThrew,
                "Render failed: \(error.localizedDescription)"))
        }
        fetchedAt = Date()
    }

    private func renderNative(method: String) async throws -> PaneContent {
        guard let plugin = platform.plugin(for: manifest) else {
            return .error(PluginError(
                .nativeActivationFailed,
                "No Swift plugin registered for id '\(manifest.id)'"))
        }
        return try await plugin.render(method)
    }

    @MainActor
    private func renderFetch(args: [String]) async -> PaneContent {
        guard let dir = manifest.pluginDir,
              let fetchRel = manifest.exec.fetch
        else {
            return .error(PluginError(
                .manifestInvalid,
                "Plugin '\(manifest.id)' has no exec.fetch path"))
        }
        let exec = URL(fileURLWithPath: fetchRel, relativeTo: dir)
            .standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: exec.path) else {
            return .error(PluginError(
                .manifestInvalid,
                "fetch executable missing or not executable: \(exec.path)"))
        }
        let timeoutMs = manifest.limits?.fetchTimeoutMs ?? 5000
        let maxBytes  = manifest.limits?.maxPayloadBytes ?? 262_144
        let logger = platform.logger(for: manifest.id)
        logger.info("fetch", "start \(args.joined(separator: " "))")

        // Per-plugin settings as JSON env var. Plugins parse with
        //   `jq -r '.foo // empty' <<< "$CLAUDE_PLUGIN_SETTINGS"`
        // (or any other JSON-aware tool). Phase-9 fetch.sh template
        // documents the convention.
        var pluginSettingsJSON = "{}"
        if let dict = store.settings.pluginSettings[manifest.id],
           let data = try? JSONEncoder().encode(dict),
           let s = String(data: data, encoding: .utf8) {
            pluginSettingsJSON = s
        }

        do {
            let result = try await ScriptExec.run(
                executable: exec,
                args: args,
                cwd: dir,
                env: [
                    "CLAUDE_PLUGIN_ID":     manifest.id,
                    "CLAUDE_HOST_VERSION":  HostKernel.version,
                    "CLAUDE_PLUGIN_SETTINGS": pluginSettingsJSON,
                ],
                timeoutMs: timeoutMs,
                maxPayloadBytes: maxBytes)

            if result.timedOut {
                let msg = "fetch.sh exceeded \(timeoutMs)ms"
                logger.error("fetch", msg)
                platform.sampler.recordFetch(plugin: manifest.id,
                    latencyMs: result.elapsedMs, payloadBytes: 0, error: msg)
                return .error(PluginError(
                    .fetchTimeout, msg,
                    stderrTail: result.stderr,
                    actionable: "Increase manifest limits.fetch_timeout_ms or speed up fetch.sh"))
            }
            if result.exitCode != 0 {
                let msg = "exit \(result.exitCode)"
                logger.error("fetch", "\(msg): \(result.stderr.prefix(200))")
                platform.sampler.recordFetch(plugin: manifest.id,
                    latencyMs: result.elapsedMs, payloadBytes: 0, error: msg)
                return .error(PluginError(
                    .fetchExitNonzero,
                    "fetch.sh exited with code \(result.exitCode)",
                    stderrTail: result.stderr))
            }
            logger.info("fetch", "ok in \(result.elapsedMs)ms (\(result.stdout.count) bytes)")
            platform.sampler.recordFetch(plugin: manifest.id,
                latencyMs: result.elapsedMs, payloadBytes: result.stdout.count, error: nil)
            return parseStdoutAsPane(result.stdout, stderr: result.stderr)
        } catch {
            let msg = "spawn failed: \(error.localizedDescription)"
            logger.error("fetch", msg)
            platform.sampler.recordFetch(plugin: manifest.id,
                latencyMs: 0, payloadBytes: 0, error: msg)
            return .error(PluginError(.fetchExitNonzero, msg))
        }
    }

    private func renderStatic(json: String) -> PaneContent {
        guard let data = json.data(using: .utf8) else {
            return .error(PluginError(.fetchBadJson, "static source is not valid UTF-8"))
        }
        return parseStdoutAsPane(data, stderr: "")
    }

    /// Parse fetch.sh output as the appropriate `PaneContent` variant.
    /// Switches on the JSON's "kind" key.
    private func parseStdoutAsPane(_ data: Data, stderr: String) -> PaneContent {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = raw["kind"] as? String else {
            return .error(PluginError(
                .fetchBadJson,
                "fetch.sh output is not a JSON object with a 'kind' field",
                stderrTail: stderr))
        }
        let decoder = JSONDecoder()
        do {
            switch kind {
            case "summary":
                return .summary(try decoder.decode(SummaryContent.self, from: data))
            case "table":
                return .table(try decoder.decode(TableContent.self, from: data))
            case "schedule":
                return .schedule(try decoder.decode(ScheduleContent.self, from: data))
            case "assets":
                return .assets(try decoder.decode(AssetsContent.self, from: data))
            case "log":
                let s = String(data: data, encoding: .utf8) ?? ""
                return .log(LogContent(text: s))
            default:
                return .error(PluginError(
                    .fetchSchemaViolation,
                    "Unknown pane kind '\(kind)' in fetch output",
                    stderrTail: stderr))
            }
        } catch {
            return .error(PluginError(
                .fetchSchemaViolation,
                "fetch output did not match the '\(kind)' schema: \(error.localizedDescription)",
                stderrTail: stderr))
        }
    }

    private struct ParsedSource {
        let scheme: String
        let argument: String
    }

    private func parseSource(_ raw: String) -> ParsedSource {
        if let colon = raw.firstIndex(of: ":") {
            return ParsedSource(
                scheme: String(raw[..<colon]),
                argument: String(raw[raw.index(after: colon)...]))
        }
        return ParsedSource(scheme: "native", argument: raw)
    }
}
