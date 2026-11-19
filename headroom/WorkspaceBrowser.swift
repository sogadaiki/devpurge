import AppKit
import SwiftUI

private enum WorkspaceTarget {
    case worktree(repo: String, path: String, branch: String, head: String)
    case branch(repo: String, name: String, head: String)

    var item: String {
        switch self {
        case let .worktree(_, path, _, _): return path
        case let .branch(_, name, _): return name
        }
    }

    var effect: String {
        switch self {
        case let .worktree(_, _, branch, head):
            return "作業フォルダを閉じます。ブランチ \(branch) と復元記録が残ります。\n確認したコミット  \(head)"
        case let .branch(repo, _, head):
            return "\(repo) のローカルブランチを削除します。復元用のコミットが残ります。\n確認したコミット  \(head)"
        }
    }

    var action: String {
        switch self {
        case .worktree: return "作業コピーを閉じる"
        case .branch: return "ブランチを整理"
        }
    }
}

private struct WorkspaceResult: Identifiable {
    let id = UUID()
    let title: String
    let item: String
    let message: String
    var restore: String?
    var record: String?
    var next: WorkspaceTarget?
}

final class WorkspaceBrowserModel: ObservableObject {
    @Published fileprivate var report: InventoryReport?
    @Published fileprivate var busy = ""
    @Published fileprivate var error = ""
    @Published fileprivate var selectedRepo: String?
    @Published fileprivate var outcome: WorkspaceResult?
    @Published fileprivate var manualProject: String?
    @Published fileprivate var canCancelRead = false
    private var cancelled = false
    private static let scopeKey = "workspaceBrowser.selectedProject"
    private var attempted = false
    private let queue = DispatchQueue(label: "jp.devpurge.headroom.workspaces", qos: .userInitiated)

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.scopeKey)
        manualProject = saved
        selectedRepo = saved
    }

    fileprivate func appear() {
        if !attempted { refresh() }
    }

    fileprivate func changeScope(_ project: String?) {
        guard busy.isEmpty else { return }
        manualProject = project
        selectedRepo = project
        if project == nil { UserDefaults.standard.removeObject(forKey: Self.scopeKey) }
        report = nil
        refresh()
    }

    fileprivate func refresh() {
        let projects = manualProject.map { [$0] } ?? []
        guard busy.isEmpty else { return }
        attempted = true
        let token = WorkspaceInventory.readToken()
        run("Gitの登録と作業フォルダを確認中…\nmacOSの「デスクトップ」へのアクセス確認が表示されたら選択してください。",
            operation: { try WorkspaceInventory.scan(projects: projects, readToken: token) }) { report in
            self.report = report
            if let chosen = projects.first, report.failedProjects == 0,
               report.projects.contains(where: { $0.repo == chosen }) {
                UserDefaults.standard.set(chosen, forKey: Self.scopeKey)
            }
            if !report.projects.contains(where: { $0.repo == self.selectedRepo }) { self.selectedRepo = nil }
        }
    }

    fileprivate func cancelRead() {
        guard canCancelRead else { return }
        cancelled = true
        canCancelRead = false
        busy = "読み取りをキャンセル中…"
        WorkspaceInventory.cancelReads()
    }

    private func run<Value>(_ label: String, readOnly: Bool = true, operation: @escaping () throws -> Value, failed: ((Error) -> Void)? = nil,
                            completed: @escaping (Value) -> Void) {
        guard busy.isEmpty else { return }
        busy = label
        canCancelRead = readOnly
        cancelled = false
        error = ""
        queue.async {
            let result = Result { try operation() }
            DispatchQueue.main.async {
                self.busy = ""
                self.canCancelRead = false
                if self.cancelled { return }
                switch result {
                case .success(let value): completed(value)
                case .failure(let failure):
                    if let failed { failed(failure) }
                    else { self.error = failure.localizedDescription }
                }
            }
        }
    }

    fileprivate func check(_ row: InventoryWorktree, in project: InventoryProject) {
        let token = WorkspaceInventory.readToken()
        run("選んだ作業コピーの保存内容と利用状況を照合中…",
            operation: { try WorkspaceInventory.check(project: project.repo, worktree: row.path, readToken: token) }) { receipt in
            let eligible = receipt.status == "eligible"
            let next: WorkspaceTarget?
            if eligible, let branch = receipt.branch, let head = receipt.head, branch == row.branch, head == row.head {
                next = .worktree(repo: project.repo, path: row.path, branch: branch, head: head)
            } else { next = nil }
            self.outcome = WorkspaceResult(title: next == nil ? "この作業コピーは保持します" : "作業コピーを閉じられます",
                item: row.path, message: eligible && next == nil ? "一覧からブランチかコミットが変わりました。一覧を更新してください。" : receipt.reason,
                next: next)
        }
    }

    fileprivate func review(_ row: InventoryBranch, in project: InventoryProject) {
        let target = WorkspaceTarget.branch(repo: project.repo, name: row.name, head: row.head)
        outcome = WorkspaceResult(title: "ブランチの整理", item: row.name, message: target.effect, next: target)
    }

    fileprivate func retire(_ target: WorkspaceTarget) {
        outcome = nil
        run("対象を再検証して整理中…", readOnly: false, operation: {
            switch target {
            case let .worktree(repo, path, branch, head):
                return try WorkspaceInventory.retire(project: repo, worktree: path, branch: branch, head: head)
            case let .branch(repo, name, head):
                return try WorkspaceInventory.retireBranch(project: repo, branch: name, head: head)
            }
        }, failed: { failure in
            self.outcome = WorkspaceResult(title: "整理の結果を取得できませんでした", item: target.item,
                                           message: failure.localizedDescription)
            self.refresh()
        }) { receipt in
            let title: String
            switch receipt.status {
            case "retired": title = "整理が完了しました"
            case "held": title = "対象を保持しました"
            default: title = "操作結果の確認が必要です"
            }
            self.outcome = WorkspaceResult(title: title, item: target.item, message: receipt.reason,
                                           restore: receipt.restoreCommand, record: receipt.record)
            self.refresh()
        }
    }

    fileprivate func compare(copy: String, keeper: String) {
        let token = WorkspaceInventory.readToken()
        run("コピーと保持先の内容を比較中…", operation: {
            try WorkspaceInventory.compare(copy: copy, keeper: keeper, readToken: token)
        }) { result in
            let title: String
            switch result.status {
            case "match": title = "コピー側の内容が一致しました"
            case "different": title = "異なる内容があります"
            default: title = "照合できなかった項目があります"
            }
            var lines = ["内容一致 \(result.matchedFiles) ファイル（\(quantity(result.matchedBytes))）",
                         "差分 \(result.differenceCount) 件"]
            lines += result.differences + result.warnings + [result.scope]
            self.outcome = WorkspaceResult(title: title, item: "コピー　\(copy)\n保持先　\(keeper)",
                                           message: lines.joined(separator: "\n"))
        }
    }
}

private enum InventorySection: String, CaseIterable {
    case trees = "作業コピー", branches = "ブランチ", folders = "登録外フォルダ"
}

private extension InventoryBranchCategory {
    var label: String {
        switch self {
        case .checkedOut: return "チェックアウト中"
        case .protected: return "保護対象"
        case .candidate: return "統合済み・整理候補"
        case .upstreamReview: return "追跡先の確認待ち"
        case .unmerged: return "統合未確認"
        case .unknown: return "判定できず"
        }
    }
}

struct WorkspaceBrowser: View {
    @ObservedObject var model: WorkspaceBrowserModel
    let openIndex: (String) -> Void
    @State private var section: InventorySection = .trees
    @State private var query = ""
    @State private var candidatesOnly = false
    @State private var showShared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.selectedRepo != nil || showShared {
                    Button { showOverview() } label: { Label("案件一覧", systemImage: "chevron.left") }
                } else { Text("案件の作業コピーとブランチ").font(.headline) }
                Spacer()
                if model.manualProject != nil {
                    Button("登録案件に戻る") { showOverview(); model.changeScope(nil) }.disabled(!model.busy.isEmpty)
                }
                Menu {
                    Button("Gitの案件を選ぶ…") {
                        if let url = choose("案件の本体フォルダを選択", prompt: "この案件を調べる", files: false) {
                            showOverview()
                            model.changeScope(url.path)
                        }
                    }
                    Divider()
                    Button("ファイル・フォルダを比較…") { compare() }
                } label: { Label("操作", systemImage: "ellipsis.circle") }
                .fixedSize().disabled(!model.busy.isEmpty)
                Button("更新", action: model.refresh).disabled(!model.busy.isEmpty)
            }
            if !model.error.isEmpty {
                Text(model.error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let report = model.report {
                if let project = report.projects.first(where: { $0.repo == model.selectedRepo }) {
                    detail(project, report: report)
                } else if showShared {
                    Text("所有案件を特定できないフォルダ").font(.headline)
                    searchField
                    folderList(report.folders.filter { $0.project == nil })
                } else { overview(report) }
            } else if model.busy.isEmpty && model.error.isEmpty {
                Text("「操作」からGitの案件を選択できます。").foregroundStyle(.secondary)
            }
            if !model.busy.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.busy).font(.callout)
                    Spacer()
                    if model.canCancelRead { Button("キャンセル", action: model.cancelRead) }
                }
            }
            if let reportFile = savedReport {
                Button("保存済みの登録案件レポートを開く") { NSWorkspace.shared.open(reportFile) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.appear() }
        .sheet(item: $model.outcome) { result in
            WorkspaceResultView(result: result, retire: model.retire) { model.outcome = nil }
        }
    }

    private var savedReport: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let file = support.appendingPathComponent("devpurge/logs/workspaces.html")
        let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return info?.isRegularFile == true && info?.isSymbolicLink == false ? file : nil
    }

    private func showOverview() {
        showShared = false
        model.selectedRepo = nil
        section = .trees
        candidatesOnly = false
        query = ""
    }

    private func overview(_ report: InventoryReport) -> some View {
        let total = report.projects.reduce(0) { $0 + $1.worktrees.filter { !$0.primary }.count }
        let branches = report.projects.reduce(0) { $0 + $1.branches.count }
        let shared = report.folders.filter { $0.project == nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !report.projects.isEmpty {
                    Text("追加の作業コピー \(total) 件　·　ローカルブランチ \(branches) 本").font(.body.weight(.semibold))
                }
                if let manual = model.manualProject {
                    Text("選択した案件　" + manual).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(report.projects, id: \.repo) { project in
                    let folders = report.folders.filter { $0.project == project.repo }
                    Button {
                        query = ""
                        section = .trees
                        candidatesOnly = false
                        model.selectedRepo = project.repo
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder").font(.title3).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(fileName(project.repo)).font(.headline)
                                Text(project.repo).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Text(project.metadataOnly ? "清掃除外・Gitの登録情報のみ" : folderCount(folders))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("作業コピー \(project.worktrees.filter { !$0.primary }.count) 件")
                                Text("ブランチ \(project.branches.count) 本")
                            }.monospacedDigit().font(.callout)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("案件の内訳を開く")
                    Divider()
                }
                if report.projects.isEmpty {
                    Text(report.failedProjects > 0 ? "案件の一覧を取得できませんでした。" : "登録されている案件がありません。")
                        .font(.headline)
                    Text("「操作」からGitの案件を選択できます。").font(.callout)
                }
                if !shared.isEmpty {
                    Button("所有案件を特定できないフォルダ（\(shared.count) 件）") { query = ""; showShared = true }
                        .buttonStyle(.link)
                }
                notes(report.warnings, failedProjects: report.failedProjects)
                if let timestamp = ISO8601DateFormatter().date(from: report.time) {
                    Text("最終確認　" + timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detail(_ project: InventoryProject, report: InventoryReport) -> some View {
        let folders = report.folders.filter { $0.project == project.repo }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(fileName(project.repo)).font(.headline)
                if project.metadataOnly { Text("清掃除外・Gitの登録情報のみ").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !project.metadataOnly {
                    Button("データ索引") { openIndex(project.repo) }
                }
                finder(project.repo)
            }
            Picker("表示する項目", selection: $section) {
                ForEach(InventorySection.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
            }.pickerStyle(.segmented).labelsHidden().onChange(of: section) { _ in query = "" }
            HStack {
                searchField
                if section == .branches && !project.metadataOnly {
                    Toggle("整理候補のみ", isOn: $candidatesOnly).toggleStyle(.checkbox)
                }
            }
            notes(project.warnings + report.warnings, failedProjects: report.failedProjects)
            switch section {
            case .trees: treeList(project)
            case .branches: branchList(project)
            case .folders:
                if project.metadataOnly { empty("清掃除外のため、登録外フォルダは調査対象外です。") }
                else { folderList(folders) }
            }
        }
    }

    @ViewBuilder private func notes(_ values: [String], failedProjects: Int) -> some View {
        if !values.isEmpty || failedProjects > 0 {
            DisclosureGroup(failedProjects > 0 ? "\(failedProjects) 案件を取得できませんでした" : "確認範囲と注意事項（\(values.count)）") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                            Text(value).font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 72)
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        TextField("名前・パス・状態で絞り込み", text: $query).textFieldStyle(.roundedBorder)
    }

    private func matches(_ words: String...) -> Bool {
        let pattern = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return pattern.isEmpty || words.contains { $0.localizedCaseInsensitiveContains(pattern) }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func state(_ row: InventoryWorktree, metadataOnly: Bool) -> String {
        var labels = [String]()
        if row.primary { labels.append("本体") }
        if row.location == "quarantine" { labels.append("隔離済み") }
        if row.location == "trash" { labels.append("ゴミ箱内") }
        if row.locked { labels.append("ロック中") }
        let states = ["dirty": "変更あり", "clean": "変更なし", "missing": "所在不明", "unknown": "状態未確認"]
        if !metadataOnly, let label = states[row.status] { labels.append(label) }
        if row.prunable { labels.append("Git登録の所在要確認") }
        if row.reviewForRetirement { labels.append("統合済み・利用状況を要確認") }
        return labels.isEmpty ? "登録情報のみ" : labels.joined(separator: " · ")
    }

    private func treeList(_ project: InventoryProject) -> some View {
        let items = project.worktrees.filter { matches($0.path, $0.branch ?? "", state($0, metadataOnly: project.metadataOnly)) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("追加の作業コピー \(project.worktrees.filter { !$0.primary }.count) 件　·　一覧には本体を含みます")
                    .font(.caption).foregroundStyle(.secondary)
                if items.isEmpty { empty("該当する作業コピーはありません。") }
                ForEach(items, id: \.path) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.branch ?? "ブランチなし（detached HEAD）").font(.body.weight(.medium)).textSelection(.enabled)
                        Text(row.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Text(state(row, metadataOnly: project.metadataOnly)).font(.caption)
                            Spacer()
                            if !project.metadataOnly, !row.primary, row.present == true, !row.locked,
                               !row.prunable, row.location == "workspace" {
                                Button("整理できるか確認") { model.check(row, in: project) }
                                    .disabled(!model.busy.isEmpty)
                            }
                            if !project.metadataOnly, row.present == true { finder(row.path) }
                        }.controlSize(.small)
                    }
                    Divider()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func branchList(_ project: InventoryProject) -> some View {
        let items = project.branches.filter {
            (!candidatesOnly || $0.category == .candidate) && matches($0.name, $0.head, $0.upstream ?? "", $0.category.label)
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("ローカル \(project.branches.count) 本　·　整理候補 \(project.branches.filter { $0.category == .candidate }.count) 本")
                    .font(.caption).foregroundStyle(.secondary)
                if items.isEmpty { empty("条件に該当するブランチはありません。") }
                ForEach(items, id: \.name) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name).font(.body.weight(.medium)).textSelection(.enabled)
                            Text(row.category.label + (row.upstream.map { "　·　" + $0 } ?? ""))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if !project.metadataOnly, row.category == .candidate {
                            Button("整理…") { model.review(row, in: project) }
                                .controlSize(.small).disabled(!model.busy.isEmpty)
                        }
                    }
                    Divider()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func folderList(_ folders: [InventoryFolder]) -> some View {
        let items = folders.filter { matches($0.path, $0.reason, folderKind($0)) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(folderCount(folders)).font(.caption).foregroundStyle(.secondary)
                if items.isEmpty { empty(query.isEmpty ? "確認できた範囲に対象のフォルダはありません。" : "検索に一致するフォルダはありません。") }
                ForEach(items, id: \.path) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileName(row.path)).font(.body.weight(.medium)).textSelection(.enabled)
                        Text(folderKind(row) + "　·　" + row.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(row.reason).font(.callout)
                        HStack {
                            Spacer()
                            Button("保持先と比較…") { compare(source: URL(fileURLWithPath: row.path)) }.disabled(!model.busy.isEmpty)
                            finder(row.path)
                        }.controlSize(.small)
                    }
                    Divider()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func folderCount(_ folders: [InventoryFolder]) -> String {
        let retained = folders.filter { $0.kind == "retained" }.count
        return "登録外 \(folders.count) 件" + (retained > 0 ? "（うち保管済み \(retained) 件）" : "")
    }

    private func folderKind(_ folder: InventoryFolder) -> String {
        switch folder.kind {
        case "retained": return "保管済み"
        case "rollback": return "退避フォルダ"
        case "copy": return "コピー名のフォルダ"
        case "independent-repo": return "独立したリポジトリ"
        case "other-worktree": return "別のGit参照"
        case "unlisted-worktree": return "未登録の作業コピー"
        case "folder": return "作業フォルダ"
        default: return "由来未確認"
        }
    }

    private func fileName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    private func finder(_ path: String) -> some View {
        Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            .controlSize(.small)
    }

    private func choose(_ title: String, prompt: String, files: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func compare(source: URL? = nil) {
        guard let copy = source ?? choose("比較するコピーを選択", prompt: "コピーを選択", files: true),
              let keeper = choose("「\(copy.lastPathComponent)」と照合する保持先を選択", prompt: "この保持先と比較", files: true) else { return }
        model.compare(copy: copy.path, keeper: keeper.path)
    }
}

private struct WorkspaceResultView: View {
    let result: WorkspaceResult
    let retire: (WorkspaceTarget) -> Void
    let dismiss: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.title).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(result.item).font(.callout.weight(.medium)).textSelection(.enabled)
                    Text(result.message).font(.callout).textSelection(.enabled)
                    if let restore = result.restore {
                        Text("復元コマンド").font(.headline)
                        Text(restore).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("コマンドをコピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(restore, forType: .string)
                        }
                    }
                    if let record = result.record {
                        Button("復元記録をFinderで表示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record)]) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("閉じる", action: dismiss).keyboardShortcut(.cancelAction)
                if let target = result.next { Button(target.action + "…") { confirming = true } }
            }
        }.padding(20).frame(width: 530, height: 325)
        .alert("選んだ1件を整理しますか？", isPresented: $confirming, presenting: result.next) { target in
            Button(target.action, role: .destructive) { retire(target) }
            Button("キャンセル", role: .cancel) {}
        } message: { target in Text(target.item + "\n\n" + target.effect) }
    }
}
