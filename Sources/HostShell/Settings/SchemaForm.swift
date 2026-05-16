import SwiftUI
import HostKernel

/// Renders a SwiftUI form from a minimal JSON Schema. Each property becomes
/// one labeled control; values are bound to the per-plugin settings dict
/// in `HostSettingsStore`. Defaults from the schema seed the form on first
/// render.
struct SchemaForm: View {
    let pluginId: String
    let schema: SettingsSchema
    @EnvironmentObject var store: HostSettingsStore
    @Environment(\.design) var design

    var body: some View {
        VStack(alignment: .leading, spacing: design.space(DesignTokens.Space.s)) {
            ForEach(orderedKeys(), id: \.self) { key in
                if let prop = schema.properties[key] {
                    row(key: key, prop: prop)
                }
            }
        }
    }

    // MARK: - Row dispatch

    @ViewBuilder
    private func row(key: String, prop: SettingsSchema.Property) -> some View {
        switch (prop.type, prop.enum) {
        case ("boolean", _):
            booleanRow(key: key, prop: prop)
        case ("string", let cases?) where !cases.isEmpty:
            enumRow(key: key, prop: prop, cases: cases)
        case ("string", _):
            stringRow(key: key, prop: prop)
        case ("integer", _), ("number", _):
            numericRow(key: key, prop: prop)
        default:
            unsupportedRow(key: key, prop: prop)
        }
    }

    // MARK: - Bindings

    private func current(_ key: String, default fallback: Any) -> AnyCodable {
        store.settings.pluginSettings[pluginId]?[key]
            ?? schema.properties[key]?.default
            ?? AnyCodable(fallback)
    }

    private func setValue(_ key: String, _ value: AnyCodable) {
        store.update { s in
            var dict = s.pluginSettings[pluginId] ?? [:]
            dict[key] = value
            s.pluginSettings[pluginId] = dict
        }
    }

    // MARK: - Row kinds

    private func booleanRow(key: String, prop: SettingsSchema.Property) -> some View {
        let v = (current(key, default: false).value as? Bool) ?? false
        return HStack {
            labelView(prop: prop, key: key)
            Spacer()
            Toggle("", isOn: Binding(
                get: { v },
                set: { setValue(key, AnyCodable($0)) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private func stringRow(key: String, prop: SettingsSchema.Property) -> some View {
        let v = (current(key, default: "").value as? String) ?? ""
        return HStack(alignment: .top) {
            labelView(prop: prop, key: key)
            Spacer()
            TextField("", text: Binding(
                get: { v },
                set: { setValue(key, AnyCodable($0)) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 240)
        }
    }

    private func enumRow(key: String, prop: SettingsSchema.Property, cases: [AnyCodable]) -> some View {
        let v = (current(key, default: "").value as? String) ?? ""
        let labels = cases.compactMap { $0.value as? String }
        return HStack {
            labelView(prop: prop, key: key)
            Spacer()
            Picker("", selection: Binding(
                get: { v },
                set: { setValue(key, AnyCodable($0)) }
            )) {
                ForEach(labels, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
    }

    private func numericRow(key: String, prop: SettingsSchema.Property) -> some View {
        let v = (current(key, default: 0).value as? Int)
            ?? Int((current(key, default: 0).value as? Double) ?? 0)
        let lo = prop.minimum.map(Int.init) ?? Int.min
        let hi = prop.maximum.map(Int.init) ?? Int.max
        return HStack {
            labelView(prop: prop, key: key)
            Spacer()
            Stepper(value: Binding(
                get: { v },
                set: { setValue(key, AnyCodable($0)) }
            ), in: lo...hi) {
                Text("\(v)")
                    .font(design.font(DesignTokens.FontSize.body, monospaced: true))
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
    }

    private func unsupportedRow(key: String, prop: SettingsSchema.Property) -> some View {
        HStack {
            labelView(prop: prop, key: key)
            Spacer()
            Text("(\(prop.type) — unsupported)")
                .font(design.font(DesignTokens.FontSize.caption))
                .foregroundStyle(DesignTokens.TextColor.tertiary)
        }
    }

    private func labelView(prop: SettingsSchema.Property, key: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(prop.title ?? key)
                .font(design.font(DesignTokens.FontSize.body))
                .foregroundStyle(DesignTokens.TextColor.primary)
            if let desc = prop.description {
                Text(desc)
                    .font(design.font(DesignTokens.FontSize.caption))
                    .foregroundStyle(DesignTokens.TextColor.tertiary)
            }
        }
    }

    private func orderedKeys() -> [String] {
        if let explicit = schema.order, !explicit.isEmpty { return explicit }
        return schema.properties.keys.sorted()
    }
}
