//
//  ChatThreadView.swift
//  LanShare
//
//  与某个设备的聊天对话：气泡消息 + 底部输入框；文本与文件皆可发送，
//  离线时自动排队，上线后由模型自动补发。
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ChatThreadView: View {
    @EnvironmentObject var model: LanShareModel
    let conversationID: String

    @State private var text = ""
    @State private var showPicker = false
    @State private var showPhotoPicker = false
    @State private var shareItem: ShareItem?

    private var conversation: Conversation? { model.conversations[conversationID] }
    private var messages: [ChatMessage] { conversation?.messages ?? [] }
    private var peerName: String {
        conversation?.name
            ?? model.peers.first { $0.id == conversationID }?.name
            ?? "未知设备"
    }
    private var online: Bool { model.isOnline(conversationID) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if messages.isEmpty {
                            Text("和 \(peerName) 还没有消息\n在下方输入即可开始聊天")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 40)
                        }
                        ForEach(messages) { msg in
                            MessageBubble(message: msg, online: online) {
                                open(message: msg)
                            } resend: {
                                model.resend(msg.id, in: conversationID)
                            } onDelete: {
                                model.deleteMessage(msg, in: conversationID)
                            }
                            .id(msg.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }

            Divider()
            composeBar
        }
        .navigationTitle(peerName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.markOpened(conversationID) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(online ? Color.green : Color.gray.opacity(0.5))
                        .frame(width: 9, height: 9)
                    Text(online ? "在线" : "离线")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { results in
                model.importFromPhotoPicker(results)
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker { urls in
                for url in urls {
                    guard let dest = model.copyIntoIncoming(url) else {
                        model.status = "无法读取所选文件：\(url.lastPathComponent)"
                        continue
                    }
                    try? FileManager.default.removeItem(at: url)
                    let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    model.draftFiles.append(PendingFile(url: dest, name: dest.lastPathComponent, size: size))
                }
            }
        }
    }

    // MARK: - 输入栏

    private var composeBar: some View {
        VStack(spacing: 8) {
            if !model.draftFiles.isEmpty || !model.sharedInbox.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.draftFiles) { file in
                            chip(file.name, subtitle: ByteFormatter.string(from: file.size)) {
                                model.draftFiles.removeAll { $0.id == file.id }
                            }
                        }
                        ForEach(model.sharedInbox) { file in
                            chip(file.name, subtitle: "导入·" + ByteFormatter.string(from: file.size)) {
                                // xmark：丢弃该导入文件
                                model.sharedInbox.removeAll { $0.id == file.id }
                            } onAdd: {
                                // 点按气泡：加入待发送附件
                                model.draftFiles.append(file)
                                model.sharedInbox.removeAll { $0.id == file.id }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 34)
            }

            HStack(spacing: 10) {
                Button {
                    showPhotoPicker = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3)
                        .foregroundStyle(Color.accentBrand)
                }

                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .foregroundStyle(Color.accentBrand)
                }

                TextField(online ? "输入消息…" : "对方离线，消息将自动排队",
                          text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button {
                    sendCurrent()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                        .foregroundStyle(canSend ? Color.accentBrand : Color.gray.opacity(0.4))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.draftFiles.isEmpty
            || !model.sharedInbox.isEmpty
    }

    private func chip(_ name: String, subtitle: String, onTap: @escaping () -> Void, onAdd: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill").foregroundStyle(Color.accentBrand)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.caption).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Button { onTap() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onAdd?() }
    }

    private func sendCurrent() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var files = model.draftFiles
        if !model.sharedInbox.isEmpty {
            files.append(contentsOf: model.sharedInbox)
            model.sharedInbox.removeAll()
        }
        guard !trimmed.isEmpty || !files.isEmpty else { return }
        if !trimmed.isEmpty { model.send(text: trimmed, to: conversationID) }
        if !files.isEmpty { model.send(files: files, to: conversationID) }
        text = ""
        model.draftFiles.removeAll()
    }

    // MARK: - 从相册选择并发送
    // 注：相册选图 / 选视频后的加载与写入逻辑已移入 LanShareModel.importFromPhotoPicker，
    // 由模型（引用类型、常驻）持有，避免 SwiftUI 视图结构体在异步闭包里被捕获成离屏副本。

    private func open(message: ChatMessage) {
        if let url = model.fileURL(for: message) {
            shareItem = ShareItem(url: url)
        }
    }
}

// MARK: - 气泡

struct MessageBubble: View {
    let message: ChatMessage
    let online: Bool
    let onOpen: () -> Void
    let resend: () -> Void
    let onDelete: () -> Void

    private var isSent: Bool { message.direction == "sent" }

    var body: some View {
        HStack {
            if isSent { Spacer(minLength: 40) }
            VStack(alignment: isSent ? .trailing : .leading, spacing: 4) {
                bubbleContent
                statusLine
            }
            .padding(10)
            .background(
                isSent ? Color.accentBrand : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            if !isSent { Spacer(minLength: 40) }
        }
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.kind == "file" {
            Button { onOpen() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(isSent ? Color.white : Color.accentBrand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.fileName).foregroundStyle(isSent ? Color.white : Color.primary)
                        Text(ByteFormatter.string(from: message.fileSize))
                            .font(.caption2)
                            .foregroundStyle(isSent ? Color.white.opacity(0.85) : .secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            Text(message.text)
                .foregroundStyle(isSent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: isSent ? .trailing : .leading)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if isSent {
            let label = Self.statusLabel(for: message.status)
            if label.isEmpty {
                EmptyView()
            } else if message.status == "failed" {
                Button { resend() } label: {
                    Text(label).font(.caption2).foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        } else {
            Text(message.time.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private static func statusLabel(for status: String) -> String {
        switch status {
        case "queued": return "待发送（离线）"
        case "sending": return "发送中…"
        case "sent":   return "已送达"
        case "failed": return "发送失败 · 点按重发"
        default:       return ""
        }
    }
}

// MARK: - 文件打开 / 选择 复用组件

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 系统相册选择器（图片 + 视频，可多选），不要求相簿读取授权。
struct PhotoPicker: UIViewControllerRepresentable {
    let onPicked: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0                       // 0 = 不限制数量
        config.filter = PHPickerFilter.any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([PHPickerResult]) -> Void
        init(onPicked: @escaping ([PHPickerResult]) -> Void) { self.onPicked = onPicked }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPicked(results)
        }
    }
}

/// 原生文档选择器：asCopy 由系统把文件拷进 App 沙盒，彻底绕开安全作用域访问。
struct DocumentPicker: UIViewControllerRepresentable {
    let onPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data, .content], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([URL]) -> Void
        init(onPicked: @escaping ([URL]) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) { onPicked(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

enum ByteFormatter {
    static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
