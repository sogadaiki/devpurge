import Darwin
import Foundation

struct WorkspaceEntry {
    let url: URL
    let label: String
    let bytes: Int64
    let partial: Bool
}

struct WorkspaceReport {
    let rows: [WorkspaceEntry]
    let message: String
    let partial: Bool
}

enum WorkspaceScan {
    static func scan(_ root: URL) -> WorkspaceReport {
        scan(root, nodeLimit: 240_000, seconds: 8)
    }

    static func scan(_ root: URL, nodeLimit: Int, seconds: TimeInterval) -> WorkspaceReport {
        let walker = ProjectWalker(root: root, nodeLimit: nodeLimit, seconds: seconds)
        return walker.report()
    }
}

private final class ProjectWalker {
    private struct Candidate {
        let url: URL
        let components: [String]
        let label: String
        let inode: ino_t
    }

    let root: URL
    let deadline: TimeInterval
    let nodeLimit: Int
    var nodes = 0
    var partial = false
    var device: dev_t = 0
    private var candidates: [Candidate] = []
    private let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK

    init(root: URL, nodeLimit: Int, seconds: TimeInterval) {
        self.root = root.standardizedFileURL
        self.nodeLimit = nodeLimit
        deadline = ProcessInfo.processInfo.systemUptime + seconds
    }

    private static func label(for name: String) -> String? {
        switch name {
        case ".render-tmp": return "Remotion 書き出し用一時領域"
        case ".render-bundle": return "Remotion 再利用バンドル"
        case "DerivedData": return "Xcode ビルドデータ"
        case "ModuleCache.noindex": return "Xcode モジュールキャッシュ"
        case ".godot": return "Godot インポート・エディタデータ"
        case "node_modules": return "Node.js 依存パッケージ"
        case ".next", ".open-next": return "Next.js ビルド出力"
        case ".turbo": return "Turborepo キャッシュ"
        case ".venv": return "Python 仮想環境"
        case ".pytest_cache": return "pytest テストキャッシュ"
        case ".build": return "SwiftPM ビルド領域"
        case "target": return "target フォルダ"
        case "build", "dist": return "ビルド・配布用フォルダ"
        default:
            if name.hasPrefix("remotion-webpack-bundle-") || name.hasPrefix("react-motion-render") ||
                (name.hasPrefix("remotion-v") && name.contains("-assets")) {
                return "Remotion 作業フォルダ"
            }
            return nil
        }
    }

    private static func excluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        if name.hasPrefix(".") && label(for: name) == nil { return true }
        if ["sadame", "cloudstorage", "mobile documents", "icloud drive", "keychains",
            "credentials", "secrets", "private keys", "archives", "backups.backupdb"].contains(lower) { return true }
        let ext = (lower as NSString).pathExtension
        return ["icloud", "pem", "key", "p12", "pfx", "mobileprovision", "keychain-db", "db",
                "sqlite", "sqlite3", "ipa", "app", "xcarchive", "dsym", "framework", "xcframework",
                "bundle", "photoslibrary", "fcpbundle", "xcodeproj", "xcworkspace"].contains(ext)
    }

    /// Open each component relative to a pinned directory. A replaced ancestor cannot redirect a scan.
    private func openPath(from parent: Int32, components: [String]) -> Int32 {
        var fd = dup(parent)
        for name in components {
            guard fd >= 0 else { break }
            let next = openat(fd, name, flags)
            close(fd)
            fd = next
        }
        return fd
    }

    private var expired: Bool {
        nodes >= nodeLimit || ProcessInfo.processInfo.systemUptime >= deadline || Thread.current.isCancelled
    }

    /// Stops iterating immediately at the cap, including directories containing only excluded entries.
    private func visit(_ fd: Int32, until limit: Int, body: (String, stat) -> Void) -> Bool {
        let copy = dup(fd)
        guard copy >= 0 else { return false }
        guard let dir = fdopendir(copy) else { close(copy); return false }
        defer { closedir(dir) }
        var complete = true
        while nodes < limit && !expired {
            errno = 0
            guard let ent = readdir(dir) else { return complete && errno == 0 }
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(validatingCString: $0) }
            }
            guard let name else { complete = false; continue }
            if name == "." || name == ".." { continue }
            nodes += 1
            if Self.excluded(name) { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { complete = false; continue }
            guard info.st_dev == device, (info.st_flags & UInt32(SF_DATALESS | UF_HIDDEN)) == 0 else { continue }
            body(name, info)
        }
        return false
    }

    private func directoryURL(_ parent: URL, _ name: String, _ info: stat) -> URL? {
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        // Finder packages with arbitrary registered extensions are opaque, including custom game saves.
        if !url.pathExtension.isEmpty, Self.label(for: name) == nil {
            guard let values = try? url.resourceValues(forKeys: [.isPackageKey]), values.isPackage == false else { return nil }
        }
        return url
    }

    private func discover(_ fd: Int32, url: URL, components: [String]) {
        var info = stat()
        guard fstat(fd, &info) == 0 && info.st_dev == device else { partial = true; return }
        if let label = Self.label(for: url.lastPathComponent) {
            if candidates.count < 150 {
                candidates.append(Candidate(url: url, components: components, label: label, inode: info.st_ino))
            } else { partial = true }
            return
        }
        guard components.count < 5 else { return }
        let complete = visit(fd, until: min(18_000, nodeLimit)) { name, info in
            guard let childURL = directoryURL(url, name, info) else { return }
            let child = openat(fd, name, flags)
            guard child >= 0 else { partial = true; return }
            defer { close(child) }
            discover(child, url: childURL, components: components + [name])
        }
        if !complete { partial = true }
    }

    private func size(_ fd: Int32, url: URL, depth: Int, limit: Int, bytes: inout Int64) -> Bool {
        if depth >= 40 { return false }
        var complete = true
        let finished = visit(fd, until: limit) { name, info in
            if (info.st_mode & S_IFMT) == S_IFREG {
                // A link may have a retained owner outside the chosen folder, as with Remotion bundles.
                if info.st_nlink == 1 { bytes += Int64(info.st_blocks) * 512 }
            } else if let childURL = directoryURL(url, name, info) {
                let child = openat(fd, name, flags)
                guard child >= 0 else { complete = false; return }
                defer { close(child) }
                if !size(child, url: childURL, depth: depth + 1, limit: limit, bytes: &bytes) { complete = false }
            }
        }
        return finished && complete
    }

    func report() -> WorkspaceReport {
        let parts = Array(root.pathComponents.dropFirst())
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let homeParts = Array(home.pathComponents.dropFirst())
        let allowedParts = parts.indices.allSatisfy { index in
            let name = parts[index]
            if name == ".worktrees", index + 1 < parts.count { return true }
            if name == ".codex", index == homeParts.count, parts.starts(with: homeParts),
               index + 3 < parts.count, parts[index + 1] == "worktrees" { return true }
            return !Self.excluded(name)
        }
        let unavailable = WorkspaceReport(rows: [], message: "ローカルの案件フォルダを選んでください。保護領域・リンク・クラウド領域は対象外です。", partial: true)
        guard root.isFileURL, !parts.isEmpty, root.path != home.path, allowedParts,
              !["System", "Library", "Network"].contains(parts[0]), !(parts.count == 1 && parts[0] == "Users"),
              !(parts.count <= 2 && parts[0] == "Volumes") else { return unavailable }
        let base = open("/", flags)
        guard base >= 0 else { return unavailable }
        defer { close(base) }
        // These two macOS system aliases are commonly returned by NSOpenPanel and FileManager.
        // Always open their fixed physical directories, without following any user-controlled links.
        let physicalParts = parts.first == "tmp" || parts.starts(with: ["var", "folders"]) ? ["private"] + parts : parts
        let fd = openPath(from: base, components: physicalParts)
        guard fd >= 0 else { return unavailable }
        defer { close(fd) }
        var info = stat()
        var fs = statfs()
        guard fstat(fd, &info) == 0, (info.st_flags & UInt32(SF_DATALESS | UF_HIDDEN)) == 0,
              fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return unavailable }
        if !root.pathExtension.isEmpty && Self.label(for: root.lastPathComponent) == nil {
            guard (try? root.resourceValues(forKeys: [.isPackageKey]).isPackage) == false else { return unavailable }
        }
        device = info.st_dev
        discover(fd, url: root, components: [])
        var rows: [WorkspaceEntry] = []
        // Measure smaller/deeper projects even when one dependency tree hits its per-folder budget.
        for candidate in candidates {
            var bytes: Int64 = 0
            var complete = false
            if !expired {
                let dir = openPath(from: fd, components: candidate.components)
                if dir >= 0 {
                    var current = stat()
                    if fstat(dir, &current) == 0, current.st_dev == device, current.st_ino == candidate.inode {
                        complete = size(dir, url: candidate.url, depth: 0, limit: nodes + 55_000, bytes: &bytes)
                    }
                    close(dir)
                }
            }
            partial = partial || !complete
            rows.append(WorkspaceEntry(url: candidate.url, label: candidate.label, bytes: bytes, partial: !complete))
        }
        rows.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.url.path < $1.url.path }
        var message = rows.isEmpty ? "深さ5階層までに既知の開発用フォルダは見つかりませんでした。" : "既知の開発用フォルダ \(rows.count) 件。割当容量順。"
        if partial { message += " 一部のみ計測できました。" }
        message += " pnpm等の共有ハードリンク・隠しストア・保護ファイル・パッケージの中身は集計外です。"
        return WorkspaceReport(rows: rows, message: message, partial: partial)
    }
}
