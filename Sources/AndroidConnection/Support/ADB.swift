import Foundation
import Darwin

enum ADBError: LocalizedError {
    case notFound
    case launchFailed(String)
    case timedOut(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "未找到 adb。请确认应用包内包含 adb，或安装 Android Platform Tools。"
        case .launchFailed(let message):
            return "无法启动 adb：\(message)"
        case .timedOut(let command):
            return "adb 命令超时：\(command)"
        case .failed(let message):
            return message
        }
    }
}

struct ADBResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var output: String { String(decoding: stdout, as: UTF8.self) }
    var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
    var succeeded: Bool { status == 0 }

    var messages: String {
        let err = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? output : output + "\n" + err
    }
}

/// Thin wrapper around the bundled Android Debug Bridge.
final class ADB {
    static let shared = ADB()

    /// AndroidConnection defaults to 5037 but can use a spare port (5038+)
    /// when 5037 is occupied by another tool.
    private static let portLock = NSLock()
    private static var _serverPort = ProcessInfo.processInfo.environment["ANDROIDCONNECTION_ADB_PORT"] ?? "5037"

    static var serverPort: String {
        portLock.lock()
        defer { portLock.unlock() }
        return _serverPort
    }

    static func setServerPort(_ port: Int) {
        guard (1...65535).contains(port) else { return }
        portLock.lock()
        _serverPort = String(port)
        portLock.unlock()
    }

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_ADB_SERVER_PORT"] = serverPort
        return environment
    }

    let executableURL: URL?

    private init() {
        executableURL = ADB.locateADB()
    }

    static func locateADB() -> URL? {
        var candidates: [URL] = []
        if let custom = ProcessInfo.processInfo.environment["ANDROIDCONNECTION_ADB"], !custom.isEmpty {
            candidates.append(URL(fileURLWithPath: custom))
        }
        if let bundled = Bundle.main.url(forResource: "adb", withExtension: nil) {
            candidates.append(bundled)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("adb"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/adb"))
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Vendor/adb"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/adb"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/adb"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func run(_ arguments: [String], serial: String? = nil, timeout: TimeInterval = 60) async throws -> ADBResult {
        guard let executableURL else { throw ADBError.notFound }
        var args = arguments
        if let serial, !serial.isEmpty {
            args = ["-s", serial] + args
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try ADB.runBlocking(executable: executableURL, arguments: args, timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    func shell(_ command: String, serial: String? = nil, timeout: TimeInterval = 60) async throws -> ADBResult {
        try await run(["shell", command], serial: serial, timeout: timeout)
    }

    func startServer() async throws {
        _ = try await run(["start-server"], timeout: 20)
    }

    func restartServer() async throws {
        _ = try await run(["kill-server"], timeout: 10)
        _ = try await run(["start-server"], timeout: 20)
    }

    func stream(arguments: [String],
                serial: String? = nil,
                onData: ((Data) -> Void)? = nil,
                onExit: ((Int32) -> Void)? = nil) throws -> ADBStream {
        guard let executableURL else { throw ADBError.notFound }
        var args = arguments
        if let serial, !serial.isEmpty {
            args = ["-s", serial] + args
        }
        return try ADBStream(executable: executableURL, arguments: args, onData: onData, onExit: onExit)
    }

    private static func runBlocking(executable: URL, arguments: [String], timeout: TimeInterval) throws -> ADBResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ADB.environment()
        process.standardInput = FileHandle.nullDevice

        // Stream captured output to temporary files instead of pipes. With an
        // unbounded pipe reader a timed-out adb child can leave the reader
        // blocked forever if a descendant inherited the descriptor, which in
        // turn leaves the calling task stuck. Files make the timeout path
        // deterministic and also avoid pipe-buffer deadlocks on large output.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidconnection-adb-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let outURL = tempDir.appendingPathComponent("stdout")
        let errURL = tempDir.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            throw ADBError.launchFailed("无法创建 adb 临时输出文件")
        }
        process.standardOutput = outHandle
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            throw ADBError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }

        var didTimeout = false
        if process.isRunning {
            didTimeout = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        try? outHandle.close()
        try? errHandle.close()
        process.waitUntilExit()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        if didTimeout {
            throw ADBError.timedOut(arguments.joined(separator: " "))
        }
        return ADBResult(status: process.terminationStatus, stdout: outData, stderr: errData)
    }

    /// Quotes a value for the device shell.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes text for `input text` (spaces must be sent as %s).
    static func escapeInputText(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "%", with: "%25")
        escaped = escaped.replacingOccurrences(of: " ", with: "%s")
        return escaped
    }
}

/// A long-running adb process whose stdout is streamed (used by scrcpy video/audio).
final class ADBStream {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stderrBuffer = Data()

    var onData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    private(set) var isRunning = false
    private let executableURL: URL
    private let arguments: [String]

    init(executable: URL,
         arguments: [String],
         onData: ((Data) -> Void)? = nil,
         onExit: ((Int32) -> Void)? = nil) throws {
        self.executableURL = executable
        self.arguments = arguments
        self.onData = onData
        self.onExit = onExit
        try start()
    }

    func start() throws {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ADB.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.onData?(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.lock.lock()
            if self.stderrBuffer.count < 64 * 1024 {
                self.stderrBuffer.append(data)
            }
            self.lock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.isRunning = false
            self.onExit?(proc.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw ADBError.launchFailed(error.localizedDescription)
        }
        isRunning = true
    }

    var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
    }
}
