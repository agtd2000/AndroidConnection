import Foundation
import AppKit

@MainActor
final class FilesStore: ObservableObject {
    enum SortField: String, CaseIterable, Identifiable {
        case name
        case size
        case modified

        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return "名称"
            case .size: return "大小"
            case .modified: return "修改时间"
            }
        }
    }

    let serial: String
    @Published var currentPath: String = "/sdcard"
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var selection: Set<String> = []
    @Published var searchText = ""
    @Published var showHidden: Bool
    @Published var sortField: SortField = .name
    @Published var sortAscending = true
    @Published private(set) var isTransferring = false

    private let adb = ADB.shared
    private let settings: SettingsStore

    init(serial: String, settings: SettingsStore) {
        self.serial = serial
        self.settings = settings
        self.showHidden = !settings.hideDotFiles
    }

    var filteredItems: [FileItem] {
        var list = items
        if !showHidden {
            list = list.filter { !$0.name.hasPrefix(".") }
        }
        let query = searchText.trimmed.lowercased()
        if !query.isEmpty {
            list = list.filter { $0.name.lowercased().contains(query) }
        }
        list.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch sortField {
            case .name:
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            case .size:
                return sortAscending ? lhs.size < rhs.size : lhs.size > rhs.size
            case .modified:
                let l = lhs.modified ?? .distantPast
                let r = rhs.modified ?? .distantPast
                return sortAscending ? l < r : l > r
            }
        }
        return list
    }

    var selectedItems: [FileItem] {
        filteredItems.filter { selection.contains($0.id) }
    }

    var breadcrumbs: [(String, String)] {
        guard currentPath != "/" else { return [("/", "根目录")] }
        var parts: [(String, String)] = [("/", "根目录")]
        var accumulated = ""
        for component in currentPath.split(separator: "/") {
            accumulated += "/" + component
            parts.append((accumulated, String(component)))
        }
        return parts
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let target = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
            let result = try await adb.shell("ls -la \(ADB.quote(target))", serial: serial, timeout: 30)
            if result.succeeded || !result.output.isEmpty {
                items = FileListingParser.parse(result.output, base: currentPath)
                errorMessage = nil
                AppLog.write("files path=\(currentPath) count=\(items.count)")
            } else {
                items = []
                errorMessage = result.messages.trimmed.isEmpty ? "无法读取目录" : result.messages.trimmed
            }
        } catch {
            items = []
            errorMessage = error.localizedDescription
            AppLog.write("file list failed path=\(currentPath): \(error.localizedDescription)")
        }
        selection = selection.filter { id in items.contains { $0.id == id } }
    }

    func open(_ item: FileItem) {
        guard item.isDirectory else {
            Task { await quickLook(item) }
            return
        }
        currentPath = item.path
        selection = []
        searchText = ""
        Task { await load() }
    }

    func goUp() {
        guard currentPath != "/" else { return }
        currentPath = RemotePath.parent(currentPath)
        selection = []
        Task { await load() }
    }

    func navigate(to path: String) {
        currentPath = path
        selection = []
        Task { await load() }
    }

    func refresh() async {
        await load()
    }

    func upload(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isTransferring = true
        statusMessage = "正在上传 0/\(urls.count)…"
        defer { isTransferring = false }

        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            statusMessage = "正在上传 \(index + 1)/\(urls.count)：\(url.lastPathComponent)"
            if settings.hideDSStore && url.lastPathComponent == ".DS_Store" {
                continue
            }
            do {
                let result = try await adb.run(["push", url.path, currentPath], serial: serial, timeout: 900)
                if !result.succeeded {
                    let message = result.messages.trimmed
                    if !message.lowercased().contains("skipped") {
                        failures.append("\(url.lastPathComponent)：\(message)")
                    }
                }
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        if settings.hideDSStore {
            let cleanup = "find \(ADB.quote(currentPath)) -name .DS_Store -exec rm {} + 2>/dev/null"
            _ = try? await adb.shell(cleanup, serial: serial, timeout: 30)
        }

        await load()
        if failures.isEmpty {
            statusMessage = "已上传 \(urls.count) 个项目"
        } else {
            statusMessage = "部分文件上传失败：\(failures.prefix(2).joined(separator: "；"))"
        }
        clearStatusSoon()
    }

    func download(_ items: [FileItem]) async {
        guard !items.isEmpty else { return }
        isTransferring = true
        let folder = settings.ensureDownloadFolder()
        statusMessage = "正在下载…"
        defer { isTransferring = false }

        var failures: [String] = []
        for item in items {
            do {
                let result = try await adb.run(["pull", item.path, folder.path], serial: serial, timeout: 1800)
                if !result.succeeded {
                    failures.append("\(item.name)：\(result.messages.trimmed)")
                }
            } catch {
                failures.append("\(item.name)：\(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            statusMessage = "已下载到 \(folder.path)"
            NSWorkspace.shared.activateFileViewerSelecting(
                items.map { folder.appendingPathComponent($0.name) }
            )
        } else {
            statusMessage = "下载失败：\(failures.prefix(2).joined(separator: "；"))"
        }
        clearStatusSoon()
    }

    func export(_ item: FileItem) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isTransferring = true
        statusMessage = "正在导出 \(item.name)…"
        defer { isTransferring = false }
        do {
            let result = try await adb.run(["pull", item.path, url.path], serial: serial, timeout: 1800)
            statusMessage = result.succeeded ? "已导出到 \(url.path)" : result.messages.trimmed
        } catch {
            statusMessage = error.localizedDescription
        }
        clearStatusSoon()
    }

    func downloadToTemp(_ item: FileItem) async -> URL? {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidConnection/QuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let target = cache.appendingPathComponent(item.name)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
           let size = attributes[.size] as? Int64,
           size == item.size,
           item.size > 0 {
            return target
        }

        do {
            let result = try await adb.run(["pull", item.path, target.path], serial: serial, timeout: 1800)
            return result.succeeded ? target : nil
        } catch {
            return nil
        }
    }

    func quickLook(_ item: FileItem) async {
        statusMessage = "正在准备预览…"
        guard let url = await downloadToTemp(item) else {
            statusMessage = "无法预览该文件"
            clearStatusSoon()
            return
        }
        statusMessage = nil
        QuickLookController.shared.show([url])
    }

    func delete(_ items: [FileItem]) async {
        guard !items.isEmpty else { return }
        isTransferring = true
        statusMessage = "正在删除…"
        defer { isTransferring = false }
        let paths = items.map { ADB.quote($0.path) }.joined(separator: " ")
        let command = items.contains(where: \.isDirectory) ? "rm -r \(paths)" : "rm \(paths)"
        do {
            let result = try await adb.shell(command, serial: serial, timeout: 120)
            statusMessage = result.succeeded ? "已删除 \(items.count) 个项目" : result.messages.trimmed
        } catch {
            statusMessage = error.localizedDescription
        }
        selection = []
        await load()
        clearStatusSoon()
    }

    func rename(_ item: FileItem, to newName: String) async {
        let name = newName.trimmed
        guard !name.isEmpty, name != item.name, !name.contains("/") else { return }
        let destination = RemotePath.join(RemotePath.parent(item.path), name)
        do {
            let result = try await adb.shell("mv \(ADB.quote(item.path)) \(ADB.quote(destination))", serial: serial, timeout: 60)
            statusMessage = result.succeeded ? "已重命名" : result.messages.trimmed
        } catch {
            statusMessage = error.localizedDescription
        }
        await load()
        clearStatusSoon()
    }

    func createFolder(named name: String) async {
        let folder = name.trimmed
        guard !folder.isEmpty, !folder.contains("/") else { return }
        let path = RemotePath.join(currentPath, folder)
        do {
            let result = try await adb.shell("mkdir -p \(ADB.quote(path))", serial: serial, timeout: 30)
            statusMessage = result.succeeded ? "已创建文件夹" : result.messages.trimmed
        } catch {
            statusMessage = error.localizedDescription
        }
        await load()
        clearStatusSoon()
    }

    func installAPK(_ item: FileItem) async -> Bool {
        statusMessage = "正在安装 \(item.name)…"
        do {
            let result = try await adb.run(["install", "-r", "-g", item.path], serial: serial, timeout: 900)
            let text = result.messages
            let ok = result.succeeded && (text.contains("Success") || text.contains("success"))
            statusMessage = ok ? "已安装 \(item.name)" : text.trimmed
            clearStatusSoon()
            return ok
        } catch {
            statusMessage = error.localizedDescription
            clearStatusSoon()
            return false
        }
    }

    private func clearStatusSoon() {
        let message = statusMessage
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if statusMessage == message { statusMessage = nil }
        }
    }
}
