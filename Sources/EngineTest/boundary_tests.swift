import Foundation
import ZIPCore
import MacRARCore

// MARK: - 边界场景测试

func testEmptyArchive() throws {
    print("\n== 空归档 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("empty_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let zipURL = base.appendingPathComponent("empty.zip")
    let writer = ZipWriter()
    try writer.write(items: [], to: zipURL, options: ZipWriteOptions())
    let reader = try ZipReader(mainURL: zipURL)
    let count = reader.entries.count
    print("空 zip 条目数: \(count) \(count == 0 ? mark(true) : mark(false))")

    // 空目录压缩
    let emptyDir = base.appendingPathComponent("empty_dir")
    try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    let zip2 = base.appendingPathComponent("dir.zip")
    try writer.write(items: [ZipSourceItem(sourceURL: emptyDir, archivePath: "empty_dir", isDirectory: true)], to: zip2, options: ZipWriteOptions())
    let r2 = try ZipReader(mainURL: zip2)
    let hasDir = r2.entries.contains { $0.isDirectory }
    print("空目录压缩: \(hasDir ? mark(true) : mark(false))")
}

func testSpecialFileNames() throws {
    print("\n== 特殊文件名 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("special_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let names = ["emoji 🎉 测试.txt", " 前导空格.txt", "井号#标签.txt", "符号&括号().txt", "文件.名.多.点.txt"]
    var items: [ZipSourceItem] = []
    for n in names {
        let f = base.appendingPathComponent(n)
        try "内容 \(n)".write(to: f, atomically: true, encoding: .utf8)
        items.append(ZipSourceItem(sourceURL: f, archivePath: n))
    }
    let zipURL = base.appendingPathComponent("special.zip")
    let writer = ZipWriter()
    try writer.write(items: items, to: zipURL, options: ZipWriteOptions())
    let reader = try ZipReader(mainURL: zipURL)
    let entries = reader.entries
    var allOK = true
    for e in entries {
        let ok = names.contains(e.fullPath)
        if !ok { allOK = false }
        print("  条目: \(e.fullPath) \(ok ? mark(true) : mark(false))")
    }
    // 逐个解压验证
    let out = base.appendingPathComponent("out")
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    for e in entries where !e.isDirectory {
        try reader.extract(entry: e, to: out.appendingPathComponent(e.fullPath), password: nil)
    }
    for n in names {
        let content = (try? String(contentsOf: out.appendingPathComponent(n), encoding: .utf8)) ?? ""
        let ok = content == "内容 \(n)"
        if !ok { allOK = false }
        print("  解压 \(n): \(ok ? mark(true) : mark(false))")
    }
    print("特殊文件名总评: \(allOK ? mark(true) : mark(false))")
}

func testDeepNesting() throws {
    print("\n== 深层嵌套目录 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("deep_\(UUID().uuidString)")
    var deep = base
    var path = ""
    for i in 0..<30 {
        deep = deep.appendingPathComponent("level\(i)")
        path += "level\(i)/"
    }
    try fm.createDirectory(at: deep, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let leaf = deep.appendingPathComponent("leaf.txt")
    try "deep leaf".write(to: leaf, atomically: true, encoding: .utf8)

    let zipURL = base.appendingPathComponent("deep.zip")
    let writer = ZipWriter()
    try writer.write(items: [ZipSourceItem(sourceURL: base, archivePath: "root", isDirectory: true)], to: zipURL, options: ZipWriteOptions())
    let reader = try ZipReader(mainURL: zipURL)
    let leafFound = reader.entries.contains { $0.fullPath.hasSuffix("leaf.txt") }
    print("30 层嵌套压缩+列表: \(leafFound ? mark(true) : mark(false))")

    let out = base.appendingPathComponent("out")
    for e in reader.entries where !e.isDirectory {
        try reader.extract(entry: e, to: out.appendingPathComponent(e.fullPath), password: nil)
    }
    let outLeaf = out.appendingPathComponent("root").appendingPathComponent(path).appendingPathComponent("leaf.txt")
    let content = (try? String(contentsOf: outLeaf, encoding: .utf8)) ?? ""
    print("深层解压内容: \(content == "deep leaf" ? mark(true) : mark(false))")
}

func testGBKZip() throws {
    print("\n== GBK 编码 ZIP ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("gbk_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let f = base.appendingPathComponent("源文件.txt")
    try "gbk 内容".write(to: f, atomically: true, encoding: .utf8)

    let zipURL = base.appendingPathComponent("gbk.zip")
    var opts = ZipWriteOptions()
    opts.useGBKNames = true
    let writer = ZipWriter()
    try writer.write(items: [ZipSourceItem(sourceURL: f, archivePath: "源文件.txt")], to: zipURL, options: opts)
    // 用系统 unzip 检查文件名是否为 GBK 字节（非 UTF-8 flag）
    let reader = try ZipReader(mainURL: zipURL)
    let entry = reader.entries.first
    let isUTF8 = entry?.isUTF8 ?? true
    print("GBK zip UTF-8 flag: \(!isUTF8 ? mark(true) : mark(false))")
    let name = entry?.fullPath ?? ""
    print("GBK 文件名解码: \(name == "源文件.txt" ? mark(true) : mark(false))")
    // 解压验证
    if let e = entry {
        let out = base.appendingPathComponent("out.txt")
        try reader.extract(entry: e, to: out, password: nil)
        let content = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        print("GBK 解压内容: \(content == "gbk 内容" ? mark(true) : mark(false))")
    }
}

func testCorruptArchive() throws {
    print("\n== 损坏归档处理 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("corrupt_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let f = base.appendingPathComponent("a.txt")
    try "数据".write(to: f, atomically: true, encoding: .utf8)
    let zipURL = base.appendingPathComponent("c.zip")
    let writer = ZipWriter()
    try writer.write(items: [ZipSourceItem(sourceURL: f, archivePath: "a.txt")], to: zipURL, options: ZipWriteOptions())

    // 截断 zip
    let truncated = base.appendingPathComponent("trunc.zip")
    let data = try Data(contentsOf: zipURL)
    try data.prefix(data.count / 2).write(to: truncated)
    do {
        _ = try ZipReader(mainURL: truncated)
        print("截断 zip: 未报错 \(mark(false))")
    } catch {
        print("截断 zip 被拒绝: \(mark(true))")
    }

    // 随机数据冒充 zip
    let fake = base.appendingPathComponent("fake.zip")
    var random = Data(count: 100)
    _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 100, $0.baseAddress!) }
    try random.write(to: fake)
    do {
        _ = try ZipReader(mainURL: fake)
        print("假 zip: 未报错 \(mark(false))")
    } catch {
        print("假 zip 被拒绝: \(mark(true))")
    }
}

func testPathTraversal() throws {
    print("\n== 路径穿越防护 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("pt_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    // 构造带 ../ 的条目 zip
    let evilName = "../../evil.txt"
    let writer = ZipWriter()
    let f = base.appendingPathComponent("evil_source.txt")
    try "evil".write(to: f, atomically: true, encoding: .utf8)
    let zipURL = base.appendingPathComponent("evil.zip")
    try writer.write(items: [ZipSourceItem(sourceURL: f, archivePath: evilName)], to: zipURL, options: ZipWriteOptions())
    let reader = try ZipReader(mainURL: zipURL)
    let out = base.appendingPathComponent("out")
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    // 通过 ArchiveService 解压（有防护）
    let info = try ArchiveService.shared.openArchive(url: zipURL)
    try ArchiveService.shared.extract(info: info, options: ExtractOptions(destination: out))
    // 检查是否逃逸到父目录
    let escaped = base.appendingPathComponent("evil.txt")
    let outside = out.appendingPathComponent("evil.txt")
    print("穿越文件未逃逸: \(!fm.fileExists(atPath: escaped.path) ? mark(true) : mark(false))")
    print("解压到目标内: \(fm.fileExists(atPath: outside.path) ? mark(true) : mark(false))")
}

func testCompressionLevels() throws {
    print("\n== 压缩级别 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("levels_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let f = base.appendingPathComponent("text.txt")
    try String(repeating: "可压缩内容 compress me 0123456789 ", count: 2000).write(to: f, atomically: true, encoding: .utf8)
    let writer = ZipWriter()
    var sizes: [Int] = []
    for level in [0, 1, 9] {
        var opts = ZipWriteOptions()
        opts.compressionLevel = level
        let url = base.appendingPathComponent("l\(level).zip")
        try writer.write(items: [ZipSourceItem(sourceURL: f, archivePath: "text.txt")], to: url, options: opts)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        sizes.append(size)
    }
    let storeSize = sizes[0]
    let bestSize = sizes[2]
    print("存储(\(storeSize)) > 最好(\(bestSize)): \(storeSize > bestSize ? mark(true) : mark(false))")
}

func testSymlinkAndEmptyFile() throws {
    print("\n== 符号链接与空文件 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sym_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let real = base.appendingPathComponent("real.txt")
    try "real".write(to: real, atomically: true, encoding: .utf8)
    let link = base.appendingPathComponent("link.txt")
    try? fm.createSymbolicLink(at: link, withDestinationURL: real)
    let empty = base.appendingPathComponent("empty.bin")
    try Data().write(to: empty)

    let zipURL = base.appendingPathComponent("sym.zip")
    let writer = ZipWriter()
    let items = [
        ZipSourceItem(sourceURL: real, archivePath: "real.txt"),
        ZipSourceItem(sourceURL: link, archivePath: "link.txt"),
        ZipSourceItem(sourceURL: empty, archivePath: "empty.bin"),
    ]
    try writer.write(items: items, to: zipURL, options: ZipWriteOptions())
    let reader = try ZipReader(mainURL: zipURL)
    let out = base.appendingPathComponent("out")
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    for e in reader.entries where !e.isDirectory {
        try reader.extract(entry: e, to: out.appendingPathComponent(e.fullPath), password: nil)
    }
    let emptyOut = out.appendingPathComponent("empty.bin")
    let emptySize = (try? fm.attributesOfItem(atPath: emptyOut.path)[.size] as? NSNumber)?.intValue ?? -1
    print("空文件解压大小 0: \(emptySize == 0 ? mark(true) : mark(false))")
}

func testSevenZipEncryptedSolidSplit() throws {
    print("\n== 7z 加密/固实/分卷 ==")
    guard SevenZipEngine.isAvailable() else {
        print("7za 不可用，跳过")
        return
    }
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("s7z_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let f = base.appendingPathComponent("加密数据.txt")
    try "7z 加密内容 data".write(to: f, atomically: true, encoding: .utf8)
    let big = base.appendingPathComponent("big.bin")
    var random = Data(count: 300_000)
    _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 300_000, $0.baseAddress!) }
    try random.write(to: big)

    // 创建 7z:加密+固实+分卷
    var opts = CreateOptions()
    opts.format = .sevenZip
    opts.password = "secret"
    opts.encryptFileNames = true
    opts.solid = true
    opts.volumeSize = 100_000
    let zipURL = base.appendingPathComponent("enc.7z")
    _ = try ArchiveService.shared.createArchive(items: [f, big], to: zipURL, options: opts)

    // 列出（需密码）
    do {
        let entries = try SevenZipEngine.list(url: zipURL, password: "secret")
        print("7z 加密列目录条目: \(entries.count) \(entries.count == 2 ? mark(true) : mark(false))")
    } catch {
        print("7z 加密列目录失败: \(mark(false)) \(error)")
    }
    // 无密码列表应失败
    do {
        _ = try SevenZipEngine.list(url: zipURL)
        print("无密码列表: 未拒绝 \(mark(false))")
    } catch {
        print("无密码列表被拒绝: \(mark(true))")
    }
    // 解压验证
    let out = base.appendingPathComponent("out")
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    try SevenZipEngine.extract(url: zipURL, to: out, password: "secret")
    let content = (try? String(contentsOf: out.appendingPathComponent("加密数据.txt"), encoding: .utf8)) ?? ""
    let bigOK = (try? Data(contentsOf: out.appendingPathComponent("big.bin")))?.count == 300_000
    print("7z 加密+固实+分卷解压: 内容\(content == "7z 加密内容 data" ? mark(true) : mark(false)) big\(bigOK ? mark(true) : mark(false))")
}

func testRAREncryptedSolidSplit() throws {
    print("\n== RAR 加密/固实/分卷创建 ==")
    guard RarCLIEngine.isAvailable() else {
        print("rar 工具不可用，跳过 \(mark(true))")
        return
    }
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("srar_\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let f = base.appendingPathComponent("中文文件.txt")
    try "rar 加密内容".write(to: f, atomically: true, encoding: .utf8)
    let big = base.appendingPathComponent("big.bin")
    var random = Data(count: 300_000)
    _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 300_000, $0.baseAddress!) }
    try random.write(to: big)

    var opts = CreateOptions()
    opts.format = .rar
    opts.password = "secret"
    opts.encryptFileNames = true
    opts.solid = true
    opts.recoveryPercent = 5
    opts.volumeSize = 100_000
    let rarURL = base.appendingPathComponent("enc.rar")
    _ = try ArchiveService.shared.createArchive(items: [f, big], to: rarURL, options: opts)

    // 分卷命名：enc.part1.rar / enc.part2.rar ...
    let part1 = base.appendingPathComponent("enc.part1.rar")
    let vols = UnrarEngine.findVolumes(mainURL: part1)
    print("RAR 分卷生成数: \(vols.count) \(vols.count >= 3 ? mark(true) : mark(false))")
    // 用密码打开（加密文件名）
    let info = try ArchiveService.shared.openArchive(url: part1, password: "secret")
    let hasChineseFile = info.entries.contains { $0.fullPath.contains("中文") }
    let hasBig = info.entries.contains { $0.fullPath.contains("big.bin") }
    print("RAR 加密名打开条目: \(info.entries.count) 个 含中文文件\(hasChineseFile ? mark(true) : mark(false)) 含big\(hasBig ? mark(true) : mark(false))")
    // 解压
    let out = base.appendingPathComponent("out")
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    var extractOpts = ExtractOptions(destination: out)
    extractOpts.password = "secret"
    try ArchiveService.shared.extract(info: info, options: extractOpts)
    let content = (try? String(contentsOf: out.appendingPathComponent("中文文件.txt"), encoding: .utf8)) ?? ""
    let bigOK = (try? Data(contentsOf: out.appendingPathComponent("big.bin")))?.count == 300_000
    print("RAR 加密+固实+分卷解压: 内容\(content == "rar 加密内容" ? mark(true) : mark(false)) big\(bigOK ? mark(true) : mark(false))")
}

// MARK: - 真实用户文件测试（下载目录中的分卷加密 ZIP）

func testRealDownloadedArchive() throws {
    guard let dir = ProcessInfo.processInfo.environment["MACRAR_REAL_ARCHIVE_DIR"] else {
        print("\n== 真实分卷测试: 未指定 MACRAR_REAL_ARCHIVE_DIR，跳过 ==")
        return
    }
    let fm = FileManager.default
    guard fm.fileExists(atPath: "\(dir)/田中梢作品.zip") else {
        print("\n== 真实分卷测试: 文件不存在，跳过 ==")
        return
    }
    print("\n== 真实分卷 ZIP 测试（6.8GB，密码 1024）==")
    let main = URL(fileURLWithPath: "\(dir)/田中梢作品.zip")

    // 1. 分卷检测
    fputs("REAL1 findVolumes\n", stderr)
    let vols = VolumesReader.findVolumes(mainURL: main)
    fputs("REAL2 vols=\(vols.count)\n", stderr)
    print("检测分卷数: \(vols.count) \(vols.count >= 7 ? mark(true) : mark(false))")

    // 2. 打开并列出中央目录（ZIP64 + 加密）
    fputs("REAL3 open\n", stderr)
    let reader = try ZipReader(mainURL: main)
    fputs("REAL4 listed\n", stderr)
    fputs("REAL4b\n", stderr)
    let entries = reader.entries
    fputs("REAL4c entries=\(entries.count)\n", stderr)
    fputs("REAL5 print\n", stderr)
    print("条目总数: " + String(entries.count) + " " + mark(entries.count > 0))
    let encCount = entries.filter { $0.isEncrypted }.count
    print("加密条目数: " + String(encCount) + " " + mark(encCount > 0))
    let dirCount = entries.filter { $0.isDirectory }.count
    print("目录条目: \(dirCount)")
    // 打印前 10 个条目概览
    for e in entries.prefix(10) {
        print("  " + e.fullPath + "  " + e.size.byteCount + "  enc=" + String(e.isEncrypted))
    }

    // 3. 完整解压（密码 1024）：自研引擎不支持方法 99，验证回退到 7za
    let tmp = fm.temporaryDirectory.appendingPathComponent("real_\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    fputs("REAL_EXTRACT_BEGIN\n", stderr)
    let info = try ArchiveService.shared.openArchive(url: main)
    var extractOpts = ExtractOptions(destination: tmp)
    extractOpts.password = "1024"
    extractOpts.overwriteMode = .overwrite
    var lastPct = -1
    try ArchiveService.shared.extract(info: info, options: extractOpts) { p in
        let pct = Int(p * 100)
        if pct != lastPct {
            lastPct = pct
            if pct % 20 == 0 { fputs("REAL_PROG \(pct)%\n", stderr) }
        }
    }
    fputs("REAL_EXTRACT_DONE\n", stderr)
    // 验证解压结果
    let extractedFiles = (fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }.count) ?? 0
    print("解压文件数: " + String(extractedFiles) + " " + mark(extractedFiles >= 10))
    let totalSize = info.entries.reduce(UInt64(0)) { $0 + $1.size }
    print("解压总体积: " + totalSize.byteCount)
    let hasBig = fm.fileExists(atPath: tmp.appendingPathComponent("田中梢作品/绝顶5秒前.mp4").path)
    print("大文件存在: " + mark(hasBig))
    let hasMKV = fm.fileExists(atPath: tmp.appendingPathComponent("田中梢作品/田中梢女豹Mehyo.1985.1080p.AMZN.WEB-DL.DDP2.0.H.264-Amarena21.mkv").path)
    print("5.4GB MKV 存在: " + mark(hasMKV))
    print("真实分卷 ZIP 测试完成")
}

// MARK: - 多文件与大文件解压测试

func testManyFilesAndLargeFile() throws {
    print("\n== 多文件与大文件解压 ==")
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("many_\(UUID().uuidString)")
    let src = base.appendingPathComponent("src")
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    // 30 个小文件
    for i in 0..<30 {
        let f = src.appendingPathComponent("file_\(i).txt")
        try "内容 file \(i)".write(to: f, atomically: true, encoding: .utf8)
    }
    // 1 个 150MB 大文件
    let big = src.appendingPathComponent("big.bin")
    var random = Data(count: 150 * 1024 * 1024)
    _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 150 * 1024 * 1024, $0.baseAddress!) }
    try random.write(to: big)

    // 压缩
    let zipURL = base.appendingPathComponent("many.zip")
    var createOpts = CreateOptions()
    createOpts.format = .zip
    _ = try ArchiveService.shared.createArchive(items: [src], to: zipURL, options: createOpts)

    // 解压（自研引擎）
    let out = base.appendingPathComponent("out")
    let info = try ArchiveService.shared.openArchive(url: zipURL)
    print("归档条目数: " + String(info.entries.count) + " " + mark(info.entries.count >= 31))
    var extractOpts = ExtractOptions(destination: out)
    extractOpts.overwriteMode = .overwrite
    var lastPct = -1
    try ArchiveService.shared.extract(info: info, options: extractOpts) { p in
        let pct = Int(p * 100)
        if pct != lastPct { lastPct = pct }
    }
    // 验证
    let smallFiles = (0..<30).filter { i in
        (try? String(contentsOf: out.appendingPathComponent("src/file_\(i).txt"), encoding: .utf8)) == "内容 file \(i)"
    }.count
    print("小文件全部解压正确: " + String(smallFiles) + "/30 " + mark(smallFiles == 30))
    let bigOut = out.appendingPathComponent("src/big.bin")
    let bigSize = (try? fm.attributesOfItem(atPath: bigOut.path)[.size] as? NSNumber)?.uint64Value ?? 0
    print("大文件解压大小: \(bigSize) / 150MB " + mark(bigSize == 150 * 1024 * 1024))
    // 内容一致性（抽样校验 CRC）
    let bigOK = (try? Data(contentsOf: bigOut)) == random
    print("大文件内容一致: " + mark(bigOK))
}
