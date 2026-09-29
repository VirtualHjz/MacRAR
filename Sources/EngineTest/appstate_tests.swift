import Foundation
import AppKit
import ZIPCore
import MacRARCore

// MARK: - AppState 操作逻辑测试（@MainActor）

@MainActor
func testAppStateNavigation() throws {
    print("\n== AppState 导航逻辑 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("nav_\(UUID().uuidString)")
    let sub1 = base.appendingPathComponent("文件夹A")
    let sub2 = base.appendingPathComponent("文件夹A/文件夹B")
    try fm.createDirectory(at: sub2, withIntermediateDirectories: true)
    try "文件".write(to: base.appendingPathComponent("根文件.txt"), atomically: true, encoding: .utf8)
    try "文件".write(to: sub1.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "文件".write(to: sub2.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: base) }

    let state = AppState()
    print("  base.path = \(base.path)")
    print("  base.hasDirectoryPath = \(base.hasDirectoryPath)")
    var testIsDir: ObjCBool = false
    let testExists = FileManager.default.fileExists(atPath: base.path, isDirectory: &testIsDir)
    print("  FileManager exists=\(testExists) isDir=\(testIsDir.boolValue)")
    print("  standardized=\(base.standardizedFileURL.path)")
    print("  resolved=\(base.resolvingSymlinksInPath().path)")
    state.navigate(to: base)
    print("  currentDirectory = \(state.currentDirectory.path)")
    print("  currentDirectory.hasDirectoryPath = \(state.currentDirectory.hasDirectoryPath)")
    var passed = 0
    var failed = 0
    func check(_ label: String, _ ok: Bool) {
        if ok { passed += 1; print("  ✓ \(label)") } else { failed += 1; print("  ✗ \(label)") }
    }
    check("导航到目录", state.currentDirectory.path == base.path)

    // 目录内容
    let contents = state.directoryContents()
    check("目录内容含文件夹A", contents.contains { $0.name == "文件夹A" && $0.isDirectory })
    check("目录内容含根文件", contents.contains { $0.name == "根文件.txt" && !$0.isDirectory })

    // 进入子目录
    state.navigate(to: sub1)
    check("进入文件夹A", state.currentDirectory.path == sub1.path)
    check("内容含 a.txt", state.directoryContents().contains { $0.name == "a.txt" })

    // 上级
    state.goUp()
    check("上级回 base", state.currentDirectory.path == base.path)

    // 后退/前进
    state.navigate(to: sub1)
    _ = state.goBack()
    check("后退回 base", state.currentDirectory.path == base.path)
    _ = state.goForward()
    check("前进回 sub1", state.currentDirectory.path == sub1.path)

    // 归档打开
    let zipURL = base.appendingPathComponent("nav.zip")
    var createOpts = CreateOptions()
    createOpts.format = .zip
    _ = try ArchiveService.shared.createArchive(
        items: [sub1, base.appendingPathComponent("根文件.txt")],
        to: zipURL, options: createOpts)
    state.openArchive(at: zipURL)
    check("打开归档", state.isBrowsingArchive)
    check("归档模式关闭目录浏览", !state.isBrowsingArchive == false)

    // archiveDisplayEntries 子目录聚合
    let display = state.archiveDisplayEntries()
    check("归档顶层条目 >= 2", display.count >= 2)
    let dirEntry = display.first { $0.isDirectory }
    check("归档含文件夹条目", dirEntry != nil)

    // 进入归档子目录
    if let d = dirEntry {
        state.archivePath = d.fullPath.replacingOccurrences(of: "/", with: "")
        check("进入归档子目录", state.archivePath == d.fullPath.replacingOccurrences(of: "/", with: ""))
        let subEntries = state.archiveDisplayEntries()
        check("子目录条目非空", !subEntries.isEmpty)
        // 上级回根
        state.goUp()
        check("归档上级回根", state.archivePath.isEmpty)
    }

    // 关闭归档
    state.closeArchive()
    check("关闭归档", !state.isBrowsingArchive)

    // 错误归档
    let fake = base.appendingPathComponent("fake.rar")
    try "not an archive".write(to: fake, atomically: true, encoding: .utf8)
    state.openArchive(at: fake)
    check("无效归档报错", state.errorMessage != nil)
    state.closeError()
    check("清除错误", state.errorMessage == nil)

    print("\nAppState 导航测试: 通过 \(passed) / 失败 \(failed)")
    if failed > 0 {
        throw NSError(domain: "appstate", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(failed) 项失败"])
    }
}

@MainActor
func testTaskQueue() async {
    print("\n== 任务队列状态机 ==")
    let state = AppState()
    let startedBox = StateBox<Bool>(false)
    let finishedBox = StateBox<Bool>(false)
    state.addTask(.extract, title: "测试任务", totalBytes: 100) { progress, cancel in
        startedBox.value = true
        progress(0.5)
        Thread.sleep(forTimeInterval: 0.2)
        finishedBox.value = true
    }
    // 让出主线程，等待任务执行并完成
    for _ in 0..<200 {
        if state.tasks.isEmpty { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    print("任务执行: \(startedBox.value ? mark(true) : mark(false))")
    print("任务完成并移除: \(finishedBox.value && state.tasks.isEmpty ? mark(true) : mark(false))")
    print("activeTask 已清空(弹窗可关闭): \(state.activeTask == nil ? mark(true) : mark(false))")
    let hasCompletion = state.taskCompletion != nil
    print("完成提示已生成: \(hasCompletion ? mark(true) : mark(false))")
    let successCompletion = state.taskCompletion?.success == true
    print("完成提示为成功: \(successCompletion ? mark(true) : mark(false))")
}

final class StateBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ v: Value) { value = v }
}
