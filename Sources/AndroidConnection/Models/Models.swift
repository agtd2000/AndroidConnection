import Foundation

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case files
    case apps
    case mirror
    case clipboard
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "设备"
        case .files: return "文件"
        case .apps: return "应用"
        case .mirror: return "投屏"
        case .clipboard: return "剪贴板"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "iphone.gen3"
        case .files: return "folder"
        case .apps: return "square.grid.2x2"
        case .mirror: return "rectangle.on.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .settings: return "gearshape"
        }
    }
}

enum ConnectionPreference: String, CaseIterable, Identifiable {
    case auto
    case usb
    case wifi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .usb: return "优先 USB"
        case .wifi: return "优先 Wi-Fi"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "按 adb 返回顺序选择第一台在线设备"
        case .usb: return "同时在线时优先使用 USB 连接"
        case .wifi: return "同时在线时优先使用无线连接"
        }
    }
}

struct AndroidDevice: Identifiable, Hashable {
    enum Connection: String {
        case usb
        case wifi

        var label: String { self == .usb ? "USB" : "无线" }
        var icon: String { self == .usb ? "cable.connector" : "wifi" }
    }

    let serial: String
    let state: String
    let model: String
    let product: String
    let device: String
    let connection: Connection
    let transportID: String?
    var deviceName: String = ""

    var id: String { serial }

    var isReady: Bool { state == "device" }

    var statusLabel: String {
        switch state {
        case "device": return "已连接"
        case "unauthorized": return "等待授权"
        case "offline": return "已离线"
        case "connecting": return "连接中"
        default: return state
        }
    }

    /// Human-readable device name first, model as fallback.
    var displayName: String {
        if !deviceName.isEmpty { return deviceName }
        if !model.isEmpty { return model }
        if !device.isEmpty { return device }
        return serial
    }

    /// Model is the secondary label when a device name is available.
    var secondaryName: String {
        if !model.isEmpty { return model }
        if !device.isEmpty { return device }
        return serial
    }

    var address: String? {
        connection == .wifi ? serial : nil
    }
}

struct DeviceDetails {
    var manufacturer: String = ""
    var model: String = ""
    var androidVersion: String = ""
    var sdk: String = ""
    var resolution: String = ""
    var ipAddress: String = ""
    var batteryLevel: Int = 0
    var isCharging: Bool = false
    var batteryStatus: Int = 0
    var batteryHealth: Int = 0
    var batteryVoltageMV: Int = 0
    var batteryTemperatureC: Double? = nil
    var batteryChargeCounterUAh: Int? = nil
    var batteryMaxChargingVoltageUV: Int? = nil
    var batteryTechnology: String = ""
    var batteryACPowered: Bool = false
    var batteryUSBPowered: Bool = false
    var batteryWirelessPowered: Bool = false
    var storageTotal: Int64 = 0
    var storageFree: Int64 = 0

    var batteryStatusTitle: String {
        switch batteryStatus {
        case 2: return "充电中"
        case 3: return "放电中"
        case 4: return "未充电"
        case 5: return "已充满"
        default: return isCharging ? "充电中" : "未知"
        }
    }

    var batteryHealthTitle: String {
        switch batteryHealth {
        case 2: return "良好"
        case 3: return "过热"
        case 4: return "损坏"
        case 5: return "电压过高"
        case 6: return "故障"
        case 7: return "温度过低"
        default: return "未知"
        }
    }

    var batterySourceTitle: String {
        if batteryACPowered { return "AC 充电器" }
        if batteryUSBPowered { return "USB" }
        if batteryWirelessPowered { return "无线充电" }
        return "电池供电"
    }

    var storageUsed: Int64 { max(0, storageTotal - storageFree) }
    var storageUsedFraction: Double {
        guard storageTotal > 0 else { return 0 }
        return min(1, Double(storageUsed) / Double(storageTotal))
    }
}

enum MirrorKeyAction: String, CaseIterable, Codable, Identifiable {
    case back
    case home
    case recents
    case volumeUp
    case volumeDown
    case mute
    case power
    case wake

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: return "返回"
        case .home: return "主页"
        case .recents: return "多任务"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 -"
        case .mute: return "静音"
        case .power: return "电源键"
        case .wake: return "唤醒屏幕"
        }
    }

    var detail: String {
        switch self {
        case .back: return "相当于手机返回键 / 返回手势"
        case .home: return "回到手机桌面"
        case .recents: return "打开最近任务"
        case .volumeUp: return "提高手机媒体音量"
        case .volumeDown: return "降低手机媒体音量"
        case .mute: return "切换手机静音"
        case .power: return "短按手机电源键"
        case .wake: return "唤醒手机屏幕"
        }
    }

    var icon: String {
        switch self {
        case .back: return "chevron.backward"
        case .home: return "house"
        case .recents: return "square.on.square"
        case .volumeUp: return "speaker.wave.3"
        case .volumeDown: return "speaker.wave.1"
        case .mute: return "speaker.slash.fill"
        case .power: return "power"
        case .wake: return "sun.max"
        }
    }

    var androidKeyCode: Int32 {
        switch self {
        case .back: return 4
        case .home: return 3
        case .recents: return 187
        case .volumeUp: return 24
        case .volumeDown: return 25
        case .mute: return 164
        case .power: return 26
        case .wake: return 224
        }
    }
}

struct KeyChord: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt
    var label: String

    private static let command = UInt(1 << 20)
    private static let option = UInt(1 << 19)
    private static let control = UInt(1 << 18)
    private static let shift = UInt(1 << 17)
    static let relevantModifiers = command | option | control | shift

    var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + label
    }

    func matches(keyCode: UInt16, modifiers: UInt) -> Bool {
        self.keyCode == keyCode && (self.modifiers & Self.relevantModifiers) == (modifiers & Self.relevantModifiers)
    }
}

enum MouseButtonAction: String, CaseIterable, Codable, Identifiable {
    case back
    case home
    case recents
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: return "返回"
        case .home: return "主页"
        case .recents: return "多任务"
        case .none: return "无操作"
        }
    }

    var icon: String {
        switch self {
        case .back: return "chevron.backward"
        case .home: return "house"
        case .recents: return "square.on.square"
        case .none: return "minus.circle"
        }
    }

    var androidKeyCode: Int32? {
        switch self {
        case .back: return 4
        case .home: return 3
        case .recents: return 187
        case .none: return nil
        }
    }
}

struct MouseMapping: Codable, Equatable {
    var right: MouseButtonAction
    var middle: MouseButtonAction

    init(right: MouseButtonAction = .back, middle: MouseButtonAction = .recents) {
        self.right = right
        self.middle = middle
    }

    static var defaults: MouseMapping { MouseMapping() }

    func action(for button: MouseButton) -> MouseButtonAction {
        switch button {
        case .right: return right
        case .middle: return middle
        }
    }
}

enum MouseButton: String, CaseIterable, Identifiable {
    case right
    case middle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .right: return "右键"
        case .middle: return "中键"
        }
    }
}

enum MouseScrollDirection: String, CaseIterable, Codable, Identifiable {
    case normal
    case reverse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "正向"
        case .reverse: return "反向"
        }
    }

    var multiplier: CGFloat {
        self == .normal ? 1 : -1
    }
}

struct KeyboardMapping: Codable, Equatable {
    var bindings: [String: KeyChord]

    init(bindings: [String: KeyChord] = [:]) {
        self.bindings = bindings
    }

    static var defaults: KeyboardMapping {
        var mapping = KeyboardMapping()
        mapping.bindings[MirrorKeyAction.back.rawValue] = KeyChord(keyCode: 53, modifiers: 0, label: "Esc")
        mapping.bindings[MirrorKeyAction.home.rawValue] = KeyChord(keyCode: 123, modifiers: 1 << 20, label: "←")
        mapping.bindings[MirrorKeyAction.recents.rawValue] = KeyChord(keyCode: 124, modifiers: 1 << 20, label: "→")
        mapping.bindings[MirrorKeyAction.volumeUp.rawValue] = KeyChord(keyCode: 72, modifiers: 0, label: "音量+")
        mapping.bindings[MirrorKeyAction.volumeDown.rawValue] = KeyChord(keyCode: 73, modifiers: 0, label: "音量-")
        mapping.bindings[MirrorKeyAction.mute.rawValue] = KeyChord(keyCode: 74, modifiers: 0, label: "静音")
        mapping.bindings[MirrorKeyAction.power.rawValue] = KeyChord(keyCode: 35, modifiers: (1 << 20) | (1 << 19), label: "P")
        mapping.bindings[MirrorKeyAction.wake.rawValue] = KeyChord(keyCode: 13, modifiers: (1 << 20) | (1 << 19), label: "W")
        return mapping
    }

    func chord(for action: MirrorKeyAction) -> KeyChord? {
        bindings[action.rawValue]
    }

    func action(keyCode: UInt16, modifiers: UInt) -> MirrorKeyAction? {
        for action in MirrorKeyAction.allCases {
            if let chord = chord(for: action), chord.matches(keyCode: keyCode, modifiers: modifiers) {
                return action
            }
        }
        return nil
    }

    mutating func set(_ chord: KeyChord, for action: MirrorKeyAction) {
        bindings[action.rawValue] = chord
    }

    mutating func reset(_ action: MirrorKeyAction) {
        bindings[action.rawValue] = Self.defaults.bindings[action.rawValue]
    }

    mutating func resetAll() {
        self = Self.defaults
    }
}

struct FileItem: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date?
    let permissions: String

    var id: String { path }

    var displaySize: String {
        if isDirectory { return "—" }
        return Formatters.fileSize(size)
    }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff", "svg":
            return "photo.fill"
        case "mp4", "mov", "mkv", "avi", "webm", "3gp", "m4v":
            return "film.fill"
        case "mp3", "wav", "flac", "ogg", "m4a", "aac", "opus":
            return "music.note"
        case "pdf":
            return "doc.richtext.fill"
        case "apk", "xapk", "apks":
            return "shippingbox.fill"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox.fill"
        case "txt", "md", "json", "xml", "log", "yaml", "yml":
            return "doc.text.fill"
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx":
            return "doc.fill"
        case "kt", "java", "swift", "js", "ts", "py", "c", "cpp", "h":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc.fill"
        }
    }

    var isAPK: Bool { name.lowercased().hasSuffix(".apk") }
}

struct AndroidApp: Identifiable, Hashable {
    let package: String
    let apkPath: String?
    let isSystem: Bool

    var id: String { package }

    var displayName: String {
        let raw = package.split(separator: ".").last.map(String.init) ?? package
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    var initials: String {
        let parts = package.split(separator: ".")
        if parts.count >= 2 {
            return parts.suffix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        }
        return String(package.prefix(2)).uppercased()
    }
}

struct SavedWirelessDevice: Codable, Identifiable, Hashable {
    var address: String
    var name: String
    var lastConnected: Date

    var id: String { address }
}

struct DiscoveredService: Identifiable, Hashable {
    let name: String
    let address: String

    var id: String { address }
}

enum MirrorQuality: String, CaseIterable, Identifiable {
    case smooth
    case balanced
    case sharp
    case native

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: return "流畅（720p）"
        case .balanced: return "均衡（1080p）"
        case .sharp: return "高清（1440p）"
        case .native: return "原始分辨率"
        }
    }

    var maxDimension: CGFloat {
        switch self {
        case .smooth: return 720
        case .balanced: return 1080
        case .sharp: return 1440
        case .native: return .greatestFiniteMagnitude
        }
    }
}

enum MirrorCommand {
    case tap(CGPoint)
    case swipe(CGPoint, CGPoint, Int)
    case key(Int32)
    case text(String)
}
