import Foundation
import AppKit
import ZIPCore

// MARK: - 后台任务模型

public enum ArchiveTaskKind {
    case extract
    case create
    case test
    case repair
    case convert
}

@MainActor
public final class ArchiveTask: Identifiable, ObservableObject {
    public let id = UUID()
    public let kind: ArchiveTaskKind
    public let title: String
    @Published public var progress: Double = 0
    @Published public var status: TaskStatus = .pending
    @Published public var message: String = ""
    @Published public var processedBytes: UInt64 = 0
    @Published public var totalBytes: UInt64 = 0
    public var startDate = Date()
    public var cancelHandler: (() -> Void)?

    /// 解压速度（字节/秒）
    public var speedBytesPerSecond: Double {
        let elapsed = Date().timeIntervalSince(startDate)
        guard elapsed > 0 else { return 0 }
        return Double(processedBytes) / elapsed
    }

public enum TaskStatus {
        case pending, running, succeeded, failed, canceled
        public var displayName: String {
            switch self {
            case .pending: return "等待中"
            case .running: return "进行中"
            case .succeeded: return "已完成"
            case .failed: return "失败"
            case .canceled: return "已取消"
            }
        }
    }

    init(kind: ArchiveTaskKind, title: String) {
        self.kind = kind
        self.title = title
    }

    public func cancel() {
        cancelHandler?()
        if status == .pending || status == .running {
            status = .canceled
        }
    }
}

public struct TaskCompletion {
    public let id: UUID
    public let success: Bool
    public let message: String
    public init(id: UUID = UUID(), success: Bool, message: String) {
        self.id = id
        self.success = success
        self.message = message
    }
}

// MARK: - 应用状态

@MainActor
public final class AppState: ObservableObject {

    @Published public var currentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published public var openArchive: ArchiveInfo?
    @Published public var archivePath: String = ""          // 归档内浏览的子路径
    @Published public var selectedEntries: Set<ArchiveEntry.ID> = []
    @Published public var tasks: [ArchiveTask] = []
    @Published public var activeTask: ArchiveTask?
    @Published public var taskCompletion: TaskCompletion?
    @Published public var selectionInDirectory: Set<URL> = []

    // 面板控制
    @Published public var showExtractSheet = false
    @Published public var showCreateSheet = false
    @Published public var showTestSheet = false
    @Published public var showRepairSheet = false
    @Published public var showInfoSheet = false
    @Published public var showSettings = false
    @Published public var showWizard = false
    @Published public var showConvertSheet = false
    @Published public var errorMessage: String?

    // 导航历史
    private var history: [URL] = []
    private var historyIndex = -1

    public var isBrowsingArchive: Bool { openArchive != nil }

    public init() {
        currentDirectory = FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: 目录导航

    public func navigate(to url: URL) {
        var u = url
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: u.path, isDirectory: &isDir)
        if exists && !isDir.boolValue {
            u = u.deletingLastPathComponent()
        } else if !exists {
            let parent = u.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path) {
                u = parent
            }
        }
        // 截断历史
        if historyIndex >= 0, historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(u)
        historyIndex = history.count - 1
        currentDirectory = u
        openArchive = nil
        archivePath = ""
    }

    public func goUp() {
        if openArchive != nil {
            if archivePath.isEmpty {
                closeArchive()
            } else {
                let parent = (archivePath as NSString).deletingLastPathComponent
                archivePath = parent == "/" ? "" : parent
            }
            return
        }
        let parent = currentDirectory.deletingLastPathComponent()
        if parent.path != currentDirectory.path {
            navigate(to: parent)
        }
    }

    public func goBack() -> Bool {
        guard historyIndex > 0 else { return false }
        historyIndex -= 1
        currentDirectory = history[historyIndex]
        openArchive = nil
        return true
    }

    public func goForward() -> Bool {
        guard historyIndex < history.count - 1 else { return false }
        historyIndex += 1
        currentDirectory = history[historyIndex]
        openArchive = nil
        return true
    }

    // MARK: 归档

    public func openArchive(at url: URL) {
        openArchiveInternal(url: url, password: nil)
    }

    private func openArchiveInternal(url: URL, password: String?) {
        do {
            let info = try ArchiveService.shared.openArchive(url: url, password: password)
            openArchive = info
            archivePath = ""
            selectedEntries = []
            closeError()
        } catch {
            if isPasswordError(error) {
                promptPassword(for: url)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func isPasswordError(_ error: Error) -> Bool {
        if let ue = error as? UnrarError, case .openFailed(let code) = ue, code == 22 {
            return true
        }
        if let se = error as? SevenZipError, case .badPassword = se {
            return true
        }
        return false
    }

    private func promptPassword(for url: URL) {
        let alert = NSAlert()
        alert.messageText = "归档已加密"
        alert.informativeText = "输入密码以打开 \(url.lastPathComponent):"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            openArchiveInternal(url: url, password: field.stringValue)
        }
    }

    public func closeArchive() {
        openArchive = nil
        archivePath = ""
        selectedEntries = []
    }

    public func canGoBack() -> Bool { historyIndex > 0 }
    public func canGoForward() -> Bool { historyIndex < history.count - 1 }

    // MARK: 目录内容

    public func directoryContents() -> [DirectoryEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return DirectoryEntry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: UInt64(values?.fileSize ?? 0),
                modifiedDate: values?.contentModificationDate
            )
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    public func archiveDisplayEntries() -> [ArchiveEntry] {
        guard let info = openArchive else { return [] }
        let path = archivePath
        let prefix = path.isEmpty ? "" : path + "/"
        let isRoot = prefix.isEmpty
        var result: [ArchiveEntry] = []
        var dirs = Set<String>()
        for entry in info.entries {
            if !entry.fullPath.hasPrefix(prefix) { continue }
            let rest = String(entry.fullPath.dropFirst(prefix.count))
            if rest.isEmpty { continue }
            if isRoot || !entry.isDirectory || entry.fullPath != prefix.dropLast() {
                if let slash = rest.firstIndex(of: "/") {
                    // 子目录条目，取顶层目录
                    let dirName = String(rest[..<slash])
                    let dirPath = prefix + dirName
                    if !dirs.contains(dirPath) {
                        dirs.insert(dirPath)
                        result.append(ArchiveEntry(fullPath: dirPath + "/", isDirectory: true, size: 0))
                    }
                } else {
                    // 文件或本层目录
                    if !(entry.isDirectory && entry.fullPath.hasSuffix("/") && entry.fullPath == prefix + rest) {
                        result.append(entry)
                    } else {
                        result.append(entry)
                    }
                }
            }
        }
        return result.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.fullPath.localizedCaseInsensitiveCompare(b.fullPath) == .orderedAscending
        }
    }

    public func archiveCurrentPath() -> String {
        guard let info = openArchive else { return currentDirectory.path }
        return info.url.lastPathComponent + (archivePath.isEmpty ? "" : "/" + archivePath)
    }

    public func closeError() {
        errorMessage = nil
    }

    // MARK: 任务管理

    public func addTask(_ kind: ArchiveTaskKind, title: String, totalBytes: UInt64 = 0,
                 operation: @escaping (@escaping (Double) -> Void, @escaping () -> Bool) throws -> Void) {
        let task = ArchiveTask(kind: kind, title: title)
        task.totalBytes = totalBytes
        task.startDate = Date()
        tasks.append(task)
        activeTask = task
        Task {
            task.status = .running
            task.message = "开始..."
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    var isDone = false
                    let cancelFlag = CancellationFlag()
                    task.cancelHandler = {
                        cancelFlag.cancelled = true
                        if !isDone {
                            isDone = true
                            continuation.resume(throwing: ArchiveServiceError.canceled)
                        }
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let progressLock = NSLock()
                            var lastProgress = Date.distantPast
                            try operation({ p in
                                // 节流：最多每 0.1 秒上报一次，避免大文件解压时 UI 卡死
                                let now = Date()
                                let shouldReport: Bool
                                progressLock.lock()
                                if now.timeIntervalSince(lastProgress) > 0.1 || p >= 1 {
                                    lastProgress = now
                                    shouldReport = true
                                } else {
                                    shouldReport = false
                                }
                                progressLock.unlock()
                                if shouldReport {
                                    DispatchQueue.main.async {
                                        task.progress = p
                                        if totalBytes > 0 {
                                            task.processedBytes = UInt64(Double(totalBytes) * min(max(p, 0), 1))
                                        }
                                    }
                                }
                            }, { cancelFlag.cancelled })
                            if !isDone {
                                isDone = true
                                continuation.resume()
                            }
                        } catch {
                            if !isDone {
                                isDone = true
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
                task.status = .succeeded
                task.progress = 1
                task.message = "完成"
                activeTask = nil
                taskCompletion = TaskCompletion(success: true, message: task.title + " 已完成")
            } catch {
                if let e = error as? ArchiveServiceError, case .canceled = e {
                    task.status = .canceled
                    task.message = "已取消"
                } else {
                    task.status = .failed
                    task.message = error.localizedDescription
                    taskCompletion = TaskCompletion(success: false, message: task.title + " 失败: " + error.localizedDescription)
                    errorMessage = error.localizedDescription
                }
                activeTask = nil
            }
            // 延迟移除已结束任务
            if task.status == .succeeded {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks.remove(at: idx)
                }
            }
        }
    }
}

public struct DirectoryEntry: Identifiable {
    public let id = UUID()
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64
    public var modifiedDate: Date?
}

private final class CancellationFlag: @unchecked Sendable {
    public var cancelled = false
}
