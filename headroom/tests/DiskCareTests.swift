import Darwin
import Foundation

@main
struct DiskCareTests {
    static func check(_ value: Bool, at line: UInt = #line) throws {
        if !value { throw NSError(domain: "DiskCareTests", code: Int(line)) }
    }

    static func freeBytes(_ url: URL) throws -> Int64 {
        var data = statfs()
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fstatfs(fd, &data) == 0 else { throw POSIXError(.EIO) }
        return Int64(data.f_bavail) * Int64(data.f_bsize)
    }

    static func main() throws {
        let fm = FileManager.default
        guard let resolved = realpath(fm.temporaryDirectory.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(resolved) }
        let fixture = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("headroom-test-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let folder = fixture.appendingPathComponent("reports")
        let outside = fixture.appendingPathComponent("outside")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let old = Date(timeIntervalSinceNow: -9 * 86_400)
        func file(_ url: URL, dated: Bool = true) throws {
            try Data(repeating: 11, count: 8192).write(to: url)
            if dated { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        }
        let moved = folder.appendingPathComponent("headroom-test-" + UUID().uuidString + ".diag")
        let changed = folder.appendingPathComponent("changed.diag")
        let busy = folder.appendingPathComponent("busy.ips")
        let outsideFile = outside.appendingPathComponent("original.ips")
        for url in [moved, changed, busy, outsideFile] { try file(url) }
        try file(folder.appendingPathComponent("unrelated.txt"))
        try file(folder.appendingPathComponent("recent.ips"), dated: false)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("link.ips"), withDestinationURL: outsideFile)
        try fm.linkItem(at: outsideFile, to: folder.appendingPathComponent("hardlink.ips"))
        let redirect = fixture.appendingPathComponent("redirect")
        try fm.createSymbolicLink(at: redirect, withDestinationURL: folder)
        try check(DiskCare.testGroup(redirect).partial)
        let group = DiskCare.testGroup(folder)
        try check(group.canTrash && Set(group.items.map { $0.url.path }) == [moved.path, changed.path, busy.path])
        try file(changed, dated: false)
        let handle = try FileHandle(forReadingFrom: busy)
        try check(DiskCare.testSelection(group.items, root: folder).map(\.path) == [moved.path])
        try check(DiskCare.finderSelection(group.items).isEmpty)
        let result = DiskCare.testTrash(group.items, root: folder)
        try handle.close()
        try check(result.moved == 1 && result.skipped == 2 && result.bytes > 0)
        try check(!fm.fileExists(atPath: moved.path) && fm.fileExists(atPath: changed.path))
        try check(fm.fileExists(atPath: busy.path) && fm.fileExists(atPath: outsideFile.path))
        // Restore only the disposable file from this transaction, then clean the fixture.
        guard let trashed = result.destinations.first, trashed.lastPathComponent == moved.lastPathComponent else {
            throw POSIXError(.ENOENT)
        }
        try fm.moveItem(at: trashed, to: moved)
        let wrongRoot = DiskCare.testTrash(group.items, root: outside)
        try check(wrongRoot.moved == 0)
        let prefix = String(repeating: "a", count: 64) + "--"
        let bottle = folder.appendingPathComponent(prefix + "demo--1.arm64.bottle.tar.gz")
        try file(bottle)
        try file(folder.appendingPathComponent(prefix + "private.tgz"))
        try file(folder.appendingPathComponent("arbitrary.bottle.tar.gz"))
        try check(DiskCare.testGroup(folder, bottles: true).items.map { $0.url.path } == [bottle.path])
        print("PASS DiskCare scope, stale and active guards, link checks, recoverable Trash, archive selection")

        let cache = fixture.appendingPathComponent("uv")
        let unreachable = cache.appendingPathComponent("archive-v0/headroom-orphan")
        try fm.createDirectory(at: unreachable, withIntermediateDirectories: true)
        let payload = unreachable.appendingPathComponent("fixture.whl")
        try Data(repeating: 83, count: 32 * 1024 * 1024).write(to: payload)
        var stored = stat()
        try check(lstat(payload.path, &stored) == 0 && stored.st_blocks * 512 >= 32 * 1024 * 1024)
        let before = try freeBytes(fixture)
        if let message = DiskCare.testPrune(cache) {
            let after = try freeBytes(fixture)
            try check(message.contains("完了しました") && !fm.fileExists(atPath: payload.path))
            print("PASS uv cache prune: fixture allocated \(stored.st_blocks * 512) -> 0 bytes; observed volume free \(before) -> \(after)")
        } else { print("SKIP isolated uv prune: no trusted uv executable") }
    }
}
