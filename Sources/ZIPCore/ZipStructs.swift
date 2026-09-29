import Foundation

// MARK: - ZIP 数据结构（根据 APPNOTE.TXT）

enum ZipConstants {
    static let localFileHeaderSignature: UInt32 = 0x04034B50
    static let centralDirectorySignature: UInt32 = 0x02014B50
    static let endOfCentralDirectorySignature: UInt32 = 0x06054B50
    static let zip64EndOfCentralDirectorySignature: UInt32 = 0x06064B50
    static let zip64EOCDLocatorSignature: UInt32 = 0x07064B50
    static let digitalSignatureSignature: UInt32 = 0x05054B50

    static let generalPurposeBitFlag = (encrypted: 0x01, compressionOption1: 0x02, compressionOption2: 0x04, useDataDescriptor: 0x08, utf8Names: 0x800, encryptedDataDescriptor: 0x40)

    static let compressionStore = 0
    static let compressionDeflate = 8
    static let compressionDeflate64 = 9
    static let compressionBZIP2 = 12
    static let compressionZstd = 93

    static let extraZip64ID: UInt16 = 0x0001
    static let extraWinZipAESID: UInt16 = 0x9901
    static let extraUnixID: UInt16 = 0x000D
    static let extraExtendedTimestampID: UInt16 = 0x5455
    static let extraInfoZIPUnixID: UInt16 = 0x5855
}

struct ZipFileHeader {
    var versionNeeded: UInt16 = 20
    var generalPurposeBits: UInt16 = 0
    var compressionMethod: UInt16 = UInt16(ZipConstants.compressionStore)
    var modifiedTime: UInt16 = 0
    var modifiedDate: UInt16 = 0
    var crc32: UInt32 = 0
    var compressedSize: UInt64 = 0
    var uncompressedSize: UInt64 = 0
    var fileName: String = ""
    var fileNameBytes: [UInt8] = []
    var extraFields: [UInt16: [UInt8]] = [:]
    var comment: String = ""
    var internalAttrs: UInt16 = 0
    var externalAttrs: UInt32 = 0
    var localHeaderOffset: UInt64 = 0
    var diskNumberStart: UInt32 = 0

    var isEncrypted: Bool { generalPurposeBits & UInt16(ZipConstants.generalPurposeBitFlag.encrypted) != 0 }
    var isUTF8: Bool { generalPurposeBits & UInt16(ZipConstants.generalPurposeBitFlag.utf8Names) != 0 }
    var usesDataDescriptor: Bool { generalPurposeBits & UInt16(ZipConstants.generalPurposeBitFlag.useDataDescriptor) != 0 }

    // WinZip AES extra field
    var aesInfo: (version: UInt16, vendor: String, strength: Int, actualMethod: UInt16)? {
        guard let data = extraFields[ZipConstants.extraWinZipAESID], data.count >= 8 else { return nil }
        let vendor = String(bytes: data[2...4], encoding: .ascii) ?? ""
        let strength: Int
        switch data[5] {
        case 1: strength = 128
        case 2: strength = 192
        case 3: strength = 256
        default: strength = 0
        }
        let m = UInt16(data[6]) | UInt16(data[7]) << 8
        return (1, vendor, strength, m)
    }

    var unixMode: UInt16? {
        // 从 external attributes 高位取 unix 权限
        let mode = (externalAttrs >> 16) & 0xFFFF
        return mode != 0 ? UInt16(mode) : nil
    }

    var isDirectoryAttr: Bool {
        (externalAttrs & 0x10) != 0 // MS-DOS directory attribute
    }

    var dateValue: Date? {
        dosToDate(modifiedDate, time: modifiedTime)
    }

    private func dosToDate(_ d: UInt16, time t: UInt16) -> Date? {
        let day = Int(d & 0x1F)
        let month = Int((d >> 5) & 0x0F)
        let year = Int((d >> 9) & 0x7F) + 1980
        let hour = Int((t >> 11) & 0x1F)
        let minute = Int((t >> 5) & 0x3F)
        let second = Int((t & 0x1F)) * 2
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}

struct ZipEOCD {
    var diskNumber: UInt16 = 0
    var centralDirDisk: UInt16 = 0
    var entriesOnDisk: UInt16 = 0
    var totalEntries: UInt16 = 0
    var centralDirSize: UInt32 = 0
    var centralDirOffset: UInt32 = 0
    var comment: String = ""
}

struct Zip64EOCD {
    var centralDirSize: UInt64 = 0
    var centralDirOffset: UInt64 = 0
    var centralDirDisk: UInt32 = 0
    var totalEntries: UInt64 = 0
    var zip64EOCDOffset: UInt64 = 0
    var usesZip64: Bool = false
}

public enum ZipError: LocalizedError {
    case notAZip
    case corrupted(String)
    case unsupportedMethod(String)
    case encrypted
    case badPassword
    case writeFailed(String)
    case missingVolume(String)
    case entryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "不是有效的 ZIP 归档"
        case .corrupted(let s): return "ZIP 归档损坏: \(s)"
        case .unsupportedMethod(let s): return "不支持的压缩方法: \(s)"
        case .encrypted: return "归档已加密"
        case .badPassword: return "密码错误或归档已损坏"
        case .writeFailed(let s): return "写入失败: \(s)"
        case .missingVolume(let s): return "缺少分卷: \(s)"
        case .entryNotFound(let s): return "找不到条目: \(s)"
        }
    }
}

/// 内部可变读取器
struct ByteReader {
    let data: [UInt8]
    var offset: Int = 0

    init(_ data: [UInt8]) { self.data = data }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset >= data.count }

    mutating func readUInt8() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBytes(_ n: Int) -> [UInt8]? {
        guard offset + n <= data.count else { return nil }
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }

    mutating func readUInt16() -> UInt16? {
        guard let b = readBytes(2) else { return nil }
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func readUInt32() -> UInt32? {
        guard let b = readBytes(4) else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    mutating func readUInt64() -> UInt64? {
        guard let lo = readUInt32(), let hi = readUInt32() else { return nil }
        return UInt64(lo) | UInt64(hi) << 32
    }
}

func putUInt16(_ v: UInt16) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
}

func putUInt32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

func putUInt64(_ v: UInt64) -> [UInt8] {
    putUInt32(UInt32(v & 0xFFFFFFFF)) + putUInt32(UInt32(v >> 32))
}

func putUInt16Array(_ v: [UInt16]) -> [UInt8] {
    v.flatMap { putUInt16($0) }
}

func dateToDos(_ date: Date) -> (UInt16, UInt16) {
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let year = max(1980, min(2107, comps.year ?? 1980))
    let d = UInt16((year - 1980) << 9) | UInt16((comps.month ?? 1) << 5) | UInt16(comps.day ?? 1)
    let t = UInt16((comps.hour ?? 0) << 11) | UInt16((comps.minute ?? 0) << 5) | UInt16((comps.second ?? 0) / 2)
    return (d, t)
}

// CRC32
enum CRC32 {
    static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            t[i] = c
        }
        return t
    }()

    static func compute(_ data: UnsafeRawBufferPointer) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data {
            crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    static func compute(_ data: [UInt8]) -> UInt32 {
        data.withUnsafeBytes { compute(UnsafeRawBufferPointer($0)) }
    }
}
