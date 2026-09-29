import Foundation

// MARK: - RAR 命令行引擎（创建/修复 RAR）
// RAR 压缩器为 RARLAB 商业组件，运行时检测本机 rar 工具

public enum RarCLIError: LocalizedError {
    case toolNotFound
    case executionFailed(code: Int32, message: String)
    case badPassword

    public var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "未检测到 rar 命令行工具。RAR 压缩需要 RARLAB 的 rar 工具（含授权），请安装后重试。"
        case .executionFailed(let code, let msg):
            return "rar 执行失败（\(code)）: \(msg)"
        case .badPassword:
            return "密码错误"
        }
    }
}

public final class RarCLIEngine {

    public static var cachedPath: URL?

    public static func rarPath() -> URL? {
        if let cached = cachedPath { return cached }
        let candidates: [String] = [
            ProcessInfo.processInfo.environment["RAR_PATH"] ?? "",
            "/opt/homebrew/bin/rar",
            "/usr/local/bin/rar",
            "/usr/bin/rar",
        ].filter { !$0.isEmpty }
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            cachedPath = URL(fileURLWithPath: p)
            return cachedPath
        }
        return nil
    }

    public static func isAvailable() -> Bool { rarPath() != nil }

    @discardableResult
    private static func run(_ args: [String], workingDir: URL? = nil) throws -> (Int32, String) {
        guard let tool = rarPath() else { throw RarCLIError.toolNotFound }
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        if let workingDir { p.currentDirectoryURL = workingDir }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, text)
    }

    /// 创建 RAR 归档
    @discardableResult
    public static func create(url: URL, sourceItems: [URL], options: CreateOptions,
                       progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        var args = ["a", "-y", "-r"]
        let level: Int
        switch options.compressionLevel {
        case .store: level = 0
        case .fastest: level = 1
        case .fast: level = 2
        case .normal: level = 3
        case .good: level = 4
        case .best: level = 5
        }
        args.append("-m\(level)")
        if options.solid { args.append("-s") }
        if options.recoveryPercent > 0 { args.append("-rr\(options.recoveryPercent)%") }
        if options.volumeSize > 0 { args.append("-v\(Self.rarVolumeSize(options.volumeSize))") }
        if options.createSFX { args.append("-sfx") }
        if let pwd = options.password, !pwd.isEmpty {
            if options.encryptFileNames {
                args.append("-hp\(pwd)")
            } else {
                args.append("-p\(pwd)")
            }
        }
        if options.deleteFilesAfterCompression { args.append("-df") }
        if let comment = options.comment, !comment.isEmpty {
            // rar 注释需要文件，写入临时文件
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rar_comment_\(UUID().uuidString).txt")
            try? comment.write(to: tmp, atomically: true, encoding: .utf8)
            args.append("-z\(tmp.path)")
        }
        // 使用共同父目录作为工作目录，归档内保留相对路径（与 WinRAR 行为一致）
        let baseDir: URL
        if let first = sourceItems.first {
            let parents = sourceItems.map { $0.deletingLastPathComponent() }
            baseDir = Self.commonParent(of: parents) ?? first.deletingLastPathComponent()
        } else {
            baseDir = url.deletingLastPathComponent()
        }
        let fm = FileManager.default
        let rargs = sourceItems.map { item -> String in
            if let rel = item.path.removingPrefix(baseDir.path + "/") {
                return rel
            }
            return item.lastPathComponent
        }
        let argsWithOut = args + [url.path] + rargs
        let (code, out) = try run(argsWithOut, workingDir: baseDir)
        if code != 0 {
            throw RarCLIError.executionFailed(code: code, message: out)
        }
        return url
    }

    private static func rarVolumeSize(_ bytes: UInt64) -> String {
        if bytes >= 1024 * 1024 * 1024 { return "\(bytes / (1024 * 1024 * 1024))g" }
        if bytes >= 1024 * 1024 { return "\(bytes / (1024 * 1024))m" }
        if bytes >= 1024 { return "\(bytes / 1024)k" }
        return "\(bytes)b"
    }

    private static func commonParent(of urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        var comps = first.pathComponents
        for url in urls.dropFirst() {
            let other = url.pathComponents
            var i = 0
            while i < comps.count && i < other.count && comps[i] == other[i] { i += 1 }
            comps = Array(comps.prefix(i))
        }
        if comps.isEmpty { return nil }
        return URL(fileURLWithPath: comps.joined(separator: "/"))
    }

    /// 修复 RAR 归档（使用恢复记录）
    public static func repair(url: URL, to destDir: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let args = ["r", "-y", url.path]
        let (code, out) = try run(args, workingDir: destDir)
        if code != 0 {
            throw RarCLIError.executionFailed(code: code, message: out)
        }
        // 修复产物为原文件名 + .recovered
        let base = url.deletingPathExtension().lastPathComponent
        return destDir.appendingPathComponent("\(base).recovered.rar")
    }

    /// 锁定归档
    public static func lock(url: URL) throws {
        let (code, out) = try run(["k", url.path])
        if code != 0 { throw RarCLIError.executionFailed(code: code, message: out) }
    }

    /// 设置注释
    public static func setComment(url: URL, comment: String) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rar_comment_\(UUID().uuidString).txt")
        try comment.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (code, out) = try run(["c", "-z\(tmp.path)", url.path])
        if code != 0 { throw RarCLIError.executionFailed(code: code, message: out) }
    }
}

extension String {
    fileprivate func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
