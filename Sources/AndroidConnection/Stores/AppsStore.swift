import Foundation
import AppKit

@MainActor
final class AppsStore: ObservableObject {
    let serial: String
    @Published private(set) var apps: [AndroidApp] = []
    @Published private(set) var isLoading = false
    @Published var query = ""
    @Published var showSystemApps = false
    @Published var statusMessage: String?
    @Published var lastError: String?
    @Published private(set) var busyPackage: String?

    private let adb = ADB.shared

    init(serial: String) {
        self.serial = serial
    }

    var filteredApps: [AndroidApp] {
        var list = apps
        if !showSystemApps {
            list = list.filter { !$0.isSystem }
        }
        let needle = query.trimmed.lowercased()
        if !needle.isEmpty {
            list = list.filter { $0.package.lowercased().contains(needle) || $0.displayName.lowercased().contains(needle) }
        }
        return list.sorted { $0.package.localizedStandardCompare($1.package) == .orderedAscending }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let argument = showSystemApps ? "pm list packages -f" : "pm list packages -f -3"
        do {
            let result = try await adb.shell(argument, serial: serial, timeout: 60)
            apps = Self.parsePackages(result.output)
            lastError = nil
            AppLog.write("apps count=\(apps.count) system=\(showSystemApps)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func launch(_ app: AndroidApp) async {
        busyPackage = app.package
        defer { busyPackage = nil }
        do {
            let result = try await adb.shell(
                "monkey -p \(ADB.quote(app.package)) -c android.intent.category.LAUNCHER 1",
                serial: serial,
                timeout: 30
            )
            let text = result.messages
            if text.contains("No activities found") {
                statusMessage = "该应用没有可启动的界面"
            } else if result.succeeded {
                statusMessage = "已在手机上启动 \(app.displayName)"
            } else {
                statusMessage = text.trimmed
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func forceStop(_ app: AndroidApp) async {
        busyPackage = app.package
        defer { busyPackage = nil }
        do {
            let result = try await adb.shell("am force-stop \(ADB.quote(app.package))", serial: serial, timeout: 30)
            statusMessage = result.succeeded ? "已停止 \(app.displayName)" : result.messages.trimmed
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func uninstall(_ app: AndroidApp) async {
        busyPackage = app.package
        defer { busyPackage = nil }
        do {
            let result = try await adb.shell("pm uninstall --user 0 \(ADB.quote(app.package))", serial: serial, timeout: 60)
            statusMessage = result.succeeded ? "已卸载 \(app.displayName)" : result.messages.trimmed
            await load()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func install(url: URL) async -> Bool {
        statusMessage = "正在安装 \(url.lastPathComponent)…"
        do {
            let result = try await adb.run(["install", "-r", "-g", url.path], serial: serial, timeout: 900)
            let text = result.messages
            let ok = result.succeeded && text.lowercased().contains("success")
            statusMessage = ok ? "已安装 \(url.lastPathComponent)" : text.trimmed
            if ok { await load() }
            return ok
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func exportAPK(_ app: AndroidApp) async {
        guard let path = app.apkPath, !path.isEmpty else {
            statusMessage = "无法定位该应用的 APK 路径"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(app.package).apk"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        statusMessage = "正在导出 APK…"
        do {
            let result = try await adb.run(["pull", path, url.path], serial: serial, timeout: 900)
            statusMessage = result.succeeded ? "已导出到 \(url.path)" : result.messages.trimmed
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func openOnPhone(website urlString: String) async {
        guard let url = URL(string: urlString), let scheme = url.scheme else { return }
        let command: String
        if scheme.lowercased() == "http" || scheme.lowercased() == "https" {
            command = "am start -a android.intent.action.VIEW -d \(ADB.quote(urlString))"
        } else {
            command = "am start -a android.intent.action.VIEW -d \(ADB.quote(urlString))"
        }
        _ = try? await adb.shell(command, serial: serial, timeout: 30)
    }

    static func parsePackages(_ output: String) -> [AndroidApp] {
        var result: [AndroidApp] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmed
            guard trimmed.hasPrefix("package:") else { continue }
            let body = trimmed.dropFirst("package:".count)
            var apkPath: String?
            var package = String(body)
            if body.contains("=") {
                let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
                apkPath = parts.first
                package = parts.count > 1 ? parts[1] : parts[0]
            }
            package = package.trimmed
            guard !package.isEmpty else { continue }
            let isSystem = apkPath?.contains("/system/") == true || apkPath?.contains("/product/") == true || apkPath?.contains("/vendor/") == true
            result.append(AndroidApp(package: package, apkPath: apkPath, isSystem: isSystem))
        }
        return result
    }
}
