import Foundation
import ZIPCore

// MARK: - macOS 自解压（SFX）引擎
// 生成可执行 .command 文件：bash stub + 内嵌 ZIP 数据，双击即可自解压

public final class SFXEngine {

    public static let stubScript = """
    #!/bin/bash
    # macOS SFX 自解压归档 (MacRAR)
    # 用法: ./archive.command  或双击打开
    SELF="$0"
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    # 让用户选择解压目录
    DEST=$(osascript -e 'POSIX path of (choose folder with prompt "选择解压目录:" default location (path to desktop))' 2>/dev/null)
    if [ -z "$DEST" ]; then
      echo "已取消"
      exit 1
    fi
    python3 - "$SELF" "$DEST" <<'MACRAR_PYEOF'
    import sys, os, zipfile, tempfile

    def find_zip_end(data, maxlen=65557):
        n = len(data)
        start = max(0, n - maxlen)
        for i in range(n - 22, start - 1, -1):
            if data[i:i+4] == b'PK\\x05\\x06':
                return i
        return -1

    def main():
        self_path = sys.argv[1]
        dest = sys.argv[2]
        with open(self_path, 'rb') as f:
            data = f.read()
        idx = find_zip_end(data)
        if idx < 0:
            print('错误: 无效的自解压归档')
            sys.exit(1)
        zdata = data[:idx + 22 + int.from_bytes(data[idx+20:idx+22], 'little')]
        tmp = tempfile.NamedTemporaryFile(suffix='.zip', delete=False)
        tmp.write(zdata)
        tmp.close()
        try:
            zf = zipfile.ZipFile(tmp.name)
            for info in zf.infolist():
                target = os.path.join(dest, info.filename)
                if info.is_dir():
                    os.makedirs(target, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with zf.open(info) as src, open(target, 'wb') as dst:
                    shutil_copy(src, dst)
                os.utime(target, (info.date_time[0], 1))
            zf.close()
            print('解压完成: ' + dest)
        except Exception as e:
            print('解压失败: ' + str(e))
            sys.exit(1)
        finally:
            os.unlink(tmp.name)

    def shutil_copy(src, dst):
        while True:
            chunk = src.read(65536)
            if not chunk:
                break
            dst.write(chunk)

    if __name__ == '__main__':
        main()
    MACRAR_PYEOF
    exit 0
    """

    /// 创建自解压归档
    @discardableResult
    public static func createSFX(items: [URL], to destURL: URL, options: CreateOptions,
                          progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 1. 先压缩为临时 zip
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }
        let tmpZip = tmpDir.appendingPathComponent("sfx_data.zip")

        let zipItems = items.map {
            ZipSourceItem(sourceURL: $0, archivePath: $0.lastPathComponent, isDirectory: $0.hasDirectoryPath)
        }
        var wopts = ZipWriteOptions()
        wopts.password = options.password
        wopts.encryptMethod = (options.password != nil) ? .traditional : .none
        let writer = ZipWriter()
        try writer.write(items: zipItems, to: tmpZip, options: wopts, progress: progress)

        // 2. 拼接 stub + zip 数据
        let sfxName = destURL.pathExtension.lowercased() == "command" ? destURL.lastPathComponent : destURL.lastPathComponent + ".command"
        let finalURL = destURL.deletingLastPathComponent().appendingPathComponent(sfxName)
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        fm.createFile(atPath: finalURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: finalURL)
        try handle.write(contentsOf: Data(stubScript.utf8))
        let zipData = try Data(contentsOf: tmpZip)
        try handle.write(contentsOf: zipData)
        try handle.close()
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: finalURL.path)
        return finalURL
    }
}
