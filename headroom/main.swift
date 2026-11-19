import AppKit
import SwiftUI

final class HeadroomApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = HeadroomModel()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenu.addItem(appMenuItem)
        let commands = NSMenu()
        commands.addItem(withTitle: "作業コピーとブランチ", action: #selector(showWorkspaces), keyEquivalent: "2").target = self
        commands.addItem(withTitle: "ウインドウを閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        commands.addItem(withTitle: "余白を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = commands
        NSApp.mainMenu = appMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "SSD")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(statusClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("余白　ストレージとメモリ")
        }
        refresh()
        timer = .scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 5
        showWindow()
    }

    private func refresh() {
        model.tick()
        let space = model.vitals.diskFree.map { String(format: "%.0f GB", Double($0) / 1e9) } ?? "未計測"
        statusItem.button?.title = " \(space)  ·  RAM \(model.vitals.pressure.label)"
        statusItem.button?.toolTip = "内蔵SSDの空き \(space)　メモリ圧 \(model.vitals.pressure.label)\nクリックして余白を開く"
    }

    @objc private func statusClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: "余白を開く", action: #selector(showWindow), keyEquivalent: "").target = self
            menu.addItem(withTitle: "作業コピーとブランチ", action: #selector(showWorkspaces), keyEquivalent: "").target = self
            menu.addItem(withTitle: "余白を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else { showWindow() }
    }

    @objc private func showWorkspaces() {
        model.page = .workspaces
        showWindow()
    }

    @objc private func showWindow() {
        if window == nil {
            let controller = NSHostingController(rootView: Dashboard(model: model))
            let panel = NSWindow(contentViewController: controller)
            panel.title = "余白"
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            panel.setContentSize(NSSize(width: 670, height: 550))
            panel.center()
            panel.setFrameAutosaveName("MacHeadroom.dashboard")
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            window = panel
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let ready = WorkspaceInventory.prepareForQuit { sender.reply(toApplicationShouldTerminate: true) }
        return ready ? .terminateNow : .terminateLater
    }
}

let application = NSApplication.shared
let delegate = HeadroomApp()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
