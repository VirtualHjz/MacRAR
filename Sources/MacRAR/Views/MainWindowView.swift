import SwiftUI
import AppKit
import ZIPCore
import MacRARCore

// MARK: - 主窗口（复刻 WinRAR 界面布局）

struct MainWindowView: View {
    @ObservedObject var appState: AppState
    @State private var addressText = ""
    @State private var searchText = ""
    @State private var dirSelection: Set<DirectoryEntry.ID> = []
    @State private var archiveSelection: Set<ArchiveEntry.ID> = []

    private var isArchiveMode: Bool { appState.isBrowsingArchive }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            addressBar
            Divider()
            fileList
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            addressText = appState.currentDirectory.path
        }
        .onChange(of: appState.currentDirectory) { _, newValue in
            addressText = newValue.path
        }
        .onChange(of: appState.archivePath) { _, _ in
            addressText = appState.archiveCurrentPath()
        }
        .onChange(of: appState.openArchive) { _, newValue in
            if newValue != nil {
                addressText = appState.archiveCurrentPath()
            }
        }
        .alert("错误", isPresented: Binding(get: { appState.errorMessage != nil }, set: { if !$0 { appState.closeError() } })) {
            Button("好") { appState.closeError() }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .sheet(isPresented: $appState.showExtractSheet) {
            ExtractSheetView(appState: appState)
        }
        .sheet(isPresented: $appState.showCreateSheet) {
            CreateArchiveSheetView(appState: appState)
        }
        .sheet(isPresented: $appState.showRepairSheet) {
            RepairSheetView(appState: appState)
        }
        .sheet(isPresented: $appState.showInfoSheet) {
            if let info = appState.openArchive {
                InfoSheetView(info: info, appState: appState)
            }
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView(appState: appState)
        }
        .sheet(isPresented: $appState.showWizard) {
            WizardSheetView(appState: appState)
        }
        .sheet(isPresented: $appState.showConvertSheet) {
            if let info = appState.openArchive {
                ConvertSheetView(info: info, appState: appState)
            }
        }
        .sheet(isPresented: $appState.showTestSheet) {
            if let info = appState.openArchive {
                TestSheetView(info: info, appState: appState)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .overlay {
            if let task = appState.activeTask {
                overlayCard {
                    TaskProgressSheet(task: task) {
                        task.cancel()
                    }
                }
            } else if let completion = appState.taskCompletion {
                overlayCard {
                    TaskCompletionAlert(completion: completion) {
                        appState.taskCompletion = nil
                    }
                }
            }
        }
    }

    /// 居中卡片遮罩（模拟弹窗，不受多 sheet 冲突影响）
    private func overlayCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            content()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
                )
        }
        .transition(.opacity)
    }

    // MARK: - 工具栏（WinRAR 风格：图标 + 文字）

    private var toolbar: some View {
        HStack(spacing: 4) {
            mainToolButtons
            Spacer()
            navigationButtons
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var mainToolButtons: some View {
        HStack(spacing: 4) {
            ToolButton(icon: "plus.square", title: "添加", enabled: true) {
                appState.showCreateSheet = true
            }
            ToolButton(icon: "arrow.down.circle", title: "解压到", enabled: appState.isBrowsingArchive) {
                appState.showExtractSheet = true
            }
            ToolButton(icon: "checkmark.shield", title: "测试", enabled: appState.isBrowsingArchive) {
                appState.showTestSheet = true
            }
            ToolButton(icon: "eye", title: "查看", enabled: selectionEnabled) {
                viewSelected()
            }
            ToolButton(icon: "trash", title: "删除", enabled: selectionEnabled) {
                deleteSelected()
            }
            ToolButton(icon: "wand.and.stars", title: "向导", enabled: true) {
                appState.showWizard = true
            }
            ToolButton(icon: "info.circle", title: "信息", enabled: appState.isBrowsingArchive) {
                appState.showInfoSheet = true
            }
            ToolButton(icon: "wrench.and.screwdriver", title: "修复", enabled: appState.isBrowsingArchive) {
                appState.showRepairSheet = true
            }
            ToolButton(icon: "doc.badge.gearshape", title: "SFX", enabled: appState.isBrowsingArchive) {
                createSFX()
            }
            ToolButton(icon: "lock", title: "保护", enabled: appState.isBrowsingArchive) {
                protectArchive()
            }
            ToolButton(icon: "arrow.triangle.2.circlepath", title: "转换", enabled: appState.isBrowsingArchive) {
                convertArchive()
            }
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 4) {
            Button {
                _ = appState.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!appState.canGoBack())
            .help("后退")
            Button {
                _ = appState.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!appState.canGoForward())
            .help("前进")
        }
    }

    private var selectionEnabled: Bool {
        appState.isBrowsingArchive ? !appState.selectedEntries.isEmpty : !appState.selectionInDirectory.isEmpty
    }

    // MARK: - 地址栏

    private var addressBar: some View {
        HStack(spacing: 6) {
            Button {
                appState.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("上级目录")
            TextField("路径", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    navigateToAddress()
                }
            if isArchiveMode {
                Button {
                    appState.closeArchive()
                } label: {
                    Text("关闭归档")
                }
                .help("关闭归档返回文件夹")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 文件列表

    private var fileList: some View {
        Group {
            if appState.isBrowsingArchive {
                archiveList
            } else {
                directoryList
            }
        }
    }

    private var directoryList: some View {
        List(selection: $dirSelection) {
            ForEach(appState.directoryContents()) { entry in
                DirectoryRow(entry: entry) {
                    if entry.isDirectory {
                        appState.navigate(to: entry.url)
                    } else if ArchiveFormat.detect(from: entry.url) != nil {
                        appState.openArchive(at: entry.url)
                    } else {
                        NSWorkspace.shared.open(entry.url)
                    }
                }
                .tag(entry.id)
                .contextMenu { directoryContextMenu(for: entry) }
            }
        }
        .listStyle(.inset)
        .onChange(of: dirSelection) { _, newValue in
            let rows = appState.directoryContents()
            appState.selectionInDirectory = Set(rows.filter { newValue.contains($0.id) }.map { $0.url })
        }
    }

    private var archiveList: some View {
        List(selection: $archiveSelection) {
            ForEach(appState.archiveDisplayEntries()) { entry in
                ArchiveRow(entry: entry) {
                    if entry.isDirectory {
                        appState.archivePath = entry.fullPath.replacingOccurrences(of: "/", with: "")
                    } else {
                        previewEntry(entry)
                    }
                }
                .tag(entry.id)
                .contextMenu { archiveContextMenu(for: entry) }
            }
        }
        .listStyle(.inset)
        .onChange(of: archiveSelection) { _, newValue in
            appState.selectedEntries = newValue
        }
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack {
            if isArchiveMode, let info = appState.openArchive {
                Text("\(info.fileCount) 个文件  \(info.dirCount) 个文件夹")
                Spacer()
                Text("原始大小: \(info.totalSize.byteCount)   压缩后: \(info.totalPackedSize.byteCount)")
            } else {
                let contents = appState.directoryContents()
                let dirs = contents.filter { $0.isDirectory }.count
                let files = contents.count - dirs
                let totalSize = contents.reduce(UInt64(0)) { $0 + ($1.isDirectory ? 0 : UInt64($1.size)) }
                Text("\(files) 个文件  \(dirs) 个文件夹")
                Spacer()
                Text("总大小: \(totalSize.byteCount)")
            }
            Spacer()
            if !appState.tasks.isEmpty {
                TaskIndicatorView(tasks: appState.tasks)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 辅助

    private var hasSelection: Bool {
        isArchiveMode ? !appState.selectedEntries.isEmpty : !appState.selectionInDirectory.isEmpty
    }

    private var canGoBack: Bool { false }
    private var canGoForward: Bool { false }

    private func icon(for entry: DirectoryEntry) -> NSImage {
        NSWorkspace.shared.icon(forFile: entry.url.path)
    }

    private func fileIconName(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz": return "archivebox"
        case "txt", "md", "log": return "doc.plaintext"
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "heic": return "photo"
        case "mp4", "mov", "avi": return "film"
        case "mp3", "wav", "flac": return "music.note"
        default: return "doc"
        }
    }

    private func navigateToAddress() {
        let path = addressText
        // 归档路径如 archive.zip/subdir
        if let range = path.range(of: ".zip/"), range.lowerBound > path.startIndex {
            let archivePath = String(path[..<range.upperBound]).replacingOccurrences(of: "/", with: "")
            let sub = String(path[range.upperBound...])
            let archiveURL = URL(fileURLWithPath: archivePath)
            appState.openArchive(at: archiveURL)
            appState.archivePath = sub
            return
        }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            if ArchiveFormat.detect(from: url) != nil {
                appState.openArchive(at: url)
            } else {
                appState.navigate(to: url)
            }
        }
    }

    private func openArchiveSelection() {
        guard let entry = currentArchiveSelection() else { return }
        if entry.isDirectory {
            appState.archivePath = entry.fullPath.replacingOccurrences(of: "/", with: "")
            return
        }
        // 打开文件（查看）
        previewEntry(entry)
    }

    private func currentArchiveSelection() -> ArchiveEntry? {
        let entries = appState.archiveDisplayEntries()
        return entries.first { appState.selectedEntries.contains($0.id) }
    }

    private func viewSelected() {
        if isArchiveMode {
            for entry in appState.archiveDisplayEntries() where appState.selectedEntries.contains(entry.id) {
                previewEntry(entry)
                break
            }
        }
    }

    private func previewEntry(_ entry: ArchiveEntry) {
        ArchiveService.shared.probeMethod()
        // 提取到临时目录并打开
        guard let info = appState.openArchive else { return }
        appState.addTask(.extract, title: "查看 \(entry.name)") { progress, cancel in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MacRAR_preview_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            // 提取选中条目到临时目录
            try ArchiveService.shared.extractEntries(info: info, entries: [entry], to: tmp, progress: progress, cancel: cancel)
            let fileURL = tmp.appendingPathComponent(entry.name)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(fileURL)
            }
        }
    }

    private func deleteSelected() {
        if isArchiveMode {
            let paths = appState.archiveDisplayEntries().filter { appState.selectedEntries.contains($0.id) }.map { $0.fullPath }
            if !paths.isEmpty { deleteArchiveEntries(paths) }
            return
        } else {
            let urls = Array(appState.selectionInDirectory)
            guard !urls.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "确认删除 \(urls.count) 个项目?"
            alert.informativeText = "删除后将无法恢复。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func createSFX() {
        guard let info = appState.openArchive else { return }
        appState.addTask(.convert, title: "创建自解压") { progress, cancel in
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = info.url.deletingPathExtension().lastPathComponent + ".command"
            if savePanel.runModal() == .OK, let dest = savePanel.url {
                var opts = CreateOptions()
                opts.format = .sevenZip
                opts.createSFX = true
                _ = try ArchiveService.shared.createSFXFromArchive(info: info, to: dest, options: opts, progress: progress, cancel: cancel)
            }
        }
    }

    private func protectArchive() {
        guard let info = appState.openArchive else { return }
        let alert = NSAlert()
        alert.messageText = "归档保护"
        alert.informativeText = "设置解压密码将保护归档内容。此操作将重建归档。"
        alert.addButton(withTitle: "取消")
        alert.runModal()
    }

    private func convertArchive() {
        guard let info = appState.openArchive else { return }
        appState.showConvertSheet = true
    }

    private func directoryContextMenu(for entry: DirectoryEntry) -> some View {
        Group {
            Button("打开") {
                if entry.isDirectory {
                    appState.navigate(to: entry.url)
                } else {
                    NSWorkspace.shared.open(entry.url)
                }
            }
            Button("压缩为...") {
                appState.showCreateSheet = true
            }
            Divider()
            Button("重命名") {}
            Button("删除") {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    private func archiveContextMenu(for entry: ArchiveEntry) -> some View {
        Group {
            Button("解压到...") {
                appState.showExtractSheet = true
            }
            Button("查看") {
                previewEntry(entry)
            }
            Divider()
            Button("添加文件...") {
                addFilesToArchive()
            }
            Button("删除") {
                deleteArchiveEntries([entry.fullPath])
            }
            Button("重命名...") {
                renameArchiveEntry(entry)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty {
                appState.showCreateSheet = true
            }
        }
        return true
    }
}

// MARK: - 工具栏按钮

struct ToolButton: View {
    let icon: String
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(width: 52, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(title)
    }
}

// MARK: - 任务指示

struct TaskIndicatorView: View {
    let tasks: [ArchiveTask]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tasks) { task in
                HStack(spacing: 4) {
                    ProgressView(value: task.progress)
                        .frame(width: 100)
                    Text(task.status.displayName)
                        .font(.caption2)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .quaternaryLabelColor)))
            }
        }
    }
}

// MARK: - 排序辅助行

struct SortableRow: Identifiable {
    let id = UUID()
    var name: String
    var isDirectory: Bool
    var size: UInt64
}

// MARK: - 文件列表行

struct DirectoryRow: View {
    let entry: DirectoryEntry
    var onDoubleTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if !entry.isDirectory {
                Text(UInt64(entry.size).byteCount)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Text(entry.modifiedDate?.formatted(date: .numeric, time: .shortened) ?? "--")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
    }
}

struct ArchiveRow: View {
    let entry: ArchiveEntry
    var onDoubleTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundColor(entry.isDirectory ? .blue : .secondary)
                .frame(width: 16)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if !entry.isDirectory {
                Text(entry.size.byteCount)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Text(entry.method)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            Text(entry.displayDate)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
    }
}

// MARK: - 归档内编辑扩展（添加/删除/重命名）

extension MainWindowView {

    private func addFilesToArchive() {
        guard let info = appState.openArchive else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let files = panel.urls
            let destURL = info.url
            appState.addTask(.create, title: "添加文件到归档") { progress, cancel in
                var op = ArchiveService.EditOperation()
                op.addFiles = files
                let newURL = try ArchiveService.shared.editArchive(info: info, operation: op, to: destURL, progress: progress, cancel: cancel)
                DispatchQueue.main.async {
                    appState.openArchive(at: newURL)
                }
            }
        }
    }

    private func deleteArchiveEntries(_ paths: [String]) {
        guard let info = appState.openArchive, !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "从归档中删除 \(paths.count) 个项目?"
        alert.informativeText = "将从归档重建中排除这些项目。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() != .alertFirstButtonReturn { return }
        appState.addTask(.create, title: "删除归档项目") { progress, cancel in
            var op = ArchiveService.EditOperation()
            op.removePaths = paths
            let newURL = try ArchiveService.shared.editArchive(info: info, operation: op, to: info.url, progress: progress, cancel: cancel)
            DispatchQueue.main.async {
                appState.openArchive(at: newURL)
            }
        }
    }

    private func renameArchiveEntry(_ entry: ArchiveEntry) {
        guard let info = appState.openArchive else { return }
        let alert = NSAlert()
        alert.messageText = "重命名"
        alert.informativeText = "新名称:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = field.stringValue
            guard !newName.isEmpty, newName != entry.name else { return }
            let oldPath = entry.fullPath
            let parent = PathSafety.parentOf(oldPath)
            let newPath = parent.isEmpty ? newName : parent + "/" + newName
            appState.addTask(.create, title: "重命名") { progress, cancel in
                var op = ArchiveService.EditOperation()
                op.renameMap = [oldPath: newPath]
                let newURL = try ArchiveService.shared.editArchive(info: info, operation: op, to: info.url, progress: progress, cancel: cancel)
                DispatchQueue.main.async {
                    appState.openArchive(at: newURL)
                }
            }
        }
    }
}
