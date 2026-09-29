import SwiftUI
import AppKit
import ZIPCore
import MacRARCore

// MARK: - 解压面板

struct ExtractSheetView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var destPath = ""
    @State private var password = ""
    @State private var updateMode: ExtractUpdateMode = .extractAndReplace
    @State private var overwriteMode: OverwriteMode = .ask
    @State private var revealAfter = false
    @State private var keepStructure = true
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("解压到")
                .font(.headline)
            if let info = appState.openArchive {
                Text("归档: \(info.url.lastPathComponent)")
                    .font(.callout)
                    .foregroundColor(.secondary)
                if info.entries.contains(where: { $0.isEncrypted }) {
                    Label("该归档已加密", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            HStack {
                TextField("目标文件夹", text: $destPath)
                    .textFieldStyle(.roundedBorder)
                Button("浏览...") {
                    chooseDestination()
                }
            }
            HStack {
                SecureField("密码（若加密）", text: $password)
                    .textFieldStyle(.roundedBorder)
                if !password.isEmpty {
                    Button("清除") { password = "" }
                        .font(.caption)
                }
            }
            HStack {
                Picker("更新模式", selection: $updateMode) {
                    ForEach(ExtractUpdateMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                Picker("覆盖模式", selection: $overwriteMode) {
                    ForEach(OverwriteMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Toggle("保留目录结构", isOn: $keepStructure)
            Toggle("解压后打开文件夹", isOn: $revealAfter)
            HStack {
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("解压") { startExtract() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destPath.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if destPath.isEmpty {
                if let info = appState.openArchive {
                    destPath = info.url.deletingLastPathComponent().path
                } else {
                    destPath = appState.currentDirectory.path
                }
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            destPath = url.path
        }
    }

    private func startExtract() {
        guard let info = appState.openArchive else { return }
        var finalPassword = password
        // 归档加密但未输入密码 → 弹窗询问
        if finalPassword.isEmpty, info.entries.contains(where: { $0.isEncrypted }) {
            let alert = NSAlert()
            alert.messageText = "归档已加密"
            alert.informativeText = "请输入解压密码："
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
            finalPassword = field.stringValue
        }
        isWorking = true
        var options = ExtractOptions()
        options.destination = URL(fileURLWithPath: destPath)
        options.password = finalPassword.isEmpty ? nil : finalPassword
        options.updateMode = updateMode
        options.overwriteMode = overwriteMode
        options.revealAfterExtract = revealAfter
        options.keepDirectoryStructure = keepStructure
        appState.addTask(.extract, title: "解压 \(info.url.lastPathComponent)", totalBytes: info.totalSize) { progress, cancel in
            try ArchiveService.shared.extract(info: info, options: options, progress: progress, cancel: cancel)
        }
        dismiss()
    }
}

// MARK: - 创建归档面板

struct CreateArchiveSheetView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var format: ArchiveFormat = .zip
    @State private var level: CompressionLevel = .normal
    @State private var outputName = ""
    @State private var password = ""
    @State private var encryptNames = false
    @State private var solid = false
    @State private var sfx = false
    @State private var volumeSize = ""
    @State private var volumeUnits: VolumeUnit = .mb
    @State private var comment = ""
    @State private var deleteAfter = false
    @State private var useGBK = false
    @State private var isWorking = false

    enum VolumeUnit: String, CaseIterable, Identifiable {
        case b, kb, mb, gb
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .b: return "字节"
            case .kb: return "KB"
            case .mb: return "MB"
            case .gb: return "GB"
            }
        }
        var multiplier: UInt64 {
            switch self {
            case .b: return 1
            case .kb: return 1024
            case .mb: return 1024 * 1024
            case .gb: return 1024 * 1024 * 1024
            }
        }
    }

    private var sourceCount: Int {
        appState.isBrowsingArchive ? 0 : appState.selectionInDirectory.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("创建归档")
                .font(.headline)
            Text(sourceSummary)
                .font(.callout)
                .foregroundColor(.secondary)
            HStack {
                Text("格式:")
                Picker("", selection: $format) {
                    ForEach(ArchiveFormat.creatableFormats) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Text("压缩方式:")
                Picker("", selection: $level) {
                    ForEach(CompressionLevel.allCases) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            if format.isRAR && !RarCLIEngine.isAvailable() {
                rarToolWarning
            }
            HStack {
                Text("输出文件:")
                TextField("", text: $outputName)
                    .textFieldStyle(.roundedBorder)
                Button("浏览...") { chooseOutput() }
            }
            HStack {
                Toggle("设置密码", isOn: Binding(get: { !password.isEmpty }, set: { if $0 { password = "password" } else { password = "" } }))
                if !password.isEmpty {
                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
            }
            if format.isRAR || format == .sevenZip {
                Toggle("加密文件名", isOn: $encryptNames)
            }
            if format.isRAR || format == .sevenZip {
                Toggle("固实归档", isOn: $solid)
            }
            if format == .rar || format == .sevenZip {
                Toggle("创建自解压 (SFX)", isOn: $sfx)
            }
            HStack {
                Text("分卷大小:")
                TextField("", text: $volumeSize)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Picker("", selection: $volumeUnits) {
                    ForEach(VolumeUnit.allCases) { u in
                        Text(u.displayName).tag(u)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            HStack {
                Text("预设:")
                Button("软盘 1.44MB") { volumeSize = "1440"; volumeUnits = .kb }
                Button("CD 700MB") { volumeSize = "700"; volumeUnits = .mb }
                Button("DVD 4.7GB") { volumeSize = "4480"; volumeUnits = .mb }
                Button("FAT32 4GB") { volumeSize = "4"; volumeUnits = .gb }
                Button("不分卷") { volumeSize = "" }
            }
            .font(.caption)
            Toggle("使用 GBK 文件名编码（兼容老系统）", isOn: $useGBK)
            Toggle("压缩后删除原文件", isOn: $deleteAfter)
            HStack {
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("确定") { startCreate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(outputName.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if outputName.isEmpty {
                let base = appState.currentDirectory.lastPathComponent.isEmpty ? "archive" : appState.currentDirectory.lastPathComponent
                outputName = base + ".zip"
            }
        }
    }

    private var rarToolWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("未检测到 rar 命令行工具", systemImage: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .font(.callout)
            Text("RAR 压缩需要 RARLAB 的 rar 工具。请下载 macOS ARM 版并解压后，将 rar 命令加入 PATH（或设置 RAR_PATH 环境变量）。")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button("检查 rar 工具") {
                    if RarCLIEngine.isAvailable() {
                        appState.errorMessage = "已检测到 rar 工具"
                    } else {
                        appState.errorMessage = "仍未检测到 rar 工具"
                    }
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }

    private var sourceSummary: String {
        if appState.isBrowsingArchive {
            return "将归档内容重新打包"
        }
        if sourceCount == 0 {
            return "未选择文件（将打包当前文件夹内所有内容）"
        }
        return "将压缩 \(sourceCount) 个选中的项目"
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = outputName
        if panel.runModal() == .OK, let url = panel.url {
            outputName = url.lastPathComponent
        }
    }

    private func startCreate() {
        isWorking = true
        var options = CreateOptions()
        options.format = format
        options.compressionLevel = level
        options.password = password.isEmpty ? nil : password
        options.encryptFileNames = encryptNames
        options.solid = solid
        options.createSFX = sfx
        options.deleteFilesAfterCompression = deleteAfter
        options.useGBKNames = useGBK
        options.comment = comment.isEmpty ? nil : comment
        if let vol = UInt64(volumeSize), vol > 0 {
            options.volumeSize = vol * volumeUnits.multiplier
        }
        let destURL = appState.currentDirectory.appendingPathComponent(outputName)
        var items: [URL] = []
        if appState.isBrowsingArchive {
            // 重建归档：将当前归档解压再打包（简化：整档转格式）
            if let info = appState.openArchive {
                appState.addTask(.create, title: "创建归档") { progress, cancel in
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("recreate_\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                    try ArchiveService.shared.extract(info: info, options: ExtractOptions(destination: tmp), progress: progress, cancel: cancel)
                    let contents = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
                    _ = try ArchiveService.shared.createArchive(items: contents, to: destURL, options: options, progress: progress)
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
        } else {
            items = Array(appState.selectionInDirectory)
            appState.addTask(.create, title: "创建归档") { progress, cancel in
                _ = try ArchiveService.shared.createArchive(items: items, to: destURL, options: options, progress: progress)
            }
        }
        dismiss()
    }
}

// MARK: - 测试面板

struct TestSheetView: View {
    let info: ArchiveInfo
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0
    @State private var resultText = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("测试归档")
                .font(.headline)
            Text(info.url.lastPathComponent)
                .font(.callout)
                .foregroundColor(.secondary)
            ProgressView(value: progress)
                .frame(width: 300)
            Text(resultText.isEmpty ? "准备测试..." : resultText)
                .font(.callout)
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            appState.addTask(.test, title: "测试") { prog, _ in
                try ArchiveService.shared.testArchive(info: info) { p in
                    prog(p)
                }
            }
        }
    }
}

// MARK: - 修复面板

struct RepairSheetView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var destPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修复归档")
                .font(.headline)
            if let info = appState.openArchive {
                Text("归档: \(info.url.lastPathComponent)")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Text("修复会尝试重建损坏的归档。RAR 格式利用恢复记录，ZIP 格式重建可读条目。")
                .font(.callout)
                .foregroundColor(.secondary)
            HStack {
                TextField("修复结果目录", text: $destPath)
                    .textFieldStyle(.roundedBorder)
                Button("浏览...") { choose() }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始修复") { startRepair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destPath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if destPath.isEmpty {
                if let info = appState.openArchive {
                    destPath = info.url.deletingLastPathComponent().path
                } else {
                    destPath = appState.currentDirectory.path
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            destPath = url.path
        }
    }

    private func startRepair() {
        guard let info = appState.openArchive else { return }
        appState.addTask(.repair, title: "修复 \(info.url.lastPathComponent)") { progress, cancel in
            _ = try ArchiveService.shared.repairArchive(url: info.url, to: URL(fileURLWithPath: destPath), progress: progress)
        }
        dismiss()
    }
}

// MARK: - 信息面板

struct InfoSheetView: View {
    let info: ArchiveInfo
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("归档信息")
                .font(.headline)
            Divider()
            infoRow("文件名", info.url.lastPathComponent)
            infoRow("格式", info.format.displayName)
            infoRow("路径", info.url.path)
            infoRow("文件数", "\(info.fileCount) 个文件, \(info.dirCount) 个文件夹")
            infoRow("原始大小", info.totalSize.byteCount)
            infoRow("压缩后大小", info.totalPackedSize.byteCount)
            infoRow("分卷", "\(info.volumeCount)")
            if !info.flags.isEmpty {
                infoRow("属性", info.flags.map { flagName($0) }.joined(separator: ", "))
            }
            if let comment = info.comment, !comment.isEmpty {
                infoRow("注释", comment)
            }
            Spacer()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 380)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key + ":")
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private func flagName(_ flag: ArchiveFlag) -> String {
        switch flag {
        case .volume: return "多卷"
        case .comment: return "含注释"
        case .locked: return "已锁定"
        case .solid: return "固实"
        case .encryptedHeaders: return "加密文件名"
        case .signed: return "签名"
        case .recovery: return "恢复记录"
        case .newNumbering: return "新版分卷"
        }
    }
}

// MARK: - 设置面板

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultExtractPath") private var defaultExtractPath = ""
    @AppStorage("useDefaultExtractPath") private var useDefaultExtractPath = false
    @AppStorage("showHiddenFiles") private var showHiddenFiles = false
    @AppStorage("defaultCompression") private var defaultCompressionIndex = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.headline)
            Toggle("始终使用默认解压目录", isOn: $useDefaultExtractPath)
            HStack {
                TextField("默认解压目录", text: $defaultExtractPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!useDefaultExtractPath)
                Button("浏览...") { chooseDefaultPath() }
            }
            Toggle("在文件列表中显示隐藏文件", isOn: $showHiddenFiles)
            HStack {
                Text("默认压缩级别:")
                Picker("", selection: $defaultCompressionIndex) {
                    ForEach(Array(CompressionLevel.allCases.enumerated()), id: \.offset) { i, l in
                        Text(l.displayName).tag(i)
                    }
                }
                .labelsHidden()
            }
            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseDefaultPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            defaultExtractPath = url.path
        }
    }
}

// MARK: - 向导面板

struct WizardSheetView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("MacRAR 向导")
                .font(.title2)
                .padding(.top, 10)
            Text("选择要执行的操作")
                .foregroundColor(.secondary)
            VStack(spacing: 10) {
                WizardOptionButton(icon: "arrow.down.circle", title: "解压归档", subtitle: "从压缩包提取文件") {
                    appState.showExtractSheet = true
                    dismiss()
                }
                WizardOptionButton(icon: "plus.square", title: "创建归档", subtitle: "将文件压缩为归档") {
                    appState.showCreateSheet = true
                    dismiss()
                }
                WizardOptionButton(icon: "checkmark.shield", title: "测试归档", subtitle: "检查归档完整性") {
                    if appState.isBrowsingArchive {
                        appState.showTestSheet = true
                        dismiss()
                    }
                }
                WizardOptionButton(icon: "wrench.and.screwdriver", title: "修复归档", subtitle: "重建损坏的归档") {
                    if appState.isBrowsingArchive {
                        appState.showRepairSheet = true
                        dismiss()
                    }
                }
            }
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 360)
    }
}

struct WizardOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .frame(width: 32)
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 转换格式面板

struct ConvertSheetView: View {
    let info: ArchiveInfo
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var targetFormat: ArchiveFormat = .zip
    @State private var outputDir = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("转换归档格式")
                .font(.headline)
            Text("将 \(info.url.lastPathComponent) 从 \(info.format.displayName) 转换为其他格式")
                .font(.callout)
                .foregroundColor(.secondary)
            HStack {
                Text("目标格式:")
                Picker("", selection: $targetFormat) {
                    ForEach(ArchiveFormat.creatableFormats.filter { $0 != info.format }) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .labelsHidden()
            }
            HStack {
                Text("输出目录:")
                TextField("", text: $outputDir)
                    .textFieldStyle(.roundedBorder)
                Button("浏览...") { choose() }
            }
            Text("转换会先解压再重新压缩。RAR 目标格式需要 rar 工具。")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始转换") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(outputDir.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if outputDir.isEmpty {
                outputDir = appState.currentDirectory.path
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = url.path
        }
    }

    private func start() {
        var opts = CreateOptions()
        opts.format = targetFormat
        let destName = info.url.deletingPathExtension().lastPathComponent + "." + targetFormat.rawValue
        let dest = URL(fileURLWithPath: outputDir).appendingPathComponent(destName)
        appState.addTask(.convert, title: "转换格式") { progress, cancel in
            try ArchiveService.shared.convert(url: info.url, to: targetFormat, destURL: dest, options: opts, progress: progress)
            DispatchQueue.main.async {
                appState.navigate(to: URL(fileURLWithPath: outputDir))
            }
        }
        dismiss()
    }
}
