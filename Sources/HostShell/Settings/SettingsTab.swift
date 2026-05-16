import SwiftUI
import HostKernel

/// V1-of-V2 settings UI: just the Appearance section. Per-plugin settings
/// sections arrive in Phase 8 (auto-form from JSON Schema).
struct SettingsTab: View {
    @EnvironmentObject var store: HostSettingsStore
    @EnvironmentObject var platform: PlatformRegistry
    @Environment(\.design) var design

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: design.space(DesignTokens.Space.l)) {
                section(title: "APPEARANCE") {
                    settingRow("Color scheme") {
                        Picker("", selection: Binding(
                            get: { store.settings.appearance.colorScheme },
                            set: { newValue in store.update { $0.appearance.colorScheme = newValue } }
                        )) {
                            Text("System").tag(HostSettings.ColorScheme.system)
                            Text("Light").tag(HostSettings.ColorScheme.light)
                            Text("Dark").tag(HostSettings.ColorScheme.dark)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    }

                    settingRow("Text size") {
                        Picker("", selection: Binding(
                            get: { store.settings.appearance.textSize },
                            set: { newValue in store.update { $0.appearance.textSize = newValue } }
                        )) {
                            Text("XS").tag(HostSettings.TextSize.extraSmall)
                            Text("S").tag(HostSettings.TextSize.small)
                            Text("M").tag(HostSettings.TextSize.medium)
                            Text("L").tag(HostSettings.TextSize.large)
                            Text("XL").tag(HostSettings.TextSize.extraLarge)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    }

                    settingRow("Density") {
                        Picker("", selection: Binding(
                            get: { store.settings.appearance.density },
                            set: { newValue in store.update { $0.appearance.density = newValue } }
                        )) {
                            Text("Compact").tag(HostSettings.Density.compact)
                            Text("Comfortable").tag(HostSettings.Density.comfortable)
                            Text("Spacious").tag(HostSettings.Density.spacious)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }
                }

                ForEach(pluginSettingsSections(), id: \.0.id) { manifest, sectionEntry, schema in
                    section(title: sectionEntry.title.uppercased()) {
                        SchemaForm(pluginId: manifest.id, schema: schema)
                    }
                }

                section(title: "ABOUT") {
                    Text("claude-instances V2 — preview")
                        .font(design.font(DesignTokens.FontSize.body))
                        .foregroundStyle(DesignTokens.TextColor.primary)
                    Text("HostKernel \(HostKernel.version) · plugin platform")
                        .font(design.font(DesignTokens.FontSize.caption))
                        .foregroundStyle(DesignTokens.TextColor.tertiary)
                }
            }
            .padding(design.space(DesignTokens.Space.l))
        }
    }

    /// Collect every plugin's settings.section + its resolved JSON Schema.
    private func pluginSettingsSections() -> [(Manifest, SettingsSection, SettingsSchema)] {
        var out: [(Manifest, SettingsSection, SettingsSchema)] = []
        for manifest in platform.manifests {
            guard let dir = manifest.pluginDir else { continue }
            for entry in manifest.contributes.settingsSection ?? [] {
                let schemaURL = URL(fileURLWithPath: entry.schema, relativeTo: dir)
                if let schema = SettingsSchema.load(from: schemaURL) {
                    out.append((manifest, entry, schema))
                }
            }
        }
        return out
    }

    // MARK: helpers

    @ViewBuilder
    private func section<Content: View>(title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: design.space(DesignTokens.Space.m)) {
            Text(title)
                .font(design.font(DesignTokens.FontSize.caption, weight: .semibold))
                .foregroundStyle(DesignTokens.TextColor.secondary)
                .tracking(0.5)
            content()
                .padding(design.space(DesignTokens.Space.m))
                .frame(maxWidth: .infinity, alignment: .leading)
                .paneBackground()
        }
    }

    private func settingRow<Content: View>(_ label: String,
                                            @ViewBuilder _ control: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(design.font(DesignTokens.FontSize.body))
                .foregroundStyle(DesignTokens.TextColor.primary)
            Spacer()
            control()
        }
    }
}
