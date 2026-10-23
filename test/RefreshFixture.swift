// Manual native acceptance fixture. Writes only inside a new, explicitly configured
// evidence directory. Keeps a deleted file open until normal app termination;
// preserves the original and supports cancellation of an unsaved-note dialog.
import Cocoa

final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var handle: FileHandle!
    let folder = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "FixtureDirectory") as! String, isDirectory: true)
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("retained original material\n".utf8).write(to: folder.appendingPathComponent("original.txt"), options: .withoutOverwriting)
            let url = folder.appendingPathComponent("disposable-working-data.bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forUpdating: url)
            let block = Data(repeating: 0x52, count: 1024 * 1024)
            for _ in 0..<128 { try handle.write(contentsOf: block) }
            try handle.synchronize()
            try FileManager.default.removeItem(at: url)
        } catch { fatalError("Fixture directory must be new: \(error)") }
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Refresh Fixture · 検証用"
        let label = NSTextField(wrappingLabelWithString: "検証専用アプリです。\n\n128 MiBの削除済みファイルを開いたまま保持しています。\n通常終了でのみ閉じます。\n\n未保存のメモがあります。終了時に保存・キャンセルを選べます。")
        label.frame = NSRect(x: 28, y: 35, width: 465, height: 170)
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "検証用メモを保存しますか？"
        alert.informativeText = "キャンセルすれば起動したまま残ります。"
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "保存して終了")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        do { try Data("saved note before normal quit\n".utf8).write(to: folder.appendingPathComponent("saved-note.txt")); try handle.close() }
        catch { return .terminateCancel }
        return .terminateNow
    }
}
let app = NSApplication.shared
let fixture = Fixture()
app.setActivationPolicy(.regular)
app.delegate = fixture
app.run()
