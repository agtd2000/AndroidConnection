import SwiftUI
import AppKit

struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                HStack(alignment: .top, spacing: 16) {
                    outgoingCard
                    incomingCard
                }

                linksCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("剪贴板与链接")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("在 Mac 与 \(model.device?.displayName ?? "手机") 之间接力文本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("自动发送 Mac 剪贴板", isOn: $store.autoSync)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
        }
    }

    private var outgoingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Mac → 手机", subtitle: "发送到当前输入框")
                Spacer()
                Button {
                    store.copyOutgoingFromMac()
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            TextEditor(text: $store.outgoingText)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 150)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )

            HStack {
                Text("\(store.outgoingText.count) 个字符 · 中文与 emoji 通过控制通道粘贴")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await store.send() }
                } label: {
                    Label("发送到手机", systemImage: "paperplane.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.outgoingText.trimmed.isEmpty)
            }

            if !store.history.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("最近发送")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(store.history, id: \.self) { item in
                        Button {
                            store.outgoingText = item
                        } label: {
                            Text(item)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var incomingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "手机 → Mac", subtitle: "读取手机剪贴板")
                Spacer()
                Button {
                    Task { await store.fetchIncoming() }
                } label: {
                    Label("读取", systemImage: "arrow.down.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            ScrollView {
                Text(store.incomingText.isEmpty ? "尚未读取。控制通道会自动同步手机复制的内容；也可点击“读取”。" : store.incomingText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(store.incomingText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 150)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )

            HStack {
                Text("提示：手机复制后会自动同步到 Mac；无需在手机输入框里手动回传")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    store.copyIncomingToMac()
                } label: {
                    Label("复制到 Mac", systemImage: "doc.on.doc")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(store.incomingText.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "链接接力", subtitle: "在手机上打开 Mac 里的网址")

            if store.detectedLinks.isEmpty {
                Text("在 Mac 或手机剪贴板中复制链接后，会自动显示在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(store.detectedLinks, id: \.self) { link in
                    HStack(spacing: 9) {
                        Image(systemName: "link")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                        Text(link)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("在手机打开") {
                            Task { await store.openLinkOnPhone(link) }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                }
            }
        }
        .card()
    }

}
