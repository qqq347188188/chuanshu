//
//  ShareViewController.swift
//  ShareExtension
//
//  「用 LanShare 打开」分享扩展：把其它 App 选中的文件写入 App Group 收件箱，
//  由主 App（LanShare）在打开 / 回到前台时读取并发送。
//
//  注意：本扩展依赖 App Group（group.com.lanshare.app）。若开发者账号未开启
//  App Group（如免费个人账号），containerURL 会返回 nil，文件将无法跨进程传递；
//  此时请使用主 App 注册的「用 LanShare 打开」文档类型（不需要 App Group）作为兜底。

import UniformTypeIdentifiers
import UIKit

class ShareViewController: UIViewController {

    private let appGroupID = "group.com.lanshare.app"

    private let spinner = UIActivityIndicatorView(style: .large)

    /// 保证扩展必定结束（避免某个 provider 回调不来时无限转圈）
    private var finished = false
    private let finishLock = NSLock()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()
        processInput()
    }

    // MARK: - 处理分享内容

    private func processInput() {
        guard let context = extensionContext else { finish(openApp: false); return }

        let providers = context.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        // 没有任何可分享内容时，直接尝试跳回主 App（让它在前台时去读收件箱）
        guard !providers.isEmpty else {
            finish(openApp: true)
            return
        }

        // 保底：最多等待 30 秒，避免个别 provider 不回调时无限转圈
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(openApp: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [(URL, String)] = []

        for provider in providers {
            group.enter()
            loadFile(from: provider) { url, name in
                if let url, let name {
                    lock.lock()
                    collected.append((url, name))
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            let saved = self?.saveToInbox(collected) ?? false
            if !saved {
                // App Group 不可用（TrollStore / 自签 / 免费账号常见）：无法跨进程传文件。
                // 明确提示用户改用系统“用 LanShare 打开”文档类型（无需 App Group）。
                self?.showAppGroupUnavailableHint()
            } else {
                self?.finish(openApp: true)
            }
        }
    }

    /// 结束扩展。openApp=true 时尝试跳回主 App（触发收件箱导入），
    /// 若无法打开主 App 再直接完成。
    private func finish(openApp: Bool) {
        guard !finished else { return }
        finishLock.lock()
        if finished {
            finishLock.unlock()
            return
        }
        finished = true
        finishLock.unlock()

        guard let context = extensionContext else { return }
        if openApp, let url = URL(string: "lanshare://shared") {
            // 跳回主 App，由主 App 读取收件箱并进入发送流程。
            // 若打开失败（例如未安装主 App），则直接完成扩展。
            context.open(url) { success in
                if !success {
                    context.completeRequest(returningItems: nil, completionHandler: nil)
                }
            }
        } else {
            context.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func loadFile(from provider: NSItemProvider,
                          completion: @escaping (URL?, String?) -> Void) {
        // 1) 文件 URL（来自“文件”App、相册导出的文件等）
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    completion(url, url.lastPathComponent)
                } else {
                    completion(nil, nil)
                }
            }
            return
        }
        // 2) 任意数据 / 文本：落到临时目录后再移交
        let type = provider.registeredTypeIdentifiers.first ?? UTType.item.identifier
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            if let url = item as? URL {
                completion(url, url.lastPathComponent)
            } else if let data = item as? Data {
                let name = "shared-\(UUID().uuidString).bin"
                completion(self?.stage(data: data, name: name), name)
            } else if let text = item as? String {
                let data = Data(text.utf8)
                let name = "shared-\(UUID().uuidString).txt"
                completion(self?.stage(data: data, name: name), name)
            } else {
                completion(nil, nil)
            }
        }
    }

    private func stage(data: Data, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        return (try? data.write(to: url)) != nil ? url : nil
    }

    // MARK: - 写入 App Group 收件箱

    /// 返回是否成功写入。App Group 不可用时返回 false（主 App 无法跨进程读取）。
    private func saveToInbox(_ items: [(URL, String)]) -> Bool {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            // App Group 不可用时无法跨进程传递文件：交由主 App 的“用 LanShare 打开”
            // 文档类型（系统会把文件直接放进 Documents/Inbox）兜底。
            return false
        }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        var manifest: [[String: String]] = []
        for (source, name) in items {
            let folder = UUID().uuidString
            let destDir = inbox.appendingPathComponent(folder, isDirectory: true)
            let dest = destDir.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            _ = try? FileManager.default.copyItem(at: source, to: dest)
            manifest.append(["id": folder, "name": name, "relativePath": "\(folder)/\(name)"])
        }

        if let data = try? JSONSerialization.data(withJSONObject: manifest) {
            try? data.write(to: inbox.appendingPathComponent("manifest.json"))
        }
        return true
    }

    /// App Group 不可用时（TrollStore / 自签 / 免费账号）的兜底提示：
    /// 分享扩展无法跨进程传文件，引导用户改用系统“用 LanShare 打开”文档类型。
    private func showAppGroupUnavailableHint() {
        let alert = UIAlertController(
            title: "无法接收文件",
            message: "当前安装方式（如 TrollStore / 自签）未启用 App Group，分享扩展无法把文件传给主程序。\n\n请改用「打开方式」：在“文件”App 中长按文件 → 打开方式（用…打开）→ 局域网互传。系统会直接把文件传入主程序，无需 App Group，可正常发送。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default) { [weak self] _ in
            self?.finish(openApp: false)
        })
        present(alert, animated: true)
    }
}
