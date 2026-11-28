import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                hero
                quickActions
                HStack(alignment: .top, spacing: 18) {
                    deviceInfo
                    connections
                }
                footer
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            Task { await devices.refreshDetails(force: true) }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("设备")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("在 Mac 上直接管理 Android 手机")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await devices.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            Button {
                model.showConnect()
            } label: {
                Label("连接设备", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    private var hero: some View {
        let detail = devices.details
        let device = model.device

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accentDeep, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))

            Image(systemName: "iphone.gen3")
                .font(.system(size: 180, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.10))
                .rotationEffect(.degrees(12))
                .offset(x: 26, y: 22)
                .clipped()

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(device?.displayName ?? "Android 设备")
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            if let device {
                                Text(device.connection.label)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(.white.opacity(0.18)))
                            }
                        }
                        Text(subtitle(detail: detail, device: device))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.78))
                    }

                    Spacer()

                    BatteryRing(level: detail?.batteryLevel ?? 0, charging: detail?.isCharging ?? false)
                }

                if let detail, detail.storageTotal > 0 {
                    StorageBar(used: detail.storageUsed, total: detail.storageTotal)
                        .frame(maxWidth: 440)
                } else {
                    Text("正在读取存储信息…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                HStack(spacing: 9) {
                    heroButton("浏览文件", icon: "folder.fill") { model.choose(.files) }
                    heroButton("开始投屏", icon: "play.fill") { model.startMirror() }
                    heroButton("应用", icon: "square.grid.2x2.fill") { model.choose(.apps) }
                    Spacer()
                    if let ip = detail?.ipAddress, !ip.isEmpty {
                        Label(ip, systemImage: "wifi")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .padding(22)
        }
        .frame(height: 222)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Theme.accentDeep.opacity(0.22), radius: 18, y: 8)
    }

    private func subtitle(detail: DeviceDetails?, device: AndroidDevice?) -> String {
        var parts: [String] = []
        if let detail, !detail.manufacturer.isEmpty {
            parts.append(detail.manufacturer)
        }
        if let detail, !detail.model.isEmpty, detail.model != device?.displayName {
            parts.append(detail.model)
        }
        if let detail, !detail.androidVersion.isEmpty {
            parts.append("Android \(detail.androidVersion)")
        }
        if parts.isEmpty {
            parts.append(device?.statusLabel ?? "等待连接")
        }
        return parts.joined(separator: " · ")
    }

    private func heroButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(0.17)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            QuickActionTile(icon: "folder.fill", title: "文件管理", tint: Theme.accent) {
                model.choose(.files)
            }
            QuickActionTile(icon: "rectangle.on.rectangle.fill", title: "屏幕投屏", tint: Theme.accentDeep) {
                model.startMirror()
            }
            QuickActionTile(icon: "shippingbox.fill", title: "安装应用", tint: Color(red: 0.55, green: 0.42, blue: 0.85)) {
                installAPK()
            }
            QuickActionTile(icon: "doc.on.clipboard.fill", title: "剪贴板与链接", tint: Color(red: 0.90, green: 0.52, blue: 0.24)) {
                model.choose(.clipboard)
            }
        }
    }

    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "设备信息", subtitle: "来自 ADB 的实时状态")
                Spacer()
                Button {
                    Task { await devices.refreshDetails(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let detail = devices.details {
                VStack(spacing: 9) {
                    InfoRow(label: "设备名称", value: model.device?.displayName ?? "—", icon: "iphone")
                    InfoRow(label: "型号", value: detail.model.isEmpty ? "—" : detail.model, icon: "number.square")
                    InfoRow(label: "系统", value: detail.androidVersion.isEmpty ? "—" : "Android \(detail.androidVersion)（SDK \(detail.sdk)）", icon: "ant")
                    InfoRow(label: "分辨率", value: detail.resolution.isEmpty ? "—" : detail.resolution, icon: "rectangle.dashed")
                    InfoRow(label: "局域网 IP", value: detail.ipAddress.isEmpty ? "USB 连接" : detail.ipAddress, icon: "network")
                    HStack(spacing: 8) {
                        Image(systemName: "battery.75")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text("电池")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        BatteryInfoButton(detail: detail)
                        Spacer(minLength: 16)
                        Text("\(detail.batteryLevel)% · \(detail.batteryStatusTitle)")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    InfoRow(label: "序列号", value: model.device?.serial ?? "—", icon: "number")
                }
            } else if let error = devices.detailsError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") {
                        Task { await devices.refreshDetails(force: true) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取设备信息…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task {
                        if let url = await model.takeScreenshot() {
                            devices.banner = "已保存截图：\(url.lastPathComponent)"
                        }
                    }
                } label: {
                    Label("截屏", systemImage: "camera")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    devices.banner = "正在下载屏幕录制…"
                    Task { await model.mirror?.start() }
                    model.choose(.mirror)
                } label: {
                    Label("录屏投屏", systemImage: "record.circle")
                }
                .buttonStyle(SecondaryButtonStyle())

                Spacer()
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "连接", subtitle: "USB 与无线调试")
                Spacer()
                Button("管理") { model.showConnect() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            VStack(spacing: 8) {
                ForEach(devices.devices) { device in
                    Button {
                        guard devices.selectedSerial != device.serial else { return }
                        Task { _ = await devices.connect(device: device) }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: device.connection.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(device.isReady ? Theme.accent : .secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.displayName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                Text(device.secondaryName)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(device.statusLabel)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(device.isReady ? Theme.accent : Theme.warning)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(model.device?.id == device.id ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.035))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if devices.devices.isEmpty {
                    Text("暂无已连接设备")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }

            if !model.settings.savedDevices.isEmpty {
                Text("已保存的无线设备")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                ForEach(model.settings.savedDevices) { saved in
                    HStack(spacing: 8) {
                        Image(systemName: "wifi")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(saved.address)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if model.device?.serial == saved.address {
                            StatusPill(text: "当前", color: Theme.accent)
                        } else {
                            Button("连接") {
                                Task { await devices.connect(address: saved.address) }
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                Task { await devices.discoverServices() }
            } label: {
                Label("扫描局域网无线调试", systemImage: "dot.radiowaves.left.and.right")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private var footer: some View {
        if let banner = devices.banner {
            HStack(spacing: 8) {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Spacer()
            }
        }
    }

    private func installAPK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let ok = await model.apps?.install(url: url) ?? false
            if ok {
                devices.banner = "已安装 \(url.lastPathComponent)"
                model.choose(.apps)
            } else {
                devices.banner = model.apps?.statusMessage ?? "安装失败"
            }
        }
    }
}

@MainActor
private final class BatteryInfoState: ObservableObject {
    @Published var show = false
}

private struct BatteryInfoButton: View {
    let detail: DeviceDetails
    @StateObject private var state = BatteryInfoState()

    var body: some View {
        Button {
            state.show.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .help("查看电池详细状态")
        .popover(isPresented: $state.show, arrowEdge: .bottom) {
            BatteryDetailView(detail: detail)
        }
    }
}

struct BatteryDetailView: View {
    let detail: DeviceDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: detail.isCharging ? "battery.100.bolt" : "battery.75")
                    .foregroundStyle(Theme.accent)
                Text("电池状态")
                    .font(.headline)
                Spacer()
                Text("\(detail.batteryLevel)%")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }

            Divider()

            BatteryDetailRow(label: "状态", value: detail.batteryStatusTitle)
            BatteryDetailRow(label: "供电", value: detail.batterySourceTitle)
            BatteryDetailRow(label: "健康", value: detail.batteryHealthTitle)
            BatteryDetailRow(label: "温度", value: detail.batteryTemperatureC.map { String(format: "%.1f ℃", $0) } ?? "系统未提供")
            BatteryDetailRow(label: "电压", value: detail.batteryVoltageMV > 0 ? String(format: "%.3f V", Double(detail.batteryVoltageMV) / 1000) : "系统未提供")
            BatteryDetailRow(label: "最大充电电压", value: detail.batteryMaxChargingVoltageUV.map { String(format: "%.2f V", Double($0) / 1_000_000) } ?? "系统未提供")
            BatteryDetailRow(label: "电量计", value: detail.batteryChargeCounterUAh.map { String(format: "%.0f mAh", Double($0) / 1000) } ?? "系统未提供")
            BatteryDetailRow(label: "电池技术", value: detail.batteryTechnology.isEmpty ? "—" : detail.batteryTechnology)

            Text("数据来自 Android dumpsys battery；设备信息约 6 秒刷新。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 310)
    }
}

private struct BatteryDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }
}

struct QuickActionTile: View {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconBubble(icon: icon, tint: tint, size: 32)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(hover.isHovered ? tint.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
    }
}
