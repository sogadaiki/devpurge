import CryptoKit
import Darwin
import Foundation

struct DuplicateGroup {
    let urls: [URL]
    let fileBytes: Int64
}

struct DuplicateReport {
    let groups: [DuplicateGroup]
    let partial: Bool
    let message: String
}

enum Duplicates {
    /// Explicit user action. Read only local media and build outputs in the selected project.
    static func scan(_ root: URL, minimumBytes: Int64 = 8 << 20, nodeLimit: Int = 30_000,
                     byteLimit: Int64 = 12 << 30, seconds: TimeInterval = 20) -> DuplicateReport {
        let scanner = DuplicateScanner(root: root, minimum: minimumBytes, nodes: nodeLimit,
                                       bytes: byteLimit, seconds: seconds)
        return scanner.report()
    }
}

private final class DuplicateScanner {
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
    private static let fileFlags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
    private static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "avi", "mp3", "m4a", "aac", "wav", "aif",
        "aiff", "flac", "ogg", "png", "jpeg", "jpg", "webp", "tif", "tiff", "pck", "apk", "aab", "ipa"
    ]
    private static func excluded(_ component: String) -> Bool {
        let name = component.lowercased()
        if name.hasPrefix(".") || ["sadame", "node_modules", "backups.backupdb", "keychains",
            "mobile documents", "library", "cloudstorage", "icloud drive", "private keys"].contains(name) { return true }
        if ["dropbox", "onedrive", "google drive", "googledrive", "icloud", "box sync", "box drive",
            "credential", "password", "private-key", "private_key", "token", "secret", "keychain"].contains(where: name.contains) { return true }
        return ["app", "bundle", "xcarchive", "xcframework", "framework", "dsym", "photoslibrary",
                "fcpbundle", "xcodeproj", "xcworkspace", "key", "p12", "pfx", "pem", "sqlite", "db"]
            .contains((name as NSString).pathExtension)
    }

    private struct Entry {
        let parts: [String]
        let info: stat
    }
    private let root: URL
    private let minimum: Int64
    private let deadline: TimeInterval
    private let discoveryDeadline: TimeInterval
    private var nodesLeft: Int
    private var bytesLeft: Int64
    private var partial = false
    private var entries: [Int64: [Entry]] = [:]
    private var inodes: Set<ino_t> = []
    private var device: dev_t = 0

    init(root: URL, minimum: Int64, nodes: Int, bytes: Int64, seconds: TimeInterval) {
        self.root = root
        self.minimum = minimum
        nodesLeft = nodes
        bytesLeft = bytes
        let now = ProcessInfo.processInfo.systemUptime
        deadline = now + seconds
        discoveryDeadline = now + seconds * 0.45
    }

    private func expired(_ at: TimeInterval) -> Bool {
        Thread.current.isCancelled || ProcessInfo.processInfo.systemUptime >= at
    }

    private func eligible(_ info: stat) -> Bool {
        info.st_dev == device && info.st_flags & UInt32(SF_DATALESS | UF_HIDDEN) == 0
    }

    private func sameFile(_ left: stat, _ right: stat) -> Bool {
        (right.st_mode & S_IFMT) == S_IFREG && eligible(right) && left.st_ino == right.st_ino &&
        left.st_size == right.st_size && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
        left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec &&
        left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }

    private func opaque(_ url: URL) -> Bool {
        if FileManager.default.isUbiquitousItem(at: url) { return true }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != false
    }

    private func discover(_ fd: Int32, at url: URL, parts: [String]) {
        let copy = dup(fd)
        guard copy >= 0 else { partial = true; return }
        guard let dir = fdopendir(copy) else { close(copy); partial = true; return }
        defer { closedir(dir) }
        while nodesLeft > 0 && !expired(discoveryDeadline) {
            errno = 0
            guard let ent = readdir(dir) else { if errno != 0 { partial = true }; return }
            let decoded = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(validatingCString: $0) }
            }
            guard let name = decoded else { partial = true; continue }
            if name == "." || name == ".." { continue }
            nodesLeft -= 1
            if Self.excluded(name) { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { partial = true; continue }
            guard eligible(info) else { continue }
            let childPath = parts + [name]
            let child = url.appendingPathComponent(name)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard !opaque(child) else { continue }
                guard childPath.count <= 32 else { partial = true; continue }
                let subdir = openat(fd, name, Self.directoryFlags)
                guard subdir >= 0 else { partial = true; continue }
                var current = stat()
                if fstat(subdir, &current) == 0, eligible(current), current.st_ino == info.st_ino {
                    discover(subdir, at: child, parts: childPath)
                } else { partial = true }
                close(subdir)
            case S_IFREG:
                guard info.st_size >= minimum, Self.extensions.contains(child.pathExtension.lowercased()),
                      !FileManager.default.isUbiquitousItem(at: child), inodes.insert(info.st_ino).inserted else { continue }
                entries[info.st_size, default: []].append(Entry(parts: childPath, info: info))
            default: continue
            }
        }
        partial = true
    }

    /// Reopen a discovered path relative to its pinned root. Never follow a replaced parent or leaf.
    private func openEntry(_ entry: Entry, from rootFD: Int32) -> Int32 {
        var fd = dup(rootFD)
        for (i, part) in entry.parts.enumerated() {
            guard fd >= 0 else { break }
            let next = openat(fd, part, i == entry.parts.count - 1 ? Self.fileFlags : Self.directoryFlags)
            close(fd)
            fd = next
            var current = stat()
            if fd >= 0 && (fstat(fd, &current) != 0 || !eligible(current)) {
                close(fd); return -1
            }
        }
        return fd
    }

    private func digest(_ entry: Entry, from rootFD: Int32) -> SHA256.Digest? {
        guard bytesLeft >= entry.info.st_size, !expired(deadline) else { return nil }
        let fd = openEntry(entry, from: rootFD)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, sameFile(entry.info, info) else { return nil }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 << 10)
        var remaining = info.st_size
        while remaining > 0 && !expired(deadline) {
            let count = buffer.withUnsafeMutableBytes { dst -> Int in
                let n = Darwin.read(fd, dst.baseAddress, min(dst.count, Int(remaining)))
                if n > 0 { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: dst.prefix(n))) }
                return n
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            remaining -= Int64(count)
            bytesLeft -= Int64(count)
        }
        guard remaining == 0, fstat(fd, &info) == 0, sameFile(entry.info, info) else { return nil }
        return hash.finalize()
    }

    func report() -> DuplicateReport {
        let unavailable = DuplicateReport(groups: [], partial: true, message: "ローカルの案件フォルダを選んでください。")
        let parts = Array(root.pathComponents.dropFirst())
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        // Foundation can preserve /var for the system temp directory. Walk its known physical
        // spelling without following the /var link or resolving any user-selected path component.
        let sysTempAlias = temp.hasPrefix("/var/") && root.path.hasPrefix(temp + "/")
        let sysTempPhysical = temp.hasPrefix("/var/") && root.path.hasPrefix("/private" + temp + "/")
        let homeParts = Array(URL(fileURLWithPath: home).pathComponents.dropFirst())
        let forbidden = parts.indices.contains { i in
            if parts[i] == ".worktrees" && parts.count > i + 1 { return false }
            if parts[i] == ".codex" && parts.count > i + 3 && Array(parts.prefix(i)) == homeParts &&
                parts[i + 1] == "worktrees" { return false }
            return Self.excluded(parts[i])
        }
        let sharedProject = parts.count >= 3 && Array(parts.prefix(2)) == ["Users", "Shared"]
        guard root.isFileURL, root.path.hasPrefix("/"),
              !parts.isEmpty, !forbidden,
              root.path.hasPrefix(home + "/") || root.path.hasPrefix(temp + "/") || sysTempPhysical || sharedProject ||
                    (parts.count > 2 && parts.first == "Volumes"),
              !["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Applications", "Music"]
                .contains(where: { root.path == home + "/" + $0 }) else { return unavailable }
        var dir = open("/", Self.directoryFlags)
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for part in (sysTempAlias ? ["private"] + parts : parts) {
            guard dir >= 0 else { return unavailable }
            ancestor.appendPathComponent(part)
            let next = openat(dir, part, Self.directoryFlags)
            close(dir)
            dir = next
            var state = stat()
            guard dir >= 0 else { return unavailable }
            if fstat(dir, &state) != 0 || state.st_flags & UInt32(SF_DATALESS) != 0 || opaque(ancestor) {
                close(dir); return unavailable
            }
        }
        defer { close(dir) }
        var fs = statfs()
        var state = stat()
        guard dir >= 0, fstatfs(dir, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              fstat(dir, &state) == 0, !sharedProject || state.st_uid == getuid() else { return unavailable }
        device = state.st_dev
        discover(dir, at: root, parts: [])
        var groups: [DuplicateGroup] = []
        let matches = entries.filter { $0.value.count > 1 }.sorted { $0.key > $1.key }
        for (size, files) in matches {
            guard !expired(deadline) else { partial = true; break }
            guard size <= bytesLeft / 2 else { partial = true; continue }
            var byHash: [SHA256.Digest: [Entry]] = [:]
            for file in files {
                guard !expired(deadline), bytesLeft >= size else { partial = true; break }
                if let key = digest(file, from: dir) { byHash[key, default: []].append(file) }
                else { partial = true }
            }
            for group in byHash.values where group.count > 1 {
                let urls: [URL] = group.compactMap { entry in
                    let fd = openEntry(entry, from: dir)
                    guard fd >= 0 else { partial = true; return nil }
                    defer { close(fd) }
                    var now = stat()
                    guard fstat(fd, &now) == 0, sameFile(entry.info, now) else { partial = true; return nil }
                    return entry.parts.reduce(root) { $0.appendingPathComponent($1) }
                }
                if urls.count > 1 { groups.append(DuplicateGroup(urls: urls.sorted { $0.path < $1.path }, fileBytes: size)) }
            }
        }
        groups.sort { $0.fileBytes != $1.fileBytes ? $0.fileBytes > $1.fileBytes : $0.urls[0].path < $1.urls[0].path }
        let scope = "対象の動画・音声・画像・配布ビルドで、同じ内容を確認したグループは \(groups.count) 件です。"
        return DuplicateReport(groups: groups, partial: partial,
                               message: scope + (partial ? " 制限時間・測定上限・アクセス状況により一部を照合できませんでした。" : ""))
    }
}
