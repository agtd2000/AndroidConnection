import Foundation
import Darwin

/// Minimal scrcpy control channel used for clipboard synchronization and
/// Unicode text insertion. The Android clipboard service is accessed by the
/// scrcpy server with shell privileges, which bypasses the Android 10+
/// background-clipboard restriction for the desktop app.
@MainActor
final class ScrcpyControl {
    var onStatus: ((String) -> Void)?
    var onClipboard: ((String) -> Void)?

    private let adb = ADB.shared
    private let serial: String
    private let remoteJar = "/data/local/tmp/androidconnection-server.jar"

    private var stream: ADBStream?
    private var socketFD: Int32 = -1
    private var port: Int = 0
    private var running = false
    private var starting = false
    private var intentionallyStopped = false
    private var retryCount = 0
    private var restartTask: Task<Void, Never>?
    private var readBuffer: [UInt8] = []
    private var pollTask: Task<Void, Never>?
    private var lastClipboard: String?
    private let writeLock = NSLock()
    private var wakeTick = 0

    /// Set by `MirrorSession` for USB sessions. Xiaomi can sleep the panel even
    /// with `stay_on_while_plugged_in` set; a periodic no-op WAKEUP keeps the
    /// USB ADB transport alive without changing the user's screen timeout.
    var keepsUSBWake = false

    init(serial: String) {
        self.serial = serial
    }

    var isRunning: Bool { running }

    /// scrcpy control message 10: set display power mode.
    /// OFF keeps SurfaceFlinger composing the virtual display while the
    /// physical panel is powered down, so video and touch injection continue.
    @discardableResult
    func setDisplayPowerMode(off: Bool) -> Bool {
        guard running, socketFD >= 0 else { return false }
        return write(Data([10, off ? 0 : 1]))
    }

    func start() async {
        guard !running, !starting else { return }
        starting = true
        intentionallyStopped = false
        defer { starting = false }
        setStatus("正在连接控制通道…")

        do {
            guard let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: "jar") else {
                throw ControlError.missingServer
            }
            let push = try await adb.run(["push", jar.path, remoteJar], serial: serial, timeout: 30)
            guard push.succeeded else { throw ControlError.message(push.messages.trimmed) }

            let scid = Int.random(in: 1...0x7FFF_FFFF)
            let hexScid = String(scid, radix: 16)
            let socketName = String(format: "scrcpy_%08x", scid)
            port = try Self.reservePort()
            _ = try? await adb.run(["forward", "--remove", "tcp:\(port)"], serial: serial, timeout: 8)
            let forward = try await adb.run(
                ["forward", "tcp:\(port)", "localabstract:\(socketName)"],
                serial: serial,
                timeout: 10
            )
            guard forward.succeeded else { throw ControlError.message(forward.messages.trimmed) }

            let command = "CLASSPATH=\(remoteJar) app_process / com.genymobile.scrcpy.Server 5.0.1 "
                + "video=false audio=false control=true clipboard_autosync=false "
                + "send_device_meta=false send_dummy_byte=true tunnel_forward=true "
                + "scid=\(hexScid) cleanup=false log_level=info"
            stream = try adb.stream(
                arguments: ["shell", command],
                serial: serial,
                onData: { _ in },
                onExit: { [weak self] code in
                    DispatchQueue.main.async { self?.serverExited(code) }
                }
            )

            try? await Task.sleep(nanoseconds: 1_000_000_000)

            var connected: Int32?
            for _ in 0..<40 {
                if let fd = Self.connect(port: port) {
                    connected = fd
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let fd = connected else { throw ControlError.connectFailed }

            var dummy: UInt8 = 0
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard read(fd, &dummy, 1) == 1 else {
                close(fd)
                throw ControlError.connectFailed
            }
            var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
            socketFD = fd
            running = true
            retryCount = 0
            setStatus("剪贴板已同步")
            AppLog.write("control start serial=\(serial) port=\(port) scid=\(hexScid)")

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.readLoop(fd)
            }
            startPolling()
            requestClipboard()
        } catch {
            setStatus("控制通道不可用：\(error.localizedDescription)")
            teardown()
            scheduleRetry()
        }
    }

    func stop() {
        intentionallyStopped = true
        restartTask?.cancel()
        restartTask = nil
        teardown()
        setStatus("控制通道已关闭")
    }

    @discardableResult
    func setClipboard(_ text: String, paste: Bool) -> Bool {
        guard running, socketFD >= 0 else { return false }
        var bytes = Array(text.utf8.prefix(240_000))
        var message = Data([9])
        message.append(contentsOf: Self.bigEndianBytes(UInt64(0)))
        message.append(paste ? 1 : 0)
        message.append(contentsOf: Self.bigEndianBytes(UInt32(bytes.count)))
        message.append(contentsOf: bytes)
        bytes.removeAll(keepingCapacity: false)
        return write(message)
    }

    func requestClipboard() {
        guard running else { return }
        _ = write(Data([8, 0]))
    }

    // MARK: - Control protocol

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self, self.running else { return }
                self.requestClipboard()
                if self.keepsUSBWake, !self.serial.contains(":") {
                    self.wakeTick += 1
                    if self.wakeTick % 8 == 0 {
                        // A no-op shell round-trip keeps the USB transport
                        // active. Do not inject WAKEUP here: it would turn the
                        // panel back on while the user requested screen-off.
                        _ = try? await self.adb.shell("true", serial: self.serial, timeout: 5)
                    }
                }
            }
        }
    }

    private nonisolated func readLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            let chunk = Array(buffer[0..<count])
            DispatchQueue.main.async { [weak self] in
                self?.consume(chunk)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.readEnded()
        }
    }

    private func consume(_ chunk: [UInt8]) {
        guard running else { return }
        readBuffer.append(contentsOf: chunk)
        while !readBuffer.isEmpty {
            let type = readBuffer[0]
            switch type {
            case 0: // clipboard: type + int32 length + UTF-8
                guard readBuffer.count >= 5 else { return }
                let length = Int(Self.readUInt32(readBuffer, at: 1))
                guard length <= 256 * 1024, readBuffer.count >= 5 + length else { return }
                let text = String(decoding: readBuffer[5..<(5 + length)], as: UTF8.self)
                readBuffer.removeFirst(5 + length)
                if text != lastClipboard {
                    lastClipboard = text
                    onClipboard?(text)
                }
            case 1: // clipboard acknowledgement: type + int64 sequence
                guard readBuffer.count >= 9 else { return }
                readBuffer.removeFirst(9)
            case 2: // UHID output: type + int16 id + int16 length + data
                guard readBuffer.count >= 5 else { return }
                let length = Int(Self.readUInt16(readBuffer, at: 3))
                guard readBuffer.count >= 5 + length else { return }
                readBuffer.removeFirst(5 + length)
            default:
                readBuffer.removeAll(keepingCapacity: true)
                return
            }
        }
    }

    private func readEnded() {
        guard running else { return }
        AppLog.write("control read ended stderr=\((stream?.stderrText ?? "").suffix(200))")
        setStatus("控制通道已断开")
        teardown()
        scheduleRetry()
    }

    private func serverExited(_ code: Int32) {
        guard running else { return }
        AppLog.write("control server exit code=\(code) stderr=\((stream?.stderrText ?? "").suffix(200))")
        setStatus("控制通道已断开（\(code)）")
        teardown()
        scheduleRetry()
    }

    private func write(_ data: Data) -> Bool {
        guard socketFD >= 0 else { return false }
        writeLock.lock()
        defer { writeLock.unlock() }
        var offset = 0
        let result = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < data.count {
                let written = Darwin.write(socketFD, base.advanced(by: offset), data.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        return result
    }

    private func scheduleRetry() {
        guard !intentionallyStopped, retryCount < 4, restartTask == nil else { return }
        retryCount += 1
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            await self.start()
        }
    }

    private func teardown() {
        running = false
        pollTask?.cancel()
        pollTask = nil
        if socketFD >= 0 {
            shutdown(socketFD, SHUT_RDWR)
            close(socketFD)
            socketFD = -1
        }
        readBuffer.removeAll(keepingCapacity: false)
        stream?.stop()
        stream = nil
        if port > 0 {
            let stalePort = port
            port = 0
            Task { [adb, serial] in
                _ = try? await adb.run(["forward", "--remove", "tcp:\(stalePort)"], serial: serial, timeout: 8)
            }
        }
    }

    private func setStatus(_ text: String) {
        onStatus?(text)
    }

    private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24) | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8) | UInt32(bytes[index + 3])
    }

    private static func readUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
    }

    private static func reservePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.connectFailed }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw ControlError.connectFailed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw ControlError.connectFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func connect(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            close(fd)
            return nil
        }
        return fd
    }
}

private enum ControlError: LocalizedError {
    case missingServer
    case connectFailed
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingServer: return "应用包内缺少控制服务端"
        case .connectFailed: return "无法连接控制通道"
        case .message(let text): return text.isEmpty ? "控制通道启动失败" : text
        }
    }
}
