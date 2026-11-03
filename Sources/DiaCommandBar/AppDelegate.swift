import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: cmdKey)
    private let commandBar = CommandBarController()
    private var statusItem: NSStatusItem?
    private var loginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKey.onPress = { [weak self] in self?.commandBar.toggle() }

        // Dia が前面のときだけ ⌘T を奪う。それ以外のアプリでは登録自体を外す。
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        updateHotKey(frontmost: NSWorkspace.shared.frontmostApplication)

        // scripts/install.sh から --enable-login-item 付きで起動されたらログイン項目に登録する
        if CommandLine.arguments.contains("--enable-login-item"), SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() } catch { NSLog("[DiaCommandBar] login item error: \(error)") }
        }

        setUpStatusItem()
    }

    @objc private func frontmostAppChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        updateHotKey(frontmost: app)
    }

    private func updateHotKey(frontmost app: NSRunningApplication?) {
        if app?.bundleIdentifier == DiaBridge.bundleID {
            hotKey.register()
            commandBar.refreshState()
        } else {
            hotKey.unregister()
            commandBar.hide()
        }
        statusItem?.button?.appearsDisabled = !hotKey.isRegistered
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Dia Command Bar")
        item.button?.appearsDisabled = !hotKey.isRegistered
        let menu = NSMenu()
        menu.addItem(withTitle: "Dia Command Bar", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        loginItem = login
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[DiaCommandBar] login item error: \(error)")
        }
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
