import Foundation
import zlib

// MARK: - 分卷读取器（把 z01/z02/.../zip 当作虚拟文件顺序读取）

public final class VolumesReader {
    public let volumes: [URL]
    public let volSizes: [UInt64]
    private var handles: [FileHandle?] = []
    public private(set) var totalSize: UInt64 = 0

    public init(volumes: [URL]) throws {
        self.volumes = volumes
        var volSizes: [UInt64] = []
        for url in volumes {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            volSizes.append(size)
            totalSize += size
            handles.append(nil)
        }
        self.volSizes = volSizes
    }

    /// 卷号 + 卷内偏移 → 全局偏移
    public func globalOffset(disk: UInt32, local: UInt64) -> UInt64 {
        var start: UInt64 = 0
        for (i, s) in volSizes.enumerated() {
            if i == Int(disk) { return start + local }
            start += s
        }
        return start + local
    }

    /// 全局偏移 → (卷号, 卷内偏移)
    public func localOffset(global: UInt64) -> (UInt32, UInt64) {
        var acc: UInt64 = 0
        for (i, s) in volSizes.enumerated() {
            if global < acc + s || i == volSizes.count - 1 {
                return (UInt32(i), global - acc)
            }
            acc += s
        }
        return (0, global)
    }

    public static func findVolumes(mainURL: URL) -> [URL] {
        let fm = FileManager.default
        let ext = mainURL.pathExtension.lowercased()
        let base = mainURL.deletingPathExtension().path
        // 尝试 z01, z02, ... 命名
        var vols: [URL] = []
        var i = 1
        while true {
            let name = String(format: "%@.z%02d", base, i)
            if fm.fileExists(atPath: name) {
                vols.append(URL(fileURLWithPath: name))
                i += 1
            } else {
                break
            }
        }
        vols.append(mainURL)
        // 若分卷为 f.zip / f.z01...（zip 为末卷）则顺序已对；
        // 若仅一个文件且无 z01，返回主文件
        return vols
    }

    private func handle(at index: Int) throws -> FileHandle {
        if let h = handles[index] { return h }
        let h = try FileHandle(forReadingFrom: volumes[index])
        handles[index] = h
        return h
    }

    public func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        guard length > 0 else { return [] }
        var result = [UInt8]()
        result.reserveCapacity(length)
        var pos = offset
        var remaining = length
        var volIndex = 0
        var volStart: UInt64 = 0
        for (i, s) in volSizes.enumerated() {
            if pos < volStart + s {
                volIndex = i
                break
            }
            volStart += s
            if i == volSizes.count - 1 {
                throw ZipError.missingVolume("分卷越界")
            }
        }
        var currentVolStart = volSizes[0..<volIndex].reduce(0, +)
        while remaining > 0 {
            let inVol = pos - currentVolStart
            if inVol >= volSizes[volIndex] {
                volIndex += 1
                guard volIndex < volSizes.count else { break }
                currentVolStart += volSizes[volIndex - 1]
                continue
            }
            let chunk = Int(min(UInt64(remaining), volSizes[volIndex] - inVol))
            let h = try handle(at: volIndex)
            try h.seek(toOffset: inVol)
            let data = try h.read(upToCount: chunk) ?? Data()
            result.append(contentsOf: data)
            pos += UInt64(data.count)
            remaining -= data.count
            if data.count < chunk { break }
        }
        return result
    }

    /// 读取一段并解析为无符号小端整数
    public func readInt(at offset: UInt64, bytes: Int) throws -> UInt64 {
        let data = try read(at: offset, length: bytes)
        guard data.count == bytes else { throw ZipError.corrupted("文件过早结束") }
        var v: UInt64 = 0
        for i in (0..<bytes).reversed() {
            v = (v << 8) | UInt64(data[i])
        }
        return v
    }
}

// MARK: - ZIP 条目信息

public struct ZipEntryInfo {
    public var fullPath: String
    public var isDirectory: Bool
    public var size: UInt64
    public var compressedSize: UInt64
    public var method: UInt16
    public var crc32: UInt32?
    public var modifiedDate: Date?
    public var isEncrypted: Bool
    public var isUTF8: Bool
    public var unixMode: UInt16?
    public var diskNumberStart: UInt32
    public var localHeaderOffset: UInt64
    public var aesStrength: Int?
}

// MARK: - ZIP 读取器

public final class ZipReader {
    private let reader: VolumesReader
    private let totalArchiveSize: UInt64
    private var zip64: Zip64EOCD?
    private var eocd: ZipEOCD?
    private var centralDirectory: [ZipFileHeader] = []
    private var centralDirectoryOffset: UInt64 = 0

    public init(volumes: [URL]) throws {
        reader = try VolumesReader(volumes: volumes)
        totalArchiveSize = reader.totalSize
        try parseEOCD()
        try parseCentralDirectory()
    }

    public convenience init(mainURL: URL) throws {
        let vols = VolumesReader.findVolumes(mainURL: mainURL)
        try self.init(volumes: vols)
    }

    public static func isZip(mainURL: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: mainURL) else { return false }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 4)) ?? Data()
        return data.count == 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
    }

    private func parseEOCD() throws {
        // 在文件尾部 64KB+22 字节范围内查找 EOCD 签名
        let searchLen = min(totalArchiveSize, 65557)
        guard totalArchiveSize >= 22 else { throw ZipError.notAZip }
        let start = totalArchiveSize - searchLen
        let tail = try reader.read(at: start, length: Int(searchLen))
        guard let idx = findEOCD(in: tail) else { throw ZipError.notAZip }
        var r = ByteReader(Array(tail[idx...]))
        _ = r.readUInt32() // signature
        var eocd = ZipEOCD()
        eocd.diskNumber = r.readUInt16() ?? 0
        eocd.centralDirDisk = r.readUInt16() ?? 0
        eocd.entriesOnDisk = r.readUInt16() ?? 0
        eocd.totalEntries = r.readUInt16() ?? 0
        eocd.centralDirSize = r.readUInt32() ?? 0
        eocd.centralDirOffset = r.readUInt32() ?? 0
        let commentLen = r.readUInt16() ?? 0
        let commentBytes = r.readBytes(Int(commentLen)) ?? []
        eocd.comment = String(bytes: commentBytes, encoding: .utf8) ?? ""
        self.eocd = eocd

        // ZIP64 判断
        var usesZip64 = eocd.totalEntries == 0xFFFF || eocd.centralDirOffset == 0xFFFFFFFF || eocd.centralDirSize == 0xFFFFFFFF
        if usesZip64, totalArchiveSize >= 20 {
            // ZIP64 EOCD locator 在 EOCD 前 20 字节
            let locatorOffset = start + UInt64(idx) - 20
            if locatorOffset + 20 <= totalArchiveSize {
                let locData = try reader.read(at: locatorOffset, length: 20)
                var lr = ByteReader(locData)
                if lr.readUInt32() == ZipConstants.zip64EOCDLocatorSignature {
                    let zip64EOCDOffset = lr.readUInt64() ?? 0
                    let z64Data = try reader.read(at: zip64EOCDOffset, length: 56)
                    var zr = ByteReader(z64Data)
                    if zr.readUInt32() == ZipConstants.zip64EndOfCentralDirectorySignature {
                        var z64 = Zip64EOCD()
                        z64.zip64EOCDOffset = zip64EOCDOffset
                        _ = zr.readUInt16() // size of record - 12
                        _ = zr.readUInt16() // version made by
                        _ = zr.readUInt16() // version needed
                        _ = zr.readUInt32() // disk number
                        z64.centralDirDisk = zr.readUInt32() ?? 0
                        z64.totalEntries = zr.readUInt64() ?? 0
                        z64.centralDirSize = zr.readUInt64() ?? 0
                        z64.centralDirOffset = zr.readUInt64() ?? 0
                        z64.usesZip64 = true
                        self.zip64 = z64
                        // 中央目录偏移为卷内偏移（相对 cd 所在卷），转全局
                        centralDirectoryOffset = reader.globalOffset(disk: z64.centralDirDisk, local: z64.centralDirOffset)
                        return
                    }
                }
            }
        }
        // 分卷时中央目录偏移为卷内偏移（相对 cd 所在卷），转全局
        centralDirectoryOffset = reader.globalOffset(disk: UInt32(eocd.centralDirDisk), local: UInt64(eocd.centralDirOffset))
    }

    private func findEOCD(in data: [UInt8]) -> Int? {
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var i = data.count - 22
        while i >= 0 {
            if data[i] == sig[0], data[i + 1] == sig[1], data[i + 2] == sig[2], data[i + 3] == sig[3] {
                return i
            }
            i -= 1
        }
        return nil
    }

    private func parseCentralDirectory() throws {
        guard let eocd else { throw ZipError.notAZip }
        let totalEntries = Int(zip64?.totalEntries ?? UInt64(eocd.totalEntries))
        // 逐条读取 CD
        var off = centralDirectoryOffset
        var headers: [ZipFileHeader] = []
        for _ in 0..<totalEntries {
            let (h, nextOff) = try readCentralDirectoryEntry(at: off)
            headers.append(h)
            off = nextOff
        }
        centralDirectory = headers
    }

    private func readCentralDirectoryEntry(at offset: UInt64) throws -> (ZipFileHeader, UInt64) {
        let sig = try reader.readInt(at: offset, bytes: 4)
        guard sig == ZipConstants.centralDirectorySignature else {
            throw ZipError.corrupted("中央目录解析失败")
        }
        var r = ByteReader(try reader.read(at: offset + 4, length: 42))
        var h = ZipFileHeader()
        _ = r.readUInt16() // version made by
        h.versionNeeded = r.readUInt16() ?? 0
        h.generalPurposeBits = r.readUInt16() ?? 0
        h.compressionMethod = r.readUInt16() ?? 0
        h.modifiedTime = r.readUInt16() ?? 0
        h.modifiedDate = r.readUInt16() ?? 0
        h.crc32 = r.readUInt32() ?? 0
        h.compressedSize = UInt64(r.readUInt32() ?? 0)
        h.uncompressedSize = UInt64(r.readUInt32() ?? 0)
        let nameLen = Int(r.readUInt16() ?? 0)
        let extraLen = Int(r.readUInt16() ?? 0)
        let commentLen = Int(r.readUInt16() ?? 0)
        h.diskNumberStart = UInt32(r.readUInt16() ?? 0)
        h.internalAttrs = r.readUInt16() ?? 0
        h.externalAttrs = r.readUInt32() ?? 0
        h.localHeaderOffset = UInt64(r.readUInt32() ?? 0)

        var pos = offset + 46
        let nameBytes = try reader.read(at: pos, length: nameLen)
        pos += UInt64(nameLen)
        let extraBytes = try reader.read(at: pos, length: extraLen)
        pos += UInt64(extraLen)
        _ = try reader.read(at: pos, length: commentLen)
        pos += UInt64(commentLen)

        h.fileNameBytes = nameBytes
        // 解析 extra fields
        var er = ByteReader(extraBytes)
        while er.remaining >= 4 {
            guard let id = er.readUInt16(), let size = er.readUInt16() else { break }
            let payload = er.readBytes(Int(size)) ?? []
            if id == ZipConstants.extraZip64ID {
                var p = ByteReader(payload)
                if h.uncompressedSize == 0xFFFFFFFF { h.uncompressedSize = p.readUInt64() ?? 0 }
                if h.compressedSize == 0xFFFFFFFF { h.compressedSize = p.readUInt64() ?? 0 }
                if h.localHeaderOffset == 0xFFFFFFFF { h.localHeaderOffset = p.readUInt64() ?? 0 }
                if h.diskNumberStart == 0xFFFF { h.diskNumberStart = UInt32(p.readUInt32() ?? 0) }
            }
            h.extraFields[id] = payload
        }
        // 解码文件名
        let decoded = TextEncoding.decodeFileName(bytes: Data(nameBytes))
        h.fileName = decoded
        // 扩展时间戳
        if let ts = h.extraFields[ZipConstants.extraExtendedTimestampID], ts.count >= 5, ts[0] == 1, ts.count >= 9 {
            let t: UInt32 = UInt32(ts[5]) | UInt32(ts[6]) << 8 | UInt32(ts[7]) << 16 | UInt32(ts[8]) << 24
            if t != 0 {
                h.modifiedTime = dateToDos(Date(timeIntervalSince1970: TimeInterval(t))).1
                h.modifiedDate = dateToDos(Date(timeIntervalSince1970: TimeInterval(t))).0
            }
        }
        return (h, pos)
    }

    public var entries: [ZipEntryInfo] {
        centralDirectory.map { header in
            let isDir = header.isDirectoryAttr || header.fileName.hasSuffix("/")
            return ZipEntryInfo(
                fullPath: header.fileName,
                isDirectory: isDir,
                size: header.uncompressedSize,
                compressedSize: header.compressedSize,
                method: header.compressionMethod,
                crc32: header.crc32,
                modifiedDate: header.dateValue,
                isEncrypted: header.isEncrypted,
                isUTF8: header.isUTF8,
                unixMode: header.unixMode,
                diskNumberStart: header.diskNumberStart,
                localHeaderOffset: header.localHeaderOffset,
                aesStrength: header.aesInfo?.strength
            )
        }
    }

    public var comment: String { eocd?.comment ?? "" }

    // MARK: - 解压单个条目

    public func extract(entry: ZipEntryInfo, to destURL: URL, password: String?, progress: @escaping (UInt64, UInt64) -> Void = { _, _ in }) throws {
        // 读取 local header 获取数据起始位置（注意分卷时偏移转换）
        let globalHeaderOffset = reader.globalOffset(disk: entry.diskNumberStart, local: entry.localHeaderOffset)
        let lh = try reader.read(at: globalHeaderOffset, length: 30)
        var lr = ByteReader(lh)
        guard lr.readUInt32() == ZipConstants.localFileHeaderSignature else {
            throw ZipError.corrupted("本地文件头签名错误")
        }
        _ = lr.readUInt16() // version needed
        let flags = lr.readUInt16() ?? 0
        let method = lr.readUInt16() ?? 0
        let lTime = lr.readUInt16() ?? 0
        let lDate = lr.readUInt16() ?? 0
        _ = lr.readUInt32() // crc (可能为 0)
        _ = lr.readUInt32() // compressed size
        _ = lr.readUInt32() // uncompressed size
        let nameLen = Int(lr.readUInt16() ?? 0)
        let extraLen = Int(lr.readUInt16() ?? 0)
        var dataOffset = globalHeaderOffset + 30 + UInt64(nameLen) + UInt64(extraLen)

        let encrypted = flags & UInt16(ZipConstants.generalPurposeBitFlag.encrypted) != 0
        let useDescriptor = flags & UInt16(ZipConstants.generalPurposeBitFlag.useDataDescriptor) != 0

        // 确定实际压缩方法与 AES 参数
        var actualMethod = method
        var aesStrength: Int? = nil
        if encrypted {
            // 需要从 CD 的 extra field 读取 AES 信息
            if let hdr = centralDirectory.first(where: { $0.localHeaderOffset == entry.localHeaderOffset }) {
                if let aes = hdr.aesInfo {
                    actualMethod = aes.actualMethod
                    aesStrength = aes.strength
                }
            }
        }

        var inputDataStart = dataOffset
        if encrypted, aesStrength != nil {
            // AES: salt 在前
            inputDataStart += UInt64(aesStrength! / 16) // salt 大小 = keySize/2，keySize = strength/8 → salt = strength/16
        }

        let sourceFile = try FileHandle(forReadingFrom: reader.volumes.first!) // 分卷场景由 reader 处理
        _ = sourceFile
        try extractData(method: actualMethod,
                        encrypted: encrypted,
                        aesStrength: aesStrength,
                        dataOffset: inputDataStart,
                        compressedSize: entry.compressedSize,
                        password: password,
                        destURL: destURL,
                        entry: entry,
                        flags: flags,
                        lTime: lTime,
                        lDate: lDate,
                        useDescriptor: useDescriptor,
                        progress: progress)
    }

    private func extractData(method: UInt16,
                             encrypted: Bool,
                             aesStrength: Int?,
                             dataOffset: UInt64,
                             compressedSize: UInt64,
                             password: String?,
                             destURL: URL,
                             entry: ZipEntryInfo,
                             flags: UInt16,
                             lTime: UInt16,
                             lDate: UInt16,
                             useDescriptor: Bool,
                             progress: @escaping (UInt64, UInt64) -> Void) throws {

        let fm = FileManager.default
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 符号链接安全处理：为安全跳过，不创建链接
        if let mode = entry.unixMode, (mode & 0xF000) == 0xA000 {
            return
        }

        // 准备密码
        let pwd = password ?? ""
        var zipCrypto: ZipCrypto? = nil
        var aes: WinZipAES? = nil
        var aesCounter: [UInt8] = []
        var saltData: [UInt8] = []
        var checkBytes: [UInt8] = []

        if encrypted {
            if aesStrength != nil {
                guard !pwd.isEmpty else { throw ZipError.encrypted }
                saltData = try reader.read(at: dataOffset, length: (aesStrength! / 16))
                let derived = WinZipAES(password: pwd, strengthBits: aesStrength!, salt: saltData)
                aes = derived
                aesCounter = [UInt8](repeating: 0, count: 16)
                // 密码验证：验证值在派生密钥里；解密完成后校验 auth code
                checkBytes = [UInt8(derived.passwordCheck & 0xFF), UInt8(derived.passwordCheck >> 8)]
            } else {
                zipCrypto = ZipCrypto(password: pwd)
            }
        }

        // 输出
        if entry.isDirectory {
            try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            return
        }

        // 使用 NSFileHandle 写入目标文件
        if !fm.fileExists(atPath: destURL.path) {
            fm.createFile(atPath: destURL.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: destURL)
        defer { try? output.close() }

        // 流式读取 + inflate
        var processed: UInt64 = 0
        let total = entry.size
        let chunkSize = 512 * 1024

        // 传统加密：跳过/验证 12 字节头
        var dataReadOffset = dataOffset
        if encrypted, zipCrypto != nil {
            let headerBytes = try reader.read(at: dataReadOffset, length: 12)
            guard headerBytes.count == 12 else { throw ZipError.corrupted("加密头不完整") }
            // 验证：解密后第 12 字节应为 CRC 高位（或时间高位，data descriptor 时）
            zipCrypto?.decryptHeader(headerBytes)
            dataReadOffset += 12
        }

        let methodName: String
        switch method {
        case UInt16(ZipConstants.compressionStore): methodName = "存储"
        case UInt16(ZipConstants.compressionDeflate): methodName = "Deflate"
        case UInt16(ZipConstants.compressionDeflate64): methodName = "Deflate64"
        case UInt16(ZipConstants.compressionBZIP2): methodName = "BZip2"
        default: methodName = "方法 \(method)"
        }
        guard method == ZipConstants.compressionStore || method == ZipConstants.compressionDeflate else {
            throw ZipError.unsupportedMethod(methodName)
        }

        let inflater = Inflater()
        var crc: UInt32 = 0xFFFFFFFF
        var expectedCRC = entry.crc32 ?? 0
        var encryptedBytesConsumed: UInt64 = 0
        var authCipherText: [UInt8] = []
        var authData: [UInt8] = []
        var firstChunk = true

        // 分块读取（处理 AES 尾部 salt/auth 时特殊处理）
        var pos = dataReadOffset
        let dataLen = compressedSize
        // AES 时数据末尾 10 字节 auth code 不属于压缩数据
        var remainingCompressed = dataLen
        if aes != nil {
            remainingCompressed = dataLen > 10 ? dataLen - 10 : 0
        }

        while remainingCompressed > 0 {
            let toRead = Int(min(UInt64(chunkSize), remainingCompressed))
            var chunk = try reader.read(at: pos, length: toRead)
            pos += UInt64(toRead)
            remainingCompressed -= UInt64(toRead)

            // 解密
            if let aes {
                if let plain = aes.ctrDecrypt(chunk, counter: &aesCounter) {
                    chunk = plain
                } else {
                    throw ZipError.corrupted("AES 解密失败")
                }
                authCipherText.append(contentsOf: chunk)
            } else if let zipCrypto {
                chunk = zipCrypto.decryptBlock(chunk)
            }

            // 传统加密时首块前 12 字节是密码验证，直接丢弃（已跳过）
            // 计算 CRC 并写压缩流
            switch method {
            case UInt16(ZipConstants.compressionStore):
                crc = updateCRC(crc, with: chunk)
                try output.write(contentsOf: Data(chunk))
                processed += UInt64(chunk.count)
                if !chunk.isEmpty { firstChunk = false }
                progress(processed, total)
            case UInt16(ZipConstants.compressionDeflate):
                let outData = try inflater.feed(chunk, finish: remainingCompressed == 0)
                if !outData.isEmpty {
                    crc = updateCRC(crc, with: outData)
                    try output.write(contentsOf: Data(outData))
                    processed += UInt64(outData.count)
                    firstChunk = false
                    progress(processed, total)
                }
            default:
                throw ZipError.unsupportedMethod(methodName)
            }
        }

        // Deflate 结尾
        if method == ZipConstants.compressionDeflate {
            let outData = try inflater.finish()
            if !outData.isEmpty {
                crc = updateCRC(crc, with: outData)
                try output.write(contentsOf: Data(outData))
                progress(processed + UInt64(outData.count), total)
            }
        }

        // AES 认证码校验
        if let aes {
            let auth = try reader.read(at: pos, length: 10)
            authData = auth
            let expected = aes.authCode(passwordCheckBytes: checkBytes, cipherText: authCipherText)
            if authData.count != 10 || !authData.elementsEqual(expected) {
                // 密码错误或数据损坏
                if crc != expectedCRC {
                    throw ZipError.badPassword
                }
            }
        }

        // CRC 校验（data descriptor 时用实际值）
        if useDescriptor {
            // 读 data descriptor（在数据之后）
            let descOffset = pos + UInt64(authData.count)
            let desc = try reader.read(at: descOffset, length: 16)
            if desc.count >= 16 {
                var dr = ByteReader(desc)
                var crcVal = dr.readUInt32() ?? 0
                if crcVal == 0, desc.count >= 20 {
                    // 签名版 descriptor
                    dr = ByteReader(Array(desc[4...]))
                    crcVal = dr.readUInt32() ?? 0
                }
                expectedCRC = crcVal
            }
        }
        if expectedCRC != 0, (crc ^ 0xFFFFFFFF) != expectedCRC {
            throw ZipError.badPassword
        }

        // 设置文件时间与权限
        if let mode = entry.unixMode {
            try? fm.setAttributes([.posixPermissions: mode & 0x1FF], ofItemAtPath: destURL.path)
        } else {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destURL.path)
        }
        let modDate = entry.modifiedDate
        if let modDate {
            try? fm.setAttributes([.modificationDate: modDate], ofItemAtPath: destURL.path)
        }
    }

    private func updateCRC(_ crc: UInt32, with data: [UInt8]) -> UInt32 {
        data.withUnsafeBytes { raw in
            let buf = UnsafeRawBufferPointer(raw)
            var c: UInt32 = crc
            for b in buf {
                c = CRC32.table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
            }
            return c
        }
    }

    public func fileSize() -> UInt64 { totalArchiveSize }
}

// MARK: - Inflater（zlib 流式解压）

final class Inflater {
    private var stream = z_stream()
    private var initialized = false

    init() {
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        stream.next_in = nil
        stream.avail_in = 0
        let rc = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        initialized = (rc == Z_OK)
    }

    deinit {
        if initialized { inflateEnd(&stream) }
    }

    /// 喂入压缩数据，返回解压出的数据
    func feed(_ input: [UInt8], finish: Bool) throws -> [UInt8] {
        var output = [UInt8]()
        guard initialized else { throw ZipError.corrupted("inflate 初始化失败") }
        var inBuf = input
        var outBuf = [UInt8](repeating: 0, count: 128 * 1024)
        inBuf.withUnsafeMutableBytes { rawIn in
            stream.next_in = rawIn.baseAddress?.assumingMemoryBound(to: UInt8.self)
            stream.avail_in = UInt32(rawIn.count)
            outBuf.withUnsafeMutableBytes { rawOut in
                stream.next_out = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = UInt32(rawOut.count)
                var rc = Z_OK
                while true {
                    let flush: Int32 = finish ? Z_FINISH : Z_NO_FLUSH
                    rc = inflate(&stream, flush)
                    let produced = rawOut.count - Int(stream.avail_out)
                    if produced > 0 { output.append(contentsOf: rawOut[0..<produced]) }
                    if rc == Z_STREAM_END || stream.avail_in == 0 { break }
                    if rc != Z_OK && rc != Z_BUF_ERROR { break }
                    if stream.avail_out == 0 {
                        stream.next_out = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self)
                        stream.avail_out = UInt32(rawOut.count)
                    }
                }
            }
        }
        return output
    }

    /// 完成解压（输入已耗尽后调用）
    func finish() throws -> [UInt8] {
        var output = [UInt8]()
        var outBuf = [UInt8](repeating: 0, count: 128 * 1024)
        var rc = Z_OK
        while rc != Z_STREAM_END {
            outBuf.withUnsafeMutableBytes { rawOut in
                stream.next_out = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = UInt32(rawOut.count)
            }
            rc = inflate(&stream, Z_FINISH)
            let produced = outBuf.count - Int(stream.avail_out)
            if produced > 0 { output.append(contentsOf: outBuf[0..<produced]) }
            if rc == Z_BUF_ERROR { break }
            if rc != Z_OK && rc != Z_STREAM_END { break }
        }
        return output
    }
}
