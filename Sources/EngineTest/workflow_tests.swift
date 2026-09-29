import Foundation
import ZIPCore
import MacRARCore

// MARK: - 完整操作流程测试（模拟用户操作链路）

func testFullWorkflow() throws {
    print("\n== 完整操作流程: 创建→打开→解压→编辑→转换→测试→修复 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("wf_\(UUID().uuidString)")
    let workDir = base.appendingPathComponent("work")
    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    // 准备源文件
    let doc = workDir.appendingPathComponent("文档.txt")
    try "工作流文档内容".write(to: doc, atomically: true, encoding: .utf8)
    let data = workDir.appendingPathComponent("data.bin")
    var random = Data(count: 200_000)
    _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 200_000, $0.baseAddress!) }
    try random.write(to: data)
    let sub = workDir.appendingPathComponent("子目录")
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    try "子目录文件".write(to: sub.appendingPathComponent("子文件.txt"), atomically: true, encoding: .utf8)

    let svc = ArchiveService.shared
    var passed = 0
    var failed = 0
    func check(_ label: String, _ ok: Bool) {
        if ok { passed += 1; print("  ✓ \(label)") } else { failed += 1; print("  ✗ \(label)") }
    }

    // 1. 创建 ZIP（含目录）
    let zipURL = workDir.appendingPathComponent("工作.zip")
    var createOpts = CreateOptions()
    createOpts.format = .zip
    _ = try svc.createArchive(items: [doc, data, sub], to: zipURL, options: createOpts)
    check("创建 ZIP", fm.fileExists(atPath: zipURL.path))

    // 2. 打开归档（打开方式流程）
    let info = try svc.openArchive(url: zipURL)
    check("打开归档: \(info.format.displayName)", info.format == .zip)
    check("归档条目数 >= 3", info.entries.count >= 3)
    check("含子目录文件", info.entries.contains { $0.fullPath.contains("子文件") })

    // 3. 归档内导航（archiveDisplayEntries 逻辑）
    let rootEntries = info.entries
    _ = rootEntries

    // 4. 解压全部
    let extractDir = base.appendingPathComponent("extract")
    var extractOpts = ExtractOptions(destination: extractDir)
    try svc.extract(info: info, options: extractOpts)
    check("解压后文档存在", fm.fileExists(atPath: extractDir.appendingPathComponent("文档.txt").path))
    check("解压后子文件存在", fm.fileExists(atPath: extractDir.appendingPathComponent("子目录/子文件.txt").path))
    let docContent = (try? String(contentsOf: extractDir.appendingPathComponent("文档.txt"), encoding: .utf8)) ?? ""
    check("解压内容一致", docContent == "工作流文档内容")

    // 5. 归档内编辑:添加文件
    let newFile = workDir.appendingPathComponent("新文件.txt")
    try "新添加文件".write(to: newFile, atomically: true, encoding: .utf8)
    var addOp = ArchiveService.EditOperation()
    addOp.addFiles = [newFile]
    let editedURL = try svc.editArchive(info: info, operation: addOp, to: base.appendingPathComponent("edited.zip"))
    let editedInfo = try svc.openArchive(url: editedURL)
    check("添加后条目含新文件", editedInfo.entries.contains { $0.fullPath == "新文件.txt" })
    check("添加后保留原文件", editedInfo.entries.contains { $0.fullPath == "文档.txt" })

    // 6. 归档内编辑:删除
    var delOp = ArchiveService.EditOperation()
    delOp.removePaths = ["文档.txt"]
    let delURL = try svc.editArchive(info: editedInfo, operation: delOp, to: base.appendingPathComponent("deleted.zip"))
    let delInfo = try svc.openArchive(url: delURL)
    check("删除后文档移除", !delInfo.entries.contains { $0.fullPath == "文档.txt" })
    check("删除后新文件保留", delInfo.entries.contains { $0.fullPath == "新文件.txt" })

    // 7. 归档内编辑:重命名
    var renOp = ArchiveService.EditOperation()
    renOp.renameMap = ["新文件.txt": "改名文件.txt"]
    let renURL = try svc.editArchive(info: delInfo, operation: renOp, to: base.appendingPathComponent("renamed.zip"))
    let renInfo = try svc.openArchive(url: renURL)
    check("重命名生效", renInfo.entries.contains { $0.fullPath == "改名文件.txt" })
    check("重命名后旧名移除", !renInfo.entries.contains { $0.fullPath == "新文件.txt" })

    // 8. 测试归档
    try svc.testArchive(info: renInfo)
    check("归档测试通过", true)

    // 9. 转换格式 ZIP → 7z
    if SevenZipEngine.isAvailable() {
        let convertOpts = CreateOptions()
        let target = base.appendingPathComponent("converted.7z")
        try svc.convert(url: renURL, to: .sevenZip, destURL: target, options: convertOpts)
        check("转换 7z 生成", fm.fileExists(atPath: target.path))
        let convInfo = try svc.openArchive(url: target)
        check("转换后条目保留", convInfo.entries.contains { $0.fullPath == "改名文件.txt" })
        // 10. 转换后解压
        let convOut = base.appendingPathComponent("conv_out")
        try svc.extract(info: convInfo, options: ExtractOptions(destination: convOut))
        let convContent = (try? String(contentsOf: convOut.appendingPathComponent("改名文件.txt"), encoding: .utf8)) ?? ""
        check("转换后内容一致", convContent == "新添加文件")
    }

    // 11. 修复（ZIP 重建）
    let repairDir = base.appendingPathComponent("repair")
    let repaired = try svc.repairArchive(url: renURL, to: repairDir)
    check("ZIP 修复生成", repaired != nil && fm.fileExists(atPath: repaired!.path))
    if let r = repaired {
        let repInfo = try svc.openArchive(url: r)
        check("修复后条目保留", repInfo.entries.contains { $0.fullPath == "改名文件.txt" })
    }

    print("\n工作流测试: 通过 \(passed) / 失败 \(failed)")
    if failed > 0 {
        throw NSError(domain: "workflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(failed) 项失败"])
    }
}

func testExtractOverwriteModes() throws {
    print("\n== 解压覆盖模式 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ow_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let f = base.appendingPathComponent("file.txt")
    try "归档版本".write(to: f, atomically: true, encoding: .utf8)
    let zipURL = base.appendingPathComponent("a.zip")
    var createOpts = CreateOptions()
    createOpts.format = .zip
    _ = try ArchiveService.shared.createArchive(items: [f], to: zipURL, options: createOpts)
    let info = try ArchiveService.shared.openArchive(url: zipURL)

    // 目标已有同名旧文件
    let dest = base.appendingPathComponent("dest")
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let existing = dest.appendingPathComponent("file.txt")
    try "旧内容".write(to: existing, atomically: true, encoding: .utf8)

    // skip 模式
    var skipOpts = ExtractOptions(destination: dest)
    skipOpts.overwriteMode = .skip
    try ArchiveService.shared.extract(info: info, options: skipOpts)
    let skipContent = (try? String(contentsOf: existing, encoding: .utf8)) ?? ""
    print("跳过模式保留旧文件: \(skipContent == "旧内容" ? mark(true) : mark(false))")

    // overwrite 模式
    var owOpts = ExtractOptions(destination: dest)
    owOpts.overwriteMode = .overwrite
    try ArchiveService.shared.extract(info: info, options: owOpts)
    let owContent = (try? String(contentsOf: existing, encoding: .utf8)) ?? ""
    print("覆盖模式更新内容: \(owContent == "归档版本" ? mark(true) : mark(false))")

    // autoRename 模式
    var arOpts = ExtractOptions(destination: dest)
    arOpts.overwriteMode = .autoRename
    try ArchiveService.shared.extract(info: info, options: arOpts)
    let renamed = dest.appendingPathComponent("file 1.txt")
    print("自动重命名生成新文件: \(fm.fileExists(atPath: renamed.path) ? mark(true) : mark(false))")
}

func testExtractEncodingFallback() throws {
    print("\n== 解压编码回退 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("enc_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    // 用 ZipWriter 创建 GBK 文件名 zip
    let f = base.appendingPathComponent("测试.txt")
    try "内容".write(to: f, atomically: true, encoding: .utf8)
    let zipURL = base.appendingPathComponent("gbk.zip")
    var opts = ZipWriteOptions()
    opts.useGBKNames = true
    let writer = ZipWriter()
    try writer.write(items: [ZipSourceItem(sourceURL: f, archivePath: "测试.txt")], to: zipURL, options: opts)
    let info = try ArchiveService.shared.openArchive(url: zipURL)
    let hasChinese = info.entries.contains { $0.fullPath.contains("测试") }
    print("GBK 文件名自动识别: \(hasChinese ? mark(true) : mark(false))")
}
