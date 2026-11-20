import AppKit
import SwiftUI

enum Area: String, CaseIterable {
    case disk = "ストレージ", project = "案件別", workspaces = "作業コピー", dataIndex = "データ索引", memory = "メモリ"
}

final class HeadroomModel: ObservableObject {
    @Published var page: Area = Area(rawValue: UserDefaults.standard.string(forKey: "dashboardArea") ?? "") ?? .disk {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "dashboardArea") }
    }
    @Published private(set) var vitals = Vitals.read()
    let backup = BackupMonitor(history: { BackupHistory.run(for: $0) })
    @Published private(set) var groups = [DiskGroup]()
    @Published private(set) var apps = [MemoryApp]()
    @Published private(set) var project: URL?
    @Published private(set) var report: WorkspaceReport?
    @Published private(set) var duplicates: DuplicateReport?
    @Published var showingDuplicates = false
    @Published private(set) var simulators: SimulatorReport?
    @Published var showingSimulators = false
    @Published private(set) var snapshotCount: Int?
    @Published private(set) var previousDisk: ScanBaseline?
    @Published private(set) var previousProject: ScanBaseline?
    @Published private(set) var diskDate: Date?
    @Published private(set) var busy = ""
    @Published var result = ""
    private let baseline = Baselines()
    private let queue = DispatchQueue(label: "jp.devpurge.headroom.scan", qos: .utility)

    func tick() {
        vitals = Vitals.read()
        backup.refresh(freeBytes: vitals.diskFree)
    }

    func loadPage() {
        guard busy.isEmpty else { return }
        switch page {
        case .disk where diskDate == nil: scanDisk()
        case .memory: loadApps()
        default: break
        }
    }

    func scanDisk() {
        guard busy.isEmpty else { return }
        busy = "ストレージを計測中"
        queue.async {
            let groups = DiskCare.scan()
            let snapshots = Inspection.localSnapshots()
            DispatchQueue.main.async {
                self.groups = groups
                self.snapshotCount = snapshots
                let complete = groups.filter { !$0.partial }
                self.tick()
                var values = Dictionary(uniqueKeysWithValues: complete.map { ($0.id, $0.bytes) })
                values["ssdFree"] = self.vitals.diskFree
                self.previousDisk = self.baseline.record(scope: "disk", values: values)
                self.diskDate = Date()
                self.busy = ""
                if self.page == .memory { self.loadApps() }
            }
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "このフォルダを調べる"
        if panel.runModal() == .OK, let url = panel.url { scanProject(url) }
    }

    func scanProject(_ url: URL) {
        guard busy.isEmpty else { return }
        project = url
        report = nil
        duplicates = nil
        previousProject = nil
        busy = "案件の作業領域を計測中"
        queue.async {
            let report = WorkspaceScan.scan(url)
            DispatchQueue.main.async {
                self.report = report
                let values = report.rows.filter { !$0.partial }.map { ($0.url.path, $0.bytes) }
                if !report.rows.isEmpty || !report.partial {
                    self.previousProject = self.baseline.record(scope: "project:" + url.path,
                        values: Dictionary(uniqueKeysWithValues: values), complete: !report.partial)
                }
                self.busy = ""
                if self.page == .memory { self.loadApps() }
            }
        }
    }

    func scanDuplicates() {
        guard busy.isEmpty, let root = project else { return }
        busy = "同じサイズの大容量ファイルを照合中"
        queue.async {
            let result = Duplicates.scan(root)
            DispatchQueue.main.async {
                self.duplicates = result
                self.busy = ""
                self.showingDuplicates = true
            }
        }
    }

    func inspectSimulators() {
        guard busy.isEmpty else { return }
        busy = "Xcodeに登録された端末とランタイムを照合中"
        queue.async {
            let report = SimulatorCare.inspect()
            DispatchQueue.main.async {
                self.simulators = report
                self.busy = ""
                self.showingSimulators = true
            }
        }
    }

    func removeSimulator(_ item: SimulatorItem) {
        showingSimulators = false
        diskOperation("選んだランタイムをXcodeで整理中") { SimulatorCare.remove(item) }
    }

    func loadApps() {
        guard busy.isEmpty else { return }
        busy = "アプリごとの使用量を計測中"
        queue.async {
            let apps = Vitals.apps()
            DispatchQueue.main.async {
                self.apps = apps
                self.tick()
                self.busy = ""
                if self.page == .disk && self.diskDate == nil { self.scanDisk() }
            }
        }
    }

    func moveToTrash(_ items: [DiskItem]) {
        guard !items.isEmpty else { return }
        diskOperation("選んだファイルを移動中") {
            DiskCare.trash(items).message
        }
    }

    func selectReports(_ items: [DiskItem]) {
        guard busy.isEmpty, !items.isEmpty else { return }
        busy = "診断レポートを再確認中"
        queue.async {
            let urls = DiskCare.finderSelection(items)
            DispatchQueue.main.async {
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                self.result = "Finderで \(urls.count) 件を選択。変更・使用中などで保留 \(items.count - urls.count) 件。"
                self.busy = ""
            }
        }
    }

    func pruneUV() {
        diskOperation("uvで未参照キャッシュを整理中") { DiskCare.pruneUV() }
    }

    private func diskOperation(_ title: String, _ action: @escaping () -> String) {
        guard busy.isEmpty else { return }
        busy = title
        result = ""
        queue.async {
            let before = Vitals.read().diskFree
            let message = action()
            let after = Vitals.read().diskFree
            let delta = change(after, before) ?? "比較不可"
            DispatchQueue.main.async {
                self.result = "\(message)\nSSD空き　\(quantity(before)) → \(quantity(after)) （\(delta)）"
                self.busy = ""
                self.scanDisk()
            }
        }
    }

    func quit(_ app: MemoryApp) {
        guard busy.isEmpty else { return }
        busy = "\(app.name) の終了を確認中"
        result = ""
        Vitals.requestQuit(app) { outcome in
            self.result = outcome.message
            self.busy = ""
            self.loadApps()
        }
    }
}
