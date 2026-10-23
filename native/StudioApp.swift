import Cocoa
import WebKit

// EOF on our pipe drains accepted operations before the engine exits. Never
// kill a PID or terminate an engine that belongs to an existing CLI session.
final class StudioApp: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var loading: NSStackView!
    private var status: NSTextField!
    private var retry: NSButton!
    private var process: Process?
    private var input: Pipe?
    private var endpoint: URL?
    private var generation = 0
    private var ready = false
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.isHidden = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(red: 0.96, green: 0.96, blue: 0.93, alpha: 1).cgColor
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let title = NSTextField(labelWithString: "Macに、ひと息。")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = NSColor(red: 0.15, green: 0.28, blue: 0.23, alpha: 1)
        status = NSTextField(wrappingLabelWithString: "お手入れの準備をしています…")
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 440
        retry = NSButton(title: "もう一度開く", target: self, action: #selector(startEngine))
        retry.bezelStyle = .rounded
        retry.isHidden = true
        loading = NSStackView(views: [title, status, retry])
        loading.orientation = .vertical
        loading.spacing = 20
        loading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(loading)
        NSLayoutConstraint.activate([
            loading.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            loading.widthAnchor.constraint(lessThanOrEqualToConstant: 480)
        ])
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "devpurge Studio"
        window.subtitle = "このMacで、小さなお手入れ。"
        window.minSize = NSSize(width: 850, height: 640)
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("StudioWindow")
        if let image = Bundle.main.url(forResource: "companion", withExtension: "png", subdirectory: "engine/ui/assets") {
            NSApp.applicationIconImage = NSImage(contentsOf: image)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startEngine()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "devpurge Studioについて", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "devpurge Studioを隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "devpurge Studioを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let edit = NSMenu(title: "編集")
        for (title, selector, key) in [("取り消す", "undo:", "z"), ("カット", "cut:", "x"), ("コピー", "copy:", "c"), ("ペースト", "paste:", "v"), ("すべてを選択", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)
        let view = NSMenu(title: "表示")
        view.addItem(withTitle: "画面を再読み込み", action: #selector(reload), keyEquivalent: "r")
        let viewItem = NSMenuItem(); viewItem.submenu = view; main.addItem(viewItem)
        let windows = NSMenu(title: "ウィンドウ")
        windows.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(); windowItem.submenu = windows; main.addItem(windowItem)
        NSApp.windowsMenu = windows
        let help = NSMenu(title: "ヘルプ")
        help.addItem(withTitle: "毎日のお手入れガイド", action: #selector(showGuide), keyEquivalent: "?")
        let helpItem = NSMenuItem(); helpItem.submenu = help; main.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    @objc private func startEngine() {
        generation += 1
        let attempt = generation
        ready = false
        endpoint = nil
        webView.isHidden = true
        loading.isHidden = false
        retry.isHidden = true
        status.stringValue = "お手入れの準備をしています…"
        if let process, process.isRunning {
            fail("前の処理を終了しています。少し待ってから、もう一度開いてください。")
            return
        }
        guard let python = Bundle.main.object(forInfoDictionaryKey: "StudioPython") as? String,
              FileManager.default.isExecutableFile(atPath: python),
              let script = Bundle.main.url(forResource: "studio", withExtension: "py", subdirectory: "engine/lib") else {
            fail("診断エンジンを起動できません。Pythonの場所が変わった場合は、devpurge Studioを再インストールしてください。")
            return
        }
        let task = Process()
        let output = Pipe()
        let channel = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = ["-I", "-B", script.path, "studio", "--native"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        task.environment = ["HOME": home, "PATH": "/usr/local/bin:/opt/homebrew/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        task.currentDirectoryURL = script.deletingLastPathComponent()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = channel
        process = task
        input = channel
        do { try task.run() }
        catch { fail("診断エンジンを起動できませんでした。アプリを再インストールしてください。"); return }
        output.fileHandleForWriting.closeFile()
        channel.fileHandleForReading.closeFile()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var firstLine = Data()
            while firstLine.count < 8192 {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                firstLine.append(data)
                if firstLine.contains(10) { break }
            }
            let line = firstLine.prefix { $0 != 10 }
            let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            DispatchQueue.main.async {
                guard let self, self.generation == attempt, !self.quitting else { return }
                guard let raw = object?["url"] as? String, let url = URL(string: raw),
                      let owned = object?["owned"] as? Bool, self.validEndpoint(url) else {
                    self.fail("診断エンジンの準備ができませんでした。別の診断や終了処理が完了してから、もう一度開いてください。")
                    return
                }
                self.connect(url, attempt: attempt)
                if owned {
                    task.terminationHandler = { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self, self.generation == attempt, !self.quitting else { return }
                            self.fail("診断エンジンが終了しました。保存済みの記録は残っています。もう一度開いてください。")
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.generation == attempt, !self.ready, !self.quitting else { return }
            self.fail("起動に時間がかかっています。少し待ってから、もう一度開いてください。")
        }
    }

    private func validEndpoint(_ url: URL) -> Bool {
        guard url.scheme == "http", url.host == "127.0.0.1", url.user == nil, url.password == nil,
              let port = url.port, (1...65535).contains(port), url.path == "/", url.query == nil,
              let token = url.fragment, (20...128).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }
    }

    private func connect(_ url: URL, attempt: Int) {
        guard let health = URL(string: "/api/health", relativeTo: url)?.absoluteURL else { return }
        var request = URLRequest(url: health, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue(url.fragment, forHTTPHeaderField: "X-Studio-Token")
        // Never forward the local capability to a redirect destination.
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        session.dataTask(with: request) { [weak self] data, response, _ in
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self, self.generation == attempt, !self.quitting else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      object?["app"] as? String == "devpurge-studio", object?["protocol"] as? Int == 1,
                      object?["closing"] as? Bool == false else {
                    self.fail("診断エンジンに接続できません。終了処理中なら少し待ってください。古いStudioをターミナルで起動している場合は終了してから、もう一度開いてください。")
                    return
                }
                self.endpoint = url
                self.webView.load(URLRequest(url: url))
            }
        }.resume()
    }

    private func fail(_ message: String) {
        ready = false
        input?.fileHandleForWriting.closeFile()
        input = nil
        loading.isHidden = false
        webView.isHidden = true
        status.stringValue = message
        retry.isHidden = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url, let endpoint,
              target.scheme == endpoint.scheme, target.host == endpoint.host,
              target.port == endpoint.port, target.user == nil, target.password == nil,
              target.path == "/", target.query == nil, navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        loading.isHidden = true
        webView.isHidden = false
        window.makeFirstResponder(webView)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { fail("画面を開けませんでした。もう一度開いてください。") }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    @objc private func reload() { if ready { webView.reload() } else { startEngine() } }
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "devpurge Studio"
        alert.informativeText = "このMacのための、お手入れアプリ。\n\n診断・整理・復元はMacの中で処理します。\nアカウント登録やクラウドへの送信はありません。\n\nバージョン \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "")"
        alert.runModal()
    }
    @objc private func showGuide() {
        let alert = NSAlert()
        alert.messageText = "毎日、ひとつだけ整える。"
        alert.informativeText = "① 普段は「今日のお手入れ」\nスキャンして、増えたものを一つ確認。残す判断でも完了です。\n\n② 急に容量が減ったら「リフレッシュ」\n今の状態を測る → 作業を保存して該当アプリを終了 → もう一度測る。\n\n③ 制作が終わったら「制作を完了する」\n完成品と再編集の素材を先に残し、中間物を確認します。\n\nゴミ箱への移動だけでは空き容量は増えません。復元は「整理と復元の履歴」から。アプリを閉じても記録は残ります。"
        alert.runModal()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        input?.fileHandleForWriting.closeFile()
        input = nil
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

let app = NSApplication.shared
let delegate = StudioApp()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
