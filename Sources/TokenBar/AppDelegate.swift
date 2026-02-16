import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let providerManager = ProviderManager()
    private var statusItems: [String: StatusItemController] = [:]
    private var fallbackItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Register providers
        providerManager.registerProvider(CursorProvider())
        providerManager.registerProvider(OpenAIProvider())

        // Wire visibility changes
        providerManager.onProviderVisibilityChange = { [weak self] id, visible in
            guard let self else { return }
            if visible {
                self.showStatusItem(for: id)
            } else {
                self.hideStatusItem(for: id)
            }
            self.updateFallbackVisibility()
        }

        // Wire snapshot updates
        providerManager.onStatusItemUpdate = { [weak self] id, snapshot in
            self?.statusItems[id]?.update(with: snapshot)
        }

        showFallback()
        providerManager.startPolling()
    }

    // MARK: - Status Items

    private func showStatusItem(for providerId: String) {
        guard statusItems[providerId] == nil,
              let provider = providerManager.provider(for: providerId) else { return }
        statusItems[providerId] = StatusItemController(provider: provider, manager: providerManager)
    }

    private func hideStatusItem(for providerId: String) {
        statusItems[providerId]?.remove()
        statusItems.removeValue(forKey: providerId)
    }

    // MARK: - Fallback

    private func showFallback() {
        guard fallbackItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                accessibilityDescription: "TokenBar"
            )
            button.title = " TokenBar"
            button.font = .systemFont(ofSize: 12)
        }

        let menu = NSMenu()
        let info = NSMenuItem(title: "Detecting providers...", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit TokenBar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        fallbackItem = item
    }

    private func hideFallback() {
        if let item = fallbackItem {
            NSStatusBar.system.removeStatusItem(item)
            fallbackItem = nil
        }
    }

    private func updateFallbackVisibility() {
        if statusItems.isEmpty {
            showFallback()
        } else {
            hideFallback()
        }
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
