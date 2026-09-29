import Foundation

/// 文件名编码工具：处理中文 GBK 编码文件名（WinRAR 中国用户的经典痛点）
public enum TextEncoding {

    /// NSEncoding 值（kCFStringEncodingGB_18030_2000 = 0x0632）
    public static var gbkNSStringEncoding: UInt {
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))
    }

    /// 从字节解码文件名。优先 UTF-8，失败时尝试 GBK（兼容老归档）。
    public static func decodeFileName(bytes: Data) -> String {
        if let utf8 = String(data: bytes, encoding: .utf8) {
            // 排除 U+FFFD 替换符（说明部分字节非 UTF-8）
            if !utf8.contains("\u{FFFD}") { return utf8 }
        }
        if let gbk = NSString(data: bytes, encoding: gbkNSStringEncoding) as String? {
            if !gbk.contains("\u{FFFD}") { return gbk }
        }
        if let utf8 = String(data: bytes, encoding: .utf8) {
            return utf8
        }
        return String(data: bytes, encoding: .isoLatin1) ?? "unknown"
    }

    /// 从原始字节（含尾部 NUL）解码文件名
    public static func decodeRawName(_ raw: UnsafeBufferPointer<Int8>, maxLen: Int = 1024) -> String {
        let ptr = raw.baseAddress
        guard let ptr else { return "" }
        var len = 0
        while len < maxLen, ptr[len] != 0 { len += 1 }
        guard len > 0 else { return "" }
        return decodeFileName(bytes: Data(bytes: ptr, count: len))
    }

    /// 编码名字是否可用（无替换符）
    public static func isValid(_ s: String) -> Bool {
        !s.contains("\u{FFFD}")
    }
}

/// 路径安全：防止解压路径穿越（zip slip）攻击
public enum PathSafety {

    /// 将归档内路径安全合并到目标目录，返回目标 URL
    public static func safeDestinationURL(dest: URL, entryPath: String) -> URL? {
        let cleaned = entryPath.replacingOccurrences(of: "\\", with: "/")
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: true)
        var pathComponents: [String] = []
        for part in parts {
            let p = String(part)
            switch p {
            case ".", "..":
                continue
            default:
                pathComponents.append(p)
            }
        }
        guard !pathComponents.isEmpty else { return nil }
        return pathComponents.reduce(dest) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// 提取条目的父目录路径
    public static func parentOf(_ entryPath: String) -> String {
        let cleaned = entryPath.replacingOccurrences(of: "\\", with: "/")
        if let range = cleaned.range(of: "/", options: .backwards) {
            return String(cleaned[..<range.lowerBound])
        }
        return ""
    }

    public static func isAbsoluteLike(_ p: String) -> Bool {
        p.hasPrefix("/") || p.hasPrefix("\\") || p.hasPrefix("//") ||
        (p.count >= 2 && p[p.index(p.startIndex, offsetBy: 1)] == ":")
    }
}

/// 便捷字节格式化
public extension UInt64 {
    var byteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
