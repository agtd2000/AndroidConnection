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
    private var savedStayOn: String?
    private var changedTimeout = false
    private var changedStayOn = false
    private var generation = 0

    private init() {}

    func activate(serial newSerial: String) async {
        guard serial != newSerial else { return }
        generation += 1
        let token = generation
        await restoreInternal()
        guard token == generation else { return }

        serial = newSerial
        if let current = await timeoutValue(serial: newSerial),
           let value = Int(current),
           value > 0,
           value < targetTimeout {
            savedTimeout = current
            let result = try? await adb.shell(
                "settings put system screen_off_timeout \(targetTimeout)",
                serial: newSerial,
                timeout: 8
            )
            changedTimeout = result?.succeeded == true
        }

        // A pre-existing `stay_on_while_plugged_in` (often left by other
        // scrcpy tools) would keep the panel awake forever and defeat the
        // ten-minute timeout. Disable it only for this connection and restore
        // the user's value afterwards.
        if let stay = await globalValue("stay_on_while_plugged_in", serial: newSerial), stay != "0" {
            savedStayOn = stay
            let stayResult = try? await adb.shell(
                "settings put global stay_on_while_plugged_in 0",
                serial: newSerial,
                timeout: 8
            )
            changedStayOn = stayResult?.succeeded == true
        }
        AppLog.write("awake: timeout=\(savedTimeout ?? "unchanged") stayOn=\(savedStayOn ?? "unchanged") serial=\(newSerial)")
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
            savedStayOn = nil
            changedTimeout = false
            changedStayOn = false
        }
        guard let serial, let executable = adb.executableURL else { return }
        func run(_ arguments: [String]) -> Int32? {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-s", serial, "shell"] + arguments
            process.environment = ADB.environment()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return nil
            }
        }
        if changedTimeout, let savedTimeout {
            _ = run(["settings", "put", "system", "screen_off_timeout", savedTimeout])
        }
        if changedStayOn, let savedStayOn {
            _ = run(["settings", "put", "global", "stay_on_while_plugged_in", savedStayOn])
        }
        AppLog.write("awake: restorer timeout=\(savedTimeout ?? "-") stayOn=\(savedStayOn ?? "-") serial=\(serial)")
    }

    private func restoreInternal() async {
        defer {
            serial = nil
            savedTimeout = nil
            savedStayOn = nil
            changedTimeout = false
            changedStayOn = false
        }
        guard let serial else { return }
        if changedTimeout, let savedTimeout {
            _ = try? await adb.shell(
                "settings put system screen_off_timeout \(savedTimeout)",
                serial: serial,
                timeout: 8
            )
        }
        if changedStayOn, let savedStayOn {
            _ = try? await adb.shell(
                "settings put global stay_on_while_plugged_in \(savedStayOn)",
                serial: serial,
                timeout: 8
            )
        }
        AppLog.write("awake: restored timeout=\(savedTimeout ?? "-") stayOn=\(savedStayOn ?? "-") serial=\(serial)")
    }

    private func globalValue(_ key: String, serial: String) async -> String? {
        guard let result = try? await adb.shell(
            "settings get global \(key)",
            serial: serial,
            timeout: 8
        ), result.succeeded else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "null" ? nil : value
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
