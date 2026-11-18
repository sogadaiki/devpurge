import Darwin
import Foundation

@main
struct WorkspaceTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("HeadroomWorkspaceTests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func directory(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func file(_ relative: String, seed: UInt8) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0) ^ seed }).write(to: url)
            return url
        }
        func allocation(_ url: URL) -> Int64 {
            var state = stat()
            precondition(lstat(url.path, &state) == 0)
            return Int64(state.st_blocks) * 512
        }

        let bundle = try directory("video/.render-bundle")
        let original = try file("video/original.mp4", seed: 6)
        try fm.linkItem(at: original, to: bundle.appendingPathComponent("shared.mp4"))
        let compiled = try file("video/.render-bundle/player.js", seed: 18)
        _ = try file("video/.render-bundle/.env.local", seed: 14)
        let game = try directory("game/.godot")
        _ = try file("game/.godot/imported.ctex", seed: 42)
        let build = try directory("game/build")
        _ = try file("game/build/kept.ipa", seed: 56)
        let deps = try directory("web/node_modules")
        let env = try directory("python/.venv")
        let pytest = try directory("python/.pytest_cache")
        let worktree = try directory(".worktrees/app")
        _ = try directory(".worktrees/app/.next")
        _ = try directory("web/node_modules/pkg/node_modules")
        _ = try file("web/node_modules/pkg/node_modules/entry.js", seed: 35)
        _ = try directory("sadame/node_modules")
        _ = try directory(".private-project/.next")
        _ = try directory("Mobile Documents/app/node_modules")
        _ = try directory("edited.app/Contents/.next")
        _ = try directory("game/archives/dist")
        _ = try directory("cycle")
        try fm.createSymbolicLink(at: root.appendingPathComponent("cycle/node_modules"), withDestinationURL: root)
        try fm.createSymbolicLink(at: bundle.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        let result = WorkspaceScan.scan(root)
        precondition(!result.partial, result.message)
        precondition(Set(result.rows.map { $0.url.path }) == Set([bundle, game, build, deps, env, pytest].map { $0.path }), result.message)
        precondition(result.rows.first { $0.url.path == bundle.path }?.bytes == allocation(compiled))
        precondition(result.rows.first { $0.url.path == build.path }?.bytes == 0)
        precondition(WorkspaceScan.scan(root, nodeLimit: 2, seconds: 10).partial)
        precondition(WorkspaceScan.scan(root, nodeLimit: 10_000, seconds: 0).partial)
        let viaLink = WorkspaceScan.scan(root.appendingPathComponent("cycle/node_modules"))
        precondition(viaLink.rows.isEmpty && viaLink.partial)
        let forbidden = WorkspaceScan.scan(root.appendingPathComponent("sadame/node_modules"))
        precondition(forbidden.rows.isEmpty && forbidden.partial)
        let protected = WorkspaceScan.scan(root.appendingPathComponent("edited.app"))
        precondition(protected.rows.isEmpty && protected.partial)
        let selectedWorktree = WorkspaceScan.scan(worktree)
        precondition(!selectedWorktree.partial && selectedWorktree.rows.map { $0.url.lastPathComponent } == [".next"])
        precondition(fm.fileExists(atPath: original.path))
        print("Workspace tests passed")
    }
}
