//
//  ChatListView.swift
//  LanShare
//
//  会话列表：按设备分组的聊天入口；未聊过的在线设备也可直接发起对话。
//

import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var model: LanShareModel

    /// 已存在的会话
    private var conversations: [Conversation] { model.sortedConversations }

    /// 可作为发送目标的设备：在线设备 + 历史配对（离线）设备，且尚未建会话
    private var newDevices: [Peer] {
        model.displayDevices.filter { model.conversations[$0.id] == nil }
    }

    var body: some View {
        List {
            Section {
                if conversations.isEmpty && newDevices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在搜索同一局域网内的设备…")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("所有设备需连接同一个 Wi-Fi 才能实时发现。已配对过的设备（曾被发现或聊过）会一直保留在列表中并标记为离线，可预先发送，待对方回到同一局域网并上线后自动补发；未配对过的陌生设备不会凭空出现。")
            }

            if !conversations.isEmpty {
                Section("对话") {
                    ForEach(conversations) { conv in
                        NavigationLink(value: conv.id) {
                            row(for: conv)
                        }
                    }
                }
            }

            if !newDevices.isEmpty {
                Section("设备（在线可直发 · 离线将排队）") {
                    ForEach(newDevices) { peer in
                        NavigationLink(value: peer.id) {
                            peerRow(peer)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for conv: Conversation) -> some View {
        HStack(spacing: 12) {
            statusDot(online: model.isOnline(conv.id))
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.name).foregroundStyle(.primary)
                Text(conv.lastSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(conv.lastTime.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func peerRow(_ peer: Peer) -> some View {
        let online = model.isOnline(peer.id)
        return HStack(spacing: 12) {
            statusDot(online: online)
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.name).foregroundStyle(.primary)
                Text(online ? peer.address : "离线 · 消息将排队，上线后自动发送")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: peer.isIOS ? "iphone" : "desktopcomputer")
                .foregroundStyle(online ? Color.accentBrand : Color.gray.opacity(0.5))
        }
    }

    private func statusDot(online: Bool) -> some View {
        Circle()
            .fill(online ? Color.green : Color.gray.opacity(0.5))
            .frame(width: 10, height: 10)
    }
}
