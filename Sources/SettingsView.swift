//
//  SettingsView.swift
//  LanShare
//
//  本机信息 + 局域网设备列表（点击设备可直接进入对话）。
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: LanShareModel
    @State private var showingClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("设备名称")
                        Spacer(minLength: 8)
                        TextField("名称", text: $model.deviceName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                    }
                    InfoRow(title: "IP 地址", value: model.localIP)
                    InfoRow(title: "接收端口", value: model.port == 0 ? "启动中…" : String(model.port))
                } header: {
                    Text("本机")
                } footer: {
                    Text("名称修改后 2 秒内会广播给局域网内的其它设备。")
                }

                Section {
                    if model.peers.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在搜索同一局域网内的设备…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(model.peers) { peer in
                            NavigationLink(value: peer.id) {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(model.isOnline(peer.id) ? Color.green : Color.gray.opacity(0.5))
                                        .frame(width: 10, height: 10)
                                    Image(systemName: peer.isIOS ? "iphone" : "desktopcomputer")
                                        .foregroundStyle(Color.accentBrand)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.name).foregroundStyle(.primary)
                                        Text(peer.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                } header: {
                    Text("局域网设备")
                } footer: {
                    Text("所有设备需连接同一个 Wi-Fi。Windows 端若被防火墙拦截，请在弹窗中选择允许访问。")
                }

                Section {
                    HStack {
                        Text("聊天文件缓存")
                        Spacer(minLength: 8)
                        Text(cacheText)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showingClear = true
                    } label: {
                        Text("清除缓存")
                    }
                } header: {
                    Text("存储")
                } footer: {
                    Text("包含所有收发文件的本地副本。清除后，历史中的文件将无法再打开，聊天文字记录保留。")
                }

                Section {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("状态")
                }
            }
            .navigationTitle("设置")
            .listStyle(.insetGrouped)
            .navigationDestination(for: String.self) { id in
                ChatThreadView(conversationID: id)
            }
            .onAppear { model.refreshCache() }
            .confirmationDialog("确定清除所有聊天文件缓存？此操作不可撤销。",
                                 isPresented: $showingClear, titleVisibility: .visible) {
                Button("清除", role: .destructive) { model.clearCache() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var cacheText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: model.cacheBytes)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
