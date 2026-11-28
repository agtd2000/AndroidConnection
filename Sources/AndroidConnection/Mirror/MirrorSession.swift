import Foundation
import AppKit
import CoreVideo

@MainActor
final class MirrorSession: ObservableObject {
    let serial: String
    private var isWireless: Bool { serial.contains(":") }
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var status = "未开始投屏"
    @Published var errorMessage: String?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var resolutionLabel = "—"
    @Published private(set) var sourceSize: CGSize = .zero
    @Published private(set) var frameCount = 0
    @Published private(set) var audioEnabled = false
    @Published private(set) var audioStatus = "音频未启用"
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var screenOff = false
    @Published private(set) var displayPoweredOff = false
    @Published private(set) var orientationLandscape = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var orientationNotice: String?

    private let adb = ADB.shared
    private let settings: SettingsStore
    private let control: ScrcpyControl?
    private weak var view: MirrorPlayerView?
    private var video: ScrcpyVideo?
    private var decoder: H264StreamDecoder?
    private var logicalSize: CGSize = .zero
    private var restartTask: Task<Void, Never>?
    private var retryCount = 0
    private var intentionallyStopped = false
    private var lastSizeRefresh = Date.distantPast
    private var audioForwarder: AudioForwarder?
    private var audioRestartTask: Task<Void, Never>?
    private var audioRetryCount = 0
    private var originalRotation: (userRotation: String, fixedRotation: String)?
    private var originalAccelerometerRotation: String?
    private var originalUserRotationSetting: String?
    private var orientationNoticeToken = UUID()
    private var screenHoldUntil: Date?
    private var orientationMonitorTask: Task<Void, Never>?
    /// True only while this app has temporarily locked `wm user-rotation`.
    /// The phone's own auto-rotate/sensor state always wins: enabling
    /// auto-rotate or changing the phone rotation releases this override.
    private var softwareRotationActive = false
    private var softwareRotationTarget: String?
    private var lastRotationPolicyCheck = Date.distantPast
    private var rotationReleaseTask: Task<Void, Never>?
    /// Set when this mirror session changed the panel direction, either via
    /// the rotate button or a physical rotation. Kept for logging/diagnostics.
    private var didChangeOrientation = false
    private var savedBrightness: String?
    private var savedBrightnessMode: String?
    private var savedStayOn: String?
    private var savedScreenOffTimeout: String?
    private var usbStayOnActive = false
    private var usbKeepAliveTask: Task<Void, Never>?
    private var streamID = UUID()
    private var isStartingVideo = false
    private var screenOffMode: ScreenOffMode = .none

    private enum ScreenOffMode {
        case none
        case displayPower
        case dimmed
    }

    /// Called when a running mirror is explicitly stopped (button or menu).
    /// The view uses this to leave the mirror page instead of leaving the
    /// last decoded frame on screen.
    var onStopped: (() -> Void)?

    init(serial: String, settings: SettingsStore, control: ScrcpyControl? = nil) {
        self.serial = serial
        self.settings = settings
        self.control = control
    }

    deinit {
        restartTask?.cancel()
        orientationMonitorTask?.cancel()
        rotationReleaseTask?.cancel()
    }

    func attach(_ view: MirrorPlayerView) {
        guard self.view !== view else { return }
        self.view = view
        view.onTap = { [weak self] point in self?.tap(point) }
        view.onSwipe = { [weak self] from, to in self?.swipe(from: from, to: to) }
        view.onKeyDown = { [weak self] event in self?.handleKey(event) }
        view.onScroll = { [weak self] direction in
            guard let self else { return }
            self.scroll(direction * self.settings.scrollDirection.multiplier)
        }
        view.onRightClick = { [weak self] in self?.handleMouseButton(.right) }
        view.onMiddleClick = { [weak self] in self?.handleMouseButton(.middle) }
        view.window?.makeFirstResponder(view)
    }

    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        intentionallyStopped = false
        errorMessage = nil
        status = "正在启动投屏…"

        // Clear a direction override left by an older build or an abnormal
        // exit before this session starts. Temporary overrides are only
        // enabled later for the short rotate/portrait transitions.
        _ = try? await adb.shell("wm fixed-to-user-rotation disabled", serial: serial, timeout: 8)

        // Start the video channel first. The separate scrcpy audio server
        // needs its own forwarded port; starting both at once can race the
        // ephemeral port reservation and leave the audio socket unconnected.
        if settings.audioForwarding {
            audioStatus = "画面连接后启动音频…"
        } else {
            audioStatus = "音频已关闭"
        }

        // The display-power command is sent over the independent control
        // server. Make sure it is up before the mirror starts so automatic
        // screen-off can use the real panel-off path on the first try.
        if settings.autoScreenOff, let control, !control.isRunning {
            await control.start()
        }

        do {
            try await startVideo()
        } catch {
            isStarting = false
            isRunning = false
            status = "启动失败"
            errorMessage = error.localizedDescription
            stopAudio()
            return
        }

        if settings.audioForwarding {
            startAudio()
        }
    }

    private func startVideo() async throws {
        // Settings/rotation changes can request a restart while a previous
        // start is still waiting for its dummy byte. Never let two scrcpy
        // video servers race on the same session: the second one leaks its
        // forwarded port and feeds a dead socket.
        guard !isStartingVideo else { return }
        isStartingVideo = true
        defer { isStartingVideo = false }
        // Capture the phone's real orientation controls on the first start,
        // not only when the rotate button is pressed. A physical rotation
        // used to leave originalRotation nil, so stop() had nothing to restore.
        await captureRotationIfNeeded()
        let display = try await currentDisplaySize()
        logicalSize = display
        sourceSize = display
        orientationLandscape = display.width > display.height
        let target = Self.targetSize(for: display, quality: settings.quality)
        resolutionLabel = "\(Int(target.width))×\(Int(target.height))"

        let bitrate = max(1, settings.bitrateMbps) * 1_000_000
        let decoder = H264StreamDecoder()
        decoder.onFrame = { [weak self] buffer, size in
            DispatchQueue.main.async {
                guard let self else { return }
                self.frameCount += 1
                if self.videoSize != size {
                    let previousSize = self.videoSize
                    let changedOrientation = previousSize.width > 0
                        && (previousSize.width > previousSize.height) != (size.width > size.height)
                    if changedOrientation { self.didChangeOrientation = true }
                    AppLog.write("video frame size=\(Int(size.width))x\(Int(size.height)) orientation=\(size.width > size.height ? "landscape" : "portrait")")
                    self.videoSize = size
                    self.resolutionLabel = "\(Int(size.width))×\(Int(size.height))"
                    self.orientationLandscape = size.width > size.height
                    Task { await self.refreshLogicalSizeIfNeeded() }
                    if changedOrientation, !self.isStarting, !self.isTransitioning {
                        self.notifyIfForegroundAppIsLocked(landscape: size.width > size.height)
                    }
                }
                self.view?.display(buffer, size: size)
            }
        }
        decoder.onError = { [weak self] message in
            DispatchQueue.main.async { self?.errorMessage = message }
        }
        self.decoder = decoder

        let streamID = UUID()
        self.streamID = streamID
        let video = ScrcpyVideo(serial: serial)
        video.onData = { data in decoder.append(data) }
        video.onStatus = { text in
            AppLog.write("video status=\(text)")
        }
        video.onExit = { [weak self] code in
            DispatchQueue.main.async { self?.handleStreamExit(code, id: streamID) }
        }
        let maxSize = settings.quality == .native ? nil : Int(max(target.width, target.height))
        do {
            try await video.start(maxSize: maxSize, bitrate: bitrate)
        } catch {
            video.stop()
            throw error
        }
        self.video = video

        isRunning = true
        isStarting = false
        status = "投屏中"
        AppLog.write("mirror start serial=\(serial) target=\(Int(target.width))x\(Int(target.height)) bitrate=\(bitrate) native=\(settings.quality == .native)")
        startOrientationMonitor()
        retryCount = 0
        if settings.autoScreenOff, !screenOff {
            Task { [weak self] in
                // Start the three-second timer at the actual mirror-success
                // point. The USB setup below can take another second or two,
                // so scheduling this after that setup made the visible delay
                // longer than requested. Then check the phone's actual panel
                // state and apply the screen-off command exactly once. If it
                // was already off, force one refresh so app state and panel
                // agree without waking it first.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isRunning, !self.intentionallyStopped else { return }
                // A manual rotation wakes the panel so the user can see the
                // result. Keep it on for a few seconds instead of immediately
                // turning it back off, otherwise the rotation looks like a
                // mirror-only change.
                if let holdUntil = self.screenHoldUntil {
                    let remaining = holdUntil.timeIntervalSinceNow
                    self.screenHoldUntil = nil
                    if remaining > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                    guard self.isRunning, !self.intentionallyStopped else { return }
                }
                let wasOff = await self.phoneScreenIsOff()
                AppLog.write("mirror auto-screen check detected=\(wasOff ? "off" : "on")")
                await self.setScreenOff(true, allowDisplayPower: true, force: wasOff)
            }
        }
        if !isWireless {
            // Xiaomi drops the ADB USB transport when the panel sleeps. Keep
            // the display awake for the whole USB mirror session, even when
            // the user disabled the automatic dimming option.
            if savedStayOn == nil {
                savedStayOn = await settingValue("stay_on_while_plugged_in", namespace: "global")
            }
            if savedScreenOffTimeout == nil {
                savedScreenOffTimeout = await settingValue("screen_off_timeout", namespace: "system")
            }
            usbStayOnActive = true
            _ = try? await adb.shell("svc power stayon usb", serial: serial, timeout: 8)
            // `svc power stayon usb` is not enough on some Xiaomi builds: the
            // panel still sleeps after the normal timeout and the USB ADB
            // transport disappears with it. Extend the timeout while the
            // mirror owns the USB connection, then restore it on stop.
            _ = try? await adb.shell("settings put system screen_off_timeout 2147483647", serial: serial, timeout: 8)
            // Do not wake the panel when automatic screen-off is enabled.
            // The delayed check below has to observe the real starting state
            // instead of the wake-up injected by the USB keepalive path.
            if !settings.autoScreenOff, !screenOff {
                _ = try? await adb.shell("input keyevent 224", serial: serial, timeout: 8)
            }
            control?.keepsUSBWake = true
            startUSBKeepAlive()
        } else if !settings.autoScreenOff {
            _ = try? await adb.shell("svc power stayon usb", serial: serial, timeout: 8)
            _ = try? await adb.shell("input keyevent 224", serial: serial, timeout: 8)
        }
    }

    /// Restart only the video pipeline. Audio stays attached while changing
    /// quality/bitrate or rotating, so there is no speaker/forwarding gap.
    func restartVideoOnly() async {
        guard isRunning, !isStarting, !isTransitioning else { return }
        isStarting = true
        isTransitioning = true
        defer { isTransitioning = false }
        status = "正在重启画面…"
        // Keep the last frame visible while the new server starts. Clearing it
        // here caused the "手机屏幕将在这里显示" placeholder to flash during
        // every quality/orientation change.
        stopVideo(clearView: false)
        do {
            try await startVideo()
        } catch {
            isStarting = false
            isRunning = false
            view?.clear()
            status = "启动失败"
            errorMessage = error.localizedDescription
        }
    }

    private func stopVideo(clearView: Bool = true) {
        streamID = UUID()
        orientationMonitorTask?.cancel()
        orientationMonitorTask = nil
        video?.stop()
        video = nil
        decoder?.reset()
        decoder = nil
        if clearView { view?.clear() }
        isRunning = false
        frameCount = 0
    }

    func stop(restoreRotation: Bool = true) {
        let wasRunning = isRunning || isStarting
        intentionallyStopped = true
        stopAudio()
        restartTask?.cancel()
        restartTask = nil
        if restoreRotation {
            rotationReleaseTask?.cancel()
            rotationReleaseTask = nil
        }
        usbKeepAliveTask?.cancel()
        usbKeepAliveTask = nil
        control?.keepsUSBWake = false
        let wasScreenOff = screenOff
        let mode = screenOffMode
        if wasScreenOff, mode == .displayPower {
            _ = video?.setDisplayPowerMode(off: false)
            _ = control?.setDisplayPowerMode(off: false)
            adbShellSync("input keyevent 224")
        }
        stopVideo()
        isStarting = false
        isTransitioning = false
        clearOrientationNotice()
        if wasScreenOff {
            // Always restore the settings we may have changed (brightness,
            // stay-awake, timeout). With display-power mode those are mostly
            // no-ops, but it also restores stay_on/screen_off_timeout.
            restoreScreenBrightnessSync()
            screenOff = false
            displayPoweredOff = false
            screenOffMode = .none
        } else if usbStayOnActive {
            restoreScreenBrightnessSync()
        }
        usbStayOnActive = false
        if restoreRotation {
            restoreRotationIfNeeded()
        }
        // Do not leave the last landscape frame size/label behind after the
        // phone has been released back to its own rotation policy.
        videoSize = .zero
        sourceSize = .zero
        logicalSize = .zero
        resolutionLabel = "—"
        status = "已停止投屏"
        if restoreRotation {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self, !self.isRunning, !self.isStarting else { return }
                if let size = await self.currentRotationSize(), size.width > 0, size.height > 0 {
                    self.sourceSize = size
                    self.orientationLandscape = size.width > size.height
                    AppLog.write("stop display size=\(Int(size.width))x\(Int(size.height)) landscape=\(size.width > size.height)")
                }
            }
        }
        if wasRunning, restoreRotation {
            onStopped?()
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        if enabled {
            audioRetryCount = 0
            startAudio()
        } else {
            stopAudio()
        }
    }

    private func startAudio() {
        guard !intentionallyStopped, audioForwarder == nil else { return }
        let forwarder = AudioForwarder(serial: serial)
        forwarder.onStatus = { [weak self, weak forwarder] text in
            guard let self else { return }
            self.audioStatus = text
            if text.hasPrefix("音频已开启") {
                self.audioEnabled = true
                self.audioRetryCount = 0
            } else if text.hasPrefix("音频不可用") || text.contains("已断开") {
                self.audioEnabled = false
                self.audioLevel = 0
                if let forwarder, self.audioForwarder === forwarder {
                    self.audioForwarder = nil
                    self.scheduleAudioRestart()
                }
            }
            AppLog.write("audio status=\(text)")
        }
        forwarder.onLevel = { [weak self] level in
            self?.audioLevel = level
        }
        audioForwarder = forwarder
        Task { await forwarder.start() }
    }

    private func scheduleAudioRestart() {
        guard settings.audioForwarding, !intentionallyStopped, audioForwarder == nil else { return }
        guard audioRetryCount < 4 else {
            audioStatus = "音频多次中断，请关闭后重新开启音频"
            return
        }
        audioRetryCount += 1
        audioStatus = "音频中断，正在恢复（\(audioRetryCount)/4）…"
        audioRestartTask?.cancel()
        audioRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, !self.intentionallyStopped, self.audioForwarder == nil else { return }
            self.startAudio()
        }
    }

    private func stopAudio() {
        audioRestartTask?.cancel()
        audioRestartTask = nil
        audioRetryCount = 0
        audioForwarder?.stop()
        audioForwarder = nil
        audioEnabled = false
        audioLevel = 0
        audioStatus = "音频已关闭"
    }

    func restart() async {
        stop(restoreRotation: false)
        try? await Task.sleep(nanoseconds: 350_000_000)
        intentionallyStopped = false
        await start()
    }

    private func handleStreamExit(_ code: Int32, id: UUID) {
        guard id == streamID, !intentionallyStopped else { return }
        let errorText = ""
        video = nil
        streamID = UUID()
        decoder?.reset()
        decoder = nil
        isRunning = false
        isStarting = false

        guard retryCount < 5 else {
            status = "投屏中断"
            errorMessage = errorText.isEmpty
                ? (isWireless
                    ? "录屏进程反复退出，请重新连接设备。"
                    : "USB 连接不稳定：请优先把数据线直连 Mac（避开 Hub/扩展坞），解锁手机并保持亮屏后重试。")
                : errorText
            stopAudio()
            return
        }
        retryCount += 1
        AppLog.write("mirror stream exit code=\(code) retry=\(retryCount) stderr=\(errorText.prefix(200))")
        status = "正在恢复投屏（\(retryCount)/5）…"
        if !errorText.isEmpty { errorMessage = errorText }

        if !isWireless {
            // The stream usually dies because the Xiaomi panel slept and took
            // the USB ADB transport with it. Re-assert the awake state before
            // reconnecting instead of immediately showing a raw adb error.
            Task { [weak self] in
                guard let self else { return }
                let devices = try? await self.adb.run(["devices"], timeout: 5)
                if devices?.output.contains(self.serial) != true {
                    AppLog.write("mirror retry: adb device missing, restarting server")
                    try? await self.adb.restartServer()
                }
                _ = try? await self.adb.shell("svc power stayon usb", serial: self.serial, timeout: 5)
                _ = try? await self.adb.shell("settings put system screen_off_timeout 2147483647", serial: self.serial, timeout: 5)
                _ = try? await self.adb.shell("input keyevent 224", serial: self.serial, timeout: 5)
            }
        }

        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !self.intentionallyStopped else { return }
            await self.start()
        }
    }

    func setOrientation(landscape: Bool) async {
        guard isRunning, !isStarting, !isTransitioning else { return }
        if orientationLandscape == landscape { return }

        // A button press is a short-lived request. It never becomes a
        // permanent phone setting: the release task or a phone-side rotation
        // change hands control back to the sensor.
        didChangeOrientation = true
        await captureRotationIfNeeded()

        // Manual rotation is a request to see the phone change direction. If
        // the mirror's automatic screen-off has powered the panel down, the
        // display would rotate while the phone stayed black, which looks like
        // only the video resolution changed. Wake it and hold it on briefly.
        var panelWasOff = screenOff || displayPoweredOff
        if !panelWasOff {
            panelWasOff = await phoneScreenIsOff()
        }
        if panelWasOff {
            if screenOff || displayPoweredOff {
                await setScreenOff(false, force: true)
            } else {
                _ = try? await adb.shell("input keyevent 224", serial: serial, timeout: 8)
            }
            AppLog.write("rotation panel wake requested")
        }
        screenHoldUntil = Date().addingTimeInterval(8)

        // Keep the last frame and the starting state across the restart. The
        // old path cleared the view and reset isStarting inside stopVideo(),
        // which made the "手机屏幕将在这里显示" placeholder flash and sometimes
        // left the user needing to press Start again.
        isStarting = true
        isTransitioning = true
        defer { isTransitioning = false }
        errorMessage = nil
        clearOrientationNotice()
        status = landscape ? "正在切换到横屏…" : "正在切换到竖屏…"
        stopVideo(clearView: false)

        // `wm user-rotation` works on Android 13+ where writing the legacy
        // Settings.System values no longer changes the display rotation. Keep
        // both paths: the legacy values are still read by some OEM builds and
        // by apps that reset the window-manager lock. Apply them before the
        // `wm` lock so the final state is the explicit user rotation.
        var applied = await applyRotation(landscape: landscape)
        var confirmed = await waitForDisplayOrientation(landscape: landscape)
        if !applied || !confirmed {
            AppLog.write("rotation retry landscape=\(landscape) applied=\(applied) confirmed=\(confirmed)")
            try? await Task.sleep(nanoseconds: 450_000_000)
            applied = await applyRotation(landscape: landscape)
            confirmed = await waitForDisplayOrientation(landscape: landscape)
        }
        AppLog.write("rotation landscape=\(landscape) applied=\(applied) confirmed=\(confirmed)")
        let rotatedSize = await displaySizeDescription()
        AppLog.write("rotation display size=\(rotatedSize)")

        do {
            try await startVideo()
            await presentRotationResult(landscape: landscape, confirmed: confirmed)
        } catch {
            // Rotation can race the USB transport on Xiaomi. Try once more
            // after the server has fully released the old port.
            try? await Task.sleep(nanoseconds: 700_000_000)
            do {
                try await startVideo()
                await presentRotationResult(landscape: landscape, confirmed: confirmed)
            } catch {
                isStarting = false
                isRunning = false
                view?.clear()
                status = "旋转失败"
                errorMessage = error.localizedDescription
                // A failed video restart must not leave the phone locked in
                // the requested direction; restore portrait and release wm.
                restoreRotationIfNeeded()
            }
        }
    }

    private struct PhoneRotationState {
        let autoRotation: String?
        let userRotation: String?
        let fixedRotation: String?
    }

    /// Read the phone's current rotation policy in one shell round-trip.
    private func phoneRotationState() async -> PhoneRotationState? {
        let command = "settings get system accelerometer_rotation; wm user-rotation; wm fixed-to-user-rotation"
        guard let result = try? await adb.shell(command, serial: serial, timeout: 8),
              result.succeeded else { return nil }
        let lines = result.output
            .components(separatedBy: .newlines)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        guard lines.count >= 3 else { return nil }
        return PhoneRotationState(autoRotation: lines[0], userRotation: lines[1], fixedRotation: lines[2])
    }

    /// Hand control back to the phone. A temporary button rotation restores
    /// the captured phone policy; a phone-initiated change adopts the phone's
    /// new choice so stop() does not undo it.
    private func releaseSoftwareRotationToPhone(adoptPhonePolicy: Bool = true) async {
        guard softwareRotationActive else { return }
        rotationReleaseTask?.cancel()
        rotationReleaseTask = nil
        softwareRotationActive = false
        softwareRotationTarget = nil

        if !adoptPhonePolicy {
            await restoreCapturedRotationPolicy()
            AppLog.write("rotation temporary lock released to captured phone policy")
            showOrientationNotice("临时旋转结束，已交还手机方向控制", seconds: 4)
            return
        }

        guard let state = await phoneRotationState() else {
            _ = try? await adb.shell("wm user-rotation free", serial: serial, timeout: 8)
            return
        }
        if state.fixedRotation == "enabled" {
            _ = try? await adb.shell("wm fixed-to-user-rotation disabled", serial: serial, timeout: 8)
        }

        if state.autoRotation == "1" {
            _ = try? await adb.shell("wm user-rotation free", serial: serial, timeout: 8)
            originalRotation = (userRotation: "free", fixedRotation: "disabled")
            originalAccelerometerRotation = "1"
            originalUserRotationSetting = nil
        } else if let user = state.userRotation, user.hasPrefix("lock") {
            originalRotation = (userRotation: user, fixedRotation: "disabled")
            originalAccelerometerRotation = "0"
            originalUserRotationSetting = user.split(separator: " ").last.map(String.init)
        } else {
            originalRotation = (userRotation: state.userRotation ?? "free", fixedRotation: "disabled")
            originalAccelerometerRotation = state.autoRotation ?? originalAccelerometerRotation
        }
        AppLog.write("rotation released to phone auto=\(state.autoRotation ?? "nil") user=\(state.userRotation ?? "nil") fixed=\(state.fixedRotation ?? "nil")")
        showOrientationNotice("已交还手机方向控制", seconds: 4)
    }

    private func scheduleTemporaryRotationRelease() {
        rotationReleaseTask?.cancel()
        rotationReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.softwareRotationActive else { return }
            AppLog.write("rotation temporary lock expired")
            await self.releaseSoftwareRotationToPhone(adoptPhonePolicy: false)
        }
    }

    private func restoreCapturedRotationPolicy() async {
        let original = originalRotation
        _ = try? await adb.shell("wm fixed-to-user-rotation disabled", serial: serial, timeout: 8)
        if originalAccelerometerRotation == "1" || original?.userRotation == "free" || original?.userRotation == nil {
            _ = try? await adb.shell("wm user-rotation free", serial: serial, timeout: 8)
        } else if let user = original?.userRotation, user.hasPrefix("lock") {
            _ = try? await adb.shell("wm user-rotation \(user)", serial: serial, timeout: 8)
        } else {
            _ = try? await adb.shell("wm user-rotation free", serial: serial, timeout: 8)
        }
        if let userSetting = originalUserRotationSetting {
            _ = try? await adb.shell("settings put system user_rotation \(userSetting)", serial: serial, timeout: 8)
        }
        if let accelerometer = originalAccelerometerRotation {
            _ = try? await adb.shell("settings put system accelerometer_rotation \(accelerometer)", serial: serial, timeout: 8)
        }
        AppLog.write("rotation policy restored fixed=disabled user=\(original?.userRotation ?? "free") accel=\(originalAccelerometerRotation ?? "nil") setting=\(originalUserRotationSetting ?? "nil")")
    }

    /// While a software lock is active, watch for the phone taking control:
    /// auto-rotate switched on, the user-rotation lock changed, or the fixed
    /// rotation flag set elsewhere. The app must never fight the phone.
    private func checkPhoneRotationOverride() async {
        guard softwareRotationActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRotationPolicyCheck) > 2.5 else { return }
        lastRotationPolicyCheck = now
        guard let state = await phoneRotationState() else { return }

        let changedByPhone = state.autoRotation == "1"
            || (softwareRotationTarget.map { state.userRotation != "lock \($0)" } ?? false)
        guard changedByPhone else { return }

        AppLog.write("rotation phone override auto=\(state.autoRotation ?? "nil") user=\(state.userRotation ?? "nil") fixed=\(state.fixedRotation ?? "nil")")
        await releaseSoftwareRotationToPhone()
    }

    /// Ask the phone for a temporary direction. The short release task and
    /// the phone-state monitor make this a request, not a persistent lock.
    /// Xiaomi needs `fixed-to-user-rotation` for the few seconds of the
    /// transition; it is always disabled on release/stop so third-party
    /// fullscreen/requestedOrientation is not permanently blocked.
    private func applyRotation(landscape: Bool) async -> Bool {
        let target = landscape ? "1" : "0"
        let commands = [
            "settings put system accelerometer_rotation 0",
            "settings put system user_rotation \(target)",
            "wm fixed-to-user-rotation enabled",
            "wm user-rotation lock \(target)"
        ]
        var succeeded = true
        for command in commands {
            do {
                let result = try await adb.shell(command, serial: serial, timeout: 8)
                AppLog.write("rotation cmd=\(command) ok=\(result.succeeded) out=\(result.output.trimmed)")
                if !result.succeeded { succeeded = false }
            } catch {
                AppLog.write("rotation cmd=\(command) error=\(error.localizedDescription)")
                succeeded = false
            }
        }
        if succeeded {
            softwareRotationActive = true
            softwareRotationTarget = target
            lastRotationPolicyCheck = Date()
            scheduleTemporaryRotationRelease()
        }
        return succeeded
    }

    private func waitForDisplayOrientation(landscape: Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = await currentRotationSize(), (size.width > size.height) == landscape {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func presentRotationResult(landscape: Bool, confirmed: Bool) async {
        guard orientationLandscape == landscape, confirmed else {
            let label = landscape ? "横屏" : "竖屏"
            showOrientationNotice("手机系统未切换为\(label)，请确认手机已解锁且未锁定方向。", seconds: 8)
            return
        }
        var text = "手机已临时切换为\(landscape ? "横屏" : "竖屏")；手机可随时接管方向"
        if let locked = await foregroundAppFixedOrientation() {
            let lockedLabel = locked == "portrait" ? "竖屏" : "横屏"
            let lockedLandscape = locked == "landscape"
            if lockedLandscape != landscape {
                text += "；当前应用固定\(lockedLabel)，画面会居中显示"
            }
        }
        AppLog.write("rotation notice=\(text)")
        showOrientationNotice(text, seconds: 7)
    }

    /// Follow rotations initiated on the phone itself (sensor, another app,
    /// or a rotation shortcut), not just the mirror's rotate button. scrcpy
    /// normally sends a new video size immediately; if the stream stalls on
    /// the old orientation, restart only the video channel once.
    private func startOrientationMonitor() {
        orientationMonitorTask?.cancel()
        orientationMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.isRunning, !self.isStarting, !self.isTransitioning else { continue }
                await self.checkPhoneRotationOverride()
                guard let size = await self.currentRotationSize() else { continue }
                let landscape = size.width > size.height
                guard landscape != self.orientationLandscape else { continue }

                let previous = self.orientationLandscape
                self.didChangeOrientation = true
                self.orientationLandscape = landscape
                self.sourceSize = size
                self.logicalSize = size
                AppLog.write("orientation sync detected previous=\(previous ? "landscape" : "portrait") current=\(landscape ? "landscape" : "portrait") size=\(Int(size.width))x\(Int(size.height))")

                // Give scrcpy's new SPS/frame time to arrive before forcing a
                // restart. This covers panels/ROMs that stop emitting frames
                // while the display is off during a physical rotation.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, self.isRunning, !self.isStarting, !self.isTransitioning else { continue }
                guard let latest = await self.currentRotationSize(),
                      (latest.width > latest.height) == landscape else { continue }
                let frameLandscape = self.videoSize.width > self.videoSize.height
                if self.videoSize.width < 1 || frameLandscape != landscape {
                    AppLog.write("orientation sync restart video frame=\(Int(self.videoSize.width))x\(Int(self.videoSize.height))")
                    await self.restartVideoOnly()
                    continue
                }

                if let locked = await self.foregroundAppFixedOrientation() {
                    let lockedLandscape = locked == "landscape"
                    if lockedLandscape != landscape {
                        let label = landscape ? "横屏" : "竖屏"
                        let lockedLabel = locked == "portrait" ? "竖屏" : "横屏"
                        let text = "手机已切换为\(label)；当前应用固定\(lockedLabel)，画面会居中显示"
                        AppLog.write("orientation sync notice=\(text)")
                        self.showOrientationNotice(text, seconds: 5)
                    }
                }
            }
        }
    }

    private func foregroundAppFixedOrientation() async -> String? {
        // The first requestedOrientation belongs to the top resumed activity.
        // Some apps hard-lock portrait; Android intentionally letterboxes them
        // when the display itself is rotated. Report that instead of pretending
        // the app content rotated too.
        guard let result = try? await adb.shell(
            "dumpsys activity activities | grep -m1 'requestedOrientation='",
            serial: serial,
            timeout: 6
        ), result.succeeded else { return nil }
        let text = result.output.uppercased()
        if text.contains("SCREEN_ORIENTATION_PORTRAIT") { return "portrait" }
        if text.contains("SCREEN_ORIENTATION_LANDSCAPE") { return "landscape" }
        return nil
    }

    private func notifyIfForegroundAppIsLocked(landscape: Bool) {
        Task { [weak self] in
            guard let self else { return }
            guard let locked = await self.foregroundAppFixedOrientation() else { return }
            let lockedLandscape = locked == "landscape"
            guard lockedLandscape != landscape else { return }
            let label = landscape ? "横屏" : "竖屏"
            let lockedLabel = locked == "portrait" ? "竖屏" : "横屏"
            let text = "手机已切换为\(label)；当前应用固定\(lockedLabel)，画面会居中显示"
            AppLog.write("orientation sync notice=\(text)")
            self.showOrientationNotice(text, seconds: 5)
        }
    }

    private func showOrientationNotice(_ text: String, seconds: TimeInterval = 6) {
        orientationNotice = text
        let token = UUID()
        orientationNoticeToken = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.orientationNoticeToken == token else { return }
            self.orientationNotice = nil
        }
    }

    private func clearOrientationNotice() {
        orientationNoticeToken = UUID()
        orientationNotice = nil
    }

    private func displaySizeDescription() async -> String {
        guard let size = await currentRotationSize() else { return "unknown" }
        return "\(Int(size.width))x\(Int(size.height))"
    }

    /// Query the real panel state rather than relying on app-side flags.
    private func phoneScreenIsOff() async -> Bool {
        let command = "dumpsys power | grep -m1 'mWakefulness='; dumpsys display | grep -m1 'mScreenState='"
        guard let result = try? await adb.shell(command, serial: serial, timeout: 10) else {
            return false
        }
        let text = result.output.lowercased()
        return text.contains("mscreenstate=off")
            || text.contains("mwakefulness=asleep")
            || text.contains("mwakefulness=dozing")
    }

    /// Turn the phone panel off without stopping video capture or touch.
    ///
    /// scrcpy control message 10 calls SurfaceControl.setDisplayPowerMode(0).
    /// Unlike KEYCODE_SLEEP, it powers down the physical panel while keeping
    /// SurfaceFlinger composing, so H.264 frames and input injection continue.
    /// If the control channel is unavailable, fall back to brightness 0.
    func setScreenOff(_ off: Bool, allowDisplayPower: Bool = true, force: Bool = false) async {
        guard force || off != screenOff else { return }
        if off {
            // Preferred: the video server's own control channel, which owns
            // the captured display. A separate control-only server may accept
            // the message without affecting the physical panel.
            if allowDisplayPower, let video, video.setDisplayPowerMode(off: true) {
                screenOff = true
                displayPoweredOff = true
                screenOffMode = .displayPower
                AppLog.write("mirror screenOff=true via=video-display usb=\(!isWireless)")
                return
            }
            if allowDisplayPower, let control, control.isRunning, control.setDisplayPowerMode(off: true) {
                screenOff = true
                displayPoweredOff = true
                screenOffMode = .displayPower
                AppLog.write("mirror screenOff=true via=control-display usb=\(!isWireless)")
                return
            }

            if savedBrightness == nil {
                savedBrightness = await settingValue("screen_brightness", namespace: "system")
            }
            if savedBrightnessMode == nil {
                savedBrightnessMode = await settingValue("screen_brightness_mode", namespace: "system")
            }
            if savedStayOn == nil {
                savedStayOn = await settingValue("stay_on_while_plugged_in", namespace: "global")
            }

            let usb = !isWireless
            _ = try? await adb.shell("svc power stayon \(usb ? "usb" : "true")", serial: serial, timeout: 8)
            _ = try? await adb.shell("settings put system screen_brightness_mode 0", serial: serial, timeout: 8)
            // Some Xiaomi builds clamp 0 to 1; the control-channel path above
            // is preferred. This is only the compatibility fallback.
            let result = try? await adb.shell("settings put system screen_brightness 0", serial: serial, timeout: 8)
            _ = try? await adb.shell("settings put system screen_brightness_float 0.0", serial: serial, timeout: 8)
            if result?.succeeded == true {
                screenOff = true
                displayPoweredOff = false
                screenOffMode = .dimmed
                AppLog.write("mirror screenOff=true via=brightness0 fallback usb=\(usb) saved=\(savedBrightness ?? "nil") mode=\(savedBrightnessMode ?? "nil") stay=\(savedStayOn ?? "nil")")
            } else {
                errorMessage = result?.messages.trimmed ?? "无法关闭手机屏幕"
                await restoreScreenBrightness()
            }
        } else {
            let mode = screenOffMode
            if mode == .displayPower {
                _ = video?.setDisplayPowerMode(off: false)
                _ = control?.setDisplayPowerMode(off: false)
                _ = try? await adb.shell("input keyevent 224", serial: serial, timeout: 8)
            }
            // The display-power path may have been entered after the automatic
            // brightness-0 path, so restore both brightness and stay-awake.
            await restoreScreenBrightness()
            if mode != .displayPower {
                _ = try? await adb.shell("input keyevent 224", serial: serial, timeout: 8)
            }
            screenOff = false
            displayPoweredOff = false
            screenOffMode = .none
            AppLog.write("mirror screenOff=false restored mode=\(mode)")
        }
    }

    private func settingValue(_ key: String, namespace: String) async -> String? {
        guard let result = try? await adb.shell("settings get \(namespace) \(key)", serial: serial, timeout: 8),
              result.succeeded else { return nil }
        let value = result.output.trimmed
        return value.isEmpty || value == "null" ? nil : value
    }

    private func restoreScreenBrightness() async {
        if let mode = savedBrightnessMode {
            _ = try? await adb.shell("settings put system screen_brightness_mode \(mode)", serial: serial, timeout: 8)
        }
        if let brightness = savedBrightness {
            _ = try? await adb.shell("settings put system screen_brightness \(brightness)", serial: serial, timeout: 8)
        }
        if let stayOn = savedStayOn {
            _ = try? await adb.shell("settings put global stay_on_while_plugged_in \(stayOn)", serial: serial, timeout: 8)
        } else {
            _ = try? await adb.shell("svc power stayon false", serial: serial, timeout: 8)
        }
        if let timeout = savedScreenOffTimeout {
            _ = try? await adb.shell("settings put system screen_off_timeout \(timeout)", serial: serial, timeout: 8)
        }
        savedBrightness = nil
        savedBrightnessMode = nil
        savedStayOn = nil
        savedScreenOffTimeout = nil
    }

    private func restoreScreenBrightnessSync() {
        if let mode = savedBrightnessMode {
            adbShellSync("settings put system screen_brightness_mode \(mode)")
        }
        if let brightness = savedBrightness {
            adbShellSync("settings put system screen_brightness \(brightness)")
        }
        if let stayOn = savedStayOn {
            adbShellSync("settings put global stay_on_while_plugged_in \(stayOn)")
        } else {
            adbShellSync("svc power stayon false")
        }
        if let timeout = savedScreenOffTimeout {
            adbShellSync("settings put system screen_off_timeout \(timeout)")
        }
        savedBrightness = nil
        savedBrightnessMode = nil
        savedStayOn = nil
        savedScreenOffTimeout = nil
    }

    func toggleScreen() {
        Task {
            if !screenOff {
                await setScreenOff(true)
            } else if !displayPoweredOff {
                // Auto mode already lowered brightness. The explicit button
                // escalates to physical panel-off; a second press restores.
                await setScreenOff(true, allowDisplayPower: true, force: true)
            } else {
                await setScreenOff(false)
            }
        }
    }

    /// A tiny shell round-trip keeps macOS USB remote wake/suspend from
    /// parking an otherwise idle ADB transport. It is intentionally cheaper
    /// than a full `adb devices` poll and never restarts the ADB server.
    private func startUSBKeepAlive() {
        guard usbKeepAliveTask == nil else { return }
        usbKeepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled, self.isRunning else { return }
                _ = try? await self.adb.shell("true", serial: self.serial, timeout: 5)
            }
        }
    }

    private func captureRotationIfNeeded() async {
        guard originalRotation == nil else { return }
        let userText = try? await adb.shell("wm user-rotation", serial: serial, timeout: 8)
        let fixedText = try? await adb.shell("wm fixed-to-user-rotation", serial: serial, timeout: 8)
        originalRotation = (
            userRotation: userText?.output.trimmed ?? "free",
            fixedRotation: fixedText?.output.trimmed ?? "default"
        )
        if let accelerometer = try? await adb.shell("settings get system accelerometer_rotation", serial: serial, timeout: 8),
           accelerometer.succeeded {
            let value = accelerometer.output.trimmed
            if value == "0" || value == "1" { originalAccelerometerRotation = value }
        }
        if let user = try? await adb.shell("settings get system user_rotation", serial: serial, timeout: 8),
           user.succeeded {
            let value = user.output.trimmed
            if value == "0" || value == "1" || value == "2" || value == "3" {
                originalUserRotationSetting = value
            }
        }
        AppLog.write("rotation captured user=\(originalRotation?.userRotation ?? "nil") fixed=\(originalRotation?.fixedRotation ?? "nil") accel=\(originalAccelerometerRotation ?? "nil") setting=\(originalUserRotationSetting ?? "nil")")
    }

    private func restoreRotationIfNeeded() {
        rotationReleaseTask?.cancel()
        rotationReleaseTask = nil
        softwareRotationActive = false
        softwareRotationTarget = nil
        lastRotationPolicyCheck = .distantPast
        didChangeOrientation = false

        // Respect the phone's current auto-rotate switch, but always end in
        // portrait so the mirrored resolution returns to the normal vertical
        // size after stopping. The fixed flag is never restored: it is what
        // breaks third-party fullscreen on this device.
        let currentAccel = adbShellOutputSync("settings get system accelerometer_rotation")
        let auto = currentAccel ?? originalAccelerometerRotation ?? "1"
        // On this Xiaomi, wm user-rotation alone does not change the panel.
        // Enable fixed only for this short portrait transition, then release
        // it unconditionally.
        adbShellSync("wm fixed-to-user-rotation enabled")
        adbShellSync("wm user-rotation lock 0")
        adbShellSync("settings put system user_rotation 0")
        adbShellSync("settings put system accelerometer_rotation 0")
        Thread.sleep(forTimeInterval: 0.35)
        adbShellSync("wm fixed-to-user-rotation disabled")
        if auto == "1" {
            adbShellSync("wm user-rotation free")
            adbShellSync("settings put system accelerometer_rotation 1")
        } else {
            adbShellSync("wm user-rotation lock 0")
            adbShellSync("settings put system accelerometer_rotation 0")
        }
        AppLog.write("rotation restored portrait fixed=disabled auto=\(auto)")

        originalRotation = nil
        originalAccelerometerRotation = nil
        originalUserRotationSetting = nil
    }

    @discardableResult
    private func adbShellSync(_ command: String) -> Bool {
        guard let executable = adb.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-s", serial, "shell", command]
        process.environment = ADB.environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func adbShellOutputSync(_ command: String) -> String? {
        guard let executable = adb.executableURL else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["-s", serial, "shell", command]
        process.environment = ADB.environment()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmed,
              !text.isEmpty else { return nil }
        return text
    }

    func tap(_ normalized: CGPoint) {
        let point = devicePoint(normalized)
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.adb.shell("input tap \(Int(point.x)) \(Int(point.y))", serial: self.serial, timeout: 10)
        }
    }

    func swipe(from: CGPoint, to: CGPoint) {
        let start = devicePoint(from)
        let end = devicePoint(to)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let duration = max(120, min(600, Int(distance / 2)))
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.adb.shell(
                "input swipe \(Int(start.x)) \(Int(start.y)) \(Int(end.x)) \(Int(end.y)) \(duration)",
                serial: self.serial,
                timeout: 15
            )
        }
    }

    func scroll(_ direction: CGFloat) {
        let size = inputSurfaceSize()
        let x = Int(size.width / 2)
        let y = Int(size.height / 2)
        let endY = y - Int(direction * size.height * 0.55)
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.adb.shell(
                "input swipe \(x) \(y) \(x) \(endY) 180",
                serial: self.serial,
                timeout: 15
            )
        }
    }

    func sendKey(_ code: Int32) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.adb.shell("input keyevent \(code)", serial: self.serial, timeout: 10)
        }
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        if text.unicodeScalars.contains(where: { $0.value > 127 }),
           let control, control.setClipboard(text, paste: true) {
            return
        }
        let escaped = ADB.escapeInputText(text)
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.adb.shell("input text \(ADB.quote(escaped))", serial: self.serial, timeout: 15)
        }
    }

    /// Entry point for the Mac text field used for Chinese/emoji input.
    func sendUnicodeText(_ text: String) {
        let value = text.trimmed
        guard !value.isEmpty else { return }
        if let control, control.setClipboard(value, paste: true) {
            status = "已粘贴到手机输入框"
        } else {
            status = "控制通道尚未就绪，暂时无法粘贴中文或 emoji"
        }
    }

    func wake() {
        sendKey(224)
    }

    func screenshot() async -> URL? {
        do {
            let result = try await adb.run(["exec-out", "screencap", "-p"], serial: serial, timeout: 30)
            guard result.succeeded, !result.stdout.isEmpty else {
                errorMessage = result.messages.trimmed
                return nil
            }
            let folder = settings.ensureDownloadFolder()
            let url = folder.appendingPathComponent(Formatters.timestampedName(prefix: "screenshot", ext: "png"))
            try result.stdout.write(to: url)
            if let image = NSImage(contentsOf: url) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func handleMouseButton(_ button: MouseButton) {
        let action = settings.mouseMapping.action(for: button)
        guard let code = action.androidKeyCode else { return }
        sendKey(code)
    }

    private func handleKey(_ event: NSEvent) {
        if let action = settings.keyboardMapping.action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags.rawValue
        ) {
            sendKey(action.androidKeyCode)
            return
        }

        switch event.keyCode {
        case 36, 76:
            sendKey(66); return
        case 51, 117:
            sendKey(67); return
        case 53:
            sendKey(4); return
        case 126, 125, 123, 124:
            handleArrowKey(event.keyCode); return
        case 48:
            sendKey(61); return
        case 115:
            sendKey(122); return
        case 119:
            sendKey(123); return
        default:
            break
        }

        guard let characters = event.characters, !characters.isEmpty else { return }
        for scalar in characters.unicodeScalars {
            let value = scalar.value
            if value == 13 || value == 3 {
                sendKey(66)
            } else if value == 127 || value == 8 {
                sendKey(67)
            } else if value == 27 {
                sendKey(4)
            } else if value >= 32 {
                sendText(String(scalar))
            }
        }
    }

    /// Arrow keys work as DPAD on the launcher, but most third-party apps do
    /// not implement DPAD focus navigation. When enabled, detect the current
    /// foreground package and turn the arrows into directional swipes inside
    /// apps while preserving DPAD navigation on the launcher.
    private func handleArrowKey(_ keyCode: UInt16) {
        let dpad: Int32
        switch keyCode {
        case 126: dpad = 19
        case 125: dpad = 20
        case 123: dpad = 21
        default: dpad = 22
        }
        guard settings.arrowKeysSwipeInApps else {
            sendKey(dpad)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let package = await self.foregroundPackageName(),
                  !Self.isLauncherPackage(package) else {
                self.sendKey(dpad)
                return
            }
            self.sendArrowSwipe(keyCode)
        }
    }

    private func foregroundPackageName() async -> String? {
        // `mCurrentFocus` is null while scrcpy holds the display power off,
        // even though a normal app is resumed. The activity task is the
        // reliable source for choosing DPAD vs. swipe.
        let commands = [
            "dumpsys activity activities | grep -m1 -E 'mResumedActivity|topResumedActivity'",
            "dumpsys window | grep -m1 mCurrentFocus"
        ]
        for command in commands {
            guard let result = try? await adb.shell(command, serial: serial, timeout: 8),
                  result.succeeded else { continue }
            let token = result.output
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .first { $0.contains("/") && !$0.contains("{") }
            if let token, let package = token.split(separator: "/").first, !package.isEmpty {
                return String(package)
            }
        }
        return nil
    }

    private static func isLauncherPackage(_ package: String) -> Bool {
        let value = package.lowercased()
        return value == "com.miui.home"
            || value.contains("launcher")
            || value.hasSuffix(".home")
    }

    private func sendArrowSwipe(_ keyCode: UInt16) {
        let center = CGPoint(x: 0.5, y: 0.5)
        let reach: CGFloat = 0.18
        let from: CGPoint
        let to: CGPoint
        // The gesture follows the content: pressing Down scrolls toward the
        // end of the list, so the finger travels up the screen.
        switch keyCode {
        case 126:
            from = CGPoint(x: center.x, y: center.y - reach)
            to = CGPoint(x: center.x, y: center.y + reach)
        case 125:
            from = CGPoint(x: center.x, y: center.y + reach)
            to = CGPoint(x: center.x, y: center.y - reach)
        case 123:
            from = CGPoint(x: center.x - reach, y: center.y)
            to = CGPoint(x: center.x + reach, y: center.y)
        default:
            from = CGPoint(x: center.x + reach, y: center.y)
            to = CGPoint(x: center.x - reach, y: center.y)
        }
        swipe(from: from, to: to)
    }

    /// Physical display size used by `adb shell input`.
    ///
    /// scrcpy creates a virtual display whose `dumpsys window displays`
    /// entry appears before `mDisplayId=0`; using the first `cur=` value
    /// shrank taps from 1440×3200 to 324×720, so every click landed in a
    /// small top-left area of the phone. Always use the physical size and
    /// swap axes when the stream is landscape.
    private func inputSurfaceSize() -> CGSize {
        var size = logicalSize.width > 1 ? logicalSize : videoSize
        if videoSize.width > 1, videoSize.height > 1,
           (videoSize.width > videoSize.height) != (size.width > size.height) {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
    }

    private func devicePoint(_ normalized: CGPoint) -> CGPoint {
        let size = inputSurfaceSize()
        return CGPoint(
            x: min(max(0, normalized.x), 1) * size.width,
            y: min(max(0, normalized.y), 1) * size.height
        )
    }

    private func refreshLogicalSizeIfNeeded() async {
        guard Date().timeIntervalSince(lastSizeRefresh) > 1 else { return }
        lastSizeRefresh = Date()
        if let size = try? await currentDisplaySize() {
            if abs(size.width - logicalSize.width) > 1 || abs(size.height - logicalSize.height) > 1 {
                logicalSize = size
            }
        }
    }

    private func currentDisplaySize() async throws -> CGSize {
        // `wm size` reports the panel's physical dimensions and does not change
        // with rotation. Read display 0's current bounds instead. Do not take
        // the first `cur=` line: scrcpy's virtual display is listed first and
        // is not the coordinate space used by `adb shell input`.
        if let size = await currentRotationSize() {
            return size
        }
        if let size = await queriedDisplaySize() {
            return size
        }
        return CGSize(width: 1080, height: 2400)
    }

    private func currentRotationSize() async -> CGSize? {
        guard let result = try? await adb.shell(
            "dumpsys window displays | grep -A3 'mDisplayId=0' | grep -m1 'cur='",
            serial: serial,
            timeout: 12
        ), result.succeeded else { return nil }
        return Self.parseSize(result.output, prefix: "cur=")
    }

    private func queriedDisplaySize() async -> CGSize? {
        guard let result = try? await adb.shell("wm size", serial: serial, timeout: 15),
              result.succeeded else { return nil }
        return Self.parseSize(result.output, prefix: nil)
    }

    private static func parseSize(_ text: String, prefix: String?) -> CGSize? {
        var candidate = text
        if let prefix, let range = candidate.range(of: prefix) {
            candidate = String(candidate[range.upperBound...])
        }
        let pattern = #"(\d{3,5})x(\d{3,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let match = regex.firstMatch(in: candidate, range: range),
              match.numberOfRanges == 3,
              let wRange = Range(match.range(at: 1), in: candidate),
              let hRange = Range(match.range(at: 2), in: candidate),
              let width = Double(candidate[wRange]),
              let height = Double(candidate[hRange]) else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func targetSize(for size: CGSize, quality: MirrorQuality) -> CGSize {
        let longest = max(size.width, size.height)
        let maximum = quality.maxDimension
        let scale = maximum == .greatestFiniteMagnitude ? 1 : min(1, maximum / longest)
        let width = max(2, (size.width * scale / 2).rounded(.down) * 2)
        let height = max(2, (size.height * scale / 2).rounded(.down) * 2)
        return CGSize(width: width, height: height)
    }
}
