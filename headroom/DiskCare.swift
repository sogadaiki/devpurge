import Darwin
import Foundation

private let diskFiles = FileManager.default

private enum FileKind {
    case report, bottle

    func accepts(_ name: String) -> Bool {
        switch self {
        case .report:
            return !name.hasPrefix(".") && ["ips", "diag", "crash", "hang", "spin"].contains((name as NSString).pathExtension)
        case .bottle:
            let prefix = name.prefix(64)
            return prefix.count == 64 && prefix.allSatisfy({ "0123456789abcdef".contains($0) })
                && name.dropFirst(64).hasPrefix("--") && name.contains(".bottle.")
                && [".tar.gz", ".tar.zst", ".tar.xz"].contains(where: name.hasSuffix)
        }
    }
}

private struct FileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modified: timespec
    let changed: timespec

    init(_ s: stat) {
        device = s.st_dev
        inode = s.st_ino
        size = s.st_size
        modified = s.st_mtimespec
        changed = s.st_ctimespec
    }

    static func == (l: Self, r: Self) -> Bool {
        l.device == r.device && l.inode == r.inode && l.size == r.size
            && l.modified.tv_sec == r.modified.tv_sec && l.modified.tv_nsec == r.modified.tv_nsec
            && l.changed.tv_sec == r.changed.tv_sec && l.changed.tv_nsec == r.changed.tv_nsec
    }
}

struct DiskItem {
    let url: URL
    let bytes: Int64
    fileprivate let root: URL
    fileprivate let kind: FileKind
    fileprivate let stamp: FileStamp
}

struct DiskGroup {
    let id: String
    let title: String
    let detail: String
    let folder: URL
    let items: [DiskItem]
    let bytes: Int64
    let partial: Bool
    let canTrash: Bool
    var canSelectInFinder: Bool { id == "system-reports" && !partial && !items.isEmpty }
    var canPruneUV: Bool { id == "uv" && DiskCare.canPruneUV }
}

struct DiskResult {
    let moved: Int
    let bytes: Int64
    let skipped: Int
    let destinations: [URL]
    var message: String { "ゴミ箱へ \(moved)件移動・保留 \(skipped)件。空き容量はゴミ箱を空にしたあとで再計測できます。" }
}

enum DiskCare {
    private static var home: URL { diskFiles.homeDirectoryForCurrentUser }
    private static let systemReports = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)

    private static func info(_ url: URL) -> stat? {
        var s = stat()
        return lstat(url.path, &s) == 0 ? s : nil
    }

    // FileManager can resolve a redirected parent while trashing a regular file.
    // Only permit the exact physical path, including every ancestor.
    private static func physical(_ url: URL) -> Bool {
        guard let resolved = realpath(url.path, nil) else { return false }
        defer { free(resolved) }
        return String(cString: resolved) == url.path
    }

    private static func item(_ url: URL, root: URL, kind: FileKind) -> DiskItem? {
        guard url.deletingLastPathComponent().path == root.path, kind.accepts(url.lastPathComponent),
              let s = info(url), (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1 else { return nil }
        return DiskItem(url: url, bytes: Int64(s.st_blocks) * 512, root: root, kind: kind, stamp: FileStamp(s))
    }

    private static func filesGroup(_ id: String, _ title: String, _ detail: String, _ folder: URL,
                                   _ kind: FileKind, allowTrash: Bool) -> DiskGroup {
        var allBytes: Int64 = 0
        func group(_ items: [DiskItem], _ suffix: String = "", partial: Bool = false) -> DiskGroup {
            DiskGroup(id: id, title: title, detail: detail + suffix, folder: folder, items: items,
                      bytes: allowTrash ? items.reduce(0) { $0 + $1.bytes } : allBytes, partial: partial,
                      canTrash: allowTrash && !partial && !items.isEmpty)
        }
        guard info(folder) != nil else {
            return errno == ENOENT ? group([], "（フォルダなし）") : group([], "（アクセス不可）", partial: true)
        }
        guard physical(folder), let children = try? diskFiles.contentsOfDirectory(at: folder,
                            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return group([], "（読み取り不可またはリンク）", partial: true)
        }
        let now = time(nil)
        var items: [DiskItem] = []
        var partial = false
        for url in children where kind.accepts(url.lastPathComponent) {
            guard let s = info(url) else { partial = true; continue }
            guard let candidate = item(url, root: folder, kind: kind) else { continue }
            allBytes += candidate.bytes
            if s.st_mtimespec.tv_sec > now - 7 * 86_400 || (allowTrash && s.st_uid != getuid()) { continue }
            items.append(candidate)
        }
        items.sort { $0.bytes > $1.bytes }
        return group(items, partial ? "（一部未確認）" : "", partial: partial)
    }

    /// Only small fixed-format stdout is requested (du); tool diagnostics never enter the UI.
    private static func run(_ path: String, args: [String], timeout: Int, capture: Bool) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "LC_ALL": "C", "UV_LOCK_TIMEOUT": "3"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = capture ? pipe : FileHandle.nullDevice as Any
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + .seconds(2))
            }
            return nil
        }
        let value = capture ? String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) : ""
        return (process.terminationStatus, value)
    }

    private static func occupancy(_ id: String, _ title: String, _ detail: String, _ url: URL) -> DiskGroup {
        var label = detail
        var bytes: Int64 = 0
        var partial = false
        if info(url) == nil && errno == ENOENT {
            label += "（フォルダなし）"
        } else if physical(url), let (code, output) = run("/usr/bin/du", args: ["-skx", url.path], timeout: 12, capture: true),
                  let first = output.split(whereSeparator: { $0.isWhitespace }).first,
                  let kib = Int64(first), kib >= 0 && kib <= Int64.max / 1024 {
            bytes = kib * 1024
            partial = code != 0
        } else { partial = true }
        if partial { label += "（計測できた範囲のみ）" }
        return DiskGroup(id: id, title: title, detail: label, folder: url, items: [], bytes: bytes,
                         partial: partial, canTrash: false)
    }

    static func scan() -> [DiskGroup] {
        let userReports = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let brew = home.appendingPathComponent("Library/Caches/Homebrew/downloads", isDirectory: true)
        let groups = [
            filesGroup("user-reports", "アプリの診断レポート", "7日以上前の診断用ファイル。調査に使うものは保持してください。", userReports, .report, allowTrash: true),
            filesGroup("bottles", "Homebrew の配布アーカイブ", "7日以上前に保存した bottle。必要な版の再取得には配布元への接続が必要です。", brew, .bottle, allowTrash: true),
            filesGroup("system-reports", "システムの診断レポート", "容量は直下の対象形式の全日付分。7日以上前のファイルを選んで Finder で確認できます。", systemReports, .report, allowTrash: false),
            occupancy("ios-runtime-assets", "iOS シミュレータのシステム配布データ", "Apple が管理する配布領域。Xcode の Settings → Components で使用するランタイムを管理できます。", URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime")),
            occupancy("sim-images", "シミュレータのディスクイメージ", "Xcode の Settings → Components で管理できます。", URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Images")),
            occupancy("derived-data", "Xcode のビルド用データ", "ビルド結果や索引の占有量。必要なプロジェクトやビルド中の対象を Finder で確認できます。", home.appendingPathComponent("Library/Developer/Xcode/DerivedData")),
            occupancy("uv", "Python・uv", "キャッシュ全体の占有量。未参照分は uv が判定します。", home.appendingPathComponent(".cache/uv")),
            occupancy("npm", "JavaScript・npm", "パッケージ本体のキャッシュ。オフライン作業や非公開パッケージにも使われます。", home.appendingPathComponent(".npm/_cacache/content-v2")),
            occupancy("pip", "Python・pip", "HTTP キャッシュの占有量。プライベート配布やオフライン利用を含む場合があります。", home.appendingPathComponent("Library/Caches/pip/http-v2"))
        ]
        return groups.sorted { $0.bytes > $1.bytes }
    }

    private static func available(_ old: DiskItem) -> Bool {
        guard physical(old.root), let current = item(old.url, root: old.root, kind: old.kind),
              current.stamp == old.stamp, current.stamp.modified.tv_sec <= time(nil) - 7 * 86_400 else { return false }
        var pid: pid_t = 0
        let openBytes = old.url.path.withCString {
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, $0, 0, &pid, Int32(MemoryLayout<pid_t>.size))
        }
        guard openBytes == 0, physical(old.root), let latest = info(old.url) else { return false }
        return FileStamp(latest) == old.stamp
    }

    private static func selection(_ input: [DiskItem], at root: URL) -> [URL] {
        input.filter { $0.root.path == root.path && $0.kind == .report && available($0) }.map(\.url)
    }

    static func finderSelection(_ items: [DiskItem]) -> [URL] {
        selection(items, at: systemReports)
    }

    private static func move(_ input: [DiskItem], userRoot: URL, brewRoot: URL) -> DiskResult {
        var moved = 0
        var bytes: Int64 = 0
        var destinations: [URL] = []
        for old in input {
            let root = old.root
            guard (root.path == userRoot.path && old.kind == .report) || (root.path == brewRoot.path && old.kind == .bottle),
                  let rootStat = info(root), rootStat.st_uid == getuid(),
                  let s = info(old.url), s.st_uid == getuid(), available(old) else { continue }
            do {
                var destination: NSURL?
                try diskFiles.trashItem(at: old.url, resultingItemURL: &destination)
                if let url = destination as URL? { destinations.append(url) }
                moved += 1
                bytes += old.bytes
            } catch { continue }
        }
        return DiskResult(moved: moved, bytes: bytes, skipped: input.count - moved, destinations: destinations)
    }

    static func trash(_ items: [DiskItem]) -> DiskResult {
        move(items, userRoot: home.appendingPathComponent("Library/Logs/DiagnosticReports"),
             brewRoot: home.appendingPathComponent("Library/Caches/Homebrew/downloads"))
    }

    private static var uvURL: URL { home.appendingPathComponent(".local/bin/uv") }
    private static var uvCache: URL { home.appendingPathComponent(".cache/uv") }

    private static var trustedUV: Bool {
        guard physical(uvURL), let s = info(uvURL),
              s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid() || s.st_uid == 0,
              access(uvURL.path, X_OK) == 0 else { return false }
        for path in [uvURL, uvURL.deletingLastPathComponent(), home.appendingPathComponent(".local"), home] {
            guard let parent = info(path), parent.st_mode & 0o022 == 0,
                  parent.st_uid == getuid() || parent.st_uid == 0 else { return false }
        }
        return true
    }

    static var canPruneUV: Bool {
        guard trustedUV, physical(uvCache), let cache = info(uvCache), cache.st_mode & S_IFMT == S_IFDIR,
              let parent = info(uvCache.deletingLastPathComponent()) else { return false }
        return cache.st_uid == getuid() && cache.st_mode & 0o022 == 0
            && parent.st_uid == getuid() && parent.st_mode & 0o022 == 0
    }

    static func pruneUV() -> String {
        guard canPruneUV else { return "uv の実行ファイルまたはキャッシュ保存先を確認できません。" }
        return prune(cache: uvCache)
    }

    private static func prune(cache: URL) -> String {
        guard let (code, _) = run(uvURL.path, args: ["cache", "prune", "--cache-dir", cache.path, "--offline", "--no-config", "--no-progress"],
                                  timeout: 45, capture: false) else { return "uv の整理完了を確認できません。容量を再計測してください。" }
        return code == 0 ? "uv が未参照キャッシュの整理を完了しました。" : "uv の整理が完了しませんでした（終了コード \(code)）。"
    }

    #if DISKCARE_TESTING
    static func testSelection(_ items: [DiskItem], root: URL) -> [URL] {
        selection(items, at: root)
    }

    static func testPrune(_ cache: URL) -> String? {
        guard trustedUV, physical(cache) else { return nil }
        return prune(cache: cache)
    }
    static func testGroup(_ root: URL, bottles: Bool = false) -> DiskGroup {
        filesGroup("test", "", "", root, bottles ? .bottle : .report, allowTrash: true)
    }

    static func testTrash(_ items: [DiskItem], root: URL) -> DiskResult {
        move(items, userRoot: root, brewRoot: root)
    }
    #endif
}
