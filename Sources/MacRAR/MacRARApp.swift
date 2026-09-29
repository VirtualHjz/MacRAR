import SwiftUI
import AppKit
import MacRARCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        DispatchQueue.main.async {
            self.appState?.openArchive(at: url)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let path = filenames.first else { return }
        DispatchQueue.main.async {
            self.appState?.openArchive(at: URL(fileURLWithPath: path))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    // Finder 服务：解压到当前文件夹
    @objc func extractService(_ sender: Any?) {
        let pb = NSPasteboard(name: .find)
        guard let items = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return }
        DispatchQueue.main.async {
            guard let first = items.first else { return }
            self.appState?.openArchive(at: first)
            self.appState?.showExtractSheet = true
        }
    }

}

@main
struct MacRARApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("MacRAR") {
            MainWindowView(appState: appState)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    appDelegate.appState = appState
                }
                .onOpenURL { url in
                    appState.openArchive(at: url)
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("打开归档...") {
                    openArchivePanel()
                }
                .keyboardShortcut("o")
                Button("后退") {
                    _ = appState.goBack()
                }
                .keyboardShortcut("[")
                Button("前进") {
                    _ = appState.goForward()
                }
                .keyboardShortcut("]")
                Button("上级目录") {
                    appState.goUp()
                }
                .keyboardShortcut(KeyEquivalent.upArrow, modifiers: .command)
            }
            CommandMenu("命令") {
                Button("解压到...") { appState.showExtractSheet = true }
                    .disabled(!appState.isBrowsingArchive)
                Button("测试归档") { appState.showTestSheet = true }
                    .disabled(!appState.isBrowsingArchive)
                Button("修复归档") { appState.showRepairSheet = true }
                    .disabled(!appState.isBrowsingArchive)
                Button("显示信息") { appState.showInfoSheet = true }
                    .disabled(!appState.isBrowsingArchive)
            }
            CommandMenu("工具") {
                Button("创建自解压 (SFX)") { appState.showCreateSheet = true }
                Button("转换格式") { appState.showCreateSheet = true }
                Button("设置...") { appState.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("MacRAR 帮助") {
                    showHelp()
                }
            }
        }
    }

    private func openArchivePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .archive, .data, .item]
        if panel.runModal() == .OK, let url = panel.url {
            appState.openArchive(at: url)
        }
    }

    private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "MacRAR — 解压软件"
        alert.informativeText = "功能完全复刻 WinRAR\n\n· 支持 RAR / ZIP / 7z / TAR / GZ / BZ2 / XZ 等格式\n· 密码加密、分卷、固实、自解压\n· 中文编码自动识别 (GBK/UTF-8)\n· 测试、修复、信息、转换\n\nRAR 压缩需要安装 RARLAB rar 命令行工具。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
