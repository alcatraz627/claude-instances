import SwiftUI
import HostKernel

/// Universal failure state. Closed code chip + message + actionable card +
/// stderr disclosure.
struct ErrorPaneView: View {
    let error: PluginError
    @State private var showStderr = false
    @Environment(\.design) var design

    var body: some View {
        VStack(alignment: .leading, spacing: design.space(DesignTokens.Space.s)) {
            HStack(spacing: design.space(DesignTokens.Space.xs) + 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.SemanticColor.error)
                Text(error.code.rawValue)
                    .font(design.font(DesignTokens.FontSize.label, monospaced: true))
                    .foregroundStyle(DesignTokens.SemanticColor.error)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .chipBackground(tone: Tone.error)
            }
            Text(error.message)
                .font(design.font(DesignTokens.FontSize.body))
                .foregroundStyle(DesignTokens.TextColor.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionable = error.actionable {
                Text(actionable)
                    .font(design.font(DesignTokens.FontSize.label))
                    .foregroundStyle(DesignTokens.TextColor.secondary)
                    .padding(design.space(DesignTokens.Space.s))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.SemanticColor.warn.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Corner.s)
                            .stroke(DesignTokens.SemanticColor.warn.opacity(0.3),
                                    lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.s))
            }
            if let stderr = error.stderrTail, !stderr.isEmpty {
                DisclosureGroup(isExpanded: $showStderr) {
                    ScrollView {
                        Text(stderr)
                            .font(design.font(DesignTokens.FontSize.caption, monospaced: true))
                            .foregroundStyle(DesignTokens.TextColor.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    .padding(design.space(DesignTokens.Space.s))
                    .background(DesignTokens.Surface.header)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.s))
                } label: {
                    Text("stderr")
                        .font(design.font(DesignTokens.FontSize.label))
                        .foregroundStyle(DesignTokens.TextColor.secondary)
                }
            }
        }
        .padding(design.space(DesignTokens.Space.m))
    }
}
