import Foundation
import Darwin

/// scrcpy video server connection.
///
/// Unlike `adb shell screenrecord`, scrcpy's video server streams an Annex-B
/// H.264 elementary stream with no 180-second limit and without MediaProjection
/// consent. Screen dimming is handled separately in `MirrorSession`; powering
/// the physical display down makes some devices return black frames and drop
/// injected touches.
@MainActor
final class ScrcpyVideo {
    var onData: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let adb = ADB.shared
    private let serial: String
    private let remoteJar = "/data/local/tmp/androidconnection-server.jar"

    private var stream: ADBStream?
    private var videoFD: Int32 = -1
    private var controlFD: Int32 = -1
    private var port = 0
    private var running = false
    private let writeLock = NSLock()

    init(serial: String) {
        self.serial = serial
    }

    var isRunning: Bool { running }

    func start(maxSize: Int?, bitrate: Int) async throws {
        guard !running else { return }
        setStatus("正在连接视频通道…")

        guard let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: "jar") else {
            throw VideoError.missingServer
        }
        let push = try await adb.run(["push", jar.path, remoteJar], serial: serial, timeout: 30)
        guard push.succeeded else { throw VideoError.message(push.messages.trimmed) }

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
        guard forward.succeeded else { throw VideoError.message(forward.messages.trimmed) }

        var options = [
            "video=true", "audio=false", "control=true",
            "video_codec=h264", "video_bit_rate=\(bitrate)",
            "send_device_meta=false", "send_frame_meta=false", "send_stream_meta=false",
            "send_dummy_byte=true", "tunnel_forward=true",
            "scid=\(hexScid)", "cleanup=false", "log_level=info"
        ]
        if let maxSize {
            options.append("max_size=\(maxSize)")
        }
        let command = "CLASSPATH=\(remoteJar) app_process / com.genymobile.scrcpy.Server 5.0.1 "
            + options.joined(separator: " ")
        stream = try adb.stream(
            arguments: ["shell", command],
            serial: serial,
            onData: { [weak self] data in
                guard let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { self?.setStatus(text.trimmed.isEmpty ? "视频服务运行中" : text.trimmed) }
            },
            onExit: { [weak self] code in
                DispatchQueue.main.async { self?.serverExited(code) }
            }
        )

        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let videoFD = connectToVideo() else {
            throw VideoError.connectFailed
        }

        var dummy: UInt8 = 0
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(videoFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard read(videoFD, &dummy, 1) == 1 else {
            close(videoFD)
            throw VideoError.connectFailed
        }
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(videoFD, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))

        // The control socket is the second connection accepted by the server.
        var controlFD: Int32?
        for _ in 0..<30 {
            if let fd = Self.connect(port: port) {
                controlFD = fd
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let controlFD else {
            close(videoFD)
            throw VideoError.connectFailed
        }

        self.videoFD = videoFD
        self.controlFD = controlFD
        running = true
        setStatus("视频已连接")
        AppLog.write("video start serial=\(serial) port=\(port) scid=\(hexScid) max=\(maxSize.map(String.init) ?? "native")")

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.readVideoLoop(videoFD)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.readControlLoop(controlFD)
        }
    }

    func stop() {
        running = false
        if videoFD >= 0 {
            shutdown(videoFD, SHUT_RDWR)
            close(videoFD)
            videoFD = -1
        }
        if controlFD >= 0 {
            shutdown(controlFD, SHUT_RDWR)
            close(controlFD)
            controlFD = -1
        }
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

    @discardableResult
    func setDisplayPowerMode(off: Bool) -> Bool {
        guard running, controlFD >= 0 else { return false }
        // scrcpy control message 10: 0 = OFF, 1 = NORMAL.
        return write(Data([10, off ? 0 : 1]), to: controlFD)
    }

    @discardableResult
    func rotate() -> Bool {
        guard running, controlFD >= 0 else { return false }
        return write(Data([11]), to: controlFD)
    }

    private func readVideoLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            onData?(Data(buffer[0..<count]))
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            AppLog.write("video read ended stderr=\((self.stream?.stderrText ?? "").suffix(300))")
            self.onStatus?("视频通道已断开")
            self.stop()
            self.onExit?(0)
        }
    }

    private func readControlLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            // Control messages from the device are not needed here; the
            // clipboard channel has its own reader.
        }
    }

    private func serverExited(_ code: Int32) {
        guard running else { return }
        AppLog.write("video server exit code=\(code) stderr=\((stream?.stderrText ?? "").suffix(300))")
        onStatus?("视频服务已退出（\(code)）")
        stop()
        onExit?(code)
    }

    private func write(_ data: Data, to fd: Int32) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private func connectToVideo() -> Int32? {
        for _ in 0..<80 {
            if let fd = Self.connect(port: port) {
                return fd
            }
            usleep(100_000)
        }
        return nil
    }

    private func setStatus(_ text: String) {
        onStatus?(text)
    }

    private static func reservePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VideoError.connectFailed }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0 else { throw VideoError.connectFailed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }) == 0 else { throw VideoError.connectFailed }
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

private enum VideoError: LocalizedError {
    case missingServer
    case connectFailed
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingServer: return "应用包内缺少视频服务端"
        case .connectFailed: return "无法连接视频通道"
        case .message(let text): return text.isEmpty ? "视频服务启动失败" : text
        }
    }
}
