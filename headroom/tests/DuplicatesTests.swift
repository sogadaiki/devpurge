import Foundation

@main
struct DuplicatesTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("headroom-duplicates-" + UUID().uuidString)
        let project = fixture.appendingPathComponent(".worktrees/history")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        func file(_ relative: String, _ value: UInt8, size: Int = 16_384) throws -> URL {
            let url = project.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: value, count: size).write(to: url)
            return url
        }
        let original = try file("first.mov", 1)
        let twin = try file("publish/final.mp4", 1)
        _ = try file("different.mp4", 2)
        let alias = project.appendingPathComponent("shared.mp4")
        try fm.linkItem(at: original, to: alias)
        _ = try file("short.wav", 1, size: 4)
        for name in ["sadame/private.mp4", ".git/objects/stored.mp4", "saved.app/Contents/output.mp4",
                     "CloudStorage/vendor/local.mp4", "Dropbox - Team/work.mp4", "credentials/input.mp4",
                     "Client.xcarchive/release.mp4", "example-secret.mp4", "notes.txt"] {
            _ = try file(name, 1)
        }
        let outside = fixture.appendingPathComponent("external")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.copyItem(at: original, to: outside.appendingPathComponent("copy.mp4"))
        let directoryLink = project.appendingPathComponent("other")
        try fm.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
        try fm.createSymbolicLink(at: project.appendingPathComponent("redirect.mp4"), withDestinationURL: original)
        let report = Duplicates.scan(project, minimumBytes: 100)
        precondition(!report.partial && report.groups.count == 1, report.message)
        let group = report.groups[0]
        precondition(group.urls.count == 2 && group.fileBytes == 16_384)
        let paths = Set(group.urls.map(\.path))
        precondition(paths.contains(twin.path) && !paths.isDisjoint(with: [original.path, alias.path]))
        precondition(Duplicates.scan(project).groups.isEmpty, "8 MiB minimum is the default")
        for path in [directoryLink, project.appendingPathComponent("sadame"), project.deletingLastPathComponent(),
                     project.appendingPathComponent("saved.app/Contents")] {
            let denied = Duplicates.scan(path, minimumBytes: 100)
            precondition(denied.partial && denied.groups.isEmpty)
        }
        precondition(Duplicates.scan(project, minimumBytes: 100, nodeLimit: 1).partial)
        precondition(Duplicates.scan(project, minimumBytes: 100, byteLimit: 1024).partial)
        precondition(Duplicates.scan(project, minimumBytes: 100, seconds: 0).partial)
        let hiddenContainer = Duplicates.scan(fixture, minimumBytes: 100)
        precondition(hiddenContainer.groups.isEmpty && !hiddenContainer.partial, "Implicit traversal of hidden worktrees")
        precondition(fm.fileExists(atPath: original.path) && fm.fileExists(atPath: twin.path))
        print("PASS: SHA-256, unequal content, hard-link identity, symlink/credential/cloud/package/private exclusions, explicit worktree, size/time/node/read limits.")
    }
}
