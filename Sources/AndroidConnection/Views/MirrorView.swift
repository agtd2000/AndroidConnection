import SwiftUI
import AppKit

struct MirrorView: View {
    @ObservedObject var session: MirrorSession
    @EnvironmentObject private var model: AppModel
    @StateObject private var ui = MirrorUIState()

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if !ui.fullscreen && !ui.mini {
                    header
                    Divider()
                }
                videoStage

                if ui.fullscreen {
                    fullscreenBar
                } else if !ui.mini {
                    inputBar
                    controlBar
                    footer
                }
            }

            if ui.mini {
                miniBar
            }
        }
        .background((ui.fullscreen || ui.mini) ? Color.black : Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.settings.quality) { _ in
            if session.isRunning && !session.isTransitioning { Task { await session.restartVideoOnly() } }
        }
        .onChange(of: model.settings.bitrateMbps) { _ in
            if session.isRunning && !session.isTransitioning { Task { await session.restartVideoOnly() } }
        }
        .onChange(of: model.settings.audioForwarding) { enabled in
            if session.isRunning { session.setAudioEnabled(enabled) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === mirrorWindow else { return }
            guard ui.fullscreen else { return }
            ui.fullscreen = false
            model.mirrorFullscreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === mirrorWindow else { return }
            guard model.section == .mirror else { return }
            ui.fullscreen = true
            model.mirrorFullscreen = true
        }
        .onDisappear {
            model.mirrorFullscreen = false
            if ui.mini {
                leaveMiniWindow()
                ui.mini = false
                model.mirrorMini = false
            }
        }
        .onAppear {
            guard ProcessInfo.processInfo.arguments.contains("--mirror-ui-test") else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !session.isRunning { await session.start() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                ui.fullscreen = true
                model.mirrorFullscreen = true
            }
        }
    }

    private var videoStage: some View {
        ZStack {
            ((ui.fullscreen || ui.mini) ? Color.black : Color(nsColor: .windowBackgroundColor))
            MirrorPlayerRepresentable(session: session)
                .aspectRatio(videoAspect, contentMode: .fit)

            if !session.isRunning && !session.isStarting && !session.isTransitioning {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(.white.opacity(0.08)).frame(width: 92, height: 92)
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Text("手机屏幕将在这里显示")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("投屏后可点击、滑动操作手机，并直接使用 Mac 键盘输入。")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Button {
                        Task { await session.start() }
                    } label: {
                        Label("开始投屏", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.72))
                )
            }

            if session.isStarting || session.isTransitioning {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("正在建立视频流…").font(.callout).foregroundStyle(.white.opacity(0.85))
                }
                .padding(18)
                .background(Capsule().fill(Color.black.opacity(0.65)))
            }

            if let notice = session.orientationNotice, !notice.isEmpty {
                VStack {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
                        .padding(.top, 14)
                        .padding(.horizontal, 16)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if let error = session.errorMessage, !error.isEmpty, !session.isRunning {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.red.opacity(0.35)))
                        .padding(.bottom, 16)
                }
            }
        }
        .overlay {
            if ui.mini {
                Rectangle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: (ui.fullscreen || ui.mini) ? 0 : 14, style: .continuous))
        .padding(.horizontal, (ui.fullscreen || ui.mini) ? 0 : 20)
        .padding(.top, (ui.fullscreen || ui.mini) ? 0 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    /// The video surface itself takes the phone's aspect ratio. The surrounding
    /// window keeps its normal background instead of drawing black pillar-box
    /// bars, which is especially visible for a portrait phone in a wide window.
    private var videoAspect: CGFloat {
        if session.videoSize.width > 0, session.videoSize.height > 0 {
            return session.videoSize.width / session.videoSize.height
        }
        return session.orientationLandscape ? 16.0 / 9.0 : 9.0 / 20.0
    }

    private var fullscreenBar: some View {
        HStack(spacing: 10) {
            fullscreenButton("chevron.backward", "返回", width: 60) { session.sendKey(4) }
            fullscreenButton("house", "主页", width: 60) { session.sendKey(3) }
            fullscreenButton("square.on.square", "多任务", width: 60) { session.sendKey(187) }
            Divider().frame(height: 18).overlay(Color.white.opacity(0.15))
            fullscreenOrientationButton()
            fullscreenButton(
                session.displayPoweredOff ? "sun.max" : "display",
                session.displayPoweredOff ? "恢复手机屏幕" : (session.screenOff ? "物理关闭手机屏幕" : "关闭手机屏幕")
            ) {
                session.toggleScreen()
            }
            Divider().frame(height: 18).overlay(Color.white.opacity(0.15))
            fullscreenButton("speaker.slash.fill", "静音") { session.sendKey(164) }
            fullscreenButton("speaker.wave.1", "音量 -") { session.sendKey(25) }
            fullscreenButton("speaker.wave.3", "音量 +") { session.sendKey(24) }
            fullscreenButton(
                session.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash",
                session.audioEnabled ? "关闭声音转发" : "开启声音转发"
            ) {
                model.settings.audioForwarding.toggle()
            }

            Spacer()

            if session.audioEnabled { AudioLevelBar(level: session.audioLevel) }
            fullscreenButton("arrow.down.right.and.arrow.up.left", "退出全屏") {
                toggleFullscreen()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.92))
    }

    /// Compact floating controls used by mini mode. The bar only appears when
    /// the pointer is inside the mirror window, so the video can otherwise use
    /// the complete window area.
    private var miniBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 20, height: 26)
                .contentShape(Rectangle())
                .help("拖动控制条任意位置可移动")
            Divider().frame(height: 18).overlay(Color.white.opacity(0.15))
            fullscreenButton("chevron.backward", "返回", width: 60) { session.sendKey(4) }
            fullscreenButton("house", "主页", width: 60) { session.sendKey(3) }
            fullscreenButton("square.on.square", "多任务", width: 60) { session.sendKey(187) }
            Divider().frame(height: 18).overlay(Color.white.opacity(0.15))
            fullscreenOrientationButton()
            fullscreenButton(
                session.displayPoweredOff ? "sun.max" : "display",
                session.displayPoweredOff ? "恢复手机屏幕" : (session.screenOff ? "物理关闭手机屏幕" : "关闭手机屏幕")
            ) {
                session.toggleScreen()
            }
            fullscreenButton("speaker.slash.fill", "静音") { session.sendKey(164) }
            fullscreenButton("speaker.wave.1", "音量 -") { session.sendKey(25) }
            fullscreenButton("speaker.wave.3", "音量 +") { session.sendKey(24) }
            fullscreenButton(
                session.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash",
                session.audioEnabled ? "关闭声音转发" : "开启声音转发"
            ) {
                model.settings.audioForwarding.toggle()
            }

            Spacer(minLength: 12)
            if session.audioEnabled { AudioLevelBar(level: session.audioLevel) }
            fullscreenButton("arrow.up.left.and.arrow.down.right", "退出 Mini，恢复完整界面") {
                toggleMini()
            }
            fullscreenButton("stop.fill", "停止投屏") { session.stop() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(model.settings.miniBarOpacity))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.12)))
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .offset(x: ui.miniBarOffset.width, y: ui.miniBarOffset.height)
        .contentShape(Rectangle())
        .simultaneousGesture(miniBarDragGesture)
        .disabled(!session.isRunning)
        .opacity(session.isRunning ? 1 : 0.55)
    }

    /// Drag the bar away from the bottom edge so it does not cover buttons
    /// rendered near the bottom of the phone screen. The offset is kept in
    /// `MirrorUIState` for the lifetime of this mirror view.
    private var miniBarDragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let now = Date()
                // A cancelled SwiftUI gesture may skip `onEnded`. Detect a new
                // mouse-down by the idle gap or by translation restarting at
                // zero, otherwise the next drag keeps adding to the previous
                // translation and the bar appears stuck.
                let idle = ui.miniBarLastDragTime.map { now.timeIntervalSince($0) > 0.25 } ?? true
                let restarted = abs(value.translation.width) < 0.5 && abs(value.translation.height) < 0.5
                if !ui.miniBarDragging || idle || restarted {
                    ui.miniBarDragStart = ui.miniBarOffset
                    ui.miniBarDragging = true
                }
                ui.miniBarLastDragTime = now
                let x = ui.miniBarDragStart.width + value.translation.width
                let y = ui.miniBarDragStart.height + value.translation.height
                ui.miniBarOffset = CGSize(
                    width: min(180, max(-180, x)),
                    height: min(0, max(-260, y))
                )
            }
            .onEnded { _ in
                ui.miniBarDragging = false
                ui.miniBarDragStart = ui.miniBarOffset
                ui.miniBarLastDragTime = nil
            }
    }

    private func fullscreenButton(_ icon: String, _ help: String, width: CGFloat = 30, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: width, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
        .help(help)
    }

    private func toggleFullscreen() {
        ui.fullscreen.toggle()
        model.mirrorFullscreen = ui.fullscreen
        guard let window = mirrorWindow else { return }
        // `keyWindow` can be a transient tooltip or popup. Toggle the real
        // document window so the desktop fullscreen state follows this flag.
        let nativeFullscreen = window.styleMask.contains(.fullScreen)
        if nativeFullscreen != ui.fullscreen {
            window.toggleFullScreen(nil)
        }
    }

    private var mirrorWindow: NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.title == "AndroidConnection" && $0.contentView != nil
        } ?? NSApp.mainWindow ?? NSApp.keyWindow
    }

    private func toggleMini() {
        guard !ui.fullscreen else { return }
        ui.mini.toggle()
        model.mirrorMini = ui.mini
        if ui.mini {
            enterMiniWindow()
        } else {
            leaveMiniWindow()
        }
    }

    /// Make the window match the phone's video aspect so mini mode contains
    /// only the mirrored screen. The normal frame is restored on exit.
    private func enterMiniWindow() {
        guard let window = mirrorWindow else { return }
        ui.savedWindowFrame = window.frame
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maxWidth = max(320, (visible?.width ?? 1200) - 48)
        let maxHeight = max(220, (visible?.height ?? 800) - 48)
        let aspect = max(0.2, videoAspect)
        var contentWidth = maxWidth
        var contentHeight = contentWidth / aspect
        if contentHeight > maxHeight {
            contentHeight = maxHeight
            contentWidth = contentHeight * aspect
        }
        contentWidth = max(320, contentWidth)
        contentHeight = max(220, contentHeight)
        let chrome = max(0, window.frame.height - window.contentLayoutRect.height)
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        var frame = NSRect(
            x: center.x - contentWidth / 2,
            y: center.y - (contentHeight + chrome) / 2,
            width: contentWidth,
            height: contentHeight + chrome
        )
        if let visible {
            frame.origin.x = min(max(frame.origin.x, visible.minX + 12), visible.maxX - frame.width - 12)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 12), visible.maxY - frame.height - 12)
        }
        window.setFrame(frame, display: true, animate: true)
    }

    private func leaveMiniWindow() {
        if let frame = ui.savedWindowFrame {
            mirrorWindow?.setFrame(frame, display: true, animate: true)
        }
        ui.savedWindowFrame = nil
    }

    private var qualityBinding: Binding<MirrorQuality> {
        Binding(
            get: { model.settings.quality },
            set: { model.settings.quality = $0 }
        )
    }

    private var bitrateBinding: Binding<Int> {
        Binding(
            get: { model.settings.bitrateMbps },
            set: { model.settings.bitrateMbps = $0 }
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("投屏")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                HStack(spacing: 7) {
                    Circle()
                        .fill(session.isRunning ? Theme.accent : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(session.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if session.isRunning {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(session.resolutionLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("输出 \(session.resolutionLabel) · 源 \(Int(session.sourceSize.width))×\(Int(session.sourceSize.height))")
                    }
                }
            }

            Spacer()

            Picker("画质", selection: qualityBinding) {
                ForEach(MirrorQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 168)
            .help("投屏分辨率")

            Picker("码率", selection: bitrateBinding) {
                ForEach([4, 8, 12, 16], id: \.self) { value in
                    Text("\(value) Mbps").tag(value)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 108)
            .help("视频码率")

            Button {
                model.settings.audioForwarding.toggle()
            } label: {
                Label(
                    session.isRunning && session.audioEnabled ? "音频开" : "音频",
                    systemImage: session.isRunning && session.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash"
                )
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(session.isRunning ? session.audioStatus : "是否在投屏时转发手机声音")

            Button {
                Task {
                    if let url = await session.screenshot() {
                        ui.toast = "截图已保存：\(url.lastPathComponent)"
                    } else {
                        ui.toast = session.errorMessage ?? "截图失败"
                    }
                }
            } label: {
                Label("截图", systemImage: "camera")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!session.isRunning)

            Button {
                toggleMini()
            } label: {
                Label("Mini", systemImage: "rectangle.compress.vertical")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("只显示投屏画面；控制条可调透明度并可拖动")

            Button {
                toggleFullscreen()
            } label: {
                Label(ui.fullscreen ? "退出全屏" : "全屏",
                      systemImage: ui.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(SecondaryButtonStyle())

            if session.isRunning {
                Button {
                    session.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.danger)
            } else {
                Button {
                    Task { await session.start() }
                } label: {
                    Label("开始投屏", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(session.isStarting)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("输入中文 / emoji，回车粘贴到手机当前输入框", text: $ui.textInput)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit { sendInputText() }
                .disabled(!session.isRunning)
            Button("发送") { sendInputText() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!session.isRunning || ui.textInput.trimmed.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private func sendInputText() {
        let value = ui.textInput.trimmed
        guard !value.isEmpty else { return }
        session.sendUnicodeText(value)
        ui.textInput = ""
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            controlButton("chevron.backward", "返回", width: 60) { session.sendKey(4) }
            controlButton("house", "主页", width: 60) { session.sendKey(3) }
            controlButton("square.on.square", "多任务", width: 60) { session.sendKey(187) }
            Divider().frame(height: 18)
            controlOrientationButton()
            controlButton(
                session.displayPoweredOff ? "sun.max" : "display",
                session.displayPoweredOff ? "恢复手机屏幕" : (session.screenOff ? "物理关闭手机屏幕" : "关闭手机屏幕")
            ) {
                session.toggleScreen()
            }
            Divider().frame(height: 18)
            controlButton("speaker.slash.fill", "静音") { session.sendKey(164) }
            controlButton("speaker.wave.1", "音量 -") { session.sendKey(25) }
            controlButton("speaker.wave.3", "音量 +") { session.sendKey(24) }
            controlButton("power", "电源键") { session.sendKey(26) }
            Divider().frame(height: 18)
            controlButton("camera", "截图") {
                Task { _ = await session.screenshot() }
            }

            Spacer()

            Text("\(session.frameCount) 帧")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .disabled(!session.isRunning)
        .opacity(session.isRunning ? 1 : 0.5)
    }

    @ViewBuilder
    private var footer: some View {
        if let toast = ui.toast {
            HStack(spacing: 8) {
                Text(toast)
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
    }

    private var orientationHelp: String {
        let target = session.orientationLandscape ? "竖屏" : "横屏"
        return "切换手机为\(target)（应用自身可能锁定方向）"
    }

    private func controlOrientationButton() -> some View {
        Button(action: toggleOrientation) {
            OrientationGlyph(landscape: session.orientationLandscape, tint: .primary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .help(orientationHelp)
    }

    private func fullscreenOrientationButton() -> some View {
        Button(action: toggleOrientation) {
            OrientationGlyph(landscape: session.orientationLandscape, tint: .white.opacity(0.9))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.09))
        )
        .help(orientationHelp)
    }

    private func toggleOrientation() {
        Task { await session.setOrientation(landscape: !session.orientationLandscape) }
    }

    private func controlButton(_ icon: String, _ help: String, width: CGFloat = 30, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: width, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .help(help)
    }
}


struct OrientationGlyph: View {
    let landscape: Bool
    var tint: Color = .primary

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(tint, lineWidth: 1.5)
                .frame(width: landscape ? 18 : 11, height: landscape ? 11 : 18)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 6.5, weight: .bold))
                .foregroundStyle(tint)
                .offset(x: landscape ? 10 : 0, y: landscape ? 0 : 10)
        }
        .frame(width: 24, height: 24)
    }
}

struct AudioLevelBar: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(index < Int(level * 8) ? Theme.accent : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: 8)
            }
        }
        .help("音频电平")
    }
}

@MainActor
final class MirrorUIState: ObservableObject {
    @Published var toast: String?
    @Published var fullscreen = false
    @Published var mini = false
    @Published var savedWindowFrame: NSRect?
    @Published var textInput = ""
    @Published var miniBarOffset: CGSize = .zero
    @Published var miniBarDragStart: CGSize = .zero
    @Published var miniBarDragging = false
    @Published var miniBarLastDragTime: Date?
}
