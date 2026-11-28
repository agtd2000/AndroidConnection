import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var quality: MirrorQuality {
        didSet { defaults.set(quality.rawValue, forKey: Keys.quality) }
    }
    @Published var bitrateMbps: Int {
        didSet { defaults.set(bitrateMbps, forKey: Keys.bitrate) }
    }
    @Published var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Keys.autoConnect) }
    }
    @Published var hideDSStore: Bool {
        didSet { defaults.set(hideDSStore, forKey: Keys.hideDSStore) }
    }
    @Published var hideDotFiles: Bool {
        didSet { defaults.set(hideDotFiles, forKey: Keys.hideDotFiles) }
    }
    @Published var audioForwarding: Bool {
        didSet { defaults.set(audioForwarding, forKey: Keys.audioForwarding) }
    }
    @Published var autoScreenOff: Bool {
        didSet { defaults.set(autoScreenOff, forKey: Keys.autoScreenOff) }
    }
    @Published var miniBarOpacity: Double {
        didSet { defaults.set(miniBarOpacity, forKey: Keys.miniBarOpacity) }
    }
    @Published var connectionPreference: ConnectionPreference {
        didSet { defaults.set(connectionPreference.rawValue, forKey: Keys.connectionPreference) }
    }
    @Published var adbPort: Int {
        didSet {
            defaults.set(adbPort, forKey: Keys.adbPort)
            ADB.setServerPort(adbPort)
        }
    }
    @Published var syncDeviceClipboard: Bool {
        didSet { defaults.set(syncDeviceClipboard, forKey: Keys.syncDeviceClipboard) }
    }
    @Published var keyboardMapping: KeyboardMapping {
        didSet {
            if let data = try? JSONEncoder().encode(keyboardMapping) {
                defaults.set(data, forKey: Keys.keyboardMapping)
            }
        }
    }
    @Published var mouseMapping: MouseMapping {
        didSet {
            if let data = try? JSONEncoder().encode(mouseMapping) {
                defaults.set(data, forKey: Keys.mouseMapping)
            }
        }
    }
    @Published var scrollDirection: MouseScrollDirection {
        didSet { defaults.set(scrollDirection.rawValue, forKey: Keys.scrollDirection) }
    }
    @Published var arrowKeysSwipeInApps: Bool {
        didSet { defaults.set(arrowKeysSwipeInApps, forKey: Keys.arrowKeysSwipeInApps) }
    }
    @Published var downloadFolder: String {
        didSet { defaults.set(downloadFolder, forKey: Keys.downloadFolder) }
    }
    @Published private(set) var savedDevices: [SavedWirelessDevice] {
        didSet { persistDevices() }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let quality = "mirror.quality"
        static let bitrate = "mirror.bitrate"
        static let autoConnect = "wifi.autoConnect"
        static let hideDSStore = "files.hideDSStore"
        static let hideDotFiles = "files.hideDotFiles"
        static let audioForwarding = "mirror.audioForwarding"
        static let autoScreenOff = "mirror.autoScreenOff"
        static let miniBarOpacity = "mirror.miniBarOpacity"
        static let connectionPreference = "connection.preference"
        static let adbPort = "connection.adbPort"
        static let syncDeviceClipboard = "clipboard.syncFromDevice"
        static let keyboardMapping = "input.keyboardMapping"
        static let mouseMapping = "input.mouseMapping"
        static let scrollDirection = "input.mouseScrollDirection"
        static let arrowKeysSwipeInApps = "input.arrowKeysSwipeInApps"
        static let downloadFolder = "files.downloadFolder"
        static let savedDevices = "wifi.savedDevices"
    }

    init() {
        let defaultQuality = MirrorQuality(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .balanced
        quality = defaultQuality
        bitrateMbps = defaults.object(forKey: Keys.bitrate) as? Int ?? 8
        autoConnect = defaults.object(forKey: Keys.autoConnect) as? Bool ?? true
        hideDSStore = defaults.object(forKey: Keys.hideDSStore) as? Bool ?? true
        hideDotFiles = defaults.object(forKey: Keys.hideDotFiles) as? Bool ?? false
        audioForwarding = defaults.object(forKey: Keys.audioForwarding) as? Bool ?? true
        autoScreenOff = defaults.object(forKey: Keys.autoScreenOff) as? Bool ?? true
        miniBarOpacity = min(0.95, max(0.15, defaults.object(forKey: Keys.miniBarOpacity) as? Double ?? 0.55))
        connectionPreference = ConnectionPreference(rawValue: defaults.string(forKey: Keys.connectionPreference) ?? "") ?? .auto
        let savedPort = defaults.object(forKey: Keys.adbPort) as? Int
        adbPort = savedPort ?? Int(ADB.serverPort) ?? 5037
        syncDeviceClipboard = defaults.object(forKey: Keys.syncDeviceClipboard) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.keyboardMapping),
           let decoded = try? JSONDecoder().decode(KeyboardMapping.self, from: data) {
            keyboardMapping = decoded
        } else {
            keyboardMapping = .defaults
        }
        if let data = defaults.data(forKey: Keys.mouseMapping),
           let decoded = try? JSONDecoder().decode(MouseMapping.self, from: data) {
            mouseMapping = decoded
        } else {
            mouseMapping = .defaults
        }
        scrollDirection = MouseScrollDirection(rawValue: defaults.string(forKey: Keys.scrollDirection) ?? "") ?? .normal
        arrowKeysSwipeInApps = defaults.object(forKey: Keys.arrowKeysSwipeInApps) as? Bool ?? true
        downloadFolder = defaults.string(forKey: Keys.downloadFolder) ?? SettingsStore.defaultDownloadFolder
        if let data = defaults.data(forKey: Keys.savedDevices),
           let decoded = try? JSONDecoder().decode([SavedWirelessDevice].self, from: data) {
            savedDevices = decoded
        } else {
            savedDevices = []
        }
        ADB.setServerPort(adbPort)
    }

    static var defaultDownloadFolder: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return downloads.appendingPathComponent("AndroidConnection").path
    }

    func remember(address: String, name: String) {
        var list = savedDevices
        if let index = list.firstIndex(where: { $0.address == address }) {
            list[index].name = name
            list[index].lastConnected = Date()
        } else {
            list.append(SavedWirelessDevice(address: address, name: name, lastConnected: Date()))
        }
        savedDevices = list
    }

    func forget(_ device: SavedWirelessDevice) {
        savedDevices.removeAll { $0.address == device.address }
    }

    func forget(address: String) {
        savedDevices.removeAll { $0.address == address }
    }

    private func persistDevices() {
        if let data = try? JSONEncoder().encode(savedDevices) {
            defaults.set(data, forKey: Keys.savedDevices)
        }
    }

    func ensureDownloadFolder() -> URL {
        let url = URL(fileURLWithPath: downloadFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
