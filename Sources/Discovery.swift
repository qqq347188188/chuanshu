//
//  Discovery.swift
//  LanShare
//
//  UDP 广播发现：每 2 秒宣告自己，同时接收其它设备的宣告。
//

import Darwin
import Foundation

struct Peer: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var platform: String      // ios / windows
    var ip: String
    var port: Int
    var lastSeen: Date

    var address: String { "\(ip):\(port)" }
    var isIOS: Bool { platform == "ios" }
}

final class Discovery {

    private let selfID: String
    private var nameProvider: () -> String
    private var portProvider: () -> UInt16
    private var socketFD: Int32 = -1
    private var running = false

    private let workerQueue = DispatchQueue(label: "LanShare.Discovery")
    private var announceTimer: DispatchSourceTimer?
    private var pruneTimer: DispatchSourceTimer?

    private var peerDict: [String: Peer] = [:]
    private let lock = NSLock()

    var onPeersChanged: (([Peer]) -> Void)?

    init(selfID: String,
         nameProvider: @escaping () -> String = { "iPhone" },
         portProvider: @escaping () -> UInt16 = { 0 }) {
        self.selfID = selfID
        self.nameProvider = nameProvider
        self.portProvider = portProvider
    }

    /// 启动前设置（避免在 init 中捕获 self）
    func configure(nameProvider: @escaping () -> String, portProvider: @escaping () -> UInt16) {
        self.nameProvider = nameProvider
        self.portProvider = portProvider
    }

    deinit { stop() }

    // MARK: - 生命周期

    func start() {
        guard !running else { return }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        socketFD = fd

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = SocketIO.makeAddress(host: "", port: LanShareProtocol.discoveryPort)
        let bindResult = SocketIO.withSockaddr(&bindAddr) { pointer, length in
            bind(fd, pointer, length)
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            socketFD = -1
            return
        }

        running = true
        startAnnounceTimer()
        startPruneTimer()
        startReceiveLoop()
    }

    func stop() {
        running = false
        announceTimer?.cancel()
        pruneTimer?.cancel()
        announceTimer = nil
        pruneTimer = nil
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    // MARK: - 广播宣告

    private func startAnnounceTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.announce()
        }
        timer.resume()
        announceTimer = timer
    }

    func announce() {
        guard running, socketFD >= 0 else { return }
        let payload: [String: Any] = [
            "v": LanShareProtocol.version,
            "type": "announce",
            "app": LanShareProtocol.appName,
            "id": selfID,
            "name": nameProvider(),
            "platform": "ios",
            "port": Int(portProvider()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        for host in NetUtils.broadcastAddresses() {
            var addr = SocketIO.makeAddress(host: host, port: LanShareProtocol.discoveryPort)
            SocketIO.withSockaddr(&addr) { pointer, length in
                _ = data.withUnsafeBytes { raw in
                    sendto(socketFD, raw.baseAddress, data.count, 0, pointer, length)
                }
            }
        }
    }

    // MARK: - 接收

    private func startReceiveLoop() {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            let fd = self.socketFD
            var buffer = [UInt8](repeating: 0, count: 65536)
            var sourceAddr = sockaddr_in()

            while self.running {
                var addrLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let capacity = buffer.count
                let readCount = SocketIO.withSockaddr(&sourceAddr) { pointer, _ in
                    buffer.withUnsafeMutableBytes { raw -> Int in
                        recvfrom(fd, raw.baseAddress, capacity, 0,
                                 UnsafeMutablePointer(mutating: pointer), &addrLength)
                    }
                }

                if readCount > 0 {
                    let data = Data(bytes: buffer, count: readCount)
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    var ip = ""
                    SocketIO.withSockaddr(&sourceAddr) { pointer, length in
                        if getnameinfo(pointer, length, &host, socklen_t(host.count),
                                       nil, 0, NI_NUMERICHOST) == 0 {
                            ip = String(cString: host)
                        }
                    }
                    self.handle(data, fromIP: ip)
                } else if readCount < 0 && errno != EINTR {
                    if !self.running { break }
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
        }
    }

    private func handle(_ data: Data, fromIP ip: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["app"] as? String == LanShareProtocol.appName,
              dict["type"] as? String == "announce",
              let id = dict["id"] as? String,
              id != selfID,
              let port = dict["port"] as? Int else { return }

        let peer = Peer(
            id: id,
            name: dict["name"] as? String ?? "未知设备",
            platform: dict["platform"] as? String ?? "?",
            ip: ip.isEmpty ? "未知" : ip,
            port: port,
            lastSeen: Date()
        )

        lock.lock()
        peerDict[id] = peer
        let snapshot = Array(peerDict.values)
        lock.unlock()

        publish(snapshot)
    }

    // MARK: - 过期清理

    private func startPruneTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.prune()
        }
        timer.resume()
        pruneTimer = timer
    }

    private func prune() {
        let deadline = Date().addingTimeInterval(-8.0)
        lock.lock()
        let before = peerDict.count
        peerDict = peerDict.filter { $0.value.lastSeen > deadline }
        let changed = peerDict.count != before
        let snapshot = Array(peerDict.values)
        lock.unlock()
        if changed {
            publish(snapshot)
        }
    }

    private func publish(_ snapshot: [Peer]) {
        let sorted = snapshot.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in
            self?.onPeersChanged?(sorted)
        }
    }
}
