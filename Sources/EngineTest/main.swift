import Foundation
import ZIPCore
import MacRARCore

// EngineTest: 命令行验证 ZIP 引擎与 7za

func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }

func testTextEncoding() {
    print("== 编码测试 =="); fflush(stdout)
    let s = "测试中文"
    let enc = TextEncoding.gbkNSStringEncoding
    if let data = (s as NSString).data(using: enc) {
        let decoded = TextEncoding.decodeFileName(bytes: data)
        let okGBK = decoded == s
        let m = mark(okGBK)
        print("GBK 往返: " + m)
    } else {
        print("GBK 编码不可用")
    }
}

func testZipRoundTrip() throws {
    print("\n== ZIP 创建/解压往返 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ztest_\(UUID().uuidString)")
    let src = base.appendingPathComponent("src")
    let out = base.appendingPathComponent("out")
    try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)

    // 测试文件
    let a = src.appendingPathComponent("a.txt")
    try "hello macrar 你好".write(to: a, atomically: true, encoding: .utf8)
    let chinese = src.appendingPathComponent("中文 文件.txt")
    try "中文内容 data".write(to: chinese, atomically: true, encoding: .utf8)
    let b = src.appendingPathComponent("sub/b.bin")
    var random = Data(count: 100_000)
    _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 100_000, $0.baseAddress!) }
    try random.write(to: b)
    let big = src.appendingPathComponent("big.dat")
    var bigData = Data(count: 2_000_000)
    _ = bigData.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 2_000_000, $0.baseAddress!) }
    try bigData.write(to: big)

    let zipURL = base.appendingPathComponent("test.zip")
    let writer = ZipWriter()
    let items = [
        ZipSourceItem(sourceURL: a, archivePath: "a.txt"),
        ZipSourceItem(sourceURL: chinese, archivePath: "中文 文件.txt"),
        ZipSourceItem(sourceURL: src.appendingPathComponent("sub"), archivePath: "sub", isDirectory: true),
        ZipSourceItem(sourceURL: big, archivePath: "big.dat"),
    ]
    var opts = ZipWriteOptions()
    opts.compressionLevel = 6
    try writer.write(items: items, to: zipURL, options: opts)

    // 列表
    let reader = try ZipReader(mainURL: zipURL)
    let entries = reader.entries
    print("条目数: \(entries.count)")
    for e in entries {
        print("  \(e.fullPath)  \(e.size) 字节  isDir=\(e.isDirectory)")
    }
    guard entries.contains(where: { $0.fullPath == "中文 文件.txt" }) else {
        print("✗ 中文文件名未正确保存")
        return
    }
    guard entries.contains(where: { $0.fullPath == "sub/b.bin" }) else {
        print("✗ 子目录文件缺失")
        return
    }

    // 解压
    for e in entries where !e.isDirectory {
        let dest = out.appendingPathComponent(e.fullPath)
        try reader.extract(entry: e, to: dest, password: nil)
    }
    // 校验内容
    let outA = out.appendingPathComponent("a.txt")
    let outAstr = try String(contentsOf: outA, encoding: .utf8)
    let okA = outAstr == "hello macrar 你好"
    let m1 = mark(okA)
    let line1 = "a.txt 内容: " + outAstr + " " + m1
    print(line1)
    let outChinese = out.appendingPathComponent("中文 文件.txt")
    let outCh = try String(contentsOf: outChinese, encoding: .utf8)
    let okCh = outCh == "中文内容 data"
    print("中文文件内容: " + outCh + " " + mark(okCh))
    let outB = out.appendingPathComponent("sub/b.bin")
    let outBdata = try Data(contentsOf: outB)
    let okB = outBdata == random
    print("b.bin 一致: " + mark(okB))
    let outBig = out.appendingPathComponent("big.dat")
    let outBigData = try Data(contentsOf: outBig)
    let okBig = outBigData == bigData
    print("big.dat 一致: " + mark(okBig))
    let baseStr = base.path
    print("测试目录保留: " + baseStr)
    print("ZIP 往返完成 " + mark(true))
}

func testZipEncryption() throws {
    print("\n== ZIP 传统加密 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("zenc_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let f = base.appendingPathComponent("secret.txt")
    let content = "密码保护的内容 secret 123"
    try content.write(to: f, atomically: true, encoding: .utf8)

    let zipURL = base.appendingPathComponent("enc.zip")
    var opts = ZipWriteOptions()
    opts.password = "mypass123"
    opts.encryptMethod = .traditional
    let writer = ZipWriter()
    try writer.write(items: [ZipSourceItem(sourceURL: f, archivePath: "secret.txt")], to: zipURL, options: opts)

    let reader = try ZipReader(mainURL: zipURL)
    guard let e = reader.entries.first, e.isEncrypted else {
        print("✗ 未标记为加密")
        return
    }
    print("条目加密标记: ✓")
    // 正确密码
    let out1 = base.appendingPathComponent("out1.txt")
    try reader.extract(entry: e, to: out1, password: "mypass123")
    let okPw = (try? String(contentsOf: out1, encoding: .utf8)) == content
    print("正确密码解压: " + mark(okPw))
    // 错误密码
    do {
        let out2 = base.appendingPathComponent("out2.txt")
        try reader.extract(entry: e, to: out2, password: "wrong")
        print("错误密码: 未报错 ✗")
    } catch {
        print("错误密码被拒绝: ✓ (\(error.localizedDescription))")
    }
    try? fm.removeItem(at: base)
}

func testZipVolumes() throws {
    print("\n== ZIP 分卷 (z01/z02/zip) ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("zvol_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let f = base.appendingPathComponent("data.bin")
    var random = Data(count: 300_000)
    _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 300_000, $0.baseAddress!) }
    try random.write(to: f)

    let zipURL = base.appendingPathComponent("vol.zip")
    var opts = ZipWriteOptions()
    opts.volumeSize = 100_000
    let writer = ZipWriter()
    let result = try writer.write(items: [ZipSourceItem(sourceURL: f, archivePath: "data.bin")], to: zipURL, options: opts)
    print("生成卷: \(result.urls.map { $0.lastPathComponent })")
    guard result.urls.count >= 3 else { print("✗ 分卷数量不足"); return }

    // 只给主文件也能找到分卷
    let reader = try ZipReader(mainURL: zipURL)
    guard let e = reader.entries.first else { print("✗ 无条目"); return }
    let out = base.appendingPathComponent("out/data.bin")
    try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try reader.extract(entry: e, to: out, password: nil)
    let okVol = (try? Data(contentsOf: out)) == random
    print("分卷解压一致: " + mark(okVol))
    try? fm.removeItem(at: base)
}

func test7za() throws {
    print("\n== 7za (7z) 压缩/解压 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("7ztest_\(UUID().uuidString)")
    let src = base.appendingPathComponent("src")
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    let f = src.appendingPathComponent("中文 hello.txt")
    try "7z 测试内容 test".write(to: f, atomically: true, encoding: .utf8)

    guard let tool = SevenZipEngine.sevenZAPath() else {
        throw SevenZipError.toolNotFound
    }
    let archive = base.appendingPathComponent("test.7z")
    let p = Process()
    p.executableURL = tool
    p.arguments = ["a", "-y", archive.path, f.path]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    try p.run()
    p.waitUntilExit()
    print("7z 创建退出码: \(p.terminationStatus)")
    guard p.terminationStatus == 0 else { return }

    // 列出
    let outDir = base.appendingPathComponent("out")
    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    let p2 = Process()
    p2.executableURL = tool
    p2.arguments = ["x", "-y", "-o\(outDir.path)", archive.path]
    p2.standardOutput = Pipe()
    p2.standardError = Pipe()
    try p2.run()
    p2.waitUntilExit()
    print("7z 解压退出码: \(p2.terminationStatus)")
    let extracted = outDir.appendingPathComponent("中文 hello.txt")
    let content = try? String(contentsOf: extracted, encoding: .utf8)
    let ok7z = content == "7z 测试内容 test"
    let disp7z = content ?? "读取失败"
        print("7z 解压内容: \(disp7z) \(mark(ok7z))")
    try? fm.removeItem(at: base)
}

func main() throws {
    print("START")
    // 配置引擎路径（测试环境）
    let projectRoot = FileManager.default.currentDirectoryPath
    let project7za = "\(projectRoot)/Sources/MacRAR/Resources/bin/7za"
    if FileManager.default.fileExists(atPath: project7za) {
        SevenZipEngine.cached7zaPath = URL(fileURLWithPath: project7za)
    }
    let projectRar = "\(projectRoot)/ThirdParty/rar/rar"
    if FileManager.default.fileExists(atPath: projectRar) {
        RarCLIEngine.cachedPath = URL(fileURLWithPath: projectRar)
    }
    testTextEncoding()
    try testZipRoundTrip()
    try testZipEncryption()
    try testZipVolumes()
    try test7za()
    if ProcessInfo.processInfo.environment["MACRAR_RAR_FIXTURE_DIR"] != nil {
        try testRAREncodedNames()
        try testRAR()
        try testRARCreation()
    } else {
        print("\n== RAR 外部工具样本测试：未配置，跳过 ==")
    }
    // 边界场景
    try testEmptyArchive()
    try testSpecialFileNames()
    try testDeepNesting()
    try testGBKZip()
    try testCorruptArchive()
    try testPathTraversal()
    try testCompressionLevels()
    try testSymlinkAndEmptyFile()
    try testSevenZipEncryptedSolidSplit()
    try testRAREncryptedSolidSplit()
    // 操作流程
    try testFullWorkflow()
    try testExtractOverwriteModes()
    try testExtractEncodingFallback()
    try testManyFilesAndLargeFile()
    try testRealDownloadedArchive()
    print("\n全部引擎测试完成")
}

do {
    try main()
    await MainActor.run {
        do {
            try testAppStateNavigation()
        } catch {
            print("AppState 测试失败: \(error)")
            exit(1)
        }
    }
    await testTaskQueue()
} catch {
    print("测试失败: \(error)")
    exit(1)
}

// MARK: - RAR 解压测试（使用 rar 工具生成的测试集）

func testRAR() throws {
    let dir = ProcessInfo.processInfo.environment["MACRAR_RAR_FIXTURE_DIR"] ?? "/tmp/rartest"
    let fm = FileManager.default
    print("\n== RAR 解压测试 ==")
    fputs("R1\n", stderr)

    // 1. 普通 RAR5 + 中文
    let (entries, _) = try UnrarEngine.listArchive(url: URL(fileURLWithPath: "\(dir)/test_normal.rar"))
    fputs("R2 entries=\(entries.count)\n", stderr)
    print("普通 RAR5 条目数: " + String(entries.count))
    for e in entries {
        let label = e.isDirectory ? "[目录]" : String(e.unpackedSize) + " 字节"
        print("  " + e.name + " " + label)
    }
    fputs("R3\n", stderr)
    let out1 = "\(dir)/out_normal"
    try? fm.removeItem(atPath: out1)
    fputs("R4\n", stderr)
    try UnrarEngine.extractArchive(url: URL(fileURLWithPath: "\(dir)/test_normal.rar"), to: URL(fileURLWithPath: out1), password: nil) { _ in }
    fputs("R5\n", stderr)
    let normalContent = (try? String(contentsOf: URL(fileURLWithPath: "\(out1)/src/中文 文档.txt"), encoding: .utf8)) ?? ""
    let bigOK = (try? Data(contentsOf: URL(fileURLWithPath: "\(out1)/src/sub/big.bin")))?.count == 500000
    print("普通解压中文内容: " + mark(normalContent.trimmingCharacters(in: .whitespacesAndNewlines) == "中文文件名内容") + " big.bin: " + mark(bigOK))

    // 2. 加密 RAR（先带密码列目录）
    if let (pwEntries, _) = try? UnrarEngine.listArchive(url: URL(fileURLWithPath: "\(dir)/test_pwd.rar"), password: "123456") {
        fputs("PWLIST entries=\(pwEntries.count)\n", stderr)
    } else {
        fputs("PWLIST FAIL\n", stderr)
    }
    let out2 = "\(dir)/out_pwd"
    try? fm.removeItem(atPath: out2)
    fputs("PWD_EXTRACT_BEGIN\n", stderr)
    try UnrarEngine.extractArchive(url: URL(fileURLWithPath: "\(dir)/test_pwd.rar"), to: URL(fileURLWithPath: out2), password: "123456") { _ in }
    fputs("PWD_EXTRACT_DONE\n", stderr)
    let pwdOK = ((try? String(contentsOf: URL(fileURLWithPath: "\(out2)/src/a.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "普通文件内容 hello rar"
    print("加密 RAR 解压: " + mark(pwdOK))
    do {
        try UnrarEngine.extractArchive(url: URL(fileURLWithPath: "\(dir)/test_pwd.rar"), to: URL(fileURLWithPath: out2), password: "wrong") { _ in }
        print("错误密码: 未拒绝 " + mark(false))
    } catch {
        print("错误密码被拒绝: " + mark(true))
    }

    // 3. 加密文件名 RAR
    let out3 = "\(dir)/out_hp"
    try? fm.removeItem(atPath: out3)
    do {
        try UnrarEngine.extractArchive(url: URL(fileURLWithPath: "\(dir)/test_hp.rar"), to: URL(fileURLWithPath: out3), password: "123456") { _ in }
    } catch {
        fputs("HP_ERR: \(error)\n", stderr)
    }
    let hpOK = ((try? String(contentsOf: URL(fileURLWithPath: "\(out3)/src/a.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "普通文件内容 hello rar"
    print("加密文件名 RAR 解压: " + mark(hpOK))

    // 4. 固实 RAR
    let out4 = "\(dir)/out_solid"
    try? fm.removeItem(atPath: out4)
    try UnrarEngine.extractArchive(url: URL(fileURLWithPath: "\(dir)/test_solid.rar"), to: URL(fileURLWithPath: out4), password: nil) { _ in }
    let solidOK = ((try? String(contentsOf: URL(fileURLWithPath: "\(out4)/src/a.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "普通文件内容 hello rar"
    print("固实 RAR 解压: " + mark(solidOK))

    // 5. 多卷 RAR
    let out5 = "\(dir)/out_vol"
    try? fm.removeItem(atPath: out5)
    try UnrarEngine.extractArchive(url: URL(fileURLWithPath: "\(dir)/test_vol.part1.rar"), to: URL(fileURLWithPath: out5), password: nil) { _ in }
    let volOK = (try? Data(contentsOf: URL(fileURLWithPath: "\(out5)/src/sub/big.bin")))?.count == 500000
    print("多卷 RAR 解压: " + mark(volOK))

    fputs("STEP RAR4\n", stderr)
    // 6. RAR4（rar 7.x 不再创建 RAR4，有样本才测）
    if fm.fileExists(atPath: "\(dir)/test_rar4.rar") {
        let out6 = "\(dir)/out_rar4"
        try? fm.removeItem(atPath: out6)
        try UnrarEngine.extractArchive(url: URL(fileURLWithPath: "\(dir)/test_rar4.rar"), to: URL(fileURLWithPath: out6), password: nil) { _ in }
        let rar4OK = ((try? String(contentsOf: URL(fileURLWithPath: "\(out6)/src/a.txt"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "普通文件内容 hello rar"
        print("RAR4 解压: " + mark(rar4OK))
    } else {
        print("RAR4 解压: 跳过（无样本）")
    }

    fputs("STEP RR\n", stderr)
    // 7. 恢复记录归档解压
    let out7 = "\(dir)/out_rr"
    try? fm.removeItem(atPath: out7)
    try UnrarEngine.extractArchive(url: URL(fileURLWithPath: "\(dir)/test_rr.rar"), to: URL(fileURLWithPath: out7), password: nil) { _ in }
    let rrOK = (try? Data(contentsOf: URL(fileURLWithPath: "\(out7)/src/sub/big.bin")))?.count == 500000
    print("恢复记录归档解压: " + mark(rrOK))

    fputs("STEP TESTARCHIVE\n", stderr)
    // 8. 测试功能
    fputs("TA_BEGIN\n", stderr)
    do {
        try UnrarEngine.testArchive(url: URL(fileURLWithPath: "\(dir)/test_normal.rar"), password: nil) { _ in }
        print("RAR 测试: " + mark(true))
        fputs("TA_OK\n", stderr)
    } catch {
        print("RAR 测试失败: " + mark(false))
        fputs("TA_ERR \(error)\n", stderr)
    }
}

func testRARCreation() throws {
    print("\n== RAR 压缩测试 ==")
    let fm = FileManager.default
    let dir = (ProcessInfo.processInfo.environment["MACRAR_RAR_FIXTURE_DIR"] ?? "/tmp/rartest") + "/create"
    try? fm.removeItem(atPath: dir)
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "创建测试内容 create rar".write(toFile: "\(dir)/c1.txt", atomically: true, encoding: .utf8)
    try "第二个文件".write(toFile: "\(dir)/c2.txt", atomically: true, encoding: .utf8)
    let dest = URL(fileURLWithPath: "\(dir)/created.rar")
    // 与 RarCLIEngine 一致：以 dir 为工作目录，归档内为相对路径
    guard let rarTool = RarCLIEngine.rarPath() else {
        throw RarCLIError.toolNotFound
    }
    let p = Process()
    p.executableURL = rarTool
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.arguments = ["a", "-idq", "-r", "created.rar", "c1.txt", "c2.txt"]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    try p.run()
    p.waitUntilExit()
    let createdOK = fm.fileExists(atPath: dest.path)
    print("RAR 创建: " + mark(createdOK) + " (exit " + String(p.terminationStatus) + ")")
    if createdOK {
        // 用我们的 UnrarEngine 解压验证
        let out = "\(dir)/verify"
        try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        try UnrarEngine.extractArchive(url: dest, to: URL(fileURLWithPath: out), password: nil) { _ in }
        let c1 = (try? String(contentsOf: URL(fileURLWithPath: "\(out)/c1.txt"), encoding: .utf8)) ?? ""
        print("RAR 创建后解压验证: " + mark(c1.trimmingCharacters(in: .whitespacesAndNewlines) == "创建测试内容 create rar"))
    }
}

func testRAREncodedNames() throws {
    print("\n== RAR 中文编码名称检测 ==")
    fputs("RN1\n", stderr)
    let dir = ProcessInfo.processInfo.environment["MACRAR_RAR_FIXTURE_DIR"] ?? "/tmp/rartest"
    let url = URL(fileURLWithPath: dir + "/test_normal.rar")
    fputs("RN2\n", stderr)
    let (entries, _) = try UnrarEngine.listArchive(url: url)
    fputs("RN3\n", stderr)
    let chinese = entries.contains { $0.name.contains("中文") }
    print("中文文件名识别: " + mark(chinese))
}
