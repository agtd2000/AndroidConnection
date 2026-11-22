import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FilesView: View {
    @ObservedObject var store: FilesStore
    @EnvironmentObject private var model: AppModel

    @StateObject private var ui = FilesUIState()

    var body: some View {
        VStack(spacing: 0) {
            header
            breadcrumbBar
            Divider()
            content
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $ui.showNewFolder) {
            TextPromptSheet(
                title: "新建文件夹",
                message: "将在 \(store.currentPath) 中创建文件夹。",
                placeholder: "文件夹名称",
                text: $ui.newFolderName,
                confirmTitle: "创建"
            ) {
                let name = ui.newFolderName
                Task { await store.createFolder(named: name) }
                ui.newFolderName = ""
            }
        }
        .sheet(item: $ui.renameItem) { item in
            TextPromptSheet(
                title: "重命名",
                message: item.path,
                placeholder: "新名称",
                text: $ui.renameText,
                confirmTitle: "重命名"
            ) {
                let name = ui.renameText
                Task { await store.rename(item, to: name) }
            }
        }
        .confirmationDialog(
            "删除所选项目？",
            isPresented: $ui.confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除 \(ui.pendingDelete.count) 个项目", role: .destructive) {
                let items = ui.pendingDelete
                Task { await store.delete(items) }
                ui.pendingDelete = []
            }
            Button("取消", role: .cancel) { ui.pendingDelete = [] }
        } message: {
            Text("此操作会直接从手机存储中删除，无法撤销。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("文件")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("\(model.device?.displayName ?? "设备") · \(store.currentPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 5) {
                ToolbarIconButton(icon: "chevron.up", help: "上级目录", disabled: store.currentPath == "/") {
                    store.goUp()
                }
                ToolbarIconButton(icon: "arrow.clockwise", help: "刷新") {
                    Task { await store.refresh() }
                }
                ToolbarIconButton(icon: "folder.badge.plus", help: "新建文件夹") {
                    ui.showNewFolder = true
                }
                ToolbarIconButton(icon: "square.and.arrow.up", help: "上传文件", disabled: store.isTransferring) {
                    upload()
                }
                ToolbarIconButton(icon: "square.and.arrow.down", help: "下载所选", disabled: store.selectedItems.isEmpty) {
                    let items = store.selectedItems
                    Task { await store.download(items) }
                }
                ToolbarIconButton(icon: "trash", help: "删除所选", disabled: store.selection.isEmpty) {
                    ui.pendingDelete = store.selectedItems
                    ui.confirmDelete = true
                }
                Menu {
                    Picker("排序方式", selection: $store.sortField) {
                        ForEach(FilesStore.SortField.allCases) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    Toggle("升序", isOn: $store.sortAscending)
                    Divider()
                    Toggle("显示隐藏文件", isOn: $store.showHidden)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(store.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        store.navigate(to: crumb.0)
                    } label: {
                        Text(crumb.1)
                            .font(.system(size: 11.5, weight: index == store.breadcrumbs.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == store.breadcrumbs.count - 1 ? Theme.accent : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 20)

                if store.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 8)
    }

    private var content: some View {
        ZStack(alignment: .center) {
            if let error = store.errorMessage {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "无法读取该目录",
                    message: error,
                    actionTitle: "返回上级",
                    action: { store.goUp() }
                )
            } else if store.isLoading && store.items.isEmpty {
                ProgressView("正在读取…")
            } else if store.filteredItems.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "这里还没有文件",
                    message: "将文件拖到窗口即可上传到 \(store.currentPath)。",
                    actionTitle: "上传文件",
                    action: upload
                )
            } else {
                fileList
            }

            if store.isTransferring {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(store.statusMessage ?? "正在传输…")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.accent.opacity(ui.dropTargeted ? 0.8 : 0), lineWidth: 2)
                .padding(10)
        )
        .animation(.easeOut(duration: 0.15), value: ui.dropTargeted)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $ui.dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("名称")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("大小")
                    .frame(width: 82, alignment: .trailing)
                Text("修改日期")
                    .frame(width: 132, alignment: .trailing)
                Text("权限")
                    .frame(width: 92, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 7)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.filteredItems) { item in
                        FileRow(item: item, selected: store.selection.contains(item.id)) {
                            select(item)
                        } onOpen: {
                            store.open(item)
                        }
                        .contextMenu {
                            Button(item.isDirectory ? "打开" : "快速查看") {
                                store.open(item)
                            }
                            if !item.isDirectory {
                                Button("下载到 Mac") {
                                    Task { await store.download([item]) }
                                }
                                Button("导出到…") {
                                    Task { await store.export(item) }
                                }
                            }
                            if item.isAPK {
                                Button("安装到手机") {
                                    Task { _ = await store.installAPK(item) }
                                }
                            }
                            Divider()
                            Button("重命名") {
                                ui.renameText = item.name
                                ui.renameItem = item
                            }
                            Button("删除", role: .destructive) {
                                ui.pendingDelete = [item]
                                ui.confirmDelete = true
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("\(store.filteredItems.count) 个项目")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !store.selection.isEmpty {
                Text("已选择 \(store.selection.count) 个")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            if store.isTransferring {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let message = store.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("拖入文件即可上传")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
    }

    private func select(_ item: FileItem) {
        if let flags = NSApp.currentEvent?.modifierFlags, flags.contains(.command) {
            if store.selection.contains(item.id) {
                store.selection.remove(item.id)
            } else {
                store.selection.insert(item.id)
            }
        } else {
            store.selection = [item.id]
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "上传"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await store.upload(urls: urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        final class Box { var urls: [URL] = [] }
        let box = Box()
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                }
                if let url {
                    lock.lock()
                    box.urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            guard !box.urls.isEmpty else { return }
            Task { await store.upload(urls: box.urls) }
        }
        return true
    }
}

struct FileRow: View {
    let item: FileItem
    let selected: Bool
    let onTap: () -> Void
    let onOpen: () -> Void

    @StateObject private var hover = HoverState()

    private var tint: Color {
        if item.isDirectory { return Theme.accent }
        if item.isAPK { return Color(red: 0.45, green: 0.68, blue: 0.30) }
        switch item.iconName {
        case "photo.fill": return Color(red: 0.55, green: 0.45, blue: 0.85)
        case "film.fill": return Color(red: 0.90, green: 0.48, blue: 0.42)
        case "music.note": return Color(red: 0.92, green: 0.62, blue: 0.28)
        case "archivebox.fill": return Color(red: 0.62, green: 0.56, blue: 0.48)
        default: return Color.secondary
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: item.iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(item.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(item.name.hasPrefix(".") ? .secondary : .primary)
                if item.isSymlink {
                    Image(systemName: "link")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.displaySize)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .trailing)

            Text(item.modified.map { Formatters.fileDate.string(from: $0) } ?? "—")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .trailing)

            Text(item.permissions)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.16) : (hover.isHovered ? Color.primary.opacity(0.035) : Color.clear))
                .padding(.horizontal, 10)
        )
        .contentShape(Rectangle())
        .onHover { hover.isHovered = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture { onTap() }
    }
}

struct TextPromptSheet: View {
    let title: String
    let message: String
    let placeholder: String
    @Binding var text: String
    let confirmTitle: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func commit() {
        guard !text.trimmed.isEmpty else { return }
        onConfirm()
        dismiss()
    }
}


@MainActor
final class FilesUIState: ObservableObject {
    @Published var showNewFolder = false
    @Published var newFolderName = ""
    @Published var renameItem: FileItem?
    @Published var renameText = ""
    @Published var pendingDelete: [FileItem] = []
    @Published var confirmDelete = false
    @Published var dropTargeted = false
}
