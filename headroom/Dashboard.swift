import AppKit
import SwiftUI

private enum Confirmation: Identifiable {
    case prune, quit(MemoryApp)
    var id: String {
        switch self { case .prune: return "uv"; case .quit(let app): return "quit-\(app.pid)" }
    }
}
private struct Selection: Identifiable {
    let group: DiskGroup
    var id: String { group.id }
}

struct Dashboard: View {
    @ObservedObject var model: HeadroomModel
    @StateObject private var workspaceBrowserModel = WorkspaceBrowserModel()
    @StateObject private var projectIndex = ProjectIndexModel()
    @State private var confirmed: Confirmation?
    @State private var selection: Selection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                metric("内蔵SSDの実空き", icon: "internaldrive", value: quantity(model.vitals.diskFree))
                Divider().frame(height: 38)
                metric("macOSの利用可能見込み", icon: "internaldrive", value: quantity(model.vitals.diskAvailableForImportantUsage))
                    .help("実空きに加え、必要に応じて解放できる領域を含めてmacOSが見積もった容量です。")
                Divider().frame(height: 38)
                metric("メモリ負荷", icon: "memorychip", value: model.vitals.pressure.label,
                       color: pressureColor)
                Spacer()
            }
            Picker("表示", selection: $model.page) {
                ForEach(Area.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if !model.result.isEmpty && model.page != .dataIndex {
                HStack(alignment: .top) {
                    Text(model.result).textSelection(.enabled).font(.callout)
                    Spacer()
                    Button { model.result = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("結果を閉じる")
                }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            switch model.page {
            case .disk: disk
            case .project: project
            case .workspaces: WorkspaceBrowser(model: workspaceBrowserModel) { root in
                projectIndex.open(URL(fileURLWithPath: root))
                model.page = .dataIndex
            }
            case .dataIndex: ProjectIndexView(model: projectIndex)
            case .memory: memory
            }
            if !model.busy.isEmpty && model.page != .workspaces && model.page != .dataIndex {
                HStack { ProgressView().controlSize(.small); Text(model.busy).font(.callout) }
                    .accessibilityElement(children: .combine)
            }
        }
        .padding(22)
        .frame(minWidth: 590, idealWidth: 670, minHeight: 425, idealHeight: 550)
        .onAppear { model.loadPage() }
        .onChange(of: model.page) { _ in model.loadPage() }
        .sheet(isPresented: $model.showingDuplicates) {
            if let report = model.duplicates { DuplicateList(report: report) }
        }
        .sheet(isPresented: $model.showingSimulators) {
            if let report = model.simulators { SimulatorList(report: report, remove: model.removeSimulator) }
        }
        .sheet(item: $selection) { item in
            FileSelection(group: item.group) { files in
                selection = nil
                if item.group.canSelectInFinder { model.selectReports(files) }
                else { model.moveToTrash(files) }
            }
        }
        .alert(item: $confirmed) { item in
            switch item {
            case .prune:
                return Alert(title: Text("uvの未参照キャッシュを整理しますか？"),
                    message: Text("uv自身が不要と判断した項目を完全に削除します。環境の再作成や再ダウンロードが必要になる場合があります。戻る容量は処理後に計測します。"),
                    primaryButton: .destructive(Text("整理する")) { model.pruneUV() },
                    secondaryButton: .cancel(Text("キャンセル")))
            case .quit(let app):
                return Alert(title: Text("\(app.name) を終了しますか？"),
                    message: Text("作業を保存してから通常終了してください。保存の確認が出た場合は、アプリ側で選べます。"),
                    primaryButton: .default(Text("通常終了を依頼")) { model.quit(app) },
                    secondaryButton: .cancel(Text("キャンセル")))
            }
        }
    }

    private var pressureColor: Color {
        switch model.vitals.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func metric(_ label: String, icon: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 27, weight: .semibold)).monospacedDigit().foregroundStyle(color)
        }
    }

    private func sectionTitle(_ title: String, subtitle: String, button: String,
                              action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action).disabled(!model.busy.isEmpty)
        }
    }

    private func comparison(_ previous: ScanBaseline?, key: String, now: Int64, partial: Bool, detectNew: Bool = false) -> String? {
        guard !partial, let previous else { return nil }
        if previous.values[key] == nil && detectNew && previous.complete { return "前回の計測後に出現" }
        guard let delta = change(now, previous.values[key]) else { return nil }
        return "前回比 " + delta
    }

    private func measured(_ bytes: Int64, partial: Bool) -> String {
        if partial && bytes == 0 { return "未計測" }
        return (partial ? "確認分 " : "") + quantity(bytes)
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("システムと開発ツール", subtitle: model.diskDate.map {
                "対象別の占有量　·　" + $0.formatted(date: .omitted, time: .shortened) + " 計測"
            } ?? "対象ごとの占有量を調べます", button: "再計測", action: model.scanDisk)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups.sorted { $0.bytes > $1.bytes }, id: \.id) { group in
                        entry(group.title, detail: group.detail,
                              value: measured(group.bytes, partial: group.partial),
                              delta: comparison(model.previousDisk, key: group.id, now: group.bytes, partial: group.partial)) {
                            if group.id == "ios-runtime-assets" || group.id == "sim-images" {
                                Button("ランタイムを確認…", action: model.inspectSimulators)
                            } else if group.canPruneUV {
                                Button("未参照分を整理…") { confirmed = .prune }
                            } else if (group.canTrash || group.canSelectInFinder) && !group.items.isEmpty {
                                Button("ファイルを選ぶ…") { selection = Selection(group: group) }
                            }
                            if FileManager.default.fileExists(atPath: group.folder.path) {
                                revealButton(group.folder)
                            }
                        }
                    }
                    entry("Time Machine のローカル復元点", detail: "内蔵SSDに残っている復元点。サイズはディスクユーティリティで確認できます。",
                          value: model.snapshotCount.map { "\($0) 件" } ?? "未計測", delta: nil) {
                        Button("ディスクユーティリティ") {
                            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") {
                                NSWorkspace.shared.open(app)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("macOSのストレージ設定を開く") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(url) }
                }.controlSize(.small)
                Spacer()
                if let baseline = model.previousDisk, let delta = change(model.vitals.diskFree, baseline.values["ssdFree"]) {
                    Text("前回計測からのSSD空き " + delta).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var project: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("案件の作業領域", subtitle: model.project?.path ?? "動画・ゲーム・開発の作業フォルダを選びます",
                         button: "フォルダを選ぶ…", action: model.chooseProject)
            if let root = model.project {
                HStack {
                    Button("大容量の重複を調べる…", action: model.scanDuplicates)
                        .disabled(!model.busy.isEmpty)
                    Spacer()
                    Button("同じ案件を再計測") { model.scanProject(root) }.disabled(!model.busy.isEmpty)
                }
            }
            if let report = model.report {
                Text(report.message).font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(report.rows, id: \.url) { row in
                            entry(row.label, detail: row.url.path,
                                  value: measured(row.bytes, partial: row.partial),
                                  delta: comparison(model.previousProject, key: row.url.path, now: row.bytes, partial: row.partial, detectNew: true)) {
                                revealButton(row.url)
                            }
                        }
                        if !report.partial, model.previousProject?.complete == true {
                            let current = Set(report.rows.map { $0.url.path })
                            let gone = (model.previousProject?.values ?? [:]).keys.filter { !current.contains($0) }.sorted()
                            ForEach(gone, id: \.self) { path in
                                entry(URL(fileURLWithPath: path).lastPathComponent, detail: path,
                                      value: "今回の対象外", delta: "前回 " + quantity(model.previousProject?.values[path])) { EmptyView() }
                            }
                        }
                    }
                }
            } else if model.project == nil {
                VStack(spacing: 9) {
                    Image(systemName: "folder").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("作業フォルダごとに容量の増減を確認").font(.headline)
                    Text("Remotionの一時領域、Godotの生成物、開発用の依存ファイルなどが対象です。")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("起動中のアプリ", subtitle:
                "搭載メモリ " + String(format: "%.0f GiB", Double(model.vitals.physicalMemory) / 1_073_741_824) + "　·　スワップ " + quantity(model.vitals.swapUsed),
                button: "再計測", action: model.loadApps)
            Text("計測できた子プロセスを含む使用量です。作業を終えたアプリを選ぶと、通常終了の前後で変化を計測します。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.apps, id: \.pid) { app in
                        entry(app.name, detail: nil, value: quantity(app.bytes), delta: nil) {
                            if app.canQuit { Button("通常終了…") { confirmed = .quit(app) } }
                        }.help("\(app.bundleURL.path)　·　PID \(app.pid)")
                    }
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private func entry<Actions: View>(_ name: String, detail: String?, value: String, delta: String?,
                                      @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.body.weight(.medium))
                Spacer()
                Text(value).monospacedDigit().fontWeight(.semibold)
            }
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if let delta { Text(delta).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                actions().controlSize(.small).disabled(!model.busy.isEmpty)
            }
            Divider()
        }.padding(.top, 8)
    }

    private func revealButton(_ url: URL) -> some View {
        Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

private struct FileSelection: View {
    let group: DiskGroup
    let submit: ([DiskItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<URL>()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.title).font(.title2.weight(.semibold))
            Text(group.canSelectInFinder
                 ? "7日以上前のシステム診断ファイルをFinderで選択します。処分する場合はFinderでゴミ箱へ移動してください。"
                 : "選んだファイルをゴミ箱へ移動します。SSDの空きが戻るのはゴミ箱から削除した後です。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(group.items, id: \.url) { item in
                        Toggle(isOn: Binding(get: { selected.contains(item.url) }, set: { on in
                            if on { selected.insert(item.url) } else { selected.remove(item.url) }
                        })) {
                            HStack {
                                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle).help(item.url.path)
                                Spacer()
                                Text(quantity(item.bytes)).monospacedDigit()
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
            }
            HStack {
                Text("\(selected.count) 件選択中")
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(group.canSelectInFinder ? "Finderで選択" : "ゴミ箱へ移動") { submit(group.items.filter { selected.contains($0.url) }) }
                    .disabled(selected.isEmpty)
            }
        }.padding(20).frame(width: 560, height: 380)
    }
}

private struct DuplicateList: View {
    let report: DuplicateReport
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内容が一致した大容量ファイル").font(.title2.weight(.semibold))
            Text(report.message).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(report.groups.enumerated()), id: \.offset) { _, group in
                        Text("\(group.urls.count) 件　·　各 " + quantity(group.fileBytes)).font(.headline)
                        ForEach(group.urls, id: \.self) { url in
                            HStack {
                                Text(url.path).font(.caption).textSelection(.enabled)
                                Spacer()
                                Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                        }
                        Divider()
                    }
                }
            }
            HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(minWidth: 555, minHeight: 370)
    }
}

private struct SimulatorList: View {
    let report: SimulatorReport
    let remove: (SimulatorItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: SimulatorItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("シミュレータのランタイム").font(.title2.weight(.semibold))
            Text(report.message).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.items, id: \.id) { item in
                        HStack {
                            Text(item.name).font(.headline)
                            Spacer()
                            Text(quantity(item.bytes)).monospacedDigit()
                        }
                        HStack {
                            Text(item.detail).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if item.canRemove { Button("取り除く…") { selected = item } }
                        }
                        Divider()
                    }
                }
            }
            HStack {
                if let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
                    Button("Xcodeを開く") { NSWorkspace.shared.open(xcode) }
                }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(minWidth: 550, minHeight: 340)
        .alert("ランタイムを取り除きますか？", isPresented: Binding(get: { selected != nil },
            set: { if !$0 { selected = nil } }), presenting: selected) { item in
            Button("取り除く", role: .destructive) { remove(item) }
            Button("キャンセル", role: .cancel) {}
        } message: { item in
            Text("\(item.name)（\(quantity(item.bytes))）をこのMacから削除します。ほかのユーザーやCIも使えなくなり、再利用時は再ダウンロードが必要です。")
        }
    }
}
