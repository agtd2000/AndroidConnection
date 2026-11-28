import Foundation
import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore
    let devices: DeviceStore

    @Published var section: SidebarSection = .dashboard
    @Published var showConnectSheet = false
    @Published var mirrorFullscreen = false
    @Published var mirrorMini = false
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published private(set) var files: FilesStore?
    @Published private(set) var apps: AppsStore?
    @Published private(set) var clipboard: ClipboardStore?
    @Published private(set) var mirror: MirrorSession?
    private(set) var control: ScrcpyControl?

    private var cancellables = Set<AnyCancellable>()
    private var currentSerial: String?

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.devices = DeviceStore(settings: settings)

        devices.$selectedSerial
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] serial in
                self?.attach(serial: serial)
            }
            .store(in: &cancellables)

        devices.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self, let serial = self.currentSerial,
                      self.control?.isRunning == false,
                      list.contains(where: { $0.serial == serial && $0.isReady }) else { return }
                Task { await self.control?.start() }
            }
            .store(in: &cancellables)

        if ProcessInfo.processInfo.arguments.contains("--mirror-ui-test") {
            section = .mirror
        }
        attach(serial: devices.selectedSerial)
    }

    var device: AndroidDevice? { devices.selectedDevice }
    var hasDevice: Bool { device?.isReady == true }

    func attach(serial: String?) {
        guard serial != currentSerial else { return }
        mirror?.stop()
        control?.stop()
        control = nil
        currentSerial = serial

        guard let serial else {
            files = nil
            apps = nil
            clipboard = nil
            mirror = nil
            Task { await DeviceAwakeController.shared.restore() }
            return
        }

        Task { await DeviceAwakeController.shared.activate(serial: serial) }

        let control = ScrcpyControl(serial: serial)
        self.control = control
        let filesStore = FilesStore(serial: serial, settings: settings)
        let appsStore = AppsStore(serial: serial)
        self.files = filesStore
        self.apps = appsStore
        self.clipboard = ClipboardStore(serial: serial, settings: settings, control: control)
        let mirror = MirrorSession(serial: serial, settings: settings, control: control)
        mirror.onStopped = { [weak self] in
            guard let self, self.section == .mirror else { return }
            // A stopped mirror must not leave the last decoded frame behind.
            // Leave the mirror page; the session has already cleared the view.
            self.section = .dashboard
        }
        self.mirror = mirror

        Task {
            await control.start()
            await filesStore.load()
            await appsStore.load()
        }
    }

    func choose(_ section: SidebarSection) {
        self.section = section
        if section == .files, let files {
            Task { await files.load() }
        }
        if section == .apps, let apps {
            Task { await apps.load() }
        }
    }

    func showConnect() {
        showConnectSheet = true
    }

    func startMirror() {
        section = .mirror
        Task { await mirror?.start() }
    }

    func takeScreenshot() async -> URL? {
        if let mirror { return await mirror.screenshot() }
        if let data = await devices.takeScreenshot() {
            let folder = settings.ensureDownloadFolder()
            let url = folder.appendingPathComponent(Formatters.timestampedName(prefix: "screenshot", ext: "png"))
            try? data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        }
        return nil
    }
}
