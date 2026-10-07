//
//  LanShareModel.swift
//  LanShare
//
//  全局状态：发现、接收服务、发送任务、聊天会话（含离线发件箱）。
//

import Foundation
import UIKit
import Photos
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// 单条聊天消息（文本或文件），可序列化持久化。
struct ChatMessage: Identifiable, Codable {
    let id: String
    var direction: String   // "sent" | "received"
    var kind: String        // "text" | "file"
    var text: String        // 文本内容 / 文件说明
    var fileName: String
    var fileSize: Int64
    /// 相对 Documents 的路径：接收文件指向 Received；发送文件指向 Sent（用于离线重发）。无则空。
    var filePath: String
    var time: Date
    var status: String      // 发送侧: queued / sending / sent / failed；接收侧: received
}

/// 与一个远端设备的会话（对话），按远端设备 ID 索引。
struct Conversation: Identifiable, Codable {
    let id: String          // 远端设备 ID
    var name: String
    var ip: String
    var port: Int
    var messages: [ChatMessage]
    var lastTime: Date

    var lastSummary: String {
        guard let m = messages.last else { return "暂无消息" }
        if m.kind == "file" { return "［文件］\(m.fileName)" }
        return m.text.isEmpty ? "［空消息］" : m.text
    }
}

struct PendingFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
}

/// 相册选中后、真实文件还在后台准备时的占位气泡（主线程立即显示，避免点“添加”卡顿）。
struct PreparingDraft: Identifiable {
    let id: UUID
    let name: String
    let isVideo: Bool
}

final class LanShareModel: ObservableObject {

    let selfID: String

    // 本机
    @Published var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "LanShare.deviceName") }
    }
    @Published var localIP: String = "获取中…"
    @Published var port: UInt16 = 0

    // 发现
    @Published var peers: [Peer] = []
    @Published var selectedPeerID: String?

    /// 历史配对设备（曾在同一局域网被发现/聊过），跨重启持久化，用于离线展示与排队发送
    @Published var knownPeers: [String: Peer] = [:]
    private let knownPeersKey = "LanShare.knownPeers"

    // 聊天会话（按远端设备 ID）
    @Published var conversations: [String: Conversation] = [:]
    @Published var selectedConversationID: String?

    /// 最近一次打开的会话 ID，用于启动时直接回到该聊天窗口
    var lastConversationID: String? {
        didSet { UserDefaults.standard.set(lastConversationID, forKey: "LanShare.lastConversationID") }
    }

    /// 聊天文件缓存占用（字节），设置页展示
    @Published var cacheBytes: Int64 = 0

    // 状态 / 进度
    @Published var status: String = "准备就绪"
    @Published var isSending = false
    @Published var sendingName = ""
    @Published var sendProgress: Double = 0
    @Published var receivingName: String = ""
    @Published var receiveProgress: Double = 0

    /// 从其它 App（Open In / 分享）导入、待发送的文件
    @Published var sharedInbox: [PendingFile] = []

    /// 对话输入框当前已选、待发送的本地文件（相册 / 文件 App 选入）。
    /// 放在模型里（引用类型）以便异步回调（相册加载完成）能安全更新并触发界面刷新，
    /// 避免把 @State 放在 View 结构体上被异步闭包捕获成值副本而失效。
    @Published var draftFiles: [PendingFile] = []

    /// 相册选中后、真实文件还在后台准备时的占位气泡（点“添加”立即显示，不卡顿）。
    @Published var preparingDrafts: [PreparingDraft] = []
    /// 已被用户取消的准备中占位 id，避免后台完成后又误加入 draftFiles。
    private var cancelledPreparing: Set<UUID> = []

    private let discovery: Discovery
    private let server = TransferServer()
    private var started = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// 已知在线的设备 ID 集合，用于检测“刚上线”以触发离线补发
    private var onlineIDs: Set<String> = []

    var selectedPeer: Peer? {
        peers.first { $0.id == selectedPeerID }
    }

    init() {
        selfID = NetUtils.deviceID()
        let savedName = UserDefaults.standard.string(forKey: "LanShare.deviceName")
        deviceName = savedName ?? NetUtils.defaultDeviceName()
        lastConversationID = UserDefaults.standard.string(forKey: "LanShare.lastConversationID")
        discovery = Discovery(selfID: selfID)
        loadChats()
        loadKnownPeers()
    }

    // MARK: - 启动

    func start() {
        guard !started else { return }
        started = true

        server.onText = { [weak self] text, from, src, ip in
            DispatchQueue.main.async { self?.didReceiveText(text, from: from, src: src, ip: ip) }
        }
        server.onFile = { [weak self] url, from, size, src, ip in
            DispatchQueue.main.async { self?.didReceiveFile(at: url, from: from, size: size, src: src, ip: ip) }
        }
        server.onProgress = { [weak self] name, received, total in
            DispatchQueue.main.async {
                self?.receivingName = name
                self?.receiveProgress = total > 0 ? Double(received) / Double(total) : 0
            }
        }
        server.onActivity = { [weak self] active in
            if active { self?.beginBackgroundTask() } else { self?.endBackgroundTask() }
        }

        if server.start() {
            port = server.port
        } else {
            status = "接收服务启动失败"
        }

        discovery.configure(
            nameProvider: { [weak self] in self?.deviceName ?? "iPhone" },
            portProvider: { [weak self] in self?.port ?? 0 }
        )
        discovery.onPeersChanged = { [weak self] peers in
            DispatchQueue.main.async { self?.handlePeersChanged(peers) }
        }
        discovery.start()

        importSharedInbox()
        refreshLocalInfo()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshLocalInfo()
        }
    }

    private func handlePeersChanged(_ peers: [Peer]) {
        let newIDs = Set(peers.map { $0.id })
        let cameOnline = newIDs.subtracting(onlineIDs)

        self.peers = peers
        // 合并进历史配对设备并持久化（用于离线展示与跨重启恢复）
        for p in peers { knownPeers[p.id] = p }
        saveKnownPeers()
        // 用发现到的信息刷新已知会话的地址
        for p in peers {
            if var c = conversations[p.id] {
                c.name = p.name
                c.ip = p.ip
                c.port = p.port
                conversations[p.id] = c
            }
        }
        if selectedConversationID == nil, let first = peers.first {
            selectedConversationID = first.id
        }
        let prevOnline = onlineIDs
        onlineIDs = newIDs

        for id in cameOnline where !prevOnline.contains(id) {
            flushOutbox(peerID: id)
        }
    }

    func refreshLocalInfo() {
        let ip = NetUtils.localIP()
        DispatchQueue.main.async {
            self.localIP = ip
            if self.port == 0 { self.port = self.server.port }
        }
        if started, !ip.contains("未连接") {
            discovery.announce()
        }
    }

    // MARK: - 在线判断

    func isOnline(_ peerID: String) -> Bool {
        peers.contains { $0.id == peerID }
    }

    /// 取用于发送的对端：优先用发现的实时地址，否则用会话里最后已知的地址兜底（离线补发场景）。
    func peer(for id: String) -> Peer? {
        if let p = peers.first(where: { $0.id == id }) { return p }
        if let p = knownPeers[id], !p.ip.isEmpty, p.port > 0 { return p }
        guard let c = conversations[id], !c.ip.isEmpty, c.port > 0 else { return nil }
        return Peer(id: id, name: c.name, platform: "?", ip: c.ip, port: c.port, lastSeen: Date())
    }

    // MARK: - 发送（含离线排队）

    func send(text: String, to peerID: String) {
        guard !text.isEmpty else { status = "文本内容为空"; return }
        let msg = ChatMessage(id: UUID().uuidString, direction: "sent", kind: "text",
                              text: text, fileName: "", fileSize: 0, filePath: "",
                              time: Date(), status: "queued")
        append(message: msg, to: peerID, name: peerName(peerID))
        guard let peer = peer(for: peerID) else {
            status = "找不到对方地址，已存为待发送"
            return
        }
        if isOnline(peerID) {
            dispatch(messageID: msg.id, conversationID: peerID, peer: peer)
        } else {
            status = "\(peer.name) 当前离线，文本已加入待发送，上线后自动发送"
        }
    }

    func send(files: [PendingFile], to peerID: String) {
        guard !files.isEmpty else { status = "请先选择文件"; return }
        guard let peer = peer(for: peerID) else { status = "找不到对方地址"; return }
        var created: [ChatMessage] = []
        for file in files {
            guard let dest = copyIntoSent(file.url) else {
                status = "无法读取文件：\(file.name)"
                continue
            }
            let rel = relativePath(of: dest)
            let msg = ChatMessage(id: UUID().uuidString, direction: "sent", kind: "file",
                                  text: "", fileName: file.name, fileSize: file.size,
                                  filePath: rel, time: Date(), status: "queued")
            created.append(msg)
        }
        guard !created.isEmpty else { return }
        for m in created { append(message: m, to: peerID, name: peerName(peerID)) }
        if isOnline(peerID) {
            for m in created { dispatch(messageID: m.id, conversationID: peerID, peer: peer) }
        } else {
            status = "\(peer.name) 当前离线，\(created.count) 个文件已加入待发送，上线后自动发送"
        }
    }

    /// 手动重发一条失败的发送消息。
    func resend(_ messageID: String, in conversationID: String) {
        guard let msg = conversations[conversationID]?.messages.first(where: { $0.id == messageID }),
              msg.direction == "sent",
              let peer = peer(for: conversationID) else { return }
        if isOnline(conversationID) {
            dispatch(messageID: messageID, conversationID: conversationID, peer: peer)
            status = "正在重发…"
        } else {
            setStatus(messageID, in: conversationID, to: "queued")
            status = "对方离线，已重新排队"
        }
    }

    /// 对方刚上线：补发该会话中排队/失败的离线消息。
    func flushOutbox(peerID: String) {
        guard let peer = peer(for: peerID) else { return }
        let pending = (conversations[peerID]?.messages ?? [])
            .filter { $0.direction == "sent" && ($0.status == "queued" || $0.status == "failed") }
        guard !pending.isEmpty else { return }
        status = "\(peer.name) 已上线，正在补发 \(pending.count) 条离线消息…"
        for m in pending {
            dispatch(messageID: m.id, conversationID: peerID, peer: peer)
        }
    }

    // MARK: - 实际发送

    private func dispatch(messageID: String, conversationID: String, peer: Peer) {
        guard let msg = conversations[conversationID]?.messages.first(where: { $0.id == messageID }) else {
            return
        }
        setStatus(messageID, in: conversationID, to: "sending")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result: Result<Void, TransferError>
            if msg.kind == "text" {
                result = TransferClient.sendText(host: peer.ip, port: UInt16(peer.port),
                                                 text: msg.text, from: self.deviceName, src: self.selfID)
            } else {
                let localURL = self.documentsDirectory()?.appendingPathComponent(msg.filePath) ?? URL(fileURLWithPath: "/dev/null")
                result = TransferClient.sendFile(host: peer.ip, port: UInt16(peer.port),
                                                 fileURL: localURL, from: self.deviceName, src: self.selfID) { sent, total in
                    DispatchQueue.main.async { self.sendProgress = total > 0 ? Double(sent) / Double(total) : 0 }
                }
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.setStatus(messageID, in: conversationID, to: "sent")
                    self.status = "已发送给 \(peer.name)"
                case .failure(let error):
                    self.setStatus(messageID, in: conversationID, to: "failed")
                    self.status = error.localizedDescription
                }
                self.sendProgress = 1
            }
        }
    }

    // MARK: - 接收

    private func didReceiveText(_ text: String, from fromName: String, src: String, ip: String) {
        let id = src.isEmpty ? ip : src
        let msg = ChatMessage(id: UUID().uuidString, direction: "received", kind: "text",
                              text: text, fileName: "", fileSize: 0, filePath: "",
                              time: Date(), status: "received")
        append(message: msg, to: id, name: fromName, ip: ip, port: 0)
        status = "收到来自 \(fromName) 的文本"
        receiveProgress = 0
        receivingName = ""
    }

    private func didReceiveFile(at url: URL, from fromName: String, size: Int64, src: String, ip: String) {
        let id = src.isEmpty ? ip : src
        let rel = relativePath(of: url)
        let msg = ChatMessage(id: UUID().uuidString, direction: "received", kind: "file",
                              text: "", fileName: url.lastPathComponent, fileSize: size,
                              filePath: rel, time: Date(), status: "received")
        append(message: msg, to: id, name: fromName, ip: ip, port: 0)
        status = "已接收文件：\(url.lastPathComponent)"
        receiveProgress = 0
        receivingName = ""

        // 图片 / 视频自动存入系统相簿
        if isMediaAsset(url) {
            saveMediaToPhotoLibrary(url)
        }
    }

    // MARK: - 媒体自动存入相簿

    /// 判断收到的文件是否为图片或视频：优先按扩展名 UTI，失败时再用文件头（magic bytes）兜底。
    private func isMediaAsset(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video) {
            return true
        }
        return mediaKind(url) != .other
    }

    /// 按文件头识别媒体类型（扩展名识别失败时的兜底）
    private enum MediaKind { case image, video, other }
    private func mediaKind(_ url: URL) -> MediaKind {
        guard let handle = try? FileHandle(forReadingAtPath: url.path) else { return .other }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 16)
        guard head.count >= 12 else { return .other }
        if head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF { return .image }   // JPEG
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image }             // PNG
        let ftyp = head.subdata(in: 4..<min(12, head.count))
        if let tag = String(data: ftyp, encoding: .ascii), tag.contains("ftyp") {
            let isVideo = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false)
                || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .video) ?? false)
            return isVideo ? .video : .image
        }
        return .other
    }

    /// 把收到的图片 / 视频存入系统相簿（需 Info.plist 的 NSPhotoLibraryAddUsageDescription）。
    /// 授权失败时退回：文件仍保留在 App 内「接收文件」目录，状态栏给出提示。
    private func saveMediaToPhotoLibrary(_ url: URL) {
        let isVideo = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false)
            || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .video) ?? false)

        func attempt() {
            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else if let image = UIImage(contentsOfFile: url.path) {
                    // 用内存中的 UIImage 创建，避免新版 photolibraryd 读不到 App 沙盒文件
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.status = "已接收并存入相簿：\(url.lastPathComponent)"
                    } else {
                        self.status = "存入相簿失败：\(error?.localizedDescription ?? "未知错误")，文件已保留在 App 内"
                    }
                }
            }
        }

        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited {
            attempt()
        } else {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                guard let self = self else { return }
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async {
                        self.status = "未授权访问相簿，文件已保留在 App 内「接收文件」"
                    }
                    return
                }
                attempt()
            }
        }
    }

    func fileURL(for message: ChatMessage) -> URL? {
        guard !message.filePath.isEmpty else { return nil }
        return documentsDirectory()?.appendingPathComponent(message.filePath)
    }

    func deleteMessage(_ message: ChatMessage, in conversationID: String) {
        guard var c = conversations[conversationID] else { return }
        c.messages.removeAll { $0.id == message.id }
        if let url = fileURL(for: message) { try? FileManager.default.removeItem(at: url) }
        conversations[conversationID] = c
        saveChats()
    }

    // MARK: - 最近会话 / 缓存

    /// 记录最近一次打开的会话，供下次启动直接回到该聊天窗口。
    func markOpened(_ id: String) {
        lastConversationID = id
    }

    func refreshCache() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let size = self?.computeCacheBytes() ?? 0
            DispatchQueue.main.async { self?.cacheBytes = size }
        }
    }

    private func computeCacheBytes() -> Int64 {
        guard let docs = documentsDirectory() else { return 0 }
        let dirs = ["Received", "Sent", "Imported", "Incoming"]
        var total: Int64 = 0
        let manager = FileManager.default
        for name in dirs {
            let dir = docs.appendingPathComponent(name)
            guard let enumerator = manager.enumerator(at: dir,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    /// 清除所有聊天文件缓存（Received/Sent/Imported/Incoming），并清空全部聊天记录（文本与文件消息）。
    func clearCache() {
        guard let docs = documentsDirectory() else { return }
        let dirs = ["Received", "Sent", "Imported", "Incoming"]
        let manager = FileManager.default
        for name in dirs {
            let dir = docs.appendingPathComponent(name)
            guard let children = try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for child in children { try? manager.removeItem(at: child) }
        }
        // 清空全部聊天记录（含文本与文件消息）
        conversations.removeAll()
        sharedInbox.removeAll()
        lastConversationID = nil
        saveChats()
        cacheBytes = 0
        status = "缓存已清除"
    }

    // MARK: - 会话写入辅助

    private func peerName(_ id: String) -> String {
        peers.first { $0.id == id }?.name
            ?? knownPeers[id]?.name
            ?? conversations[id]?.name
            ?? "未知设备"
    }

    /// 设备列表：在线发现设备 + 历史配对（离线）设备，去重，在线优先，按名称排序。
    var displayDevices: [Peer] {
        var map: [String: Peer] = [:]
        for (id, p) in knownPeers { map[id] = p }
        for p in peers { map[p.id] = p }
        return map.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func append(message: ChatMessage, to id: String, name: String) {
        var c = conversations[id] ?? Conversation(id: id, name: name, ip: "", port: 0,
                                                   messages: [], lastTime: message.time)
        c.name = name.isEmpty ? c.name : name
        c.messages.append(message)
        c.lastTime = message.time
        conversations[id] = c
        if selectedConversationID == nil { selectedConversationID = id }
        saveChats()
    }

    private func append(message: ChatMessage, to id: String, name: String, ip: String, port: Int) {
        var c = conversations[id] ?? Conversation(id: id, name: name, ip: ip, port: port,
                                                   messages: [], lastTime: message.time)
        if !name.isEmpty { c.name = name }
        if !ip.isEmpty { c.ip = ip }
        if port > 0 { c.port = port }
        c.messages.append(message)
        c.lastTime = message.time
        conversations[id] = c
        if selectedConversationID == nil { selectedConversationID = id }
        saveChats()
    }

    private func setStatus(_ messageID: String, in conversationID: String, to status: String) {
        guard var c = conversations[conversationID],
              let index = c.messages.firstIndex(where: { $0.id == messageID }) else { return }
        c.messages[index].status = status
        conversations[conversationID] = c
        saveChats()
    }

    private func relativePath(of url: URL) -> String {
        guard let documents = documentsDirectory() else { return url.lastPathComponent }
        return url.path.replacingOccurrences(of: documents.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var sortedConversations: [Conversation] {
        conversations.values.sorted { $0.lastTime > $1.lastTime }
    }

    // MARK: - 从分享扩展 / Open In 导入

    func importFileURL(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let documents = documentsDirectory() else { return }
        let destDir = documents.appendingPathComponent("Imported", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = uniqueURL(in: destDir, name: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            DispatchQueue.main.async {
                self.sharedInbox.append(PendingFile(url: dest, name: dest.lastPathComponent, size: size))
                self.status = "已从其它 App 导入 1 个文件，可在对话中发送"
            }
            try? FileManager.default.removeItem(at: url)
        } catch {
            DispatchQueue.main.async { self.status = "导入失败：\(error.localizedDescription)" }
        }
    }

    func importSharedInbox() {
        var roots: [URL] = []
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.lanshare.app") {
            roots.append(container.appendingPathComponent("Inbox", isDirectory: true))
        }
        if let documents = documentsDirectory() {
            roots.append(documents.appendingPathComponent("Inbox", isDirectory: true))
        }

        let manager = FileManager.default
        var imported: [PendingFile] = []
        for inbox in roots {
            guard manager.fileExists(atPath: inbox.path) else { continue }

            let manifest = inbox.appendingPathComponent("manifest.json")
            var entries: [[String: String]] = []
            if let data = try? Data(contentsOf: manifest),
               let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] {
                entries = list
            } else if let children = try? manager.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.isDirectoryKey]) {
                for child in children where !child.lastPathComponent.hasPrefix(".") {
                    let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if !isDir {
                        entries.append(["name": child.lastPathComponent, "relativePath": child.lastPathComponent])
                    }
                }
            }

            guard let documents = documentsDirectory() else { continue }
            let destDir = documents.appendingPathComponent("Imported", isDirectory: true)
            try? manager.createDirectory(at: destDir, withIntermediateDirectories: true)

            for entry in entries {
                guard let relative = entry["relativePath"], let name = entry["name"] else { continue }
                let source = inbox.appendingPathComponent(relative)
                let dest = uniqueURL(in: destDir, name: name)
                do {
                    try manager.copyItem(at: source, to: dest)
                    let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    imported.append(PendingFile(url: dest, name: name, size: Int64(size)))
                } catch { continue }
            }
            try? manager.removeItem(at: inbox)
        }

        if !imported.isEmpty {
            DispatchQueue.main.async {
                self.sharedInbox.append(contentsOf: imported)
                self.status = "已从其它 App 导入 \(imported.count) 个文件，可在对话中发送"
            }
        }
    }

    /// 把文件拷入 Documents/Sent，供离线重发时读取；返回沙盒内 URL。
    func copyIntoSent(_ url: URL) -> URL? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let documents = documentsDirectory() else { return nil }
        let dir = documents.appendingPathComponent("Sent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(in: dir, name: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// 把（可能带安全作用域的）外部文件拷入 App 沙盒的 Incoming 目录，返回沙盒内 URL。
    func copyIntoIncoming(_ url: URL) -> URL? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let documents = documentsDirectory() else { return nil }
        let dir = documents.appendingPathComponent("Incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(in: dir, name: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func uniqueURL(in directory: URL, name: String) -> URL {
        let manager = FileManager.default
        let base = directory.appendingPathComponent(name)
        guard manager.fileExists(atPath: base.path) else { return base }
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    // MARK: - 从系统相册导入（PHPicker 回调）

    /// 由 ChatThreadView 的相册选择器回调触发。
    /// 关键优化：点“添加”后**立即**在主线程创建占位气泡（preparingDrafts），相册关闭后立刻可见，
    /// 之后所有耗时的取数据 / 写盘 / 拷入沙盒都放到后台线程，主线程零阻塞，彻底消除“卡几秒”。
    ///
    /// 不再依赖 NSItemProvider 的 item 加载（在 iOS 26 上 picker 关闭后加载常被取消、回调不触发），
    /// 改为用 result.assetIdentifier 取出 PHAsset，再通过 PHImageManager 直接读取原始数据/导出视频，
    /// 完全独立于 picker 生命周期，对 iCloud 照片也稳定。
    func importFromPhotoPicker(_ results: [PHPickerResult]) {
        guard !results.isEmpty else {
            DispatchQueue.main.async { self.status = "未选择任何项目" }
            return
        }

        // 1) 立即把每一项以占位气泡展示（主线程，瞬间完成，不卡顿）
        var placeholders: [(UUID, PHPickerResult)] = []
        var models: [PreparingDraft] = []
        for result in results {
            let isVideo = result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let id = UUID()
            placeholders.append((id, result))
            models.append(PreparingDraft(id: id, name: isVideo ? "视频" : "照片", isVideo: isVideo))
        }
        DispatchQueue.main.async {
            self.preparingDrafts.append(contentsOf: models)
            self.status = "正在准备 \(results.count) 个文件…"
        }

        // 2) 后台逐个取出真实数据，完成后把占位气泡替换为可发送文件
        func begin(_ items: [(UUID, PHPickerResult)]) {
            let fileManager = FileManager.default
            let imageManager = PHImageManager.default()

            let imageOptions = PHImageRequestOptions()
            imageOptions.isNetworkAccessAllowed = true      // iCloud 照片允许下载
            imageOptions.deliveryMode = .highQualityFormat
            imageOptions.isSynchronous = false

            let videoOptions = PHVideoRequestOptions()
            videoOptions.isNetworkAccessAllowed = true
            videoOptions.deliveryMode = .highQualityFormat

            // 后台准备完成：移除占位气泡，加入可发送文件（或报告错误）
            func finish(_ pid: UUID, dest: URL?, errorMsg: String?) {
                DispatchQueue.main.async {
                    self.preparingDrafts.removeAll { $0.id == pid }
                    guard !self.cancelledPreparing.contains(pid) else {
                        self.cancelledPreparing.remove(pid)
                        return
                    }
                    if let dest {
                        let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                        self.draftFiles.append(PendingFile(url: dest, name: dest.lastPathComponent, size: size))
                        self.status = "已添加 \(self.draftFiles.count) 个文件，点右下角发送按钮即可发出"
                    } else if let errorMsg {
                        self.status = errorMsg
                    }
                }
            }

            func process(_ pid: UUID, _ result: PHPickerResult) {
                guard let assetID = result.assetIdentifier,
                      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
                    finish(pid, dest: nil, errorMsg: "无法定位所选的相册项目")
                    return
                }
                if asset.mediaType == .video {
                    imageManager.requestExportSession(forVideo: asset, options: videoOptions,
                                                     exportPreset: AVAssetExportPresetPassthrough) { session, _ in
                        guard let session else {
                            finish(pid, dest: nil, errorMsg: "无法导出所选视频")
                            return
                        }
                        let tmp = fileManager.temporaryDirectory
                            .appendingPathComponent("video-\(Int(Date().timeIntervalSince1970 * 1000)).mov")
                        session.outputURL = tmp
                        session.outputFileType = .mov
                        session.exportAsynchronously {
                            guard session.status == .completed else {
                                finish(pid, dest: nil, errorMsg: "导出视频失败：\(session.error?.localizedDescription ?? "未知错误")")
                                return
                            }
                            let dest = self.copyIntoIncoming(tmp)
                            try? fileManager.removeItem(at: tmp)
                            finish(pid, dest: dest, errorMsg: dest == nil ? "无法保存所选视频" : nil)
                        }
                    }
                } else {
                    imageManager.requestImageDataAndOrientation(for: asset, options: imageOptions) { data, uti, _, info in
                        let detail = (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "未知错误"
                        guard let data, let uti else {
                            finish(pid, dest: nil, errorMsg: "读取照片失败：\(detail)")
                            return
                        }
                        let ext = (UTType(uti)?.preferredFilenameExtension) ?? "jpg"
                        let name = "photo-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
                        let tmp = fileManager.temporaryDirectory.appendingPathComponent(name)
                        do {
                            try data.write(to: tmp)
                            let dest = self.copyIntoIncoming(tmp)
                            try? fileManager.removeItem(at: tmp)
                            finish(pid, dest: dest, errorMsg: dest == nil ? "无法保存所选照片" : nil)
                        } catch {
                            finish(pid, dest: nil, errorMsg: "写入照片失败：\(error.localizedDescription)")
                        }
                    }
                }
            }

            for (pid, result) in items { process(pid, result) }
        }

        // 读取相册资源需要“照片”读取授权；先确认授权再处理。
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            begin(placeholders)
        } else {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                guard let self = self else { return }
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async {
                        self.preparingDrafts.removeAll()
                        self.status = "未授权访问相册，无法选取照片/视频"
                    }
                    return
                }
                begin(placeholders)
            }
        }
    }

    /// 用户取消某个“准备中”的占位气泡
    func cancelPreparing(_ id: UUID) {
        cancelledPreparing.insert(id)
        preparingDrafts.removeAll { $0.id == id }
    }

    // MARK: - 持久化

    private func loadKnownPeers() {
        guard let data = UserDefaults.standard.data(forKey: knownPeersKey),
              let dict = try? JSONDecoder().decode([String: Peer].self, from: data) else { return }
        knownPeers = dict
    }

    private func saveKnownPeers() {
        guard let data = try? JSONEncoder().encode(knownPeers) else { return }
        UserDefaults.standard.set(data, forKey: knownPeersKey)
    }

    private func chatsFile() -> URL? {
        documentsDirectory()?.appendingPathComponent("Chat").appendingPathComponent("chats.json")
    }

    private func saveChats() {
        guard let file = chatsFile() else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(conversations) {
            try? data.write(to: file)
        }
    }

    private func loadChats() {
        guard let file = chatsFile(), let data = try? Data(contentsOf: file),
              let dict = try? JSONDecoder().decode([String: Conversation].self, from: data) else { return }
        conversations = dict
    }

    // MARK: - 后台任务

    func beginBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.backgroundTaskID == .invalid else { return }
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LanShare.transfer") {
                self.endBackgroundTask()
            }
        }
    }

    func endBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.backgroundTaskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
    }

    func documentsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}
