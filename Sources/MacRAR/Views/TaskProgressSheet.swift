import SwiftUI
import AppKit
import MacRARCore

// MARK: - 任务进度弹窗（含速度、进度、取消）

struct TaskProgressSheet: View {
    @ObservedObject var task: ArchiveTask
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: taskIcon(task.kind))
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            ProgressView(value: min(max(task.progress, 0), 1))
                .frame(width: 320)
            HStack {
                Text(String(Int(min(max(task.progress, 0), 1) * 100)) + "%")
                Spacer()
                if task.totalBytes > 0 {
                    Text(bytesText(task.processedBytes) + " / " + bytesText(task.totalBytes))
                } else if task.progress > 0 {
                    Text(bytesText(task.processedBytes))
                }
            }
            .font(.callout)
            .foregroundColor(.secondary)
            if task.speedBytesPerSecond > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                    Text("速度: " + speedText(task.speedBytesPerSecond))
                }
                .font(.callout)
                .foregroundColor(.secondary)
            }
            if task.status == .canceled {
                Text("正在取消...")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func taskIcon(_ kind: ArchiveTaskKind) -> String {
        switch kind {
        case .extract: return "arrow.down.circle"
        case .create: return "plus.square"
        case .test: return "checkmark.shield"
        case .repair: return "wrench.and.screwdriver"
        case .convert: return "arrow.triangle.2.circlepath"
        }
    }

    private func bytesText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func speedText(_ bytesPerSec: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = bytesPerSec
        var idx = 0
        while v >= 1024 && idx < units.count - 1 {
            v /= 1024
            idx += 1
        }
        return String(format: "%.1f %@", v, units[idx])
    }
}

// MARK: - 任务完成提示弹窗

struct TaskCompletionAlert: View {
    let completion: TaskCompletion
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: completion.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 36))
                .foregroundColor(completion.success ? .green : .red)
            Text(completion.success ? "操作成功" : "操作失败")
                .font(.headline)
            Text(completion.message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("好") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360)
    }
}
