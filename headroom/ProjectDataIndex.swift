import Foundation

struct DataIndexReport: Decodable {
    let root: String
    let entries: [DataIndexEntry]
    let warnings: [String]
}

struct DataIndexEntry: Decodable, Identifiable {
    var path: String
    var role = "unknown"
    var owner = ""
    var reason = ""
    var decision = "review"
    var detail = ""
    var keeper: String?
    var rebuild: String?
    var until: String?
    var recorded = false
    var version: String? = "new"
    var backupInclusion: String?
    var id: String { path }

    var backupLabel: String {
        switch backupInclusion {
        case "included": return "バックアップ対象"
        case "excluded": return "バックアップ対象外"
        default: return "バックアップ対象は未確認"
        }
    }

    enum CodingKeys: String, CodingKey {
        case path, role, owner, reason, decision, detail, keeper, rebuild, until, recorded, backupInclusion
        case version = "revision"
    }
}

struct DataIndexVerification: Decodable {
    let decision: String
    let detail: String
}

enum ProjectDataIndex {
    private struct Projects: Decodable { let projects: [String] }

    private static func run<T: Decodable>(_ arguments: [String], writing: Bool = false) throws -> T {
        let script = Bundle.main.url(forResource: "project_index", withExtension: "py", subdirectory: "devpurge/lib")
        return try WorkspaceInventory.run(arguments + ["--json"], accepting: [0], writing: writing,
            readToken: writing ? nil : WorkspaceInventory.readToken(.projectIndex), script: script)
    }

    static func registeredProjects() throws -> [String] {
        let result: Projects = try run(["projects"])
        return result.projects
    }

    static func list(_ root: String) throws -> DataIndexReport {
        try run(["list", root])
    }

    static func record(_ root: String, entry: DataIndexEntry) throws -> DataIndexReport {
        var args = ["record", root, "--path=" + entry.path, "--role=" + entry.role,
                    "--owner=" + entry.owner, "--reason=" + entry.reason, "--expected=" + (entry.version ?? "new")]
        for (flag, value) in [("--keeper=", entry.keeper), ("--rebuild=", entry.rebuild), ("--until=", entry.until)] {
            if let value, !value.isEmpty { args.append(flag + value) }
        }
        return try run(args, writing: true)
    }

    static func verify(_ root: String, path: String, expected: String? = nil) throws -> DataIndexVerification {
        var args = ["verify", root, "--path=" + path]
        if let expected { args.append("--expected=" + expected) }
        return try run(args)
    }
}
