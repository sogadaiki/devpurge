import AppKit
import SwiftUI

private enum IndexRole: String, CaseIterable {
    case unknown, source, deliverable, recovery, temporary, copy

    var label: String {
        switch self {
        case .unknown: return "用途未確定"
        case .source: return "原本・編集元"
        case .deliverable: return "完成品・納品物"
        case .recovery: return "復元用データ"
        case .temporary: return "一時生成物"
        case .copy: return "作業用のコピー"
        }
    }
}

private func decisionLabel(_ value: String) -> String {
    switch value {
    case "keep": return "保持"
    case "candidate": return "整理候補"
    default: return "要確認"
    }
}

private struct IndexSelection: Identifiable {
    let id = UUID()
    let root: String
    let entry: DataIndexEntry
}

private struct CheckedEntry {
    let result: DataIndexVerification
    let date: Date
}

final class ProjectIndexModel: ObservableObject {
    @Published fileprivate var projects = [String]()
    @Published fileprivate var root: String?
    @Published fileprivate var report: DataIndexReport?
    @Published fileprivate var busy = ""
    @Published fileprivate var error = ""
    @Published fileprivate var message = ""
    @Published fileprivate var editor: IndexSelection?
    @Published fileprivate var checks = [String: CheckedEntry]()
    private let queue = DispatchQueue(label: "jp.devpurge.headroom.index", qos: .userInitiated)
    private var request = UUID()
    private var didLoad = false

    fileprivate func appear() {
        if !didLoad && root == nil { overview() }
    }

    fileprivate func overview() {
        didLoad = true
        root = nil
        report = nil
        editor = nil
        checks = [:]
        run("登録案件を確認中…", work: ProjectDataIndex.registeredProjects) { self.projects = $0 }
    }

    func open(_ url: URL) {
        didLoad = true
        let path = url.path
        root = path
        report = nil
        editor = nil
        checks = [:]
        run("案件の索引を読み込み中…", work: { try ProjectDataIndex.list(path) }) { self.report = $0 }
    }

    private func run<T>(_ label: String, work: @escaping () throws -> T, done: @escaping (T) -> Void) {
        let id = UUID()
        request = id
        busy = label
        error = ""
        message = ""
        queue.async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard self.request == id else { return }
                self.busy = ""
                switch result {
                case .success(let value): done(value)
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
    }

    fileprivate func edit(_ entry: DataIndexEntry) {
        guard let root, report != nil, busy.isEmpty else { return }
        error = ""
        editor = IndexSelection(root: root, entry: entry)
    }

    fileprivate func save(_ entry: DataIndexEntry, in directory: String) {
        guard directory == root, busy.isEmpty else { return }
        run("索引に保存中…", work: { try ProjectDataIndex.record(directory, entry: entry) }) { report in
            self.report = report
            self.checks = [:]
            self.editor = nil
            self.message = "「\(entry.path)」を索引に記録しました。"
        }
    }

    fileprivate func verify(_ entry: DataIndexEntry) {
        guard let root, entry.recorded, entry.role == "copy", busy.isEmpty else { return }
        checks.removeValue(forKey: entry.path)
        run("原本とコピーの内容を照合中…", work: { try ProjectDataIndex.verify(root, path: entry.path, expected: entry.version) }) { result in
            self.checks[entry.path] = CheckedEntry(result: result, date: Date())
            self.message = "\(entry.path)　\(decisionLabel(result.decision))　\(result.detail)"
        }
    }
}

private enum IndexFilter: String, CaseIterable {
    case all = "すべて", unrecorded = "未登録", recorded = "記録済み", review = "要確認", keep = "保持", candidate = "整理候補"
}

private func selectIndexURL(_ title: String, root: String? = nil, directoriesOnly: Bool = false) -> URL? {
    let panel = NSOpenPanel()
    panel.message = title
    panel.prompt = "選択"
    panel.canChooseFiles = !directoriesOnly
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    if let root { panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true) }
    return panel.runModal() == .OK ? panel.url : nil
}

private func indexRelativePath(_ url: URL, root: String) -> String? {
    let base = URL(fileURLWithPath: root).pathComponents
    let parts = url.pathComponents
    guard parts.count > base.count, parts.starts(with: base) else { return nil }
    return parts.dropFirst(base.count).joined(separator: "/")
}

struct ProjectIndexView: View {
    @ObservedObject var model: ProjectIndexModel
    @State private var query = ""
    @State private var filter = IndexFilter.all

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if let root = model.root {
                    Button { model.overview() } label: { Label("案件一覧", systemImage: "chevron.left") }
                    Text(URL(fileURLWithPath: root).lastPathComponent).font(.headline).lineLimit(1).help(root)
                    Spacer()
                    Button("項目を追加…") { addItem(in: root) }.disabled(model.report == nil)
                    Button("更新") { model.open(URL(fileURLWithPath: root)) }
                } else {
                    Text("案件のデータ索引").font(.headline)
                    Spacer()
                    Button("案件を選ぶ…") {
                        if let url = selectIndexURL("索引を開く案件のフォルダを選択", directoriesOnly: true) { model.open(url) }
                    }
                    Button("更新", action: model.overview)
                }
            }.disabled(!model.busy.isEmpty)
            if !model.error.isEmpty && model.editor == nil {
                Text(model.error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if !model.message.isEmpty {
                Text(model.message).font(.callout).textSelection(.enabled)
            }
            if let report = model.report {
                inventory(report)
            } else if model.root == nil && model.busy.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("案件を開くと、作業で使ったファイルの用途・担当・見直す条件を確認できます。")
                            .font(.callout).foregroundStyle(.secondary)
                        if model.projects.isEmpty && model.error.isEmpty {
                            Text("「案件を選ぶ…」からプロジェクトのフォルダを開いてください。").font(.callout)
                        }
                        ForEach(model.projects, id: \.self) { path in
                            Button {
                                model.open(URL(fileURLWithPath: path))
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline)
                                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.busy.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(model.busy).font(.callout) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.appear() }
        .onChange(of: model.root) { _ in query = ""; filter = .all }
        .sheet(item: $model.editor) { selected in
            IndexEntryEditor(model: model, selected: selected)
        }
    }

    private func addItem(in root: String) {
        guard let url = selectIndexURL("索引に記録するファイルまたはフォルダを選択", root: root) else { return }
        guard let path = indexRelativePath(url, root: root) else {
            model.error = "この案件の中にあるファイルまたはフォルダを選んでください。"
            return
        }
        model.edit(model.report?.entries.first { $0.path == path } ?? DataIndexEntry(path: path))
    }

    private func inventory(_ report: DataIndexReport) -> some View {
        let recorded = report.entries.filter(\.recorded).count
        let matchesFilter = report.entries.filter { entry in
            let decision = model.checks[entry.path]?.result.decision ?? entry.decision
            let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = phrase.isEmpty || [entry.path, entry.owner, entry.reason, entry.until ?? "", entry.keeper ?? "",
                                              IndexRole(rawValue: entry.role)?.label ?? ""].contains { $0.localizedCaseInsensitiveContains(phrase) }
            guard matches else { return false }
            switch filter {
            case .all: return true
            case .recorded: return entry.recorded
            case .unrecorded: return !entry.recorded
            case .keep: return decision == "keep"
            case .review: return decision == "review"
            case .candidate: return decision == "candidate"
            }
        }
        let rows = matchesFilter.filter(\.recorded) + matchesFilter.filter { !$0.recorded }
        return VStack(alignment: .leading, spacing: 8) {
            Text("記録済み \(recorded) 件　·　未登録 \(report.entries.count - recorded) 件").font(.callout.weight(.medium))
            if !report.warnings.isEmpty {
                DisclosureGroup("確認範囲と注意事項（\(report.warnings.count)）") {
                    ScrollView {
                        Text(report.warnings.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 58)
                }.font(.caption)
            }
            HStack {
                TextField("パス・担当・用途で検索", text: $query).textFieldStyle(.roundedBorder)
                Picker("表示", selection: $filter) {
                    ForEach(IndexFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if rows.isEmpty { Text(report.entries.isEmpty ? "「項目を追加…」から用途を記録できます。" : "条件に一致する項目がありません。").font(.callout).foregroundStyle(.secondary) }
                    ForEach(rows, id: \.path) { entry in
                        entryRow(entry)
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func entryRow(_ entry: DataIndexEntry) -> some View {
        let checked = model.checks[entry.path]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.path).font(.body.weight(.medium)).textSelection(.enabled)
                Spacer()
                Text(decisionLabel(checked?.result.decision ?? entry.decision)).font(.callout.weight(.medium))
            }
            if entry.recorded {
                Text([IndexRole(rawValue: entry.role)?.label ?? entry.role, entry.owner, entry.reason].filter { !$0.isEmpty }.joined(separator: "　·　"))
                    .font(.callout).textSelection(.enabled)
                if let until = entry.until, !until.isEmpty { Text("見直す条件　" + until).font(.caption).textSelection(.enabled) }
            }
            Text(checked?.result.detail ?? entry.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Text(checked.map { "照合 " + $0.date.formatted(date: .omitted, time: .standard) } ?? (entry.recorded ? "記録済み" : "未登録"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if entry.recorded && entry.role == "copy" && !(entry.keeper ?? "").isEmpty {
                    Button("原本と照合") { model.verify(entry) }
                }
                Button(entry.recorded ? "記録を編集…" : "用途を記録…") { model.edit(entry) }
            }.controlSize(.small).disabled(!model.busy.isEmpty)
        }
    }
}

private struct IndexEntryEditor: View {
    @ObservedObject var model: ProjectIndexModel
    let selected: IndexSelection
    @State private var entry: DataIndexEntry
    @State private var keeper: String
    @State private var rebuild: String
    @State private var until: String
    @State private var pickerError = ""

    init(model: ProjectIndexModel, selected: IndexSelection) {
        self.model = model
        self.selected = selected
        _entry = State(initialValue: selected.entry)
        _keeper = State(initialValue: selected.entry.keeper ?? "")
        _rebuild = State(initialValue: selected.entry.rebuild ?? "")
        _until = State(initialValue: selected.entry.until ?? "")
    }

    private func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selected.entry.recorded ? "索引の記録を編集" : "用途を索引に記録").font(.title2.weight(.semibold))
            Text(entry.path).font(.callout.weight(.medium)).textSelection(.enabled)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("用途")
                        Picker("用途", selection: $entry.role) {
                            ForEach(IndexRole.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow { Text("担当（必須）"); TextField("担当者・チーム・作業名", text: $entry.owner) }
                    GridRow { Text("理由（必須）"); TextField("何に使うか、なぜ残すか", text: $entry.reason) }
                    if entry.role == "copy" {
                        GridRow {
                            Text("残す原本")
                            HStack {
                                TextField("案件内の相対パス", text: $keeper)
                                Button("選択…", action: chooseKeeper)
                            }
                        }
                    }
                    if entry.role == "temporary" {
                        GridRow { Text("再生成手順"); TextField("必要な入力と作り直す手順", text: $rebuild) }
                    }
                    GridRow { Text("見直す条件"); TextField("例：テスト配布の承認後", text: $until) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            if !pickerError.isEmpty || !model.error.isEmpty {
                Text(pickerError.isEmpty ? model.error : pickerError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Text("保存先　案件直下の .devpurge-index.json").font(.caption).foregroundStyle(.secondary)
                    .help("索引の判定は作業の引き継ぎに使います。自動清掃の除外はdevpurgeの設定で指定します。")
                Spacer()
                Button("キャンセル") { model.editor = nil }.keyboardShortcut(.cancelAction)
                Button("索引に保存") {
                    var value = entry
                    value.keeper = entry.role == "copy" ? optional(keeper) : nil
                    value.rebuild = entry.role == "temporary" ? optional(rebuild) : nil
                    value.until = optional(until)
                    pickerError = ""
                    model.save(value, in: selected.root)
                }.keyboardShortcut(.defaultAction)
                    .disabled(optional(entry.owner) == nil || optional(entry.reason) == nil)
            }
        }
        .padding(20).frame(width: 535, height: 365)
        .disabled(!model.busy.isEmpty)
        .interactiveDismissDisabled(!model.busy.isEmpty)
    }

    private func chooseKeeper() {
        guard let url = selectIndexURL("残す原本を選択", root: selected.root) else { return }
        guard let path = indexRelativePath(url, root: selected.root), path != entry.path else {
            pickerError = "同じ案件にある別のファイルまたはフォルダを選んでください。"
            return
        }
        pickerError = ""
        keeper = path
    }
}
