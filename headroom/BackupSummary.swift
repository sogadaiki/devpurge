import SwiftUI

struct BackupSummary: View {
    @ObservedObject var monitor: BackupMonitor

    private var isRunning: Bool {
        switch monitor.phase {
        case .preparing, .copying, .finishing, .stopping, .running: return true
        case .checking, .idle, .unknown: return false
        }
    }

    private func stamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .numeric, time: .standard, locale: Locale(identifier: "ja_JP")))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("Time Machine", systemImage: "clock.arrow.circlepath").fontWeight(.semibold)
                Text(monitor.phase.label)
                if isRunning, let run = monitor.run, !run.isClosed, let name = run.destinationName {
                    Text(name).foregroundStyle(.secondary)
                }
            }
            if let saved = monitor.latest {
                Text("外付けへの保存を確認　\(stamp(saved.completedAt))　\(saved.destinationName)")
            } else {
                Text("外付けへの最終保存　未確認")
            }
            if let run = monitor.run {
                let label = run.isClosed ? (run.confirmedAt == nil ? "保存未確認" : "保存確認済み")
                                         : (isRunning ? "観測中" : "終了未確認")
                let range = "実空き　観測開始 \(quantity(run.firstFree)) → 最小 \(quantity(run.minimumFree))"
                Text(run.isClosed ? range + " → 終了 \(quantity(run.finalFree))" : range)
                    .monospacedDigit()
                Text("\(stamp(run.firstAt)) からの記録（\(label)）")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("バックアップを観測すると、ここに実空きの最小値と終了時の値が表示されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7).padding(.horizontal, 11)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
