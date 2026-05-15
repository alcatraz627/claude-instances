import SwiftUI
import HostKernel

/// Universal failure state. Surfaces the closed error `code`, the message,
/// the actionable hint (if any), and a disclosure for `stderr_tail`.
struct ErrorPaneView: View {
    let error: PluginError

    @State private var showStderr = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.error)
                Text(error.code.rawValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.error)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Palette.error.opacity(0.12))
                    .clipShape(Capsule())
            }
            Text(error.message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if let actionable = error.actionable {
                Text(actionable)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.warn.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Palette.warn.opacity(0.3), lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if let stderr = error.stderrTail, !stderr.isEmpty {
                DisclosureGroup(isExpanded: $showStderr) {
                    ScrollView {
                        Text(stderr)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(Palette.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } label: {
                    Text("stderr").font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
            }
        }
        .padding(12)
    }
}
