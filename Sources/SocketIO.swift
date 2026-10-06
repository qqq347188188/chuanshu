//
//  SocketIO.swift
//  LanShare
//
//  协议常量 + BSD Socket 读写工具（与 Windows 端完全一致的帧格式）
//

import Darwin
import Foundation

enum LanShareProtocol {
    static let appName = "LanShare"
    static let version = 1
    static let discoveryPort: UInt16 = 53520
    static let preferredTCPPort: UInt16 = 53521
    static let chunkSize = 256 * 1024
    static let maxHeaderSize = 1024 * 1024
}

/// 帧头部：{"v":1,"kind":"text|file|ack|error","id":"","name":"","size":0,"from":"","ok":true,"msg":""}
struct FrameHeader {
    var kind: String
    var id: String
    var name: String
    var size: Int
    var from: String
    var src: String = ""        // 发送方设备唯一 ID（对话会话的 key）
    var ok: Bool = true
    var msg: String = ""

    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "v": LanShareProtocol.version,
            "kind": kind,
            "id": id,
            "name": name,
            "size": size,
            "from": from,
            "src": src,
        ]
        if kind == "ack" || kind == "error" {
            dict["ok"] = ok
            dict["msg"] = msg
        }
        return dict
    }

    func encoded() -> Data? {
        try? JSONSerialization.data(withJSONObject: dictionary)
    }

    static func decode(_ data: Data) -> FrameHeader? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let kind = dict["kind"] as? String,
              (dict["v"] as? Int) == LanShareProtocol.version else {
            return nil
        }
        return FrameHeader(
            kind: kind,
            id: dict["id"] as? String ?? "",
            name: dict["name"] as? String ?? "",
            size: dict["size"] as? Int ?? 0,
            from: dict["from"] as? String ?? "",
            src: dict["src"] as? String ?? "",
            ok: dict["ok"] as? Bool ?? true,
            msg: dict["msg"] as? String ?? ""
        )
    }

    static func text(_ text: String, from: String, src: String) -> FrameHeader {
        var h = FrameHeader(kind: "text", id: UUID().uuidString, name: "文本",
                            size: text.utf8.count, from: from)
        h.src = src
        return h
    }

    static func file(name: String, size: Int, from: String, src: String) -> FrameHeader {
        var h = FrameHeader(kind: "file", id: UUID().uuidString, name: name, size: size, from: from)
        h.src = src
        return h
    }

    static func ack(id: String, ok: Bool = true, msg: String = "") -> FrameHeader {
        FrameHeader(kind: "ack", id: id, name: "", size: 0, from: "", ok: ok, msg: msg)
    }
}

enum SocketIO {

    // MARK: - 通用设置

    static func disableSigPipe(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    static func makeAddress(host: String, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if host.isEmpty {
            addr.sin_addr.s_addr = 0
        } else {
            inet_pton(AF_INET, host, &addr.sin_addr)
        }
        return addr
    }

    /// 把 sockaddr_in 转成 sockaddr 指针执行系统调用
    static func withSockaddr<T>(_ addr: inout sockaddr_in,
                                _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                body(rebound, length)
            }
        }
    }

    // MARK: - 读写

    /// 精确读取 count 字节，连接断开返回 nil
    static func readExact(_ fd: Int32, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(LanShareProtocol.chunkSize, count))
        while data.count < count {
            let remaining = count - data.count
            let toRead = min(buffer.count, remaining)
            let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(fd, base, toRead, 0)
            }
            if readCount <= 0 { return nil }
            data.append(buffer, count: readCount)
        }
        return data
    }

    /// 完整写入，失败返回 false
    static func writeAll(_ fd: Int32, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base.advanced(by: sent), data.count - sent, 0)
            }
            if written <= 0 { return false }
            sent += written
        }
        return true
    }

    // MARK: - 帧

    /// 写一帧头部（不含数据体）；数据体由调用方继续 writeAll
    static func writeHeader(_ fd: Int32, header: FrameHeader) -> Bool {
        guard let raw = header.encoded() else { return false }
        var length = UInt32(raw.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        return writeAll(fd, data: lengthData) && writeAll(fd, data: raw)
    }

    static func readHeader(_ fd: Int32) -> FrameHeader? {
        guard let lengthData = readExact(fd, count: 4), lengthData.count == 4 else { return nil }
        let bytes = [UInt8](lengthData)
        let rawLength = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        let length = Int(rawLength)
        guard length > 0, length <= LanShareProtocol.maxHeaderSize else { return nil }
        guard let raw = readExact(fd, count: length) else { return nil }
        return FrameHeader.decode(raw)
    }

    static func close(_ fd: Int32) {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
