import SwiftUI
import AppKit

enum AppInfo {
    static let name = "AndroidConnection"
    static let version = "1.2.10"
    static let build = "1"
    static let scrcpyServerVersion = "5.0.1"
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsContent(settings: model.settings, devices: model.devices)
    }
}

@MainActor
final class KeyboardMappingUIState: ObservableObject {
    @Published var recording: MirrorKeyAction?
    @Published var message: String?
    private var monitor: Any?

    func startRecording(_ action: MirrorKeyAction, onChord: @escaping (KeyChord) -> Void) {
        stopRecording()
        recording = action
        message = "请按下要绑定的组合键（支持 ⌘ / ⌥ / ⌃ / ⇧）"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let chord = KeyChord(
                keyCode: event.keyCode,
                modifiers: flags.rawValue,
                label: Self.keyLabel(for: event)
            )
            onChord(chord)
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = nil
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 72: return "音量+"
        case 73: return "音量-"
        case 74: return "静音"
        default:
            let text = event.charactersIgnoringModifiers?.uppercased() ?? ""
            return text.isEmpty ? "键码 \(event.keyCode)" : text
        }
    }
}

struct KeyboardMappingEditor: View {
    @ObservedObject var settings: SettingsStore
    @StateObject private var ui = KeyboardMappingUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "键盘映射", subtitle: "投屏时用 Mac 键盘操控手机")
            Text("点击“录制”后按下组合键即可绑定。绑定只在投屏画面获得焦点时生效；方向键、回车、退格等未绑定按键仍按默认方式输入。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(MirrorKeyAction.allCases) { action in
                HStack(spacing: 10) {
                    Image(systemName: action.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title)
                            .font(.callout.weight(.medium))
                        Text(action.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(settings.keyboardMapping.chord(for: action)?.display ?? "未设置")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button(ui.recording == action ? "请按键…" : "录制") {
                        ui.startRecording(action) { chord in
                            var mapping = settings.keyboardMapping
                            mapping.set(chord, for: action)
                            settings.keyboardMapping = mapping
                            ui.message = "已绑定 \(action.title) → \(chord.display)"
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 10) {
                Button("全部恢复默认") {
                    settings.keyboardMapping.resetAll()
                    ui.message = "已恢复默认键位"
                }
                .buttonStyle(SecondaryButtonStyle())
                if let message = ui.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .font(.callout)
        .card()
        .onDisappear { ui.stopRecording() }
    }
}

struct SettingsContent: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var devices: DeviceStore

    @StateObject private var vm = SettingsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                mirrorSection
                keyboardSection
                fileSection
                connectionSection
                wirelessSection
                clipboardSection
                diagnosticSection
                aboutSection
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await vm.loadDiagnostics()
        }
        .onChange(of: settings.adbPort) { port in
            Task {
                try? await ADB.shared.restartServer()
                await devices.refresh()
                await vm.loadDiagnostics()
                vm.banner = "ADB 端口已切换到 \(port)"
            }
        }
        .confirmationDialog("重启 ADB 服务？", isPresented: $vm.confirmReset, titleVisibility: .visible) {
            Button("重启", role: .destructive) {
                Task {
                    try? await ADB.shared.restartServer()
                    await vm.loadDiagnostics()
                    await devices.refresh()
                    vm.banner = "ADB 服务已重启"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会断开当前所有 ADB 连接并自动重连。")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("投屏、连接优先级、ADB 端口与剪贴板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let banner = vm.banner {
                StatusPill(text: banner, color: Theme.accent, icon: "checkmark.circle.fill")
            }
        }
    }

    private var mirrorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "投屏", subtitle: "基于硬件解码的实时画面")

            Picker("画质", selection: $settings.quality) {
                ForEach(MirrorQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            Picker("码率", selection: $settings.bitrateMbps) {
                ForEach([4, 8, 12, 16], id: \.self) { value in
                    Text("\(value) Mbps").tag(value)
                }
            }
            Toggle("投屏时保持手机屏幕常亮", isOn: $settings.keepScreenAwake)
            Toggle("转发手机播放声音到 Mac", isOn: $settings.audioForwarding)
            Toggle("投屏时关闭手机屏幕（画面和触控继续）", isOn: $settings.autoScreenOff)
            Text("优先通过 scrcpy 控制通道关闭手机显示电源，物理屏幕熄灭但 SurfaceFlinger 继续合成，因此投屏画面、点击和键盘操作都不受影响；若控制通道不可用，则回退到最低亮度。音频捕获需要 Android 13 或更高版本。画质与码率修改只重启画面，不会打断音频。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .card()
    }

    private var keyboardSection: some View {
        KeyboardMappingEditor(settings: settings)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "文件与传输", subtitle: "下载目录与隐藏文件策略")

            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(settings.downloadFolder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("选择…") {
                    chooseDownloadFolder()
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("打开") {
                    NSWorkspace.shared.open(settings.ensureDownloadFolder())
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Toggle("上传时忽略并清理 .DS_Store", isOn: $settings.hideDSStore)
            Toggle("默认显示以 . 开头的隐藏文件", isOn: $settings.hideDotFiles)
            Text("下载的文件默认保存到上述目录，并在 Finder 中自动定位。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .card()
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "连接与 ADB", subtitle: "USB / Wi-Fi 优先级与备用端口")

            Picker("同时连接时优先使用", selection: $settings.connectionPreference) {
                ForEach(ConnectionPreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            Text(settings.connectionPreference.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Picker("ADB 服务端口", selection: $settings.adbPort) {
                Text("5037（默认）").tag(5037)
                Text("5038（备用）").tag(5038)
                Text("5039（备用）").tag(5039)
            }
            Text("切换端口会重启本应用的 ADB 服务。USB 设备同一时刻只能被一个 adb server 占用；若 5037 已被 Android Studio 等程序使用，请先退出对方或将本应用切到备用端口。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .card()
    }

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "剪贴板", subtitle: "Mac 与手机双向同步")
            Toggle("手机复制的内容自动同步到 Mac 剪贴板", isOn: $settings.syncDeviceClipboard)
            Text("通过 scrcpy 控制通道以 shell 权限读取手机剪贴板，绕过 Android 10+ 的后台读取限制；中文与 emoji 可直接从 Mac 输入。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .card()
    }

    private var wirelessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "无线连接", subtitle: "USB 与 Wi-Fi ADB")

            Toggle("自动重连已保存的无线设备", isOn: $settings.autoConnect)

            if devices.savedDevices.isEmpty {
                Text("还没有保存的无线设备。连接一次后会出现在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices.savedDevices) { saved in
                    HStack(spacing: 9) {
                        Image(systemName: "wifi")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(saved.name)
                                .font(.system(size: 12, weight: .medium))
                            Text("上次连接 \(Formatters.relative(saved.lastConnected))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("连接") {
                            Task { await devices.connect(address: saved.address) }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        Button {
                            devices.forget(saved)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("移除")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                }
            }

            Text("Android 11 及以上可使用“无线调试 + 配对码”；旧版本可先用 USB 连接并开启 5555 端口。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .card()
    }

    private var diagnosticSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "诊断", subtitle: "运行时组件")

            InfoRow(label: "ADB", value: vm.adbVersion, icon: "terminal")
            InfoRow(label: "ADB 路径", value: vm.adbPath, icon: "link")
            InfoRow(label: "ADB 端口", value: "\(settings.adbPort)", icon: "number")
            InfoRow(label: "视频管线", value: "scrcpy video · H.264 · VideoToolbox", icon: "server.rack")
            InfoRow(label: "音频管线", value: "scrcpy-server \(AppInfo.scrcpyServerVersion) · PCM 48 kHz", icon: "waveform")
            InfoRow(label: "架构", value: architecture, icon: "cpu")

            HStack {
                Button("重启 ADB 服务") { vm.confirmReset = true }
                    .buttonStyle(SecondaryButtonStyle())
                Button("在 Finder 中显示应用") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
        }
        .font(.callout)
        .card()
    }

    private var aboutSection: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accentDeep, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(AppInfo.name) \(AppInfo.version)")
                    .font(.callout.weight(.semibold))
                Text("本地运行的 Mac × Android 设备管理工具。通过 ADB 连接，无需账号，不上传数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Intel 与 Apple Silicon 通用 · 最低 macOS 13")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private var architecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.downloadFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.downloadFolder = url.path
    }

}


@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var adbVersion = "正在读取…"
    @Published var adbPath = "—"
    @Published var confirmReset = false
    @Published var banner: String?

    func loadDiagnostics() async {
        adbPath = ADB.shared.executableURL?.path ?? "未找到"
        guard ADB.shared.executableURL != nil else {
            adbVersion = "不可用"
            return
        }
        if let result = try? await ADB.shared.run(["version"], timeout: 15) {
            adbVersion = result.output.components(separatedBy: .newlines).first ?? "已安装"
        } else {
            adbVersion = "读取失败"
        }
    }
}
