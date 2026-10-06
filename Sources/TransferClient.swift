//
//  TransferClient.swift
//  LanShare
//
//  TCP 发送端：连接对方 IP:端口，写帧 → 写数据 → 等 ack。
//  大文件用 InputStream 分块读取，内存占用恒定。
//

import Darwin
import Foundation

enum TransferError: LocalizedError {
    case connectionFailed
    case sendFailed
    case noAck
    case rejected(String)
    case fileUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "无法连接到对方，请确认：(1) 对方已打开 LanShare 且在同一 Wi-Fi；(2) Windows 防火墙已允许本程序通过（专用+公用网络）；(3) 路由器未开启“AP 隔离 / 客户端隔离”"
        case .sendFailed: return "传输中断，请检查网络后重试"
        case .noAck: return "未收到对方确认，传输可能未完成"
        case .rejected(let message):
            return message.isEmpty ? "对方拒绝或接收失败" : "对方返回错误：\(message)"
        case .fileUnavailable: return "无法读取所选文件"
        }
    }
}

enum TransferClient {

    private static func connect(host: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        SocketIO.disableSigPipe(fd)

        // 连接超时：避免默认 TCP 重传导致界面长时间卡在“正在发送”（最长可达数十秒）。
        // 连接成功后恢复为阻塞模式，确保大文件传输不被发送超时打断。
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = SocketIO.makeAddress(host: host, port: port)
        let result = SocketIO.withSockaddr(&addr) { pointer, length in
            Darwin.connect(fd, pointer, length)
        }
        if result != 0 {
            Darwin.close(fd)
            return -1
        }
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// 发送文本（无长度限制）
    static func sendText(host: String, port: UInt16, text: String, from: String, src: String) -> Result<Void, TransferError> {
        let fd = connect(host: host, port: port)
        guard fd >= 0 else { return .failure(.connectionFailed) }
        defer { SocketIO.close(fd) }

        let header = FrameHeader.text(text, from: from, src: src)
        guard SocketIO.writeHeader(fd, header: header),
              SocketIO.writeAll(fd, data: Data(text.utf8)) else {
            return .failure(.sendFailed)
        }
        guard let ack = SocketIO.readHeader(fd) else { return .failure(.noAck) }
        return ack.ok ? .success(()) : .failure(.rejected(ack.msg))
    }

    /// 发送文件（流式，进度回调在后台线程）
    static func sendFile(host: String, port: UInt16, fileURL: URL, from: String, src: String,
                         progress: ((Int64, Int64) -> Void)? = nil) -> Result<Void, TransferError> {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, size >= 0 else { return .failure(.fileUnavailable) }

        let fd = connect(host: host, port: port)
        guard fd >= 0 else { return .failure(.connectionFailed) }
        defer { SocketIO.close(fd) }

        guard let stream = InputStream(url: fileURL) else { return .failure(.fileUnavailable) }
        stream.open()
        defer { stream.close() }

        let header = FrameHeader.file(name: fileURL.lastPathComponent, size: size, from: from, src: src)
        guard SocketIO.writeHeader(fd, header: header) else { return .failure(.sendFailed) }

        var buffer = [UInt8](repeating: 0, count: LanShareProtocol.chunkSize)
        var sent = 0
        while sent < size {
            let toRead = min(buffer.count, size - sent)
            let readCount = stream.read(&buffer, maxLength: toRead)
            if readCount <= 0 { break }
            guard SocketIO.writeAll(fd, data: Data(bytes: buffer, count: readCount)) else {
                return .failure(.sendFailed)
            }
            sent += readCount
            progress?(Int64(sent), Int64(size))
        }

        guard sent == size else { return .failure(.sendFailed) }
        guard let ack = SocketIO.readHeader(fd) else { return .failure(.noAck) }
        return ack.ok ? .success(()) : .failure(.rejected(ack.msg))
    }
}
