import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppsView: View {
    @ObservedObject var store: AppsStore
    @EnvironmentObject private var model: AppModel
    @StateObject private var ui = AppsUIState()

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if store.apps.isEmpty {
                Task { await store.load() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("应用")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("\(model.device?.displayName ?? "设备") · \(store.filteredApps.count) 个应用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    install()
                } label: {
                    Label("安装 APK", systemImage: "plus.app")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索应用或包名", text: $store.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .frame(maxWidth: 320)

                Toggle("显示系统应用", isOn: $store.showSystemApps)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                    .onChange(of: store.showSystemApps) { _ in
                        Task { await store.load() }
                    }

                if store.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var content: some View {
        ZStack {
            if store.isLoading && store.apps.isEmpty {
                ProgressView("正在读取应用列表…")
            } else if store.filteredApps.isEmpty {
                EmptyStateView(
                    icon: "square.grid.2x2",
                    title: store.query.isEmpty ? "没有找到应用" : "没有匹配的应用",
                    message: store.query.isEmpty ? "切换“显示系统应用”，或安装一个 APK 试试。" : "换一个关键词，或清空搜索条件。",
                    actionTitle: "安装 APK",
                    action: install
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.filteredApps) { app in
                            AppCard(
                                app: app,
                                busy: store.busyPackage == app.package,
                                onLaunch: { Task { await store.launch(app) } },
                                onStop: { Task { await store.forceStop(app) } }
                            )
                            .contextMenu {
                                Button("启动") { Task { await store.launch(app) } }
                                Button("强制停止") { Task { await store.forceStop(app) } }
                                Divider()
                                Button("复制包名") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(app.package, forType: .string)
                                    store.statusMessage = "已复制包名"
                                }
                                Button("导出 APK…") { Task { await store.exportAPK(app) } }
                                Divider()
                                Button("卸载", role: .destructive) { Task { await store.uninstall(app) } }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }

            if let message = store.statusMessage ?? store.lastError {
                VStack {
                    Spacer()
                    ToastBanner(text: message, color: store.lastError == nil ? Theme.accent : Theme.danger)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.accent.opacity(ui.dropTargeted ? 0.8 : 0), lineWidth: 2)
                .padding(10)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $ui.dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func install() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                _ = await store.install(url: url)
            }
            model.devices.banner = store.statusMessage
        }
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
                if let url, url.pathExtension.lowercased() == "apk" {
                    lock.lock()
                    box.urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            guard !box.urls.isEmpty else { return }
            Task {
                for url in box.urls {
                    _ = await store.install(url: url)
                }
            }
        }
        return true
    }
}


struct AppCard: View {
    let app: AndroidApp
    let busy: Bool
    let onLaunch: () -> Void
    let onStop: () -> Void

    @StateObject private var hover = HoverState()

    private var tint: Color {
        let palette: [Color] = [
            Theme.accent,
            Theme.accentDeep,
            Color(red: 0.55, green: 0.44, blue: 0.86),
            Color(red: 0.91, green: 0.55, blue: 0.28),
            Color(red: 0.87, green: 0.38, blue: 0.51),
            Color(red: 0.35, green: 0.62, blue: 0.86)
        ]
        let index = abs(app.package.hashValue) % palette.count
        return palette[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.16))
                    Text(app.initials)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(app.package)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                if busy {
                    ProgressView().controlSize(.small)
                } else if app.isSystem {
                    Text("系统")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }

            HStack(spacing: 7) {
                Button(action: onLaunch) {
                    Label("启动", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.vertical, 6)
                .background(Capsule().fill(tint))
                .disabled(busy)

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(busy)
                .help("强制停止")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(hover.isHovered ? tint.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hover.isHovered = $0 }
        .onTapGesture(count: 2) { onLaunch() }
    }
}


@MainActor
final class AppsUIState: ObservableObject {
    @Published var dropTargeted = false
}
