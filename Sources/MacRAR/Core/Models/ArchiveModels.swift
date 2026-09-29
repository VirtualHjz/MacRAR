import Foundation

// MARK: - 归档格式

public enum ArchiveFormat: String, CaseIterable, Identifiable, Codable, Equatable {
    case zip, rar, rar4, rar5, sevenZip = "7z", tar, gzip, bzip2, xz, lzma, zstd, iso, cpio, cab, ar, deb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .rar, .rar4: return "RAR"
        case .rar5: return "RAR5"
        case .sevenZip: return "7z"
        case .tar: return "TAR"
        case .gzip: return "GZip"
        case .bzip2: return "BZip2"
        case .xz: return "XZ"
        case .lzma: return "LZMA"
        case .zstd: return "Zstandard"
        case .iso: return "ISO"
        case .cpio: return "CPIO"
        case .cab: return "CAB"
        case .ar: return "AR"
        case .deb: return "DEB"
        }
    }

    /// 可创建的格式（压缩输出）
    public static var creatableFormats: [ArchiveFormat] {
        [.zip, .rar, .sevenZip, .tar, .gzip, .bzip2, .xz]
    }

    public var isRAR: Bool { self == .rar || self == .rar4 || self == .rar5 }

    /// WinRAR 压缩方式（用于创建归档）
    public var usesSevenZip: Bool {
        switch self {
        case .sevenZip, .tar, .gzip, .bzip2, .xz, .lzma, .zstd, .iso, .cpio, .cab, .deb, .ar: return true
        case .zip, .rar, .rar4, .rar5: return false
        }
    }

    public static func detect(from url: URL, magic: Data? = nil) -> ArchiveFormat? {
        let ext = url.pathExtension.lowercased()
        if let magic {
            if let f = detectByMagic(magic) { return f }
        }
        switch ext {
        case "zip", "zipx": return .zip
        case "rar": return .rar
        case "7z": return .sevenZip
        case "tar": return .tar
        case "gz", "gzip", "tgz": return .gzip
        case "bz2", "tbz", "tbz2": return .bzip2
        case "xz", "txz": return .xz
        case "lzma": return .lzma
        case "zst", "zstd": return .zstd
        case "iso": return .iso
        case "cpio": return .cpio
        case "cab": return .cab
        case "a", "ar": return .ar
        case "deb": return .deb
        default: return nil
        }
    }

    private static func detectByMagic(_ data: Data) -> ArchiveFormat? {
        guard let first = data.first else { return nil }
        switch first {
        case 0x50: // P K — zip
            if data.count >= 4, data[data.startIndex + 1] == 0x4B { return .zip }
            return nil
        case 0x52: // R a r
            if data.count >= 8 {
                let bytes = [UInt8](data.prefix(8))
                if bytes[1] == 0x61, bytes[2] == 0x72, bytes[3] == 0x21 {
                    return bytes[4] == 0x1A && bytes[5] == 0x07 ? .rar5 : .rar4
                }
            }
            return nil
        case 0x37: // 7 z
            if data.count >= 6 {
                let bytes = [UInt8](data.prefix(6))
                if bytes == [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C] { return .sevenZip }
            }
            return nil
        case 0x1F: // 1f 8b gzip
            if data.count >= 3, data[data.startIndex + 1] == 0x8B, data[data.startIndex + 2] == 0x08 { return .gzip }
            return nil
        case 0x42: // BZh bzip2
            if data.count >= 4, [UInt8](data.prefix(3)) == [0x42, 0x5A, 0x68] { return .bzip2 }
            return nil
        case 0xFD: // xz
            if data.count >= 6, [UInt8](data.prefix(6)) == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] { return .xz }
            return nil
        case 0x75: // ustar tar (ustar 在 257 偏移,首字节是文件内容,不一定可靠)
            return extFallback("tar")
        default:
            return nil
        }
    }

    private static func extFallback(_ ext: String) -> ArchiveFormat? {
        ArchiveFormat(rawValue: ext)
    }
}

// MARK: - 归档条目

public struct ArchiveEntry: Identifiable, Equatable, Hashable {
    public var id: String { fullPath }

    public init(fullPath: String, isDirectory: Bool, size: UInt64 = 0, packedSize: UInt64 = 0,
                modifiedDate: Date? = nil, method: String = "", isEncrypted: Bool = false,
                crc: UInt32? = nil, fileAttributes: Int? = nil) {
        self.fullPath = fullPath
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modifiedDate = modifiedDate
        self.method = method
        self.isEncrypted = isEncrypted
        self.crc = crc
        self.fileAttributes = fileAttributes
    }

    /// 归档内的完整路径（使用 / 分隔）
    public var fullPath: String
    public var isDirectory: Bool
    /// 未压缩大小
    public var size: UInt64
    /// 压缩后大小
    public var packedSize: UInt64
    public var modifiedDate: Date?
    public var method: String
    public var isEncrypted: Bool
    public var crc: UInt32?
    /// 解压后的文件属性（unix 权限等）
    public var fileAttributes: Int?

    public var name: String {
        (fullPath as NSString).lastPathComponent
    }

    public var parentPath: String {
        let path = (fullPath as NSString).deletingLastPathComponent
        return path == "." || path.isEmpty ? "" : path + "/"
    }

    public var displaySize: String {
        isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    public var displayDate: String {
        guard let modifiedDate else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: modifiedDate)
    }
}

// MARK: - 归档信息

public struct ArchiveInfo: Equatable {
    public var url: URL
    public var format: ArchiveFormat
    public var entries: [ArchiveEntry]
    public var comment: String?
    /// 归档标志（RAR: 锁定/固实/加密头/多卷/恢复记录/签名）
    public var flags: Set<ArchiveFlag> = []
    public var volumeCount: Int = 1
    /// 分卷文件名列表（含第一个）
    public var volumes: [URL] = []

    public var totalSize: UInt64 { entries.reduce(0) { $0 + $1.size } }
    public var totalPackedSize: UInt64 { entries.reduce(0) { $0 + $1.packedSize } }
    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    public var dirCount: Int { entries.count - fileCount }
}

public enum ArchiveFlag: String, Hashable {
    case volume         // 多卷
    case comment        // 含注释
    case locked         // 已锁定
    case solid          // 固实
    case encryptedHeaders
    case signed
    case recovery       // 含恢复记录
    case newNumbering   // 新版分卷命名
}

// MARK: - 解压选项

public struct ExtractOptions {
    /// 目标文件夹
    public var destination: URL = URL(fileURLWithPath: "/")

    public init() {}

    public init(destination: URL) {
        self.destination = destination
    }
    /// 密码（解压加密归档）
    public var password: String?
    /// 更新模式
    public var updateMode: ExtractUpdateMode = .extractAndReplace
    /// 覆盖模式
    public var overwriteMode: OverwriteMode = .ask
    /// 保留文件属性（unix 权限等）
    public var preserveAttributes: Bool = true
    /// 保留目录结构（不展开到单目录）
    public var keepDirectoryStructure: Bool = true
    /// 编码覆盖（nil = 自动）
    public var filenameEncoding: String.Encoding?
    /// 跳过已存在且较新的文件
    public var skipOlder: Bool = false
    /// 解压后打开文件夹
    public var revealAfterExtract: Bool = false
    /// 归档内子路径过滤（nil = 全部）
    public var subPath: String?
}

public enum ExtractUpdateMode: String, CaseIterable, Identifiable {
    case extractAndReplace // 解压并替换文件
    case extractAndUpdate  // 解压并更新文件
    case freshExisting     // 仅更新已存在文件

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .extractAndReplace: return "解压并替换文件"
        case .extractAndUpdate: return "解压并更新文件"
        case .freshExisting: return "仅更新已存在文件"
        }
    }
}

public enum OverwriteMode: String, CaseIterable, Identifiable {
    case ask          // 询问
    case overwrite    // 覆盖
    case skip         // 跳过
    case autoRename   // 自动重命名
    case overwriteOlder // 覆盖较旧

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ask: return "询问"
        case .overwrite: return "覆盖"
        case .skip: return "跳过"
        case .autoRename: return "自动重命名"
        case .overwriteOlder: return "覆盖较旧文件"
        }
    }
}

// MARK: - 创建归档选项

public struct CreateOptions {
    public var format: ArchiveFormat = .zip

    public init() {}
    /// 压缩方式 0-5（存储/最快/较快/标准/较好/最好）
    public var compressionLevel: CompressionLevel = .normal
    /// 字典大小（MB，7z 用）
    public var dictionarySize: Int = 64
    /// 分卷大小（字节，0 = 不分卷）
    public var volumeSize: UInt64 = 0
    /// 密码
    public var password: String?
    /// 加密文件名（RAR/7z 支持）
    public var encryptFileNames: Bool = false
    /// 固实归档（RAR/7z 支持）
    public var solid: Bool = false
    /// 多线程
    public var multiThreaded: Bool = true
    /// 创建自解压
    public var createSFX: Bool = false
    /// 添加恢复记录（RAR）
    public var recoveryPercent: Int = 0
    /// 压缩后删除原文件
    public var deleteFilesAfterCompression: Bool = false
    /// 添加归档注释
    public var comment: String?
    /// 每个文件独立归档（批量向导用）
    public var oneFilePerArchive: Bool = false
    /// ZIP 文件名使用 GBK 编码（兼容老系统）
    public var useGBKNames: Bool = false
    /// 时间戳属性（7z: 保留修改时间）
    public var keepTimestamps: Bool = true
}

public enum CompressionLevel: Int, CaseIterable, Identifiable {
    case store = 0
    case fastest = 1
    case fast = 2
    case normal = 3
    case good = 4
    case best = 5

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .store: return "存储"
        case .fastest: return "最快"
        case .fast: return "较快"
        case .normal: return "标准"
        case .good: return "较好"
        case .best: return "最好"
        }
    }
}

// MARK: - 任务结果

public struct TaskResult {
    public var success: Bool
    public var message: String
    public var canceled: Bool = false
    public var outputURL: URL?
    public var error: Error?
}
