import Foundation
import CUnrar

// MARK: - UnRAR 引擎（RAR 解压：加密、多卷、固实）

public enum UnrarError: LocalizedError {
    case openFailed(code: Int32)
    case badData
    case badArchive
    case unknownFormat
    case openError
    case createError
    case closeError
    case readError
    case writeError
    case missingPassword
    case badPassword
    case canceled
    case unknown(Int32)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let code): return "无法打开 RAR 归档（错误码 \(code)）"
        case .badData: return "RAR 数据已损坏"
        case .badArchive: return "RAR 归档已损坏"
        case .unknownFormat: return "无法识别的归档格式"
        case .openError: return "无法打开文件"
        case .createError: return "无法创建文件"
        case .closeError: return "无法关闭文件"
        case .readError: return "读取错误"
        case .writeError: return "写入错误"
        case .missingPassword: return "需要密码"
        case .badPassword: return "密码错误"
        case .canceled: return "已取消"
        case .unknown(let code): return "UnRAR 错误（错误码 \(code)）"
        }
    }

    public static func fromCode(_ code: Int32) -> UnrarError? {
        switch code {
        case 0, 10: return nil
        case 12: return .badData
        case 13: return .badArchive
        case 14: return .unknownFormat
        case 15: return .openError
        case 16: return .createError
        case 17: return .closeError
        case 18: return .readError
        case 19: return .writeError
        case 22: return .missingPassword
        case 24: return .badPassword
        default: return .unknown(code)
        }
    }
}

public struct MRArchiveEntry {
    public var name: String
    public var rawName: String
    public var packedSize: UInt64
    public var unpackedSize: UInt64
    public var flags: Int32
    public var hostOS: Int32
    public var crc: Int32
    public var fileTime: Int32
    public var unpVer: Int32
    public var method: Int32
    public var dictSize: Int32

    public var isDirectory: Bool { flags & 0x20 != 0 }
    public var isEncrypted: Bool { flags & 0x04 != 0 }
    public var isSolid: Bool { flags & 0x10 != 0 }
    public var isSplitBefore: Bool { flags & 0x01 != 0 }
    public var isSplitAfter: Bool { flags & 0x02 != 0 }

    public var modifiedDate: Date? {
        guard fileTime != 0 else { return nil }
        // DOS 时间：fileTime 为 DOS 格式（date 高16位, time 低16位）
        let time = UInt32(bitPattern: fileTime)
        let datePart = (time >> 16) & 0xFFFF
        let timePart = time & 0xFFFF
        var comps = DateComponents()
        comps.year = Int((datePart >> 9) & 0x7F) + 1980
        comps.month = Int((datePart >> 5) & 0x0F)
        comps.day = Int(datePart & 0x1F)
        comps.hour = Int((timePart >> 11) & 0x1F)
        comps.minute = Int((timePart >> 5) & 0x3F)
        comps.second = Int(timePart & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}

public final class UnrarEngine {

    /// 找出 RAR 多卷的所有分卷文件（part1.rar, part2.rar / .rar, .r00...）
    public static func findVolumes(mainURL: URL) -> [URL] {
        let fm = FileManager.default
        let path = mainURL.path
        let ext = mainURL.pathExtension.lowercased()
        let base = mainURL.deletingLastPathComponent()

        // 命名模式 1: name.part1.rar / name.part2.rar ...
        if ext == "rar" {
            let stem = mainURL.deletingPathExtension().lastPathComponent
            if let partRange = stem.range(of: ".part", options: .backwards) {
                let prefix = String(stem[..<partRange.lowerBound])
                let numPart = stem[partRange.upperBound...]
                if let firstNum = Int(numPart) {
                    var vols: [URL] = []
                    var i = firstNum
                    while true {
                        let name = String(format: "%@.part%d.%@", prefix, i, ext)
                        let url = base.appendingPathComponent(name)
                        if fm.fileExists(atPath: url.path) {
                            vols.append(url)
                            i += 1
                        } else {
                            break
                        }
                    }
                    if !vols.isEmpty { return vols }
                }
            }
        }

        // 命名模式 2: name.rar / name.r00 / name.r01 ...
        var vols: [URL] = []
        if ext == "rar" {
            var i = 0
            while true {
                let name = String(format: "%@.r%02d", mainURL.deletingPathExtension().path, i)
                if fm.fileExists(atPath: name) {
                    vols.append(URL(fileURLWithPath: name))
                    i += 1
                } else { break }
            }
        }
        vols.append(mainURL)
        return vols
    }

    // MARK: - wchar 辅助

    private static func decodeWide(_ ptr: UnsafePointer<wchar_t>) -> String {
        var units: [UInt16] = []
        var i = 0
        while i < 1024 && ptr[i] != 0 {
            let v = UInt32(ptr[i])
            if v <= 0xFFFF {
                units.append(UInt16(v))
            } else {
                let d = v - 0x10000
                units.append(UInt16(0xD800 + (d >> 10)))
                units.append(UInt16(0xDC00 + (d & 0x3FF)))
            }
            i += 1
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func withWideString<T>(_ s: String, _ body: (UnsafeMutablePointer<wchar_t>?) throws -> T) rethrows -> T {
        let units = Array(s.utf16)
        let ptr = UnsafeMutablePointer<wchar_t>.allocate(capacity: units.count + 1)
        defer { ptr.deallocate() }
        for (i, u) in units.enumerated() { ptr[i] = wchar_t(u) }
        ptr[units.count] = 0
        return try body(ptr)
    }

    // MARK: - 列出内容

    public static func listArchive(url: URL, password: String? = nil) throws -> ([MRArchiveEntry], MROpenInfo) {
        let volumes = findVolumes(mainURL: url)
        guard let first = volumes.first else { throw UnrarError.openError }
        var openInfo = MROpenInfo()
        var pwdBuf: [Int8] = []
        if let password, !password.isEmpty {
            pwdBuf = password.utf8.map { Int8(bitPattern: $0) } + [0]
        }
        return try withWideString(first.path) { pathPtr in
            guard let handle = mr_archive_open(pathPtr, 2, nil, nil, pwdBuf.isEmpty ? nil : pwdBuf, &openInfo) else {
                throw UnrarError.openFailed(code: openInfo.OpenResult)
            }
            defer { mr_archive_close(handle) }
            var entries: [MRArchiveEntry] = []
            while true {
                var hdr = MRHeaderInfo()
                let rc = mr_archive_read_header(handle, &hdr)
                if rc == 10 { break }
                if rc != 0 { throw UnrarError.fromCode(rc) ?? .unknown(rc) }
                let name = withUnsafeBytes(of: &hdr.NameW) { raw in
                    decodeWide(raw.baseAddress!.assumingMemoryBound(to: wchar_t.self))
                }
                let rawName = withUnsafeBytes(of: &hdr.NameUTF8) { raw in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                entries.append(MRArchiveEntry(
                    name: name,
                    rawName: rawName,
                    packedSize: hdr.PackedSize,
                    unpackedSize: hdr.UnpackedSize,
                    flags: hdr.Flags,
                    hostOS: hdr.HostOS,
                    crc: hdr.FileCRC,
                    fileTime: hdr.FileTime,
                    unpVer: hdr.UnpVer,
                    method: hdr.Method,
                    dictSize: hdr.DictSize
                ))
                _ = mr_archive_process(handle, 0, nil, nil, nil) // RAR_SKIP
            }
            return (entries, openInfo)
        }
    }

    /// 解压或测试（op: 1=test, 2=extract）
    public static func process(url: URL, op: Int32, destPath: String?, password: String?,
                        totalBytes: UInt64 = 0,
                        progress: @escaping (Int32) -> Void, cancel: @escaping () -> Bool = { false }) throws {
        let volumes = findVolumes(mainURL: url)
        guard let first = volumes.first else { throw UnrarError.openError }
        var openInfo = MROpenInfo()

        let box = Unmanaged.passRetained(ProgressBox())
        var processedBytes: UInt64 = 0
        box.takeUnretainedValue().handler = { chunkBytes in
            processedBytes += UInt64(max(0, chunkBytes))
            if totalBytes > 0 {
                progress(Int32(min(100, processedBytes * 100 / totalBytes)))
            }
        }
        let boxOpaque = box.toOpaque()
        var pwdUTF8: [Int8] = []
        if let password, !password.isEmpty {
            pwdUTF8 = password.utf8.map { Int8(bitPattern: $0) } + [0]
        }
        let openResult = withWideString(first.path) { pathPtr -> (Int32, HANDLE_Box?) in
            guard let handle = mr_archive_open(pathPtr, 1, unrarCProgressCallback, boxOpaque, pwdUTF8.isEmpty ? nil : pwdUTF8, &openInfo) else {
                return (-1, nil)
            }
            return (0, HANDLE_Box(handle: handle))
        }
        guard openResult.0 == 0, let hbox = openResult.1 else {
            box.release()
            throw UnrarError.openFailed(code: openInfo.OpenResult)
        }
        defer {
            mr_archive_close(hbox.handle)
            box.release()
        }

        var destPtrStorage: (UnsafeMutablePointer<wchar_t>?)?
        let destPtr = destPath.map { s -> UnsafeMutablePointer<wchar_t> in
            let units = Array(s.utf16)
            let p = UnsafeMutablePointer<wchar_t>.allocate(capacity: units.count + 1)
            for (i, u) in units.enumerated() { p[i] = wchar_t(u) }
            p[units.count] = 0
            destPtrStorage = p
            return p
        }
        defer { destPtrStorage??.deallocate() }

        while true {
            if cancel() { throw UnrarError.canceled }
            var hdr = MRHeaderInfo()
            let rc = mr_archive_read_header(hbox.handle, &hdr)
            if rc == 10 { break }
            if rc != 0 { throw UnrarError.fromCode(rc) ?? .unknown(rc) }
            let isDir = hdr.Flags & 0x20 != 0
            if isDir {
                let name = withUnsafeBytes(of: &hdr.NameW) { raw in
                    decodeWide(raw.baseAddress!.assumingMemoryBound(to: wchar_t.self))
                }
                if let destPath, !name.isEmpty {
                    try? FileManager.default.createDirectory(at: URL(fileURLWithPath: destPath).appendingPathComponent(name), withIntermediateDirectories: true)
                }
                _ = mr_archive_process(hbox.handle, op, destPtr, nil, pwdUTF8.isEmpty ? nil : pwdUTF8)
                continue
            }
            let rc2 = mr_archive_process(hbox.handle, op, destPtr, nil, pwdUTF8.isEmpty ? nil : pwdUTF8)
            if rc2 != 0 {
                throw UnrarError.fromCode(rc2) ?? .unknown(rc2)
            }
        }
    }

    public static func testArchive(url: URL, password: String?, progress: @escaping (Int32) -> Void) throws {
        try process(url: url, op: 1, destPath: nil, password: password, progress: progress)
    }

    public static func extractArchive(url: URL, to dest: URL, password: String?, progress: @escaping (Int32) -> Void) throws {
        let (entries, _) = try listArchive(url: url, password: password)
        let total = entries.reduce(UInt64(0)) { $0 + $1.unpackedSize }
        try process(url: url, op: 2, destPath: dest.path, password: password, totalBytes: total, progress: progress)
    }

    /// 按条目解压（预览/部分解压）
    public static func extractEntries(url: URL, entries: [String], to dest: URL,
                                      progress: @escaping (Double) -> Void = { _ in },
                                      cancel: @escaping () -> Bool = { false }) throws {
        let volumes = findVolumes(mainURL: url)
        guard let first = volumes.first else { throw UnrarError.openError }
        var openInfo = MROpenInfo()
        let box = Unmanaged.passRetained(ProgressBox())
        box.takeUnretainedValue().handler = { pct in progress(Double(pct) / 100.0) }
        let boxOpaque = box.toOpaque()
        let openResult = withWideString(first.path) { ptr -> (Int32, HANDLE_Box?) in
            guard let h = mr_archive_open(ptr, 1, unrarCProgressCallback, boxOpaque, nil, &openInfo) else { return (-1, nil) }
            return (0, HANDLE_Box(handle: h))
        }
        guard openResult.0 == 0, let hbox = openResult.1 else {
            box.release()
            throw UnrarError.openFailed(code: openInfo.OpenResult)
        }
        defer {
            mr_archive_close(hbox.handle)
            box.release()
        }
        let targetSet = Set(entries)
        var destPtr: UnsafeMutablePointer<wchar_t>?
        withWideString(dest.path) { ptr in destPtr = ptr }
        defer { destPtr?.deallocate() }
        while true {
            if cancel() { throw UnrarError.canceled }
            var hdr = MRHeaderInfo()
            let rc = mr_archive_read_header(hbox.handle, &hdr)
            if rc == 10 { break }
            if rc != 0 { throw UnrarError.fromCode(rc) ?? .unknown(rc) }
            let name = withUnsafeBytes(of: &hdr.NameW) { raw in
                decodeWide(raw.baseAddress!.assumingMemoryBound(to: wchar_t.self))
            }
            if targetSet.contains(name) || targetSet.contains(name + "/") {
                let rc2 = mr_archive_process(hbox.handle, 2, destPtr, nil, nil)
                if rc2 != 0 { throw UnrarError.fromCode(rc2) ?? .unknown(rc2) }
            } else {
                _ = mr_archive_process(hbox.handle, 0, nil, nil, nil)
            }
        }
    }

    fileprivate final class ProgressBox {
        var handler: ((Int32) -> Void)?
    }
    private struct HANDLE_Box { let handle: UnsafeMutableRawPointer }
}

/// C 回调（无捕获）——从 context 取出 ProgressBox 转发进度
private func unrarCProgressCallback(_ ctx: UnsafeMutableRawPointer?, _ phase: Int32, _ percent: Int32, _ name: UnsafePointer<wchar_t>?) {
    guard let ctx else { return }
    let box = Unmanaged<UnrarEngine.ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
    if phase == 0 {
        box.handler?(percent)
    }
}
