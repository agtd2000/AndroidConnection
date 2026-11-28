import Foundation

/// Temporarily raises the phone's auto-lock timeout to ten minutes while a
/// device is connected. The user's original value is restored on disconnect
/// or application termination, so Android's own setting is not permanently
/// changed.
@MainActor
final class DeviceAwakeController {
    static let shared = DeviceAwakeController()

    private let adb = ADB.shared
    private let targetTimeout = 600_000

    private var serial: String?
    private var savedTimeout: String?
    private var changed = false
    private var generation = 0

    private init() {}

    func activate(serial newSerial: String) async {
        guard serial != newSerial else { return }
        generation += 1
        let token = generation
        await restoreInternal()
        guard token == generation else { return }

        serial = newSerial
        guard let current = await timeoutValue(serial: newSerial),
              let value = Int(current),
              value > 0,
              value < targetTimeout else {
            AppLog.write("awake: keep user timeout serial=\(newSerial)")
            return
        }

        savedTimeout = current
        let result = try? await adb.shell(
            "settings put system screen_off_timeout \(targetTimeout)",
            serial: newSerial,
            timeout: 8
        )
        changed = result?.succeeded == true
        AppLog.write("awake: timeout \(current)->\(targetTimeout) serial=\(newSerial) changed=\(changed)")
    }

    func restore() async {
        generation += 1
        await restoreInternal()
    }

    /// Synchronous fallback for `NSApplication.willTerminate`, where async adb
    /// work would not get a chance to run.
    func restoreNow() {
        generation += 1
        defer {
            serial = nil
            savedTimeout = nil
            changed = false
        }
        guard changed, let serial, let savedTimeout,
              let executable = adb.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-s", serial, "shell", "settings", "put", "system", "screen_off_timeout", savedTimeout]
        process.environment = ADB.environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            AppLog.write("awake: restored timeout=\(savedTimeout) serial=\(serial) status=\(process.terminationStatus)")
        } catch {
            AppLog.write("awake: restore failed \(error.localizedDescription)")
        }
    }

    private func restoreInternal() async {
        defer {
            serial = nil
            savedTimeout = nil
            changed = false
        }
        guard changed, let serial, let savedTimeout else { return }
        let result = try? await adb.shell(
            "settings put system screen_off_timeout \(savedTimeout)",
            serial: serial,
            timeout: 8
        )
        AppLog.write("awake: restored timeout=\(savedTimeout) serial=\(serial) ok=\(result?.succeeded == true)")
    }

    private func timeoutValue(serial: String) async -> String? {
        guard let result = try? await adb.shell(
            "settings get system screen_off_timeout",
            serial: serial,
            timeout: 8
        ), result.succeeded else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "null" ? nil : value
    }
}
