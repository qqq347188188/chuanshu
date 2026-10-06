//
//  ContentView.swift
//  LanShare
//

import SwiftUI

struct ContentView: View {
    @StateObject private var model = LanShareModel()
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            ChatListView()
                .navigationTitle("局域网互传")
                .navigationDestination(for: String.self) { id in
                    ChatThreadView(conversationID: id)
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
        .tint(Color.accentBrand)
        .environmentObject(model)
        .onOpenURL { url in
            if url.scheme == "lanshare" {
                model.importSharedInbox()
            } else if url.isFileURL {
                model.importFileURL(url)
            }
        }
        .onAppear {
            model.start()
            // 默认首页为最近一次打开的聊天窗口
            if path.isEmpty, let id = model.lastConversationID, model.conversations[id] != nil {
                path.append(id)
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                model.beginBackgroundTask()
            case .active:
                model.refreshLocalInfo()
                model.importSharedInbox()
                model.endBackgroundTask()
            default:
                break
            }
        }
    }
}

extension Color {
    static let accentBrand = Color(red: 0.30, green: 0.40, blue: 0.95)
}
