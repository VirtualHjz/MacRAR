import Foundation
import AppKit
import ZIPCore

// MARK: - 统一归档服务：检测格式、调度引擎

public final class ArchiveService {

    public static let shared = ArchiveService()

    private init() {}

    // MARK: 格式检测

    public func detectFormat(url: URL) -> ArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16) else { return nil }
        if let f = ArchiveFormat.detect(from: url, magic: data) { return f }
        return nil
    }

    /// 判断文件是否可识别为归档
    public func isArchive(url: URL) -> Bool {
        detectFormat(url: url) != nil
    }

    // MARK: 打开归档

    public func openArchive(url: URL, password: String? = nil) throws -> ArchiveInfo {
        guard let format = detectFormat(url: url) else {
            throw ArchiveServiceError.unsupported("无法识别的归档格式")
        }
        switch format {
        case .rar, .rar4, .rar5:
            return try openRAR(url: url, format: format, password: password)
        case .zip:
            return try openZip(url: url, format: format)
        case .zstd:
            throw ArchiveServiceError.unsupported("当前内置 7za 不支持 Zstandard 格式")
        case .sevenZip, .tar, .gzip, .bzip2, .xz, .lzma, .iso, .cpio, .cab, .ar, .deb:
            return try openSevenZip(url: url, format: format)
        }
    }

    private func openRAR(url: URL, format: ArchiveFormat, password: String? = nil) throws -> ArchiveInfo {
        let (entries, info) = try UnrarEngine.listArchive(url: url, password: password)
        var flags: Set<ArchiveFlag> = []
        let f = Int(info.Flags)
        if f & 0x0001 != 0 { flags.insert(.volume) }
        if f & 0x0002 != 0 { flags.insert(.comment) }
        if f & 0x0004 != 0 { flags.insert(.locked) }
        if f & 0x0008 != 0 { flags.insert(.solid) }
        if f & 0x0020 != 0 { flags.insert(.signed) }
        if f & 0x0040 != 0 { flags.insert(.recovery) }
        if f & 0x0080 != 0 { flags.insert(.encryptedHeaders) }
        let volumeCount = UnrarEngine.findVolumes(mainURL: url).count
        var archiveInfo = ArchiveInfo(url: url, format: format,
                                      entries: entries.map { convert(entry: $0) },
                                      flags: flags, volumeCount: volumeCount)
        archiveInfo.volumes = UnrarEngine.findVolumes(mainURL: url)
        return archiveInfo
    }

    private func openZip(url: URL, format: ArchiveFormat) throws -> ArchiveInfo {
        let reader = try ZipReader(mainURL: url)
        let volumes = VolumesReader.findVolumes(mainURL: url)
        let entries: [ArchiveEntry] = reader.entries.map { e in
            ArchiveEntry(
                fullPath: e.fullPath,
                isDirectory: e.isDirectory,
                size: e.size,
                packedSize: e.compressedSize,
                modifiedDate: e.modifiedDate,
                method: zipMethodName(e.method),
                isEncrypted: e.isEncrypted,
                crc: e.crc32,
                fileAttributes: e.unixMode.map { Int($0) }
            )
        }
        let info = ArchiveInfo(url: url, format: .zip, entries: entries,
                               comment: reader.comment,
                               volumeCount: volumes.count, volumes: volumes)
        return info
    }

    private func openSevenZip(url: URL, format: ArchiveFormat) throws -> ArchiveInfo {
        let list = try SevenZipEngine.list(url: url)
        var total = 0
        let entries: [ArchiveEntry] = list.map { e in
            if !e.isDirectory { total += 1 }
            return ArchiveEntry(
                fullPath: e.path,
                isDirectory: e.isDirectory,
                size: e.size,
                packedSize: e.packedSize,
                modifiedDate: e.modifiedDate,
                method: "",
                isEncrypted: e.isEncrypted,
                crc: e.crc
            )
        }
        return ArchiveInfo(url: url, format: format, entries: entries)
    }

    private func convert(entry: MRArchiveEntry) -> ArchiveEntry {
        let methodName: String
        switch entry.method {
        case 0x30: methodName = "存储"
        case 0x33: methodName = "最快"
        case 0x35: methodName = "快速"
        case 0x48: methodName = "标准"
        case 0x52: methodName = "较好"
        case 0x5A: methodName = "最好"
        default: methodName = ""
        }
        // 编码修正：UnRAR 转换出的名字若含替换符，用原始字节按 GBK 解码
        var finalName = entry.name
        if entry.name.contains("\u{FFFD}") {
            let decoded = TextEncoding.decodeFileName(bytes: Data(entry.rawName.utf8))
            if TextEncoding.isValid(decoded) {
                finalName = decoded
            }
        }
        return ArchiveEntry(
            fullPath: finalName,
            isDirectory: entry.isDirectory,
            size: entry.unpackedSize,
            packedSize: entry.packedSize,
            modifiedDate: entry.modifiedDate,
            method: methodName,
            isEncrypted: entry.isEncrypted,
            crc: entry.crc >= 0 ? UInt32(bitPattern: entry.crc) : nil,
            fileAttributes: nil
        )
    }

    private func zipMethodName(_ m: UInt16) -> String {
        switch m {
        case 0: return "存储"
        case 8: return "Deflate"
        case 9: return "Deflate64"
        case 12: return "BZip2"
        case 93: return "Zstandard"
        default: return "方法 \(m)"
        }
    }

    // MARK: 解压

    public func extract(info: ArchiveInfo, options: ExtractOptions,
                 progress: @escaping (Double) -> Void = { _ in },
                 cancel: @escaping () -> Bool = { false }) throws {
        switch info.format {
        case .rar, .rar4, .rar5:
            try UnrarEngine.extractArchive(url: info.url, to: options.destination, password: options.password) { pct in
                progress(Double(pct) / 100.0)
            }
        case .zip:
            do {
                try extractZip(info: info, options: options, progress: progress, cancel: cancel)
            } catch let e as ZipError {
                if case .unsupportedMethod = e {
                    // 自研引擎不支持的压缩方法（如 ZIP 方法 99），回退到 7za
                    try SevenZipEngine.extract(url: info.url, to: options.destination, password: options.password, progress: progress)
                } else {
                    throw e
                }
            }
        default:
            try SevenZipEngine.extract(url: info.url, to: options.destination, password: options.password, progress: progress)
        }
        if options.revealAfterExtract {
            NSWorkspace.shared.activateFileViewerSelecting([options.destination])
        }
    }

    private func extractZip(info: ArchiveInfo, options: ExtractOptions,
                            progress: @escaping (Double) -> Void, cancel: @escaping () -> Bool) throws {
        let reader = try ZipReader(mainURL: info.url)
        let entries = reader.entries
        let totalSize = entries.reduce(UInt64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
        var processed: UInt64 = 0
        // 收集目录条目以确保创建
        var createdDirs = Set<String>()
        try FileManager.default.createDirectory(at: options.destination, withIntermediateDirectories: true)
        for entry in entries {
            if cancel() { throw ArchiveServiceError.canceled }
            // 过滤子路径
            if let subPath = options.subPath {
                if !entry.fullPath.hasPrefix(subPath) { continue }
            }
            let safeURL: URL
            if options.keepDirectoryStructure {
                guard let u = PathSafety.safeDestinationURL(dest: options.destination, entryPath: entry.fullPath) else { continue }
                safeURL = u
            } else {
                safeURL = options.destination.appendingPathComponent(entry.fullPath.components(separatedBy: "/").last ?? entry.fullPath)
            }
            // 确保父目录存在（目录条目）
            let parent = safeURL.deletingLastPathComponent()
            if !createdDirs.contains(parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                createdDirs.insert(parent.path)
            }
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: safeURL, withIntermediateDirectories: true)
                continue
            }
            // 覆盖策略
            let fm = FileManager.default
            if fm.fileExists(atPath: safeURL.path) {
                switch options.overwriteMode {
                case .skip: continue
                case .ask:
                    // 询问模式：默认跳过已存在（UI 层另行处理更细）
                    continue
                case .autoRename:
                    let renamed = Self.uniqueURL(for: safeURL)
                    try reader.extract(entry: entry, to: renamed, password: options.password) { done, total in
                        processed = min(processed + done, totalSize)
                        progress(totalSize > 0 ? Double(processed) / Double(totalSize) : 0)
                    }
                    continue
                case .overwriteOlder:
                    if let existing = try? fm.attributesOfItem(atPath: safeURL.path)[.modificationDate] as? Date,
                       let newer = entry.modifiedDate, existing > newer {
                        continue
                    }
                    fallthrough
                case .overwrite:
                    break
                }
            }
            try reader.extract(entry: entry, to: safeURL, password: options.password) { done, total in
                _ = total
                processed = min(processed + done, totalSize)
                progress(totalSize > 0 ? Double(processed) / Double(totalSize) : 0)
            }
        }
    }

    public static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 1
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    // MARK: 测试

    public func testArchive(info: ArchiveInfo, progress: @escaping (Double) -> Void = { _ in }) throws {
        switch info.format {
        case .rar, .rar4, .rar5:
            try UnrarEngine.testArchive(url: info.url, password: nil) { pct in
                progress(Double(pct) / 100.0)
            }
        case .zip:
            try testZip(info: info, progress: progress)
        default:
            try SevenZipEngine.test(url: info.url)
        }
    }

    private func testZip(info: ArchiveInfo, progress: @escaping (Double) -> Void) throws {
        let reader = try ZipReader(mainURL: info.url)
        let entries = reader.entries
        let total = entries.reduce(UInt64(0)) { $0 + $1.size }
        var processed: UInt64 = 0
        for entry in entries where !entry.isDirectory {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try reader.extract(entry: entry, to: tmp, password: nil) { done, _ in
                processed += done
                progress(total > 0 ? Double(processed) / Double(total) : 0)
            }
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // MARK: 创建

    public func createArchive(items: [URL], to destURL: URL, options: CreateOptions,
                       progress: @escaping (Double) -> Void = { _ in }) throws -> TaskResult {
        let fm = FileManager.default
        var sourceItems: [URL] = items
        // 确保目标目录存在
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 已有目标文件则先删除
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }

        switch options.format {
        case .zip:
            // 有密码且不分卷 → 7za（AES-256）；否则自研引擎（支持分卷/GBK）
            if let pwd = options.password, !pwd.isEmpty, options.volumeSize == 0 {
                try SevenZipEngine.create(url: destURL, sourceItems: items, format: .zip, options: options, progress: progress)
            } else {
                let zipItems: [ZipSourceItem] = sourceItems.map {
                    var isDir: ObjCBool = false
                    _ = FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
                    return ZipSourceItem(sourceURL: $0, archivePath: $0.lastPathComponent, isDirectory: isDir.boolValue)
                }
                var wopts = ZipWriteOptions()
                wopts.compressionLevel = zipLevel(options.compressionLevel)
                wopts.password = options.password
                wopts.encryptMethod = (options.password != nil) ? .traditional : .none
                wopts.volumeSize = options.volumeSize
                wopts.useGBKNames = options.useGBKNames
                let writer = ZipWriter()
                try writer.write(items: zipItems, to: destURL, options: wopts, progress: progress)
            }
        case .rar, .rar4, .rar5:
            if !RarCLIEngine.isAvailable() {
                throw ArchiveServiceError.rarNotAvailable
            }
            try RarCLIEngine.create(url: destURL, sourceItems: sourceItems, options: options, progress: progress)
        case .sevenZip, .tar, .gzip, .bzip2, .xz:
            if options.createSFX {
                try SFXEngine.createSFX(items: sourceItems, to: destURL, options: options, progress: progress)
            } else {
                try SevenZipEngine.create(url: destURL, sourceItems: sourceItems, format: options.format, options: options, progress: progress)
            }
        default:
            throw ArchiveServiceError.unsupported("该格式不支持创建")
        }

        // 压缩后删除源文件
        if options.deleteFilesAfterCompression {
            for item in items {
                try? fm.removeItem(at: item)
            }
        }
        return TaskResult(success: true, message: "压缩完成", outputURL: destURL)
    }

    private func zipLevel(_ l: CompressionLevel) -> Int {
        switch l {
        case .store: return 0
        case .fastest: return 1
        case .fast: return 3
        case .normal: return 6
        case .good: return 7
        case .best: return 9
        }
    }

    // MARK: 修复

    public func repairArchive(url: URL, to destDir: URL,
                       progress: @escaping (Double) -> Void = { _ in }) throws -> URL? {
        let format = detectFormat(url: url)
        switch format {
        case .rar, .rar4, .rar5:
            guard RarCLIEngine.isAvailable() else { throw ArchiveServiceError.rarNotAvailable }
            return try RarCLIEngine.repair(url: url, to: destDir, progress: progress)
        case .zip:
            // zip 修复：尝试读取并重建（跳过损坏条目）
            return try repairZip(url: url, to: destDir)
        default:
            throw ArchiveServiceError.unsupported("该格式暂不支持修复")
        }
    }

    private func repairZip(url: URL, to destDir: URL) throws -> URL? {
        let reader = try ZipReader(mainURL: url)
        let entries = reader.entries
        guard let first = entries.first else { return nil }
        let repairedURL = destDir.appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".zip", with: "_repaired.zip"))
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        // 将能解压的条目重新压缩（通过临时目录）
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        var okCount = 0
        for entry in entries where !entry.isDirectory {
            let dest = tmpDir.appendingPathComponent(entry.fullPath)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? reader.extract(entry: entry, to: dest, password: nil)) != nil {
                okCount += 1
            }
        }
        if okCount == 0 {
            throw ArchiveServiceError.unsupported("无法修复该 ZIP（所有条目均损坏）")
        }
        let writer = ZipWriter()
        let items = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil).map {
            ZipSourceItem(sourceURL: $0, archivePath: $0.lastPathComponent, isDirectory: $0.hasDirectoryPath)
        }
        try writer.write(items: items, to: repairedURL, options: ZipWriteOptions())
        return repairedURL
    }

    // MARK: 转换格式

    public func convert(url: URL, to format: ArchiveFormat, destURL: URL,
                 options: CreateOptions, progress: @escaping (Double) -> Void = { _ in }) throws {
        try SevenZipEngine.convert(sourceURL: url, to: format, destURL: destURL, options: options, progress: progress)
    }

    public func probeMethod() {}

    // MARK: 按条目解压（用于预览/部分解压）

    public func extractEntries(info: ArchiveInfo, entries: [ArchiveEntry], to dest: URL,
                        progress: @escaping (Double) -> Void = { _ in },
                        cancel: @escaping () -> Bool = { false }) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        switch info.format {
        case .zip:
            let reader = try ZipReader(mainURL: info.url)
            let total = entries.reduce(UInt64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
            var processed: UInt64 = 0
            for entry in entries {
                if cancel() { throw ArchiveServiceError.canceled }
                guard let safe = PathSafety.safeDestinationURL(dest: dest, entryPath: entry.fullPath) else { continue }
                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
                    continue
                }
                try FileManager.default.createDirectory(at: safe.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let zipEntry = reader.entries.first(where: { $0.fullPath == entry.fullPath }) {
                    try reader.extract(entry: zipEntry, to: safe, password: nil) { done, _ in
                        processed = min(processed + done, total)
                        progress(total > 0 ? Double(processed) / Double(total) : 0)
                    }
                }
            }
        case .rar, .rar4, .rar5:
            try UnrarEngine.extractEntries(url: info.url, entries: entries.map { $0.fullPath }, to: dest, progress: progress, cancel: cancel)
        default:
            // 其他格式：整档解压
            try SevenZipEngine.extract(url: info.url, to: dest, password: nil, progress: progress)
        }
    }

    // MARK: 从归档创建自解压

    public func createSFXFromArchive(info: ArchiveInfo, to destURL: URL, options: CreateOptions,
                              progress: @escaping (Double) -> Void = { _ in },
                              cancel: @escaping () -> Bool = { false }) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("sfx_src_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try extract(info: info, options: ExtractOptions(destination: tmpDir), progress: progress, cancel: cancel)
        let items = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        return try SFXEngine.createSFX(items: items, to: destURL, options: options, progress: progress)
    }

    // MARK: 归档内编辑（重建归档：添加/删除/重命名）

    public struct EditOperation {
        public var addFiles: [URL] = []
        public var removePaths: [String] = []
        public var renameMap: [String: String] = [:]
        public init() {}
    }

    public func editArchive(info: ArchiveInfo, operation: EditOperation, to destURL: URL,
                     progress: @escaping (Double) -> Void = { _ in },
                     cancel: @escaping () -> Bool = { false }) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("edit_\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 1. 解压原归档到临时目录
        var total = 0.0
        let halfProgress: (Double) -> Void = { p in total = p * 0.5 }
        try extract(info: info, options: ExtractOptions(destination: tmp), progress: halfProgress, cancel: cancel)

        // 2. 删除条目
        for path in operation.removePaths {
            let target = tmp.appendingPathComponent(path)
            try? fm.removeItem(at: target)
        }
        // 3. 重命名条目
        for (oldPath, newPath) in operation.renameMap {
            let old = tmp.appendingPathComponent(oldPath)
            if fm.fileExists(atPath: old.path) {
                let new = tmp.appendingPathComponent(newPath)
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: old, to: new)
            }
        }
        // 4. 添加文件
        for file in operation.addFiles {
            let dest = tmp.appendingPathComponent(file.lastPathComponent)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: dest)
        }

        // 5. 重新压缩（同格式）
        if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
        let items = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        var opts = CreateOptions()
        opts.format = info.format
        let secondHalf: (Double) -> Void = { p in progress(0.5 + p * 0.5) }
        _ = try createArchive(items: items, to: destURL, options: opts, progress: secondHalf)
        return destURL
    }

    // MARK: 详情

    public func archiveDetails(url: URL) -> [String: String] {
        var details: [String: String] = [:]
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return details }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        details["大小"] = UInt64(size).byteCount
        if let date = attrs[.creationDate] as? Date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            details["创建时间"] = f.string(from: date)
        }
        if let date = attrs[.modificationDate] as? Date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            details["修改时间"] = f.string(from: date)
        }
        details["路径"] = url.path
        return details
    }
}

public enum ArchiveServiceError: LocalizedError {
    case unsupported(String)
    case canceled
    case rarNotAvailable

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .canceled: return "操作已取消"
        case .rarNotAvailable:
            return "RAR 压缩需要 rar 命令行工具。请安装 RARLAB 的 rar 工具后重试。"
        }
    }
}
