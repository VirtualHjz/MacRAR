import Foundation
import ZIPCore

// MARK: - 7za (p7zip) 引擎：7z/tar/gz/bz2/xz/cpio 等格式的压缩与解压

public enum SevenZipError: LocalizedError {
    case toolNotFound
    case executionFailed(code: Int32, message: String)
    case notAnArchive
    case badPassword
    case noFilesMatched

    public var errorDescription: String? {
        switch self {
        case .toolNotFound: return "未找到 7za 压缩工具"
        case .executionFailed(let code, let msg): return "7za 执行失败（\(code)）: \(msg)"
        case .notAnArchive: return "不是有效的压缩归档"
        case .badPassword: return "密码错误或归档已损坏"
        case .noFilesMatched: return "没有找到匹配的文件"
        }
    }
}

public struct SevenZipEntry {
    public var path: String
    public var isDirectory: Bool
    public var size: UInt64
    public var packedSize: UInt64
    public var modifiedDate: Date?
    public var isEncrypted: Bool
    public var crc: UInt32?
}

public final class SevenZipEngine {

    // MARK: - 定位 7za

    public static var cached7zaPath: URL?

    public static func sevenZAPath() -> URL? {
        if let cached = cached7zaPath { return cached }
        // 0. 环境变量覆盖
        if let envPath = ProcessInfo.processInfo.environment["MACKRAR_7ZA_PATH"],
           FileManager.default.fileExists(atPath: envPath) {
            cached7zaPath = URL(fileURLWithPath: envPath)
            return cached7zaPath
        }
        // 1. 主 bundle 资源（Resources/bin/7za 或 Resources/7za）
        if let res = Bundle.main.resourceURL {
            for rel in ["bin/7za", "7za", "Resources/bin/7za", "Resources/7za"] {
                let candidate = res.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    cached7zaPath = candidate
                    return candidate
                }
            }
        }
        // 2. 系统路径
        for p in ["/usr/local/bin/7za", "/opt/homebrew/bin/7za", "/usr/bin/7za"] {
            if FileManager.default.fileExists(atPath: p) {
                cached7zaPath = URL(fileURLWithPath: p)
                return cached7zaPath
            }
        }
        return nil
    }

    public static func isAvailable() -> Bool {
        sevenZAPath() != nil
    }

    // MARK: - 进程执行

    private struct RunResult {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    @discardableResult
    private static func run(_ args: [String], workingDir: URL? = nil, password: String? = nil,
                            progressLine: ((String) -> Void)? = nil) throws -> RunResult {
        guard let tool = sevenZAPath() else { throw SevenZipError.toolNotFound }
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        if let workingDir {
            p.currentDirectoryURL = workingDir
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()

        let outData = NSMutableData()
        let outHandle = outPipe.fileHandleForReading
        outHandle.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty {
                outData.append(d)
                if let line = String(data: d, encoding: .utf8) {
                    progressLine?(line)
                }
            }
        }
        let errData = NSMutableData()
        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty { errData.append(d) }
        }
        p.waitUntilExit()
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        let stdout = String(data: outData as Data, encoding: .utf8) ?? ""
        let stderr = String(data: errData as Data, encoding: .utf8) ?? ""
        return RunResult(code: p.terminationStatus, stdout: stdout, stderr: stderr)
    }

    // MARK: - 分卷路径解析（7z 分卷为 .001/.002/...，list/extract 需用首卷）

    public static func resolveVolumePath(_ url: URL) -> URL {
        let fm = FileManager.default
        let base = url.path
        // 主文件名可能不含扩展名（如 enc.7z），检查 enc.7z.001
        let firstVol = base + ".001"
        if fm.fileExists(atPath: firstVol) {
            return URL(fileURLWithPath: firstVol)
        }
        return url
    }

    // MARK: - 格式映射

    private static func formatType(_ f: ArchiveFormat) -> String {
        switch f {
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .gzip: return "gzip"
        case .bzip2: return "bzip2"
        case .xz: return "xz"
        case .lzma: return "lzma"
        case .zstd: return "zstd"
        case .iso: return "iso"
        case .cpio: return "cpio"
        case .cab: return "cab"
        case .ar: return "ar"
        case .deb: return "deb"
        default: return "7z"
        }
    }

    // MARK: - 列表

    public static func list(url: URL, password: String? = nil) throws -> [SevenZipEntry] {
        var args = ["l", "-slt", "-bb0"]
        if let pwd = password, !pwd.isEmpty {
            args += ["-p\(pwd)"]
        }
        args.append(resolveVolumePath(url).path)
        let result = try run(args)
        if result.code != 0 {
            let msg = result.stdout + result.stderr
            if msg.contains("Cannot open the file") || msg.contains("is not archive") {
                throw SevenZipError.notAnArchive
            }
            if msg.contains("Wrong password") || msg.contains("Can not open encrypted") {
                throw SevenZipError.badPassword
            }
            throw SevenZipError.executionFailed(code: result.code, message: msg)
        }
        return parseSLT(result.stdout)
    }

    private static func parseSLT(_ text: String) -> [SevenZipEntry] {
        var entries: [SevenZipEntry] = []
        var path = ""
        var isDir = false
        var size: UInt64 = 0
        var packed: UInt64 = 0
        var date: Date?
        var encrypted = false
        var crc: UInt32?

        func flush() {
            if !path.isEmpty {
                entries.append(SevenZipEntry(path: path, isDirectory: isDir, size: size, packedSize: packed, modifiedDate: date, isEncrypted: encrypted, crc: crc))
            }
            path = ""
            isDir = false
            size = 0
            packed = 0
            date = nil
            encrypted = false
            crc = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "----------" {
                flush()
                continue
            }
            if let idx = line.range(of: " = ") {
                let key = String(line[..<idx.lowerBound])
                let value = String(line[idx.upperBound...])
                switch key {
                case "Path":
                    path = value
                case "Folder":
                    isDir = value == "+"
                case "Size":
                    size = UInt64(value) ?? 0
                case "Packed Size":
                    packed = UInt64(value) ?? 0
                case "Modified":
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    date = f.date(from: value)
                case "Encrypted":
                    encrypted = value == "+"
                case "CRC":
                    crc = UInt32(value, radix: 16)
                default:
                    break
                }
            }
        }
        flush()
        return entries
    }

    // MARK: - 解压

    public static func extract(url: URL, to dest: URL, password: String? = nil, flatten: Bool = false,
                        progress: @escaping (Double) -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var args = flatten ? ["e"] : ["x"]
        args += ["-y", "-bb1"]
        if let pwd = password, !pwd.isEmpty {
            args += ["-p\(pwd)"]
        }
        args += ["-o\(dest.path)", resolveVolumePath(url).path]
        _ = try run(args, password: password) { line in
            parsePercent(line, into: progress)
        }
    }

    private static func parsePercent(_ line: String, into progress: (Double) -> Void) {
        // 解析 "  xx%" 进度
        if let r = line.range(of: "%", options: .backwards) {
            let before = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let pct = before.components(separatedBy: CharacterSet(charactersIn: " \t\n")).last, let v = Double(pct) {
                progress(min(1.0, v / 100.0))
            }
        }
    }

    // MARK: - 测试

    public static func test(url: URL, password: String? = nil) throws {
        var args = ["t"]
        if let pwd = password, !pwd.isEmpty {
            args += ["-p\(pwd)"]
        }
        args.append(resolveVolumePath(url).path)
        let result = try run(args)
        if result.code != 0 {
            let msg = result.stdout + result.stderr
            if msg.contains("Wrong password") { throw SevenZipError.badPassword }
            throw SevenZipError.executionFailed(code: result.code, message: msg)
        }
    }

    // MARK: - 创建

    @discardableResult
    public static func create(url: URL, sourceItems: [URL], format: ArchiveFormat,
                       options: CreateOptions, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        let type = formatType(format)
        var args = ["a", "-y", "-t\(type)", "-bb1"]

        // 压缩级别
        let mx = zipLevel(options.compressionLevel)
        args.append("-mx=\(mx)")
        // 多线程
        args.append(options.multiThreaded ? "-mmt=on" : "-mmt=off")
        // 固实（7z 有效）
        if options.solid && format == .sevenZip {
            args.append("-ms=on")
        }
        // 字典大小（7z）
        if format == .sevenZip, options.dictionarySize > 0 {
            args.append("-md=\(options.dictionarySize)m")
        }
        // 分卷
        if options.volumeSize > 0 {
            args.append("-v\(options.volumeSize)")
        }
        // 密码
        if let pwd = options.password, !pwd.isEmpty {
            if format == .sevenZip {
                args.append("-p\(pwd)")
                if options.encryptFileNames {
                    args.append("-mhe=on")
                }
            } else if format == .zip {
                args.append("-p\(pwd)")
                args.append("-mem=AES256")
            }
        }
        // 时间戳
        args.append(options.keepTimestamps ? "-mtc=on" : "-mtc=off")
        args.append(url.path)
        for item in sourceItems {
            args.append(item.path)
        }
        _ = try run(args, password: options.password) { line in
            parsePercent(line, into: progress)
        }
        return url
    }

    private static func zipLevel(_ level: CompressionLevel) -> Int {
        switch level {
        case .store: return 0
        case .fastest: return 1
        case .fast: return 3
        case .normal: return 5
        case .good: return 7
        case .best: return 9
        }
    }

    // MARK: - 转换格式（可用作"转换"功能基础）
    public static func convert(sourceURL: URL, to format: ArchiveFormat, destURL: URL,
                        options: CreateOptions, progress: @escaping (Double) -> Void = { _ in }) throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // 先解压到临时目录
        try extract(url: sourceURL, to: tmpDir, password: options.password, progress: progress)
        // 再压缩
        let contents = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        try create(url: destURL, sourceItems: contents, format: format, options: options, progress: progress)
    }
}
