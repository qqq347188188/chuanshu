//
//  TransferServer.swift
//  LanShare
//
//  TCP 接收端：优先监听 53521，被占用时改用随机端口。
//  文本直接回调；文件边收边写到 Documents/Received，内存占用恒定。
//

import Darwin
import Foundation

final class TransferServer {

    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "LanShare.Server")
    private(set) var port: UInt16 = 0

    var onText: ((String, String, String, String) -> Void)?   // (内容, 来源设备名, 来源设备ID, 来源IP)
    var onFile: ((URL, String, Int64, String, String) -> Void)? // (本地URL, 来源名, 字节数, 来源ID, 来源IP)
    var onProgress: ((String, Int64, Int64) -> Void)?   // (文件名, 已收, 总数)
    var onActivity: ((Bool) -> Void)?                   // true=开始传输 false=结束

    // MARK: - 启动 / 停止

    func start() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        SocketIO.disableSigPipe(fd)

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var preferred = SocketIO.makeAddress(host: "", port: LanShareProtocol.preferredTCPPort)
        var bindResult = SocketIO.withSockaddr(&preferred) { pointer, length in
            bind(fd, pointer, length)
        }
        if bindResult != 0 {
            var any = SocketIO.makeAddress(host: "", port: 0)
            bindResult = SocketIO.withSockaddr(&any) { pointer, length in
                bind(fd, pointer, length)
            }
            guard bindResult == 0 else {
                Darwin.close(fd)
                return false
            }
        }
        guard listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return false
        }

        var boundAddr = SocketIO.makeAddress(host: "", port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = SocketIO.withSockaddr(&boundAddr) { pointer, _ in
            getsockname(fd, UnsafeMutablePointer(mutating: pointer), &length)
        }
        if nameResult == 0 {
            port = UInt16(bigEndian: boundAddr.sin_port)
        }

        listenFD = fd
        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
        return true
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    // MARK: - 连接处理

    private func acceptLoop() {
        while running {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(listenFD, sockaddrPtr, &len)
                }
            }
            if clientFD < 0 {
                if running {
                    usleep(200_000)
                    continue
                }
                break
            }
            SocketIO.disableSigPipe(clientFD)
            let peerIP = TransferServer.peerIP(from: addr)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleConnection(clientFD, peerIP: peerIP)
            }
        }
    }

    /// 从 sockaddr_in 取出对端 IPv4 地址（用于按设备建立会话）
    private static func peerIP(from addr: sockaddr_in) -> String {
        var addrCopy = addr
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addrCopy) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getnameinfo(sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return result == 0 ? String(cString: host) : ""
    }

    private func handleConnection(_ fd: Int32, peerIP: String) {
        onActivity?(true)
        defer {
            SocketIO.close(fd)
            onActivity?(false)
        }

        while true {
            guard let header = SocketIO.readHeader(fd) else { return }
            switch header.kind {
            case "text":
                let data = SocketIO.readExact(fd, count: header.size) ?? Data()
                let text = String(data: data, encoding: .utf8) ?? ""
                _ = SocketIO.writeHeader(fd, header: .ack(id: header.id))
                onText?(text, header.from, header.src, peerIP)
            case "file":
                let ok = receiveFile(fd, header: header, src: header.src, peerIP: peerIP)
                _ = SocketIO.writeHeader(fd, header: .ack(id: header.id, ok: ok))
                if !ok { return }
            default:
                return
            }
        }
    }

    // MARK: - 文件接收

    private func receiveFile(_ fd: Int32, header: FrameHeader, src: String, peerIP: String) -> Bool {
        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let directory = documents.appendingPathComponent("Received", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = uniqueURL(for: directory.appendingPathComponent(safeFileName(header.name)))
        guard manager.createFile(atPath: target.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: target) else {
            return false
        }
        defer { try? handle.close() }

        let total = max(header.size, 0)
        var received = 0
        var lastReport = Date()

        while received < total {
            let toRead = min(LanShareProtocol.chunkSize, total - received)
            guard let chunk = SocketIO.readExact(fd, count: toRead) else { break }
            handle.write(chunk)
            received += chunk.count
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.2 || received == total {
                lastReport = now
                onProgress?(target.lastPathComponent, Int64(received), Int64(total))
            }
        }

        guard received == total else {
            try? manager.removeItem(at: target)
            return false
        }
        onFile?(target, header.from, Int64(total), src, peerIP)
        return true
    }

    // MARK: - 文件命名

    private func safeFileName(_ name: String) -> String {
        var value = (name as NSString).lastPathComponent
        if value.isEmpty { value = "file.bin" }
        let invalid = CharacterSet(charactersIn: "/\\:?*<>|\"")
        value = value.components(separatedBy: invalid).joined(separator: "_")
        return value.isEmpty ? "file.bin" : value
    }

    private func uniqueURL(for url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        var index = 1
        while true {
            let candidateName = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !manager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
