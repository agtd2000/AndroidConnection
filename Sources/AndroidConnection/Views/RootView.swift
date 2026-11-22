import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceStore

    var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 218, ideal: 238, max: 290)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $model.showConnectSheet) {
            ConnectSheet()
                .environmentObject(model)
                .environmentObject(model.devices)
        }
        .frame(
            minWidth: model.mirrorMini ? 320 : 1020,
            minHeight: model.mirrorMini ? 220 : 680
        )
        .environmentObject(model.devices)
        .onChange(of: model.mirrorFullscreen) { fullscreen in
            withAnimation(.easeInOut(duration: 0.2)) {
                model.sidebarVisibility = fullscreen ? .detailOnly : (model.mirrorMini ? .detailOnly : .all)
            }
        }
        .onChange(of: model.mirrorMini) { mini in
            withAnimation(.easeInOut(duration: 0.2)) {
                model.sidebarVisibility = (mini || model.mirrorFullscreen) ? .detailOnly : .all
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Do not leave the phone physically powered off after quit.
            model.mirror?.stop()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.section == .settings {
            SettingsView()
        } else if let device = devices.selectedDevice, device.isReady {
            switch model.section {
            case .dashboard:
                DashboardView()
            case .files:
                if let files = model.files {
                    FilesView(store: files)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .apps:
                if let apps = model.apps {
                    AppsView(store: apps)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .mirror:
                if let mirror = model.mirror {
                    MirrorView(session: mirror)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .clipboard:
                if let clipboard = model.clipboard {
                    ClipboardView(store: clipboard)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .settings:
                SettingsView()
            }
        } else if let device = devices.selectedDevice {
            DeviceAttentionView(device: device)
        } else {
            NoDeviceView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceStore

    private var items: [SidebarSection] {
        SidebarSection.allCases.filter { $0 != .settings }
    }

    var body: some View {
        VStack(spacing: 0) {
            brand
            Divider().opacity(0.5)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(items) { item in
                        SidebarRow(
                            section: item,
                            isSelected: model.section == item,
                            badge: badge(for: item)
                        ) {
                            model.choose(item)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }

            Spacer(minLength: 8)
            Divider().opacity(0.5)
            deviceFooter
            settingsRow
        }
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accentDeep, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 0) {
                Text("AndroidConnection")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("Mac × Android")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func badge(for section: SidebarSection) -> String? {
        switch section {
        case .apps:
            let count = model.apps?.apps.count ?? 0
            return count > 0 ? "\(count)" : nil
        case .files:
            return nil
        default:
            return nil
        }
    }

    private var footerDevice: AndroidDevice? {
        devices.devices.first(where: { $0.serial == devices.selectedSerial })
    }

    private var deviceFooter: some View {
        Group {
            if let device = footerDevice {
                Button {
                    model.choose(.dashboard)
                } label: {
                    HStack(spacing: 10) {
                        DeviceAvatar(name: device.displayName, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(device.isReady ? Theme.accent : Theme.warning)
                                    .frame(width: 6, height: 6)
                                Text("\(device.secondaryName) · \(device.connection.label)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    model.showConnect()
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("未连接设备")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("USB 或无线 ADB")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var settingsRow: some View {
        SidebarRow(section: .settings, isSelected: model.section == .settings, badge: nil) {
            model.choose(.settings)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

struct SidebarRow: View {
    let section: SidebarSection
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.14) : (hover.isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovered = $0 }
    }
}

struct NoDeviceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设备")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button("刷新") {
                    Task { await model.devices.refresh() }
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("连接设备") { model.showConnect() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)

            EmptyStateView(
                icon: "cable.connector",
                title: "连接你的 Android 手机",
                message: "用 USB 数据线连接手机并开启「USB 调试」，或通过无线调试在同一 Wi-Fi 下连接。连接后即可管理文件、启动应用、投屏与同步剪贴板。",
                actionTitle: "打开连接向导",
                action: { model.showConnect() }
            )

            HStack(spacing: 22) {
                hint(icon: "1.circle", text: "设置 → 关于手机 → 连续点击版本号")
                hint(icon: "2.circle", text: "开启「开发者选项 → USB 调试」")
                hint(icon: "3.circle", text: "连接后在手机上允许调试授权")
            }
            .padding(.bottom, 30)
        }
    }

    private func hint(icon: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct DeviceAttentionView: View {
    @EnvironmentObject private var model: AppModel
    let device: AndroidDevice

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: device.state == "unauthorized" ? "lock.shield" : "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(device.state == "unauthorized" ? Theme.warning : Theme.danger)
            Text(device.state == "unauthorized" ? "等待手机授权" : "设备当前不可用")
                .font(.title3.weight(.semibold))
            Text(device.state == "unauthorized"
                 ? "请解锁手机，在“允许 USB 调试吗？”弹窗中点击“允许”。勾选“始终允许”可避免重复授权。"
                 : "设备状态：\(device.statusLabel)。请重新插拔数据线，或重启 ADB 服务后重试。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("重新扫描") {
                    Task { await model.devices.refresh() }
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("重启 ADB") {
                    Task {
                        try? await ADB.shared.restartServer()
                        await model.devices.refresh()
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
