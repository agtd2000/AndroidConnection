import Foundation
import AppKit

@MainActor
final class ClipboardStore: ObservableObject {
    let serial: String
    @Published var outgoingText = ""
    @Published private(set) var incomingText = ""
    @Published var statusMessage: String?
    @Published var autoSync = false {
        didSet {
            autoSync ? startMonitor() : stopMonitor()
            if autoSync { statusMessage = "已开启 Mac → 手机自动发送（仅在手机有输入焦点时生效）" }
        }
    }
    @Published private(set) var history: [String] = []

    private let adb = ADB.shared
    private let settings: SettingsStore
    private let control: ScrcpyControl?
    private var monitorTask: Task<Void, Never>?
    private var lastChangeCount = NSPasteboard.general.changeCount

    init(serial: String, settings: SettingsStore, control: ScrcpyControl? = nil) {
        self.serial = serial
        self.settings = settings
        self.control = control
        control?.onClipboard = { [weak self] text in
            self?.handleIncomingClipboard(text)
        }
        control?.onStatus = { [weak self] text in
            self?.statusMessage = text
        }
    }

    deinit {
        monitorTask?.cancel()
    }

    func send(_ text: String? = nil) async {
        let value = (text ?? outgoingText).trimmed
        guard !value.isEmpty else { return }

        // Unicode (Chinese, emoji) cannot be sent by `input text`; use the
        // scrcpy controller to place it on the device clipboard and paste it
        // into the focused field. ASCII keeps the lighter key-event path.
        if value.unicodeScalars.contains(where: { $0.value > 127 }) {
            guard let control, control.setClipboard(value, paste: true) else {
                statusMessage = "控制通道尚未就绪，暂时无法发送中文或 emoji"
                return
            }
            statusMessage = "已通过控制通道粘贴到手机（支持中文与 emoji）"
            remember(value)
            return
        }

        do {
            let escaped = ADB.escapeInputText(value)
            let result = try await adb.shell("input text \(ADB.quote(escaped))", serial: serial, timeout: 20)
            if result.succeeded {
                statusMessage = "已发送到手机输入框"
                remember(value)
            } else {
                statusMessage = result.messages.trimmed
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func fetchIncoming() async {
        if let control, control.isRunning {
            control.requestClipboard()
            statusMessage = "正在通过控制通道读取手机剪贴板…"
            return
        }
        let commands = ["cmd clipboard get", "dumpsys clipboard"]
        for command in commands {
            guard let result = try? await adb.shell(command, serial: serial, timeout: 15) else { continue }
            let output = result.output.trimmed
            guard result.succeeded, !output.isEmpty else { continue }
            if output.contains("No shell command implementation") || output.contains("Unknown command") {
                continue
            }
            incomingText = output
            statusMessage = "已读取手机剪贴板"
            return
        }
        statusMessage = "Android 10 及以上限制后台读取剪贴板。可先在手机端复制，再粘贴到任意输入框后使用“发送到 Mac”。"
    }

    func copyIncomingToMac() {
        guard !incomingText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(incomingText, forType: .string)
        statusMessage = "已复制到 Mac 剪贴板"
    }

    func copyOutgoingFromMac() {
        if let string = NSPasteboard.general.string(forType: .string), !string.isEmpty {
            outgoingText = string
            statusMessage = "已从 Mac 剪贴板粘贴"
        }
    }

    func openLinkOnPhone(_ link: String) async {
        let trimmed = link.trimmed
        guard URL(string: trimmed) != nil else { return }
        let command = "am start -a android.intent.action.VIEW -d \(ADB.quote(trimmed))"
        do {
            let result = try await adb.shell(command, serial: serial, timeout: 30)
            statusMessage = result.succeeded ? "已在手机上打开链接" : result.messages.trimmed
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    var detectedLinks: [String] {
        let sources = [outgoingText, incomingText, NSPasteboard.general.string(forType: .string) ?? ""]
        var seen = Set<String>()
        var links: [String] = []
        let pattern = #"https?://[^\s"'<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for source in sources {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) {
                guard let matchRange = Range(match.range, in: source) else { continue }
                let link = String(source[matchRange])
                if seen.insert(link).inserted {
                    links.append(link)
                }
            }
        }
        return links
    }

    private func handleIncomingClipboard(_ text: String) {
        guard !text.isEmpty, text != incomingText else { return }
        incomingText = text
        remember(text)
        if settings.syncDeviceClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            statusMessage = "已同步手机剪贴板到 Mac"
        } else {
            statusMessage = "已读取手机剪贴板"
        }
    }

    private func remember(_ value: String) {
        history.removeAll { $0 == value }
        history.insert(value, at: 0)
        if history.count > 8 { history.removeLast(history.count - 8) }
    }

    private func startMonitor() {
        stopMonitor()
        lastChangeCount = NSPasteboard.general.changeCount
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard let self, self.autoSync else { continue }
                let pasteboard = NSPasteboard.general
                if pasteboard.changeCount != self.lastChangeCount {
                    self.lastChangeCount = pasteboard.changeCount
                    if let value = pasteboard.string(forType: .string), !value.isEmpty {
                        await self.send(value)
                    }
                }
            }
        }
    }

    private func stopMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }
}
