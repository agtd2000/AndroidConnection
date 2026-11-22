import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppLog.write("launched, pid=\(ProcessInfo.processInfo.processIdentifier)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            // SwiftUI restores the last frame in bottom-left coordinates and
            // can leave the window pinned to the bottom edge after a mirror
            // rotation. Disable that restore and center the main window once.
            window.setFrameAutosaveName("")
            window.isRestorable = false
            window.center()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let windows = NSApp.windows
            AppLog.write("windows=\(windows.count) visible=\(windows.filter(\.isVisible).count)")
        }
        scheduleSnapshotIfRequested()
        scheduleAudioTestIfRequested()
        scheduleControlTestIfRequested()
        scheduleClipboardTestIfRequested()
        scheduleMirrorTestIfRequested()
        scheduleScreenOffTestIfRequested()
    }

    private func scheduleAudioTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--audio-test") else { return }
        Task { @MainActor in
            let arguments = ProcessInfo.processInfo.arguments
            let forcedSerial: String? = {
                guard let index = arguments.firstIndex(of: "--audio-test"), index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                return value.hasPrefix("-") ? nil : value
            }()
            let result = try? await ADB.shared.run(["devices"], timeout: 15)
            let serial = forcedSerial ?? result?.output
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    guard parts.count >= 2, parts[1] == "device" else { return nil }
                    return parts[0]
                }
                .first
            guard let serial else {
                AppLog.write("audio-test: no device")
                NSApp.terminate(nil)
                return
            }
            AppLog.write("audio-test: serial=\(serial)")
            _ = try? await ADB.shared.shell(
                "am start -a android.intent.action.VIEW -d file:///sdcard/Download/tone30.wav -t audio/wav",
                serial: serial,
                timeout: 15
            )
            let forwarder = AudioForwarder(serial: serial)
            var maximumLevel: Float = 0
            forwarder.onStatus = { AppLog.write("audio-test: status=\($0)") }
            forwarder.onLevel = { level in maximumLevel = max(maximumLevel, level) }
            await forwarder.start()
            let recording = URL(fileURLWithPath: "/tmp/androidconnection-audio-test.caf")
            forwarder.startDiagnosticRecording(to: recording)
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            forwarder.stopDiagnosticRecording()
            let size = (try? FileManager.default.attributesOfItem(atPath: recording.path)[.size] as? Int) ?? 0
            AppLog.write("audio-test: maxLevel=\(String(format: "%.4f", maximumLevel)) record=\(recording.path) bytes=\(size ?? 0)")
            forwarder.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }

    private func scheduleControlTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--control-test") else { return }
        Task { @MainActor in
            let arguments = ProcessInfo.processInfo.arguments
            let forcedSerial: String? = {
                guard let index = arguments.firstIndex(of: "--control-test"), index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                return value.hasPrefix("-") ? nil : value
            }()
            let result = try? await ADB.shared.run(["devices"], timeout: 15)
            let serial = forcedSerial ?? result?.output
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    guard parts.count >= 2, parts[1] == "device" else { return nil }
                    return parts[0]
                }
                .first
            guard let serial else {
                AppLog.write("control-test: no device")
                NSApp.terminate(nil)
                return
            }
            AppLog.write("control-test: serial=\(serial)")
            let control = ScrcpyControl(serial: serial)
            var received = ""
            control.onStatus = { AppLog.write("control-test: status=\($0)") }
            control.onClipboard = { text in
                received = text
                AppLog.write("control-test: clipboard=\(text)")
            }
            await control.start()
            let sample = "中文输入 😀 AndroidConnection"
            let sent = control.setClipboard(sample, paste: false)
            AppLog.write("control-test: set clipboard ok=\(sent) running=\(control.isRunning)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            control.requestClipboard()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            AppLog.write("control-test: verified=\(received == sample) received=\(received)")
            control.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }

    private func scheduleClipboardTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--clipboard-test") else { return }
        Task { @MainActor in
            let arguments = ProcessInfo.processInfo.arguments
            let forcedSerial: String? = {
                guard let index = arguments.firstIndex(of: "--clipboard-test"), index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                return value.hasPrefix("-") ? nil : value
            }()
            let result = try? await ADB.shared.run(["devices"], timeout: 15)
            let serial = forcedSerial ?? result?.output
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    guard parts.count >= 2, parts[1] == "device" else { return nil }
                    return parts[0]
                }
                .first
            guard let serial else {
                AppLog.write("clipboard-test: no device")
                NSApp.terminate(nil)
                return
            }
            let settings = SettingsStore()
            settings.syncDeviceClipboard = true
            let control = ScrcpyControl(serial: serial)
            let store = ClipboardStore(serial: serial, settings: settings, control: control)
            await control.start()
            let sample = "手机复制到 Mac 😀"
            _ = control.setClipboard(sample, paste: false)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let macText = NSPasteboard.general.string(forType: .string) ?? ""
            AppLog.write("clipboard-test: serial=\(serial) incoming=\(store.incomingText) mac=\(macText) verified=\(macText == sample)")
            control.stop()
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApp.terminate(nil)
        }
    }

    private func scheduleMirrorTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--mirror-test") else { return }
        Task { @MainActor in
            let arguments = ProcessInfo.processInfo.arguments
            let forcedSerial: String? = {
                guard let index = arguments.firstIndex(of: "--mirror-test"), index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                return value.hasPrefix("-") ? nil : value
            }()
            let result = try? await ADB.shared.run(["devices"], timeout: 15)
            let serial = forcedSerial ?? result?.output
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    guard parts.count >= 2, parts[1] == "device" else { return nil }
                    return parts[0]
                }
                .first
            guard let serial else {
                AppLog.write("mirror-test: no device")
                NSApp.terminate(nil)
                return
            }
            let settings = SettingsStore()
            settings.autoScreenOff = true
            let session = MirrorSession(serial: serial, settings: settings)
            AppLog.write("mirror-test: serial=\(serial)")
            await session.start()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            AppLog.write("mirror-test: initial frames=\(session.frameCount) size=\(session.resolutionLabel) audio=\(session.audioEnabled) status=\(session.audioStatus) screenOff=\(session.screenOff)")
            settings.bitrateMbps = 8
            await session.restartVideoOnly()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            AppLog.write("mirror-test: bitrate frames=\(session.frameCount) audio=\(session.audioEnabled) status=\(session.audioStatus)")
            let beforeOff = session.frameCount
            await session.setScreenOff(true)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            AppLog.write("mirror-test: off frames=\(session.frameCount) delta=\(session.frameCount - beforeOff) screenOff=\(session.screenOff)")
            await session.setScreenOff(false)
            await session.setOrientation(landscape: true)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            AppLog.write("mirror-test: landscape frames=\(session.frameCount) size=\(session.resolutionLabel) landscape=\(session.orientationLandscape)")
            await session.setOrientation(landscape: false)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            AppLog.write("mirror-test: portrait frames=\(session.frameCount) size=\(session.resolutionLabel) landscape=\(session.orientationLandscape)")
            session.stop()
            try? await Task.sleep(nanoseconds: 800_000_000)
            NSApp.terminate(nil)
        }
    }

    private func scheduleScreenOffTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--screenoff-test") else { return }
        Task { @MainActor in
            let arguments = ProcessInfo.processInfo.arguments
            let forcedSerial: String? = {
                guard let index = arguments.firstIndex(of: "--screenoff-test"), index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                return value.hasPrefix("-") ? nil : value
            }()
            let result = try? await ADB.shared.run(["devices"], timeout: 15)
            let serial = forcedSerial ?? result?.output
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    guard parts.count >= 2, parts[1] == "device" else { return nil }
                    return parts[0]
                }
                .first
            guard let serial else {
                AppLog.write("screenoff-test: no device")
                NSApp.terminate(nil)
                return
            }
            let settings = SettingsStore()
            settings.autoScreenOff = false
            settings.audioForwarding = false
            let session = MirrorSession(serial: serial, settings: settings)
            AppLog.write("screenoff-test: serial=\(serial)")
            await session.start()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let before = session.frameCount
            await session.setScreenOff(true, allowDisplayPower: true)
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            AppLog.write("screenoff-test: off before=\(before) after=\(session.frameCount) delta=\(session.frameCount - before) screenOff=\(session.screenOff)")
            await session.setScreenOff(false)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let beforeRotate = session.frameCount
            await session.setOrientation(landscape: true)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            AppLog.write("screenoff-test: landscape frames=\(session.frameCount) delta=\(session.frameCount - beforeRotate) landscape=\(session.orientationLandscape) status=\(session.status)")
            await session.setOrientation(landscape: false)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            AppLog.write("screenoff-test: portrait frames=\(session.frameCount) landscape=\(session.orientationLandscape) status=\(session.status)")
            session.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }

    /// Debug/verification hook: `--snapshot <path>` renders the app's own
    /// window to PNG and exits. It needs no Screen Recording permission.
    private func scheduleSnapshotIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return }
        let path = arguments[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if let window = NSApp.windows.first(where: { $0.isVisible }),
               let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.layoutSubtreeIfNeeded()
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    AppLog.write("snapshot written path=\(path) size=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
                }
            }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.write("applicationWillTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AndroidConnectionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.devices)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("设备") {
                Button("连接设备…") {
                    model.showConnect()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("刷新设备") {
                    Task { await model.devices.refresh() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button("开始或停止投屏") {
                    if model.mirror?.isRunning == true {
                        model.mirror?.stop()
                    } else {
                        model.startMirror()
                    }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("截屏") {
                    Task { _ = await model.takeScreenshot() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}
