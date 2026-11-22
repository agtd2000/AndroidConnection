import Foundation
import Combine

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [AndroidDevice] = []
    @Published var selectedSerial: String? {
        didSet {
            guard oldValue != selectedSerial else { return }
            details = nil
            detailsError = nil
            lastDetailsFetch = .distantPast
            Task { await refreshDetails(force: true) }
        }
    }
    @Published private(set) var details: DeviceDetails?
    @Published private(set) var detailsError: String?
    /// Set after the user explicitly disconnects. Automatic selection and
    /// reconnect stay paused until the user presses the connect button again.
    @Published private(set) var connectionPaused = false
    @Published private(set) var deviceNames: [String: String] = [:]
    @Published private(set) var savedDevices: [SavedWirelessDevice] = []
    @Published private(set) var discoveredServices: [DiscoveredService] = []
    @Published private(set) var isBusy = false
    @Published var banner: String?
    @Published var lastError: String?

    private let adb = ADB.shared
    private let settings: SettingsStore
    private var refreshTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var lastDetailsFetch = Date.distantPast
    private var isFetchingDetails = false
    private var lastReconnect: [String: Date] = [:]
    private var lastRecovery = Date.distantPast
    private var isRefreshing = false
    private var nameFetching: Set<String> = []
    private var nameAttempted: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore) {
        self.settings = settings
        self.savedDevices = settings.savedDevices
        settings.$connectionPreference
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyConnectionPreference() }
            .store(in: &cancellables)
        Task {
            try? await adb.startServer()
            await refresh()
        }
        start()
    }

    var selectedDevice: AndroidDevice? {
        guard let selectedSerial else { return nil }
        return devices.first { $0.serial == selectedSerial }
    }

    var readyDevices: [AndroidDevice] { devices.filter(\.isReady) }

    var connectionSummary: String {
        guard let device = selectedDevice else { return "未连接设备" }
        return "\(device.connection.label) · \(device.statusLabel)"
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
        detailTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDetails()
                // Device information changes slowly; refresh every 6 seconds.
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        detailTask?.cancel()
        refreshTask = nil
        detailTask = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var result = try await adb.run(["devices", "-l"], timeout: 15)
            var parsed = Self.parseDevices(result.output)

            if parsed.isEmpty, Date().timeIntervalSince(lastRecovery) > 6 {
                lastRecovery = Date()
                // `start-server` does not clear a dead USB transport. Xiaomi
                // re-enumerates the port but adb keeps the old transport and
                // reports no devices forever; only a full server restart makes
                // it enumerate the reconnected phone again.
                AppLog.write("adb recovery: restarting server")
                try? await adb.restartServer()
                result = try await adb.run(["devices", "-l"], timeout: 15)
                parsed = Self.parseDevices(result.output)
            }

            if settings.autoConnect, !connectionPaused {
                for saved in settings.savedDevices where !parsed.contains(where: { $0.serial == saved.address }) {
                    let last = lastReconnect[saved.address] ?? .distantPast
                    guard Date().timeIntervalSince(last) > 20 else { continue }
                    lastReconnect[saved.address] = Date()
                    _ = try? await adb.run(["connect", saved.address], timeout: 8)
                }
                if !settings.savedDevices.isEmpty {
                    parsed = Self.parseDevices((try? await adb.run(["devices", "-l"], timeout: 15))?.output ?? result.output)
                }
            }

            devices = parsed
            applyCachedNames()
            let unnamed = parsed.filter { $0.isReady && deviceNames[$0.serial] == nil && !nameAttempted.contains($0.serial) }
            for device in unnamed {
                Task { await fetchName(for: device) }
            }
            savedDevices = settings.savedDevices
            lastError = nil
            AppLog.write("devices=\(parsed.count) selected=\(selectedSerial ?? "-") adb=\(adb.executableURL?.path ?? "nil")")

            if parsed.isEmpty {
                // Keep the previous selection across transient USB re-enumerations.
            } else if let serial = selectedSerial,
                      parsed.contains(where: { $0.serial == serial && $0.isReady }) {
                // Keep the current ready selection; offline devices fall through
                // to the preferred ready device (e.g. Wi-Fi drops, USB remains).
            } else if !connectionPaused, let preferred = preferredDevice(in: parsed) {
                // Do not attach a device that is still on the lock screen or
                // has its screen off. The user can unlock it and press the
                // connect button in the connection sheet.
                if await isDeviceUnlocked(serial: preferred.serial) == true {
                    selectedSerial = preferred.serial
                }
            }
        } catch {
            lastError = error.localizedDescription
            AppLog.write("device refresh failed: \(error.localizedDescription)")
        }
    }

    func refreshDetails(force: Bool = false) async {
        guard !isFetchingDetails else { return }
        guard let device = selectedDevice, device.isReady else {
            if details != nil { details = nil }
            detailsError = nil
            return
        }
        if !force, Date().timeIntervalSince(lastDetailsFetch) < 4 { return }
        isFetchingDetails = true
        lastDetailsFetch = Date()
        defer { isFetchingDetails = false }

        // Keep the potentially slow battery service query separate from the
        // basic device properties. If `dumpsys battery` is busy, the rest of
        // the device information still appears and the next cycle retries it.
        let baseCommand = ([
            "getprop ro.product.manufacturer",
            "getprop ro.product.model",
            "getprop ro.build.version.release",
            "getprop ro.build.version.sdk",
            "wm size | tail -n 1",
            "df -k /sdcard 2>/dev/null | tail -n 1",
            "ip -f inet addr show wlan0 2>/dev/null | grep 'inet '"
        ].joined(separator: "; echo @@; ")) + "; true"

        do {
            let result = try await adb.shell(baseCommand, serial: device.serial, timeout: 15)
            guard selectedSerial == device.serial else { return }
            guard result.succeeded else {
                if details == nil {
                    detailsError = "设备信息读取失败，请稍后重试。"
                }
                AppLog.write("details base failed serial=\(device.serial)")
                return
            }
            var parsed = Self.parseDetails(result.output, fallbackName: device.displayName)
            if let battery = try? await adb.shell("dumpsys battery", serial: device.serial, timeout: 8),
               battery.succeeded {
                Self.applyBattery(battery.output, to: &parsed)
            }
            guard selectedSerial == device.serial else { return }
            details = parsed
            detailsError = nil
            AppLog.write("details model=\(parsed.model) android=\(parsed.androidVersion) battery=\(parsed.batteryLevel) storage=\(parsed.storageFree)/\(parsed.storageTotal) res=\(parsed.resolution) ip=\(parsed.ipAddress)")
        } catch {
            if details == nil {
                detailsError = "设备信息读取超时，请稍后重试。"
            }
            AppLog.write("details failed serial=\(device.serial) error=\(error.localizedDescription)")
        }
    }

    /// The preferred online device for the current connection preference.
    func preferredDevice(in list: [AndroidDevice]? = nil) -> AndroidDevice? {
        let candidates = (list ?? devices).filter(\.isReady)
        guard !candidates.isEmpty else { return nil }
        switch settings.connectionPreference {
        case .auto:
            return candidates.first
        case .usb:
            return candidates.first(where: { $0.connection == .usb }) ?? candidates.first
        case .wifi:
            return candidates.first(where: { $0.connection == .wifi }) ?? candidates.first
        }
    }

    /// Re-apply the preference after the user changes it in Settings.
    func applyConnectionPreference() {
        guard let preferred = preferredDevice() else { return }
        if selectedSerial != preferred.serial {
            selectedSerial = preferred.serial
            AppLog.write("connection preference=\(settings.connectionPreference.rawValue) selected=\(preferred.serial)")
        }
    }

    /// Whether the phone is unlocked and its screen is awake. `nil` means the
    /// state could not be queried (for example while ADB is still unauthorized).
    func isDeviceUnlocked(serial: String) async -> Bool? {
        let command = "dumpsys window | grep -iE 'isKeyguardShowing=|mDreamingLockscreen=|mShowingLockscreen=' | head -6; dumpsys power | grep -m1 'mWakefulness='"
        guard let result = try? await adb.shell(command, serial: serial, timeout: 12),
              result.succeeded else { return nil }
        let text = result.output.lowercased()
        guard !text.trimmed.isEmpty else { return nil }
        if text.contains("iskeyguardshowing=true")
            || text.contains("mdreaminglockscreen=true")
            || text.contains("mshowinglockscreen=true")
            || text.contains("mkeyguardshowing=true") {
            return false
        }
        if text.contains("mwakefulness=asleep") || text.contains("mwakefulness=dozing") {
            return false
        }
        if text.contains("iskeyguardshowing=false")
            || text.contains("mdreaminglockscreen=false")
            || text.contains("mshowinglockscreen=false") {
            return true
        }
        return nil
    }

    /// Attach an already discoverable USB/Wi-Fi device after verifying that
    /// the phone is unlocked. This is the app-session connect path used by the
    /// connection sheet and the device card.
    @discardableResult
    func connect(device: AndroidDevice) async -> String {
        guard device.isReady else {
            let message = "设备当前不可用，请检查 USB 或无线调试连接。"
            banner = message
            return message
        }
        isBusy = true
        defer { isBusy = false }
        let unlockState = await isDeviceUnlocked(serial: device.serial)
        guard unlockState == true else {
            let message = unlockState == false
                ? "手机尚未解锁，请先解锁手机再连接。"
                : "无法确认手机解锁状态，请解锁后重试。"
            banner = message
            AppLog.write("connect blocked serial=\(device.serial) unlocked=\(unlockState.map(String.init) ?? "unknown")")
            return message
        }
        connectionPaused = false
        selectedSerial = device.serial
        let message = "已连接 \(device.displayName)"
        banner = message
        return message
    }

    /// Disconnect the app session. USB remains physically attached, so the
    /// device stays in the list and can be reconnected with one click. Wi-Fi
    /// also removes its ADB transport.
    @discardableResult
    func disconnect(_ device: AndroidDevice) async -> String {
        connectionPaused = true
        if device.connection == .wifi {
            _ = try? await adb.run(["disconnect", device.serial], timeout: 10)
        }
        if selectedSerial == device.serial {
            selectedSerial = nil
        }
        details = nil
        await refresh()
        let message = device.connection == .wifi
            ? "已断开 \(device.displayName)"
            : "已断开应用连接；USB 数据线仍保持连接，可随时重新连接。"
        banner = message
        AppLog.write("disconnect serial=\(device.serial) kind=\(device.connection.rawValue) paused=true")
        return message
    }

    @discardableResult
    func connect(address: String) async -> String {
        let target = address.contains(":") ? address : "\(address):5555"
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await adb.run(["connect", target], timeout: 25)
            let text = result.messages.trimmed
            guard text.lowercased().contains("connected to") || text.lowercased().contains("already connected") else {
                banner = text.isEmpty ? "连接 \(target) 失败" : text
                return banner ?? "连接失败"
            }

            let unlockState = await isDeviceUnlocked(serial: target)
            guard unlockState == true else {
                connectionPaused = true
                if selectedSerial != target {
                    _ = try? await adb.run(["disconnect", target], timeout: 10)
                }
                await refresh()
                let message = unlockState == false
                    ? "手机尚未解锁，请先解锁手机再连接。"
                    : "无法确认手机解锁状态，已取消连接。请解锁后重试。"
                banner = message
                AppLog.write("wireless connect blocked target=\(target) unlocked=\(unlockState.map(String.init) ?? "unknown")")
                return message
            }

            connectionPaused = false
            settings.remember(address: target, name: target)
            savedDevices = settings.savedDevices
            await refresh()
            selectedSerial = devices.first(where: { $0.serial == target })?.serial ?? target
            let message = "已连接 \(target)"
            banner = message
            return message
        } catch {
            banner = error.localizedDescription
            return error.localizedDescription
        }
    }

    @discardableResult
    func pair(address: String, code: String) async -> String {
        let target = address.contains(":") ? address : "\(address):5555"
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await adb.run(["pair", target, code], timeout: 40)
            let text = result.messages.trimmed
            banner = text.isEmpty ? "配对请求已发送" : text
            return text
        } catch {
            banner = error.localizedDescription
            return error.localizedDescription
        }
    }

    @discardableResult
    func enableWireless(serial: String) async -> String {
        isBusy = true
        defer { isBusy = false }
        do {
            let tcpip = try await adb.run(["tcpip", "5555"], serial: serial, timeout: 20)
            guard tcpip.succeeded else {
                let message = tcpip.messages.trimmed
                banner = message
                return message
            }
            let ip = await wifiAddress(serial: serial)
            guard !ip.isEmpty else {
                let message = "已在 USB 连接上开启 5555 端口，但未读取到 Wi-Fi IP。请确认手机与 Mac 在同一网络。"
                banner = message
                return message
            }
            let address = "\(ip):5555"
            settings.remember(address: address, name: address)
            savedDevices = settings.savedDevices
            _ = try? await adb.run(["connect", address], timeout: 25)
            await refresh()
            let message = "无线调试已开启：\(address)。现在可以拔掉数据线。"
            banner = message
            return message
        } catch {
            banner = error.localizedDescription
            return error.localizedDescription
        }
    }

    func discoverServices() async {
        do {
            let result = try await adb.run(["mdns", "services"], timeout: 15)
            let lines = result.output.components(separatedBy: .newlines)
            var services: [DiscoveredService] = []
            for line in lines {
                let trimmed = line.trimmed
                guard trimmed.contains("_adb-tls-connect._tcp") || trimmed.contains("_adb._tcp") else { continue }
                let tokens = trimmed.split(separator: " ").map(String.init)
                guard let address = tokens.last, address.contains(":") else { continue }
                let name = tokens.dropLast().joined(separator: " ")
                services.append(DiscoveredService(name: name.isEmpty ? address : name, address: address))
            }
            discoveredServices = services
            if services.isEmpty {
                banner = "未发现无线调试服务。请确认手机与 Mac 在同一网络，并在开发者选项中开启无线调试。"
            }
        } catch {
            banner = error.localizedDescription
        }
    }

    func forget(_ device: SavedWirelessDevice) {
        settings.forget(device)
        savedDevices = settings.savedDevices
        if selectedSerial == device.address {
            selectedSerial = nil
        }
    }

    func takeScreenshot() async -> Data? {
        guard let serial = selectedDevice?.serial else { return nil }
        do {
            let result = try await adb.run(["exec-out", "screencap", "-p"], serial: serial, timeout: 30)
            guard result.succeeded, !result.stdout.isEmpty else { return nil }
            return result.stdout
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func setStayAwake(_ enabled: Bool, serial: String) async {
        _ = try? await adb.shell("svc power stayon \(enabled ? "usb" : "false")", serial: serial, timeout: 10)
    }

    private func wifiAddress(serial: String) async -> String {
        if let result = try? await adb.shell("ip -f inet addr show wlan0 2>/dev/null | grep 'inet '", serial: serial, timeout: 10),
           let ip = Self.ipv4(after: "inet ", in: result.output) {
            return ip
        }
        if let result = try? await adb.shell("ip route get 8.8.8.8 2>/dev/null", serial: serial, timeout: 10),
           let ip = Self.ipv4(after: "src ", in: result.output) {
            return ip
        }
        return ""
    }

    private static func ipv4(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        return firstIPv4(in: String(text[range.upperBound...]))
    }

    private static func firstIPv4(in text: String) -> String? {
        let pattern = #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }

    private func applyCachedNames() {
        guard !deviceNames.isEmpty else { return }
        for index in devices.indices {
            if let name = deviceNames[devices[index].serial] {
                devices[index].deviceName = name
            }
        }
    }

    private func fetchName(for device: AndroidDevice) async {
        guard nameFetching.insert(device.serial).inserted else { return }
        nameAttempted.insert(device.serial)
        defer { nameFetching.remove(device.serial) }
        let command = "settings get global device_name; getprop ro.product.marketname"
        guard let result = try? await adb.shell(command, serial: device.serial, timeout: 8),
              result.succeeded else { return }
        let candidates = result.output
            .components(separatedBy: .newlines)
            .map { $0.trimmed }
            .filter { !$0.isEmpty && $0.lowercased() != "null" && $0.lowercased() != "unknown" }
        guard let name = candidates.first else { return }
        deviceNames[device.serial] = name
        applyCachedNames()
        AppLog.write("device name serial=\(device.serial) name=\(name)")
    }

    static func parseDevices(_ output: String) -> [AndroidDevice] {
        var result: [AndroidDevice] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmed
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("List of devices"),
                  !trimmed.hasPrefix("*"),
                  !trimmed.hasPrefix("adb server") else { continue }
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 2 else { continue }
            let serial = tokens[0]
            let state = tokens[1]
            guard state == "device" || state == "unauthorized" || state == "offline" || state == "connecting" || state == "authorizing" else { continue }

            var props: [String: String] = [:]
            for token in tokens.dropFirst(2) {
                if let index = token.firstIndex(of: ":") {
                    props[String(token[..<index])] = String(token[token.index(after: index)...])
                }
            }
            let isUSB = props["usb"] != nil || serial.hasPrefix("usb:")
            let connection: AndroidDevice.Connection = (serial.contains(":") && !isUSB) ? .wifi : .usb
            result.append(AndroidDevice(
                serial: serial,
                state: state,
                model: props["model"] ?? "",
                product: props["product"] ?? "",
                device: props["device"] ?? "",
                connection: connection,
                transportID: props["transport_id"]
            ))
        }
        return result
    }

    private static func applyBattery(_ battery: String, to details: inout DeviceDetails) {
        for line in battery.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmed.lowercased()
            let value = String(parts[1]).trimmed
            let intValue = Int(value.filter { $0.isNumber || $0 == "-" })
            switch key {
            case "level":
                details.batteryLevel = intValue ?? details.batteryLevel
            case "status":
                details.batteryStatus = intValue ?? 0
            case "health":
                details.batteryHealth = intValue ?? 0
            case "voltage":
                details.batteryVoltageMV = intValue ?? 0
            case "temperature":
                if let value = intValue { details.batteryTemperatureC = Double(value) / 10.0 }
            case "charge counter":
                details.batteryChargeCounterUAh = intValue
            case "max charging voltage":
                if let value = intValue, value > 0 { details.batteryMaxChargingVoltageUV = value }
            case "technology":
                details.batteryTechnology = value
            case "ac powered":
                details.batteryACPowered = value.lowercased() == "true"
            case "usb powered":
                details.batteryUSBPowered = value.lowercased() == "true"
            case "wireless powered":
                details.batteryWirelessPowered = value.lowercased() == "true"
            default:
                break
            }
        }
        details.isCharging = details.batteryStatus == 2 || details.batteryStatus == 5
            || details.batteryACPowered || details.batteryUSBPowered || details.batteryWirelessPowered
    }

    static func parseDetails(_ output: String, fallbackName: String) -> DeviceDetails {
        let sections = output.components(separatedBy: "@@")
        func section(_ index: Int) -> String {
            guard index < sections.count else { return "" }
            return sections[index].trimmed
        }

        var details = DeviceDetails()
        details.manufacturer = section(0)
        details.model = section(1).isEmpty ? fallbackName : section(1)
        details.androidVersion = section(2)
        details.sdk = section(3)
        details.resolution = section(4)
            .replacingOccurrences(of: "Physical size:", with: "")
            .replacingOccurrences(of: "Override size:", with: "")
            .trimmed

        let storage = section(5).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if storage.count >= 4,
           let totalKB = Int64(storage[1]),
           let freeKB = Int64(storage[3]) {
            details.storageTotal = totalKB * 1024
            details.storageFree = freeKB * 1024
        }

        if let ip = ipv4(after: "inet ", in: section(6)) ?? firstIPv4(in: section(6)) {
            details.ipAddress = ip
        }
        return details
    }
}
