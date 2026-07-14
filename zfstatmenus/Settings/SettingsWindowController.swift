import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let existingWindow = visibleSystemSettingsWindow() {
            present(existingWindow)
            return
        }

        if let window {
            present(window)
            return
        }

        let contentController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 790, height: 550),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZFStatMenus 设置"
        window.identifier = NSUserInterfaceItemIdentifier("ZFStatMenus.Settings")
        window.contentViewController = contentController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ZFStatMenus.SettingsWindow")
        self.window = window
        present(window)
    }

    private func visibleSystemSettingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            guard window.isVisible else { return false }
            let title = window.title.lowercased()
            return title.contains("zfstatmenus") && (title.contains("settings") || title.contains("设置"))
        }
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

enum AppWindowActions {
    @MainActor
    static func openSettings() {
        SettingsWindowController.shared.show()
    }

    @MainActor
    static func quit() {
        let alert = NSAlert()
        alert.messageText = "确定要退出 ZFStatMenus 吗？"
        alert.informativeText = "退出后将停止系统与 Token 监控。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSApp.terminate(nil)
    }
}
