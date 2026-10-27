import Cocoa
import WebKit

struct RefreshIdentity: Equatable {
    let pid: pid_t
    let bundle: String
    let path: String
    let launched: TimeInterval

    static func trustedFrame(source: URL?, endpoint: URL?, main: Bool) -> Bool {
        guard main, let source, let endpoint else { return false }
        return source.scheme == endpoint.scheme && source.host == endpoint.host && source.port == endpoint.port
            && source.path == "/" && source.query == nil && source.user == nil && source.password == nil
    }

    static func protection(bundle: String, name: String) -> String? {
        let text = (bundle + " " + name).lowercased()
        if bundle == "com.apple.finder" || bundle == "local.devpurge.studio" {
            return "Macとお手入れのために起動を保ちます"
        }
        if ["codex", "chatgpt", "openai", "claude", "anthropic", "terminal", "iterm", "warp", "ghostty", "alacritty", "wezterm", "visual studio code", "com.microsoft.vscode", "cursor", "xcode", "zed", "jetbrains"].contains(where: text.contains) {
            return "開発・AIの作業を守るため、ここからは終了しません"
        }
        return nil
    }

    static func read(_ app: NSRunningApplication) -> RefreshIdentity? {
        guard app.activationPolicy == .regular, !app.isTerminated, app.isFinishedLaunching,
              let id = app.bundleIdentifier, let url = app.bundleURL, let date = app.launchDate,
              url.isFileURL else { return nil }
        return RefreshIdentity(pid: app.processIdentifier, bundle: id, path: url.path, launched: date.timeIntervalSince1970)
    }

    func valid(current: RefreshIdentity?, expires: Date, now: Date = Date()) -> Bool {
        expires > now && current == self
    }
}

private final class SaveAcknowledgement: NSObject {
    weak var confirm: NSButton?
    @objc func changed(_ sender: NSButton) { confirm?.isEnabled = sender.state == .on }
}

// This bridge has no shell, file-deletion or arbitrary-PID operation. A short-lived
// native ticket identifies the exact application instance the user inspected.
final class NativeRefresh: NSObject, WKScriptMessageHandlerWithReply {
    struct Target {
        let app: NSRunningApplication
        let identity: RefreshIdentity
        let expires: Date
    }
    private var targets: [String: Target] = [:]
    private var sessions: [String: Target] = [:]
    private var inFlight = false
    var endpoint: URL?
    weak var window: NSWindow?
    private let historyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/devpurge/studio/native-refresh-history.json")

    func userContentController(_ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard RefreshIdentity.trustedFrame(source: message.frameInfo.request.url, endpoint: endpoint, main: message.frameInfo.isMainFrame),
              let data = message.body as? [String: String] else {
            replyHandler(nil, "この画面からは操作できません"); return
        }
        let reply: ([String: Any]) -> Void = { replyHandler($0, nil) }
        if (message.body as? [String: Any])?["action"] as? String == "folder-access" {
            let panel = NSOpenPanel()
            panel.title = "作業データを照合する場所を選択"
            panel.message = "デスクトップを選択して読み取りを許可します。この操作ではデータを削除しません。"
            panel.prompt = "読み取りを許可"
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            guard let window else { replyHandler(nil, "アプリの画面を開いてください"); return }
            panel.beginSheetModal(for: window) { result in
                reply(["granted": result == .OK])
            }
            return
        }
        do {
            switch data["action"] {
            case "list":
                targets = targets.count > 256 ? [:] : targets.filter { $0.value.expires > Date() }
                var rows: [[String: Any]] = []
                for app in NSWorkspace.shared.runningApplications {
                    guard let identity = RefreshIdentity.read(app) else { continue }
                    let ticket = UUID().uuidString
                    targets[ticket] = Target(app: app, identity: identity, expires: Date().addingTimeInterval(300))
                    let name = app.localizedName ?? identity.bundle
                    rows.append(["ticket": ticket, "pid": identity.pid, "name": name,
                        "protected": RefreshIdentity.protection(bundle: identity.bundle, name: name) ?? ""])
                }
                reply(["apps": rows, "sessions": Array(sessions.keys)])
            case "focus":
                let target = try checked(data["ticket"])
                reply(["activated": target.app.activate(options: [.activateAllWindows])])
            case "quit":
                guard !inFlight else { throw failure("別のアプリを確認中です") }
                let target = try checked(data["ticket"])
                if let reason = RefreshIdentity.protection(bundle: target.identity.bundle, name: target.app.localizedName ?? "") { throw failure(reason) }
                guard let window else { throw failure("ウィンドウを開き直してください") }
                inFlight = true
                let alert = NSAlert()
                let name = target.app.localizedName ?? target.identity.bundle
                alert.messageText = "\(name)を、ひと休みさせますか？"
                alert.informativeText = "このアプリのすべてのウィンドウを通常終了します。保存・書き出し・アップロードを終えてから進んでください。\n\nアプリによっては保存確認が出ません。終了を断られた場合は、そのまま残します。空き容量は実測で確認します。"
                alert.addButton(withTitle: "保存を確認して通常終了")
                alert.addButton(withTitle: "今は残す")
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
                let acknowledgement = SaveAcknowledgement()
                acknowledgement.confirm = alert.buttons[0]
                let check = NSButton(checkboxWithTitle: "必要な作業は保存済みで、実行中の処理もありません", target: acknowledgement, action: #selector(SaveAcknowledgement.changed(_:)))
                check.setFrameSize(NSSize(width: 440, height: 28))
                alert.accessoryView = check
                alert.buttons[0].isEnabled = false
                alert.beginSheetModal(for: window) { [self, acknowledgement] answer in
                    _ = acknowledgement
                    guard answer == .alertFirstButtonReturn, check.state == .on else {
                        inFlight = false; reply(["status": "cancelled"]); return
                    }
                    guard target.identity.valid(current: RefreshIdentity.read(target.app), expires: target.expires) else {
                        inFlight = false; replyHandler(nil, "アプリが再起動されたか、確認期限が切れました。再チェックしてください"); return
                    }
                    measure { before, error in
                        guard let before else { self.inFlight = false; replyHandler(nil, error); return }
                        // Measurement can take time; revalidate immediately before quit.
                        guard target.identity.valid(current: RefreshIdentity.read(target.app), expires: target.expires) else {
                            self.inFlight = false; replyHandler(nil, "アプリの状態が変わったため終了しませんでした"); return
                        }
                        let id = UUID().uuidString
                        var record: [String: Any] = ["id": id, "name": name, "pid": target.identity.pid,
                            "at": ISO8601DateFormatter().string(from: Date()), "status": "prepared", "before": before]
                        do { try self.save(record) } catch { self.inFlight = false; replyHandler(nil, "記録できないため終了しませんでした"); return }
                        self.targets.removeValue(forKey: data["ticket"] ?? "")
                        self.sessions[id] = target
                        guard target.app.terminate() else {
                            record["status"] = "refused"
                            self.finish(record, replyHandler); return
                        }
                        self.waitForExit(id, target, record, remaining: 15, replyHandler)
                    }
                }
            case "check":
                guard !inFlight, let id = data["id"], let target = sessions[id],
                      let record = try history().first(where: { $0["id"] as? String == id }),
                      record["status"] as? String == "waiting" else { throw failure("起動中の確認記録がありません。いまの膨らみを再チェックしてください") }
                inFlight = true
                waitForExit(id, target, record, remaining: 0, replyHandler)
            default: throw failure("対応していない操作です")
            }
        } catch { replyHandler(nil, error.localizedDescription) }
    }

    private func checked(_ ticket: String?) throws -> Target {
        guard let ticket, let target = targets[ticket],
              target.identity.valid(current: RefreshIdentity.read(target.app), expires: target.expires) else {
            throw failure("確認期限が切れたか、アプリが入れ替わりました。もう一度チェックしてください")
        }
        return target
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "StudioRefresh", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func history() throws -> [[String: Any]] {
        if !FileManager.default.fileExists(atPath: historyURL.path) { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [[String: Any]] else { throw failure("記録を読めません") }
        return rows
    }
    private func save(_ record: [String: Any]) throws {
        var rows = try history().filter { $0["id"] as? String != record["id"] as? String }
        rows.insert(record, at: 0)
        let data = try JSONSerialization.data(withJSONObject: Array(rows.prefix(60)), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: historyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }
    private func finish(_ record: [String: Any], _ reply: @escaping (Any?, String?) -> Void) {
        inFlight = false
        do { try save(record); reply(record, nil) }
        catch { reply(nil, "操作後の記録を保存できませんでした。状態を再チェックしてください") }
    }
    private func waitForExit(_ id: String, _ target: Target, _ initial: [String: Any], remaining: Int,
        _ reply: @escaping (Any?, String?) -> Void) {
        if target.app.isTerminated {
            measure { after, error in
                var record = initial
                record["status"] = after == nil ? "exited_unmeasured" : "completed"
                record["after"] = after
                record["ended_at"] = ISO8601DateFormatter().string(from: Date())
                if let error { record["error"] = error }
                self.finish(record, reply)
            }
        } else if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.waitForExit(id, target, initial, remaining: remaining - 1, reply)
            }
        } else {
            var record = initial
            record["status"] = "waiting" // Save dialog, refusal or long shutdown; never escalate.
            finish(record, reply)
        }
    }
    private func measure(_ completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let endpoint, let url = URL(string: "/api/pressure", relativeTo: endpoint)?.absoluteURL else { completion(nil, "診断エンジンに接続できません"); return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.fragment, forHTTPHeaderField: "X-Studio-Token")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        session.dataTask(with: request) { data, response, _ in
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard (response as? HTTPURLResponse)?.statusCode == 200, let s = object?["system"] as? [String: Any], s["free"] is NSNumber else {
                    completion(nil, object?["error"] as? String ?? "容量を計測できませんでした"); return
                }
                var compact = s.filter { ["free", "swap_used", "swap_reserved", "vm_volume_bytes", "boot_epoch"].contains($0.key) }
                compact["at"] = object?["at"]
                compact["deleted_open_bytes"] = (object?["deleted_open"] as? [String: Any])?["bytes"]
                completion(compact, nil)
            }
        }.resume()
    }
}
