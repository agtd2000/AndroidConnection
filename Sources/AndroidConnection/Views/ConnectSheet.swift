import SwiftUI
import AppKit

struct ConnectSheet: View {
    @EnvironmentObject private var devices: DeviceStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var vm = ConnectViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("连接方式", selection: $vm.mode) {
                ForEach(ConnectMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    currentConnectionCard
                    Group {
                        if vm.mode == .usb {
                            usbContent
                        } else {
                            wirelessContent
                        }
                    }
                }
                .padding(22)
            }

            Divider()

            HStack(spacing: 10) {
                if vm.busy {
                    ProgressView().controlSize(.small)
                }
                Text(vm.message ?? "提示：连接前请先解锁手机；首次连接还需要在手机上允许 USB 调试授权。")
                    .font(.caption)
                    .foregroundStyle(vm.message == nil ? .secondary : Theme.accent)
                    .lineLimit(2)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 580, height: 620)
        .task {
            await devices.refresh()
            if vm.host.isEmpty, let ip = devices.details?.ipAddress, !ip.isEmpty {
                vm.host = ip
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accentDeep, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "cable.connector")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("连接 Android 设备")
                    .font(.headline)
                Text("USB 数据线或同一 Wi-Fi 下的无线调试")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var currentConnectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "当前连接", subtitle: "连接前需解锁手机")
                Spacer()
                if devices.connectionPaused {
                    StatusPill(text: "已断开", color: Theme.warning)
                }
            }

            if let device = devices.selectedDevice {
                HStack(spacing: 10) {
                    Image(systemName: device.connection.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("\(device.secondaryName) · \(device.connection.label)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(
                        text: device.statusLabel,
                        color: device.isReady ? Theme.accent : Theme.warning
                    )
                    Button("断开") { toggleConnection(device) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(vm.busy)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("尚未连接设备。解锁手机后，在下方选择设备并点击“连接”。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var usbContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepsCard

            HStack {
                SectionHeader(title: "USB 设备", subtitle: "已通过数据线连接的手机")
                Spacer()
                Button("重新扫描") {
                    Task { await devices.refresh() }
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            let usbDevices = devices.devices.filter { $0.connection == .usb }
            if usbDevices.isEmpty {
                Text("未检测到 USB 设备。请确认数据线支持数据传输，并在手机上开启“USB 调试”。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
            } else {
                ForEach(usbDevices) { device in
                    let isCurrent = devices.selectedSerial == device.serial
                    let statusText = isCurrent
                        ? device.statusLabel
                        : (device.isReady ? "可连接" : device.statusLabel)
                    let statusColor = isCurrent
                        ? (device.isReady ? Theme.accent : Theme.warning)
                        : (device.isReady ? Theme.accentDeep : Theme.warning)
                    HStack(spacing: 10) {
                        DeviceAvatar(name: device.displayName, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.displayName)
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(device.secondaryName)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(text: statusText, color: statusColor)
                        Button(isCurrent ? "断开" : "连接") {
                            toggleConnection(device)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!device.isReady || vm.busy)

                        Button("开启无线") {
                            Task {
                                vm.busy = true
                                vm.message = await devices.enableWireless(serial: device.serial)
                                vm.busy = false
                                vm.mode = .wireless
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!device.isReady)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                }
            }

            Text("开启无线调试后，手机会在 5555 端口监听；请确保 Mac 与手机处于同一局域网，然后在“无线”页连接。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("准备手机")
                .font(.callout.weight(.semibold))
            step("1", "设置 → 关于手机 → 连续点击“版本号”7 次")
            step("2", "开发者选项 → 开启“USB 调试”")
            step("3", "用数据线连接 Mac，并在手机上点击“允许”")
            step("4", "解锁手机后点击“连接”；锁屏或息屏状态会被拒绝")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1)
        )
    }

    private func step(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.accent))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var wirelessContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "无线连接", subtitle: "通过 Wi-Fi 连接已开启调试的手机")

            HStack(spacing: 8) {
                TextField("手机 IP，例如 192.168.1.20", text: $vm.host)
                    .textFieldStyle(.roundedBorder)
                TextField("端口", text: $vm.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                Button("连接") {
                    connect()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(vm.host.trimmed.isEmpty || vm.busy)
            }

            HStack(spacing: 10) {
                Text("提示：先在同一 Wi-Fi 下用 USB 开启无线调试，或使用 Android 11+ 的配对码。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task {
                        vm.busy = true
                        await devices.discoverServices()
                        vm.busy = false
                        if let first = devices.discoveredServices.first {
                            vm.host = first.address.components(separatedBy: ":").first ?? vm.host
                            vm.message = "发现 \(devices.discoveredServices.count) 个无线调试服务"
                        }
                    }
                } label: {
                    Label("扫描局域网", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            if !devices.discoveredServices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("发现的服务")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(devices.discoveredServices) { service in
                        HStack(spacing: 8) {
                            Image(systemName: "wifi")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                            Text(service.name)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text(service.address)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button("连接") {
                                vm.host = service.address.components(separatedBy: ":").first ?? vm.host
                                vm.port = service.address.components(separatedBy: ":").last ?? "5555"
                                connect()
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("配对码配对")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("Android 11+")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("手机：开发者选项 → 无线调试 → 使用配对码配对设备。将显示的 IP、端口和 6 位配对码填入下方。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("配对端口", text: $vm.pairPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField("6 位配对码", text: $vm.pairCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Button("配对并连接") {
                        pairAndConnect()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(vm.host.trimmed.isEmpty || vm.pairPort.trimmed.isEmpty || vm.pairCode.trimmed.isEmpty || vm.busy)
                }
            }

            if !devices.savedDevices.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("已保存")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(devices.savedDevices) { saved in
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(saved.address)
                                .font(.system(size: 11.5, design: .monospaced))
                            Spacer()
                            if devices.selectedSerial == saved.address {
                                StatusPill(text: "当前", color: Theme.accent)
                                if let device = devices.devices.first(where: { $0.serial == saved.address }) {
                                    Button("断开") { toggleConnection(device) }
                                        .font(.caption)
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Theme.danger)
                                        .disabled(vm.busy)
                                }
                            } else {
                                Button("连接") {
                                    vm.host = saved.address.components(separatedBy: ":").first ?? saved.address
                                    vm.port = saved.address.components(separatedBy: ":").last ?? "5555"
                                    connect()
                                }
                                .font(.caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                                .disabled(vm.busy)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggleConnection(_ device: AndroidDevice) {
        guard !vm.busy else { return }
        vm.busy = true
        Task {
            if devices.selectedSerial == device.serial {
                vm.message = await devices.disconnect(device)
            } else {
                vm.message = await devices.connect(device: device)
            }
            vm.busy = false
        }
    }

    private func connect() {
        let targetHost = vm.host.trimmed
        let targetPort = vm.port.trimmed.isEmpty ? "5555" : vm.port.trimmed
        guard !targetHost.isEmpty else { return }
        vm.busy = true
        Task {
            vm.message = await devices.connect(address: "\(targetHost):\(targetPort)")
            vm.busy = false
        }
    }

    private func pairAndConnect() {
        let targetHost = vm.host.trimmed
        let targetPort = vm.port.trimmed.isEmpty ? "5555" : vm.port.trimmed
        vm.busy = true
        Task {
            let pairAddress = "\(targetHost):\(vm.pairPort.trimmed)"
            let pairResult = await devices.pair(address: pairAddress, code: vm.pairCode.trimmed)
            vm.message = pairResult
            if pairResult.lowercased().contains("success") {
                vm.message = await devices.connect(address: "\(targetHost):\(targetPort)")
            }
            vm.busy = false
        }
    }
}


enum ConnectMode: String, CaseIterable, Identifiable {
    case usb = "USB"
    case wireless = "无线"
    var id: String { rawValue }
}

@MainActor
final class ConnectViewModel: ObservableObject {
    @Published var mode: ConnectMode = .usb
    @Published var host = ""
    @Published var port = "5555"
    @Published var pairPort = ""
    @Published var pairCode = ""
    @Published var message: String?
    @Published var busy = false
}
