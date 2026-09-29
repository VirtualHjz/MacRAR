import Foundation
import zlib

// MARK: - 待压缩条目

public struct ZipSourceItem {
    public var sourceURL: URL       // 源文件（文件夹会被递归）
    public var archivePath: String  // 归档内路径（/ 分隔）
    public var isDirectory: Bool = false

    public init(sourceURL: URL, archivePath: String, isDirectory: Bool = false) {
        self.sourceURL = sourceURL
        self.archivePath = archivePath
        self.isDirectory = isDirectory
    }
}

public struct ZipWriteOptions {
    public var compressionLevel: Int = 6      // 0-9
    public var password: String?
    public var encryptMethod: ZipEncryptMethod = .none
    public var volumeSize: UInt64 = 0         // 0 = 不分卷
    public var useGBKNames: Bool = false
    public var keepTimestamps: Bool = true

    public init() {}
}

public enum ZipEncryptMethod {
    case none
    case traditional   // ZipCrypto
}

public struct ZipWriteResult {
    public var urls: [URL]
    public var size: UInt64
}

// MARK: - ZIP 压缩器

public final class ZipWriter {

    private struct EntryRecord {
        var header: ZipFileHeader
        var tmpOffset: UInt64
        var compressedDataLen: UInt64
        var uncompressedLen: UInt64
        var crc: UInt32
    }

    public init() {}

    /// 压缩条目到目标 zip。分卷时生成 z01/z02/.../zip。
    @discardableResult
    public func write(items: [ZipSourceItem], to destURL: URL, options: ZipWriteOptions,
                      progress: @escaping (Double) -> Void = { _ in }) throws -> ZipWriteResult {

        let fm = FileManager.default
        var allItems: [ZipSourceItem] = []
        // 展开目录树
        for item in items {
            if item.isDirectory {
                // 目录自身条目（空目录也需要）
                let selfPath = item.archivePath.hasSuffix("/") ? item.archivePath : item.archivePath + "/"
                allItems.append(ZipSourceItem(sourceURL: item.sourceURL, archivePath: selfPath, isDirectory: true))
                let basePath = item.sourceURL.standardizedFileURL.path
                if let entries = fm.enumerator(at: item.sourceURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for case let url as URL in entries {
                        let urlPath = url.standardizedFileURL.path
                        guard urlPath.hasPrefix(basePath) else { continue }
                        let rel = String(urlPath.dropFirst(basePath.count))
                        var archivePath = item.archivePath + rel
                        if url.hasDirectoryPath {
                            if !archivePath.hasSuffix("/") { archivePath += "/" }
                            allItems.append(ZipSourceItem(sourceURL: url, archivePath: archivePath, isDirectory: true))
                        } else {
                            allItems.append(ZipSourceItem(sourceURL: url, archivePath: archivePath))
                        }
                    }
                }
            } else {
                allItems.append(item)
            }
        }
        // 确保目录条目存在于路径中
        let dirs = Set(allItems.map { PathSafety.parentOf($0.archivePath) })
        for d in dirs where !d.isEmpty {
            if !allItems.contains(where: { $0.archivePath == d + "/" }) {
                // 目录条目（无源目录可附加时间，用源文件的）
            }
        }

        // 压缩所有条目到临时数据文件，记录元数据
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        var records: [EntryRecord] = []
        let tmpData = tmpDir.appendingPathComponent("data.bin")
        fm.createFile(atPath: tmpData.path, contents: nil)
        let dataHandle = try FileHandle(forWritingTo: tmpData)
        var tmpCursor: UInt64 = 0

        let totalWork = Double(max(1, allItems.count))
        var processed = 0

        for item in allItems {
            var header = ZipFileHeader()
            header.fileName = item.archivePath
            header.compressionMethod = UInt16(ZipConstants.compressionDeflate)
            if let attrs = try? fm.attributesOfItem(atPath: item.sourceURL.path) {
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                header.uncompressedSize = size
                if let date = attrs[.modificationDate] as? Date, options.keepTimestamps {
                    let (d, t) = dateToDos(date)
                    header.modifiedDate = d
                    header.modifiedTime = t
                }
                if let mode = attrs[.posixPermissions] as? NSNumber {
                    header.externalAttrs = UInt32(mode.uint16Value) << 16
                }
            }
            if item.isDirectory {
                header.fileName = item.archivePath.hasSuffix("/") ? item.archivePath : item.archivePath + "/"
                header.compressionMethod = UInt16(ZipConstants.compressionStore)
                header.uncompressedSize = 0
                header.externalAttrs |= 0x10 // directory attribute
                // 写入数据（空）
                let rec = EntryRecord(header: header, tmpOffset: tmpCursor, compressedDataLen: 0, uncompressedLen: 0, crc: 0)
                records.append(rec)
                processed += 1
                progress(Double(processed) / totalWork)
                continue
            }

            // 符号链接：存储链接目标
            let attrs = (try? fm.attributesOfItem(atPath: item.sourceURL.path)) ?? [:]
            let fileType = attrs[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink {
                header.compressionMethod = UInt16(ZipConstants.compressionStore)
                let target = (try? fm.destinationOfSymbolicLink(atPath: item.sourceURL.path)) ?? ""
                header.uncompressedSize = UInt64(target.utf8.count)
                header.externalAttrs = UInt32(0xA000) << 16 // S_IFLNK
                let rec = try writeRecord(header: &header, data: Array(target.utf8), dataHandle: dataHandle, tmpCursor: &tmpCursor)
                records.append(rec)
                processed += 1
                progress(Double(processed) / totalWork)
                continue
            }

            // 读取文件并压缩
            guard let input = FileHandle(forReadingAtPath: item.sourceURL.path) else {
                throw ZipError.writeFailed("无法打开 \(item.archivePath)")
            }
            defer { try? input.close() }

            let level = min(9, max(0, options.compressionLevel))
            let deflater = Deflater(level: level)
            var crc: UInt32 = 0xFFFFFFFF
            var compressedLen: UInt64 = 0
            var uncompressedLen: UInt64 = 0
            let chunkSize = 512 * 1024
            var total = (try? fm.attributesOfItem(atPath: item.sourceURL.path))?[.size] as? UInt64 ?? 0
            var readTotal: UInt64 = 0

            while true {
                let data = try input.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }
                readTotal += UInt64(data.count)
                data.withUnsafeBytes { raw in
                    for b in raw { crc = CRC32.table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
                }
                let outData = try deflater.feed([UInt8](data), finish: false)
                uncompressedLen += UInt64(data.count)
                if !outData.isEmpty {
                    try dataHandle.write(contentsOf: Data(outData))
                    compressedLen += UInt64(outData.count)
                    tmpCursor += UInt64(outData.count)
                }
                if total > 0 {
                    progress(Double(processed) / totalWork + (Double(readTotal) / Double(total)) / totalWork)
                }
            }
            let finalOut = try deflater.finish()
            if !finalOut.isEmpty {
                try dataHandle.write(contentsOf: Data(finalOut))
                compressedLen += UInt64(finalOut.count)
                tmpCursor += UInt64(finalOut.count)
            }

            header.uncompressedSize = uncompressedLen
            header.compressedSize = compressedLen
            header.crc32 = crc ^ 0xFFFFFFFF
            let rec = EntryRecord(header: header, tmpOffset: tmpCursor - compressedLen, compressedDataLen: compressedLen, uncompressedLen: uncompressedLen, crc: crc ^ 0xFFFFFFFF)
            records.append(rec)
            processed += 1
            progress(Double(processed) / totalWork)
            total = 0
        }
        try dataHandle.close()

        // 构建卷文件
        let volSize = options.volumeSize
        let (volumeURLs, _) = try buildVolumes(records: records,
                                               dataFile: tmpData,
                                               destURL: destURL,
                                               volSize: volSize,
                                               options: options)
        let totalSize = volumeURLs.reduce(UInt64(0)) { acc, url in acc + (UInt64(((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0)) }
        return ZipWriteResult(urls: volumeURLs, size: totalSize)
    }

    private func writeRecord(header: inout ZipFileHeader, data: [UInt8], dataHandle: FileHandle, tmpCursor: inout UInt64) throws -> EntryRecord {
        header.crc32 = CRC32.compute(data)
        header.compressedSize = UInt64(data.count)
        let offset = tmpCursor
        try dataHandle.write(contentsOf: Data(data))
        tmpCursor += UInt64(data.count)
        return EntryRecord(header: header, tmpOffset: offset, compressedDataLen: UInt64(data.count), uncompressedLen: UInt64(data.count), crc: header.crc32)
    }

    private func buildVolumes(records: [EntryRecord], dataFile: URL, destURL: URL, volSize: UInt64, options: ZipWriteOptions) throws -> ([URL], [UInt32]) {
        let fm = FileManager.default
        let name = destURL.deletingPathExtension().lastPathComponent
        let dir = destURL.deletingLastPathComponent()
        let ext = destURL.pathExtension.isEmpty ? "zip" : destURL.pathExtension

        // 标准分卷命名：z01 为第一卷，最后一个分卷为 .zip
        func volumeName(_ i: Int) -> URL {
            if volSize == 0 {
                return dir.appendingPathComponent("\(name).\(ext)")
            }
            return dir.appendingPathComponent(String(format: "%@.z%02d", name, i + 1))
        }

        let dataHandle = try FileHandle(forReadingFrom: dataFile)
        defer { try? dataHandle.close() }

        var currentVolume: FileHandle? = nil
        var currentVolumeIndex = 0
        var currentVolumeOffset: UInt64 = 0
        var createdURLs: [URL] = []
        // 记录每个条目写入的（卷号, 卷内偏移）
        var entryVolumeDisk: [UInt32] = []
        var entryVolumeOffset: [UInt64] = []

        func closeCurrentVolume() throws {
            try currentVolume?.close()
            currentVolume = nil
        }
        func openNextVolume() throws {
            try closeCurrentVolume()
            currentVolumeIndex += 1
            let url = volumeName(currentVolumeIndex)
            fm.createFile(atPath: url.path, contents: nil)
            currentVolume = try FileHandle(forWritingTo: url)
            currentVolumeOffset = 0
            createdURLs.append(url)
        }
        func writeBytes(_ bytes: [UInt8]) throws {
            if currentVolume == nil {
                let url = volumeName(0)
                fm.createFile(atPath: url.path, contents: nil)
                currentVolume = try FileHandle(forWritingTo: url)
                currentVolumeOffset = 0
                createdURLs.append(url)
            }
            if volSize > 0 {
                var i = 0
                while i < bytes.count {
                    let remainingInVol = volSize - currentVolumeOffset
                    if remainingInVol == 0 {
                        try openNextVolume()
                        continue
                    }
                    let chunk = Int(min(UInt64(bytes.count - i), remainingInVol))
                    try currentVolume?.write(contentsOf: Data(bytes[i..<i + chunk]))
                    currentVolumeOffset += UInt64(chunk)
                    i += chunk
                }
            } else {
                try currentVolume?.write(contentsOf: Data(bytes))
                currentVolumeOffset += UInt64(bytes.count)
            }
        }

        // 逐条目写入：local header + 数据
        for rec in records {
            var header = rec.header
            let disk = UInt32(currentVolumeIndex)
            let offsetInVol = currentVolumeOffset

            // local header 数据
            var localData: [UInt8] = []
            localData += putUInt32(ZipConstants.localFileHeaderSignature)
            localData += putUInt16(10) // version needed
            var flags: UInt16 = header.generalPurposeBits
            if !options.password.isEmptyOrNil {
                flags |= UInt16(ZipConstants.generalPurposeBitFlag.encrypted)
            }
            if !options.useGBKNames {
                flags |= UInt16(ZipConstants.generalPurposeBitFlag.utf8Names)
            }
            header.generalPurposeBits = flags
            localData += putUInt16(flags)
            localData += putUInt16(header.compressionMethod)
            localData += putUInt16(header.modifiedTime)
            localData += putUInt16(header.modifiedDate)
            localData += putUInt32(header.crc32)
            localData += putUInt32(UInt32(min(UInt64(0xFFFFFFFF), header.compressedSize)))
            localData += putUInt32(UInt32(min(UInt64(0xFFFFFFFF), header.uncompressedSize)))
            let nameBytes = options.useGBKNames
                ? Array((header.fileName as NSString).data(using: TextEncoding.gbkNSStringEncoding) ?? Data(header.fileName.utf8))
                : Array(header.fileName.utf8)
            localData += putUInt16(UInt16(nameBytes.count))
            let extra = buildExtra(header: header)
            localData += putUInt16(UInt16(extra.count))
            localData += nameBytes
            localData += extra
            try writeBytes(localData)

            // 加密：头部 12 字节与数据共用同一状态（传统 ZipCrypto）
            var crypto: ZipCrypto?
            if !options.password.isEmptyOrNil {
                crypto = ZipCrypto(password: options.password!)
                let crcHigh = UInt8((header.crc32 >> 24) & 0xFF)
                let encHeader = crypto!.headerBytes(crcHighByte: crcHigh)
                try writeBytes(encHeader)
            }

            // 数据（加密则加密）
            try dataHandle.seek(toOffset: rec.tmpOffset)
            var remaining = rec.compressedDataLen
            let chunkSize = 512 * 1024
            while remaining > 0 {
                let data = try dataHandle.read(upToCount: Int(min(UInt64(chunkSize), remaining))) ?? Data()
                if data.isEmpty { break }
                remaining -= UInt64(data.count)
                if let crypto {
                    try writeBytes(crypto.encryptBlock([UInt8](data)))
                } else {
                    try writeBytes([UInt8](data))
                }
            }

            entryVolumeDisk.append(disk)
            entryVolumeOffset.append(offsetInVol)
        }

        // Central Directory（末卷）
        var cdStart = currentVolumeOffset
        _ = cdStart
        var cdData: [UInt8] = []
        var cdOffsets: [UInt64] = []
        var totalCDSize: UInt64 = 0

        for (i, rec) in records.enumerated() {
            let offsetField = entryVolumeOffset[i]
            let diskField = entryVolumeDisk[i]
            var h = rec.header
            if !options.password.isEmptyOrNil {
                h.generalPurposeBits |= UInt16(ZipConstants.generalPurposeBitFlag.encrypted)
            }
            if !options.useGBKNames {
                h.generalPurposeBits |= UInt16(ZipConstants.generalPurposeBitFlag.utf8Names)
            }
            let nameBytes = options.useGBKNames
                ? Array((h.fileName as NSString).data(using: TextEncoding.gbkNSStringEncoding) ?? Data(h.fileName.utf8))
                : Array(h.fileName.utf8)
            let extra = buildExtra(header: h)

            cdOffsets.append(totalCDSize)
            var entry: [UInt8] = []
            entry += putUInt32(ZipConstants.centralDirectorySignature)
            entry += putUInt16(20) // version made by (unix)
            entry += putUInt16(20) // version needed
            entry += putUInt16(h.generalPurposeBits)
            entry += putUInt16(h.compressionMethod)
            entry += putUInt16(h.modifiedTime)
            entry += putUInt16(h.modifiedDate)
            entry += putUInt32(h.crc32)
            entry += putUInt32(UInt32(min(UInt64(0xFFFFFFFF), h.compressedSize)))
            entry += putUInt32(UInt32(min(UInt64(0xFFFFFFFF), h.uncompressedSize)))
            entry += putUInt16(UInt16(nameBytes.count))
            entry += putUInt16(UInt16(extra.count))
            entry += putUInt16(0) // comment len
            entry += putUInt16(UInt16(diskField)) // disk number start
            entry += putUInt16(0) // internal attrs
            entry += putUInt32(h.externalAttrs)
            entry += putUInt32(UInt32(min(UInt64(0xFFFFFFFF), offsetField)))
            entry += nameBytes
            entry += extra
            cdData += entry
            totalCDSize += UInt64(entry.count)
        }

        let cdStartOffset = currentVolumeOffset
        // EOCD 中 central directory 偏移需为全局偏移（相对首卷）
        var globalBase: UInt64 = 0
        if volSize > 0 {
            for url in createdURLs.dropLast() {
                globalBase += (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            }
        }
        try writeBytes(cdData)

        // EOCD
        var eocdData: [UInt8] = []
        eocdData += putUInt32(ZipConstants.endOfCentralDirectorySignature)
        eocdData += putUInt16(0)
        eocdData += putUInt16(0)
        eocdData += putUInt16(UInt16(min(0xFFFF, records.count)))
        eocdData += putUInt16(UInt16(min(0xFFFF, records.count)))
        eocdData += putUInt32(UInt32(min(UInt64(0xFFFFFFFF), totalCDSize)))
        eocdData += putUInt32(UInt32(min(UInt64(0xFFFFFFFF), globalBase + cdStartOffset)))
        eocdData += putUInt16(0) // comment len
        try writeBytes(eocdData)

        try closeCurrentVolume()
        // 若为分卷，将最后一个 .zNN 重命名为 .zip（末卷）
        if volSize > 0, let lastURL = createdURLs.last, lastURL.pathExtension.hasPrefix("z") {
            let finalURL = dir.appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: lastURL, to: finalURL)
            createdURLs[createdURLs.count - 1] = finalURL
        }
        return (createdURLs, entryVolumeDisk)
    }

    private func buildExtra(header: ZipFileHeader) -> [UInt8] {
        // unix 权限 + 时间戳
        var extra: [UInt8] = []
        // unix 属性 (0x000D)
        var unixPayload: [UInt8] = []
        unixPayload += putUInt16(0) // version
        unixPayload += putUInt32(header.externalAttrs) // atime (unused)
        unixPayload += putUInt32(header.externalAttrs)
        unixPayload += putUInt32(header.externalAttrs)
        if !unixPayload.isEmpty {
            extra += putUInt16(ZipConstants.extraUnixID)
            extra += putUInt16(UInt16(unixPayload.count))
            extra += unixPayload
        }
        // 扩展时间戳 (0x5455) - 修改时间
        if let date = header.dateValue {
            let ts = UInt32(date.timeIntervalSince1970)
            var tsPayload: [UInt8] = [1] // mtime flag
            tsPayload += putUInt32(ts)
            extra += putUInt16(ZipConstants.extraExtendedTimestampID)
            extra += putUInt16(UInt16(tsPayload.count))
            extra += tsPayload
        }
        return extra
    }
}

private extension String {
    var isEmptyOrNil: Bool { isEmpty }
}

extension Optional where Wrapped == String {
    var isEmptyOrNil: Bool {
        guard let s = self else { return true }
        return s.isEmpty
    }
}

// MARK: - Deflater（zlib 流式压缩）

final class Deflater {
    private var stream = z_stream()
    private var initialized = false

    init(level: Int) {
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        let rc = deflateInit2_(&stream, Int32(level), Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        initialized = (rc == Z_OK)
    }

    deinit {
        if initialized { deflateEnd(&stream) }
    }

    func feed(_ input: [UInt8], finish: Bool) throws -> [UInt8] {
        guard initialized else { throw ZipError.writeFailed("deflate 初始化失败") }
        var output = [UInt8]()
        var inBuf = input
        var outBuf = [UInt8](repeating: 0, count: 128 * 1024)
        inBuf.withUnsafeMutableBytes { rawIn in
            stream.next_in = rawIn.baseAddress?.assumingMemoryBound(to: UInt8.self)
            stream.avail_in = UInt32(rawIn.count)
            outBuf.withUnsafeMutableBytes { rawOut in
                stream.next_out = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = UInt32(rawOut.count)
                while stream.avail_in > 0 {
                    let rc = deflate(&stream, Z_NO_FLUSH)
                    let produced = rawOut.count - Int(stream.avail_out)
                    if produced > 0 { output.append(contentsOf: rawOut[0..<produced]) }
                    if rc != Z_OK { break }
                    if stream.avail_out == 0 {
                        stream.next_out = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self)
                        stream.avail_out = UInt32(rawOut.count)
                    }
                }
            }
        }
        return output
    }

    func finish() throws -> [UInt8] {
        var output = [UInt8]()
        var outBuf = [UInt8](repeating: 0, count: 128 * 1024)
        var rc = Z_OK
        while rc != Z_STREAM_END {
            outBuf.withUnsafeMutableBytes { rawOut in
                stream.next_out = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = UInt32(rawOut.count)
            }
            rc = deflate(&stream, Z_FINISH)
            let produced = outBuf.count - Int(stream.avail_out)
            if produced > 0 { output.append(contentsOf: outBuf[0..<produced]) }
            if rc == Z_BUF_ERROR { break }
        }
        return output
    }
}