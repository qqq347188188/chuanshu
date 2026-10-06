//
//  NetUtils.swift
//  LanShare
//
//  本机网络信息：局域网 IP、子网掩码、广播地址、设备 ID。
//

import Darwin
import Foundation
import UIKit

enum NetUtils {

    struct Interface {
        let ip: String
        let netmask: String
    }

    /// 获取 Wi-Fi（en0）的 IPv4 地址与子网掩码
    static func wiFiInterface() -> Interface? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        var result: Interface?

        while let current = pointer {
            let ifa = current.pointee
            let family = ifa.ifa_addr.pointee.sa_family
            let name = String(cString: ifa.ifa_name)

            if family == UInt8(AF_INET), name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var netmask = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                var ipString: String?
                if getnameinfo(ifa.ifa_addr, socklen_t(MemoryLayout<sockaddr>.size),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if value != "0.0.0.0" { ipString = value }
                }
                var maskString: String?
                if let mask = ifa.ifa_netmask,
                   getnameinfo(mask, socklen_t(MemoryLayout<sockaddr>.size),
                               &netmask, socklen_t(netmask.count), nil, 0, NI_NUMERICHOST) == 0 {
                    maskString = String(cString: netmask)
                }
                if let ipString {
                    let candidate = Interface(ip: ipString, netmask: maskString ?? "255.255.255.0")
                    if result == nil || name == "en0" {
                        result = candidate
                    }
                    if name == "en0" { break }
                }
            }
            pointer = ifa.ifa_next
        }
        return result
    }

    static func localIP() -> String {
        wiFiInterface()?.ip ?? "未连接 Wi-Fi"
    }

    /// 由 IP 与掩码计算子网广播地址，如 192.168.1.255
    static func subnetBroadcast(ip: String, netmask: String) -> String? {
        let ipParts = ip.split(separator: ".").compactMap { UInt32($0) }
        let maskParts = netmask.split(separator: ".").compactMap { UInt32($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return nil }
        var out: [String] = []
        for index in 0..<4 {
            out.append(String(ipParts[index] | (~maskParts[index] & 0xFF)))
        }
        return out.joined(separator: ".")
    }

    /// 广播目标地址列表：全局广播 + 每个 IPv4 接口各自的子网广播 + /16 兜底。
    /// 遍历所有接口（而不是只认 en0），避免新设备活跃接口不是 en0 / 存在 VPN、个人热点等
    /// 导致子网广播算错、广播发不到同网段老设备（表现为“老设备看不到新设备”）。
    static func broadcastAddresses() -> [String] {
        var list = ["255.255.255.255"]

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return list }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let ifa = current.pointee
            let family = ifa.ifa_addr.pointee.sa_family
            let name = String(cString: ifa.ifa_name)
            if family == UInt8(AF_INET), !name.hasPrefix("lo") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var netmask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var ipString: String?
                if getnameinfo(ifa.ifa_addr, socklen_t(MemoryLayout<sockaddr>.size),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if value != "0.0.0.0", value != "127.0.0.1" { ipString = value }
                }
                var maskString: String?
                if let mask = ifa.ifa_netmask,
                   getnameinfo(mask, socklen_t(MemoryLayout<sockaddr>.size),
                               &netmask, socklen_t(netmask.count), nil, 0, NI_NUMERICHOST) == 0 {
                    maskString = String(cString: netmask)
                }
                if let ipString, let maskString {
                    if let subnet = subnetBroadcast(ip: ipString, netmask: maskString) {
                        list.append(subnet)
                    }
                    let parts = ipString.split(separator: ".").map(String.init)
                    if parts.count == 4 {
                        list.append("\(parts[0]).\(parts[1]).255.255")
                    }
                }
            }
            pointer = ifa.ifa_next
        }

        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// 设备唯一 ID（持久化）
    static func deviceID() -> String {
        let key = "LanShare.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }

    static func defaultDeviceName() -> String {
        UIDevice.current.name
    }
}
