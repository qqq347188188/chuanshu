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
