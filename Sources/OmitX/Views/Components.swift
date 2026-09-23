import SwiftUI
import AppKit

extension Safety {
    var color: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .danger: .red
        }
    }
    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }
}

struct SafetyBadge: View {
    let safety: Safety
    var body: some View {
        Label(safety.label, systemImage: safety.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(safety.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(safety.color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

struct SizeText: View {
    let bytes: Int64
    var unknownLabel = "—"
    var body: some View {
        Text(bytes > 0 ? ByteFormat.string(bytes) : unknownLabel)
            .monospacedDigit()
            .foregroundStyle(bytes >= 1_000_000_000 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .fontWeight(bytes >= 1_000_000_000 ? .semibold : .regular)
    }
}

/// Three-state checkbox for group headers.
struct TriStateCheckbox: View {
    let selected: Int
    let total: Int
    let action: (Bool) -> Void
    var body: some View {
        Button {
            action(selected < total)
        } label: {
            Image(systemName: selected == 0 ? "square" : (selected == total ? "checkmark.square.fill" : "minus.square.fill"))
                .foregroundStyle(selected == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .font(.body)
        }
        .buttonStyle(.plain)
    }
}

struct NoteBanner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Disk usage bar.
struct DiskBar: View {
    let total: Int64
    let available: Int64
    var reclaimable: Int64 = 0

    var body: some View {
        let used = max(0, total - available)
        let reclaim = min(reclaimable, used)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.blue.gradient)
                        .frame(width: w * CGFloat(Double(used) / Double(max(total, 1))))
                    Capsule().fill(.green.gradient)
                        .frame(width: w * CGFloat(Double(reclaim) / Double(max(total, 1))))
                        .offset(x: w * CGFloat(Double(used - reclaim) / Double(max(total, 1))))
                }
            }
            .frame(height: 14)
            HStack(spacing: 14) {
                legend(.blue, L("Đã dùng \(ByteFormat.string(used))"))
                if reclaim > 0 { legend(.green, L("Có thể dọn \(ByteFormat.string(reclaim))")) }
                Spacer()
                Text("Còn trống \(ByteFormat.string(available)) / \(ByteFormat.string(total))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension Date {
    var relative: String {
        // Just now → "now" instead of "in 0 seconds"
        if abs(timeIntervalSinceNow) < 60 { return L("vừa xong") }
        let f = RelativeDateTimeFormatter()
        // Arabic CLDR .short data renders past months as "خلال" (= "within the coming …") → use .full
        f.unitsStyle = AppLanguage.current == "ar" ? .full : .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}

/// File/app icon cache — avoids calling NSWorkspace.icon on every SwiftUI redraw.
@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(img, forKey: key)
        return img
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: IconCache.icon(for: url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// Proportional size bar (used in the analyzer table).
struct ProportionBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
            }
        }
        .frame(height: 6)
    }
}

/// The sidebar background material (translucent, following whether the window is active).
///
/// `List(.sidebar)` gets this background for free, but `.inspector` uses an opaque pane background —
/// so the right panel looked heavier than the left sidebar. This is the only way to get that material:
/// SwiftUI does not expose `NSVisualEffectView.Material.sidebar`.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
