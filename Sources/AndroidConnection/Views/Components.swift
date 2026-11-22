import SwiftUI
import AppKit

enum Theme {
    static let accent = Color(red: 0.18, green: 0.68, blue: 0.61)
    static let accentDeep = Color(red: 0.09, green: 0.42, blue: 0.60)
    static let warning = Color(red: 0.95, green: 0.62, blue: 0.24)
    static let danger = Color(red: 0.91, green: 0.36, blue: 0.36)
    static let cardRadius: CGFloat = 16
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = Theme.accent
    var icon: String?

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 92, height: 92)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [
                        Theme.accentDeep.opacity(configuration.isPressed ? 0.82 : 1),
                        Theme.accent.opacity(configuration.isPressed ? 0.82 : 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: Theme.accent.opacity(0.25), radius: 8, y: 3)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.06))
            )
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var icon: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct BatteryRing: View {
    let level: Int
    var charging: Bool

    private var tint: Color {
        if level <= 15 { return Theme.danger }
        if level <= 35 { return Theme.warning }
        return Theme.accent
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, level))) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text("\(level)%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 64, height: 64)
    }
}

struct StorageBar: View {
    let used: Int64
    let total: Int64
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * CGFloat(total > 0 ? min(1, Double(used) / Double(total)) : 0))
                }
            }
            .frame(height: 7)
            HStack {
                Text("\(Formatters.fileSize(used)) 已用")
                Spacer()
                Text("共 \(Formatters.fileSize(total))")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

struct IconBubble: View {
    let icon: String
    var tint: Color = Theme.accent
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.13))
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

struct ToastBanner: View {
    let text: String
    var color: Color = Theme.accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 1)
        )
    }
}

struct ToolbarIconButton: View {
    let icon: String
    var help: String = ""
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? AnyShapeStyle(Color.secondary.opacity(0.5)) : AnyShapeStyle(Color.primary))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .disabled(disabled)
        .help(help)
    }
}

struct DeviceAvatar: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accentDeep, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "iphone")
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}


@MainActor
final class HoverState: ObservableObject {
    @Published var isHovered = false
}
