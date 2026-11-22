import Foundation
import AVFoundation
import Darwin

/// Streams device playback audio to the Mac.
///
/// The bundled scrcpy server captures the Android audio mix and exposes it as
/// raw 48 kHz / stereo / 16-bit PCM over an abstract socket. `adb forward`
/// bridges that socket to a local TCP port, which we read and feed into
/// AVAudioEngine. No Opus/AAC decoder is required.
@MainActor
final class AudioForwarder {
    var onStatus: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let adb = ADB.shared
    private let serial: String
    private let remoteJar = "/data/local/tmp/androidconnection-server.jar"

    private var stream: ADBStream?
    private var socketFD: Int32 = -1
    private var port: Int = 0
    private var running = false
    private var remainder = Data()
    private var lastLevelUpdate = Date.distantPast
    private var reportedFirstAudio = false
    private var serverLog = ""

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var format: AVAudioFormat?
    private var diagnosticFile: AVAudioFile?
    private let ring = AudioRingBuffer(capacitySeconds: 2.0, sampleRate: 48_000, channels: 2)

    init(serial: String) {
        self.serial = serial
    }

    func start() async {
        guard !running else { return }
        setStatus("正在准备音频…")

        do {
            let sdkResult = try? await adb.shell("getprop ro.build.version.sdk", serial: serial, timeout: 8)
            if let sdkText = sdkResult?.output.trimmed, let sdk = Int(sdkText), sdk < 33 {
                throw AudioError.unsupported
            }

            guard let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: "jar") else {
                throw AudioError.missingServer
            }
            let push = try await adb.run(["push", jar.path, remoteJar], serial: serial, timeout: 30)
            guard push.succeeded else {
                throw AudioError.message(push.messages.trimmed)
            }

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
            guard forward.succeeded else {
                throw AudioError.message(forward.messages.trimmed)
            }

            // scid is parsed as hexadecimal by the server; the abstract socket
            // name is scrcpy_<scid as 8 hex digits>.
            let command = "CLASSPATH=\(remoteJar) app_process / com.genymobile.scrcpy.Server 5.0.1 "
                + "audio=true video=false control=false audio_codec=raw "
                + "send_device_meta=false send_frame_meta=false send_stream_meta=false send_dummy_byte=true "
                + "tunnel_forward=true scid=\(hexScid) cleanup=false log_level=info audio_source=output"
            stream = try adb.stream(
                arguments: ["shell", command],
                serial: serial,
                onData: { [weak self] data in
                    guard let text = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.serverLog += text
                        if self.serverLog.count > 8_000 {
                            self.serverLog = String(self.serverLog.suffix(6_000))
                        }
                    }
                },
                onExit: { [weak self] code in
                    DispatchQueue.main.async { self?.serverExited(code) }
                }
            )

            // The server needs a moment to create its abstract socket. Connecting
            // to adb forward too early yields a TCP connection that is closed
            // before the server accepts it.
            try? await Task.sleep(nanoseconds: 800_000_000)

            var connected: Int32?
            for _ in 0..<80 {
                if let fd = Self.connect(port: port) {
                    connected = fd
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let fd = connected else {
                throw AudioError.connectFailed
            }
            // Consume the single dummy byte written once the server has
            // accepted the audio socket. This validates the connection.
            var dummy: UInt8 = 0
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard read(fd, &dummy, 1) == 1 else {
                close(fd)
                throw AudioError.connectFailed
            }
            var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
            socketFD = fd

            try startEngine()
            running = true
            setStatus("音频已开启")
            AppLog.write("audio start serial=\(serial) port=\(port) scid=\(hexScid) push=\(push.output.trimmed)")
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.readLoop(fd)
            }
        } catch {
            setStatus("音频不可用：\(error.localizedDescription)")
            teardown()
        }
    }

    func stop() {
        stopDiagnosticRecording()
        setStatus("音频已关闭")
        teardown()
    }

    /// Diagnostic-only tap used by the command-line audio self-test.
    func startDiagnosticRecording(to url: URL) {
        guard let engine, let format else { return }
        stopDiagnosticRecording()
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return }
        diagnosticFile = file
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            try? file.write(from: buffer)
        }
    }

    func stopDiagnosticRecording() {
        guard let engine, diagnosticFile != nil else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        diagnosticFile = nil
    }

    // MARK: - Audio pipeline

    private func startEngine() throws {
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioError.engineFailed("无法创建 48 kHz 立体声格式")
        }

        // A source node pulls PCM at the exact hardware render rate. Unlike
        // scheduleBuffer(), it cannot build up a queue or play bursts faster
        // than real time, which was the cause of the accelerated audio.
        ring.clear()
        let ring = self.ring
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            ring.render(into: audioBufferList, frameCount: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        self.sourceNode = source
        self.format = format
        AppLog.write("audio engine output=\(engine.outputNode.outputFormat(forBus: 0).sampleRate)Hz mix=\(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)Hz")
    }

    private nonisolated func readLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            let data = Data(buffer[0..<count])
            DispatchQueue.main.async { [weak self] in
                self?.consume(data)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.readEnded()
        }
    }

    private func consume(_ data: Data) {
        guard running, format != nil else { return }
        remainder.append(data)

        let bytesPerFrame = 4 // stereo Int16
        let frames = remainder.count / bytesPerFrame
        guard frames > 0 else { return }

        let sampleCount = frames * 2
        let samples = remainder.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self).prefix(sampleCount))
        }
        remainder.removeFirst(frames * bytesPerFrame)
        if remainder.count > 64 * 1024 {
            remainder.removeAll(keepingCapacity: true)
        }

        var floats = [Float](repeating: 0, count: frames * 2)
        var sum: Double = 0
        for index in 0..<frames {
            let left = Float(samples[index * 2]) / 32_768
            let right = Float(samples[index * 2 + 1]) / 32_768
            floats[index * 2] = left
            floats[index * 2 + 1] = right
            sum += Double(left * left + right * right)
        }
        ring.append(floats)

        let rms = sqrt(sum / Double(frames * 2))
        if !reportedFirstAudio, rms > 0.001 {
            reportedFirstAudio = true
            AppLog.write("audio first samples serial=\(serial) rms=\(String(format: "%.4f", rms))")
        }
        if Date().timeIntervalSince(lastLevelUpdate) > 0.08 {
            lastLevelUpdate = Date()
            onLevel?(Float(min(1, rms / 0.35)))
        }
    }

    private func readEnded() {
        guard running else { return }
        AppLog.write("audio read ended running=\(stream?.isRunning ?? false) stderr=\((stream?.stderrText ?? "").suffix(300)) serverLog=\(serverLog.suffix(300))")
        setStatus("音频通道已断开")
        teardown()
    }

    private func serverExited(_ code: Int32) {
        guard running else { return }
        let detail = stream?.stderrText.trimmed ?? ""
        AppLog.write("audio server exit code=\(code) stderr=\(detail.prefix(160)) out=\(serverLog.suffix(400))")
        setStatus("音频通道已断开（\(code)）")
        teardown()
    }

    private func teardown() {
        running = false
        if socketFD >= 0 {
            shutdown(socketFD, SHUT_RDWR)
            close(socketFD)
            socketFD = -1
        }
        engine?.stop()
        engine = nil
        sourceNode = nil
        format = nil
        ring.clear()
        remainder.removeAll(keepingCapacity: false)
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

    // MARK: - Local socket helpers

    private static func reservePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AudioError.connectFailed }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw AudioError.connectFailed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else { throw AudioError.connectFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func connect(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            close(fd)
            return nil
        }
        return fd
    }
}

/// Lock-protected stereo float ring buffer consumed by the audio render thread.
/// It deliberately drops the oldest samples if the network bursts, keeping
/// latency bounded instead of playing stale audio faster to catch up.
private final class AudioRingBuffer {
    private var storage: [Float] = []
    private var head = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacitySeconds: Double, sampleRate: Int, channels: Int) {
        capacity = Int(capacitySeconds * Double(sampleRate)) * channels
        storage.reserveCapacity(capacity)
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        storage.append(contentsOf: samples)
        compactIfNeeded()
    }

    func clear() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        head = 0
        lock.unlock()
    }

    func render(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return }

        let left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
        let right = buffers.count > 1
            ? buffers[1].mData?.assumingMemoryBound(to: Float.self)
            : left

        lock.lock()
        defer { lock.unlock() }
        for frame in 0..<frameCount {
            var l: Float = 0
            var r: Float = 0
            if head + 1 < storage.count {
                l = storage[head]
                r = storage[head + 1]
                head += 2
            }
            left?[frame] = l
            right?[frame] = r
        }
        compactIfNeeded()
    }

    private func compactIfNeeded() {
        if head >= capacity {
            storage.removeFirst(head)
            head = 0
        } else if storage.count - head > capacity {
            storage.removeFirst(storage.count - head - capacity)
            head = 0
        }
    }
}

private enum AudioError: LocalizedError {
    case unsupported
    case missingServer
    case connectFailed
    case engineFailed(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "需要 Android 13 或更高版本才能捕获设备播放音频"
        case .missingServer:
            return "应用包内缺少音频服务端"
        case .connectFailed:
            return "无法连接本机音频端口"
        case .engineFailed(let text):
            return "音频输出启动失败：\(text)"
        case .message(let text):
            return text.isEmpty ? "音频服务启动失败" : text
        }
    }
}
