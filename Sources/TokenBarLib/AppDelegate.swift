import AppKit
import SwiftUI

/// Notification posted by status items to open the settings window.
public extension Notification.Name {
    static let openTokenBarSettings = Notification.Name("com.tokenbar.openSettings")
    static let reauthenticateProvider = Notification.Name("com.tokenbar.reauthenticateProvider")
    static let testConfettiAllBubbles = Notification.Name("com.tokenbar.testConfettiAllBubbles")
}

public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let providerManager = ProviderManager()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var oauthAuthenticator: ClaudeOAuthAuthenticator?
    private let confettiController = ConfettiWindowController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        TBLog.log("App launched. Log file: \(TBLog.logPath)", category: "app")

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenSettings(_:)),
            name: .openTokenBarSettings, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleReauthenticate(_:)),
            name: .reauthenticateProvider, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAppearanceChanged),
            name: .appearanceModeChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTestConfetti),
            name: .testConfettiAllBubbles, object: nil
        )

        providerManager.onStatusChange = { [weak self] in
            self?.updateMenuBarIcon()
        }

        providerManager.onTokensRestored = { [weak self] providerId, origin in
            TBLog.log("Confetti triggered for \(providerId)", category: "confetti")
            if let manualOrigin = origin {
                // Easter egg / manual trigger — shoot upward from click point
                self?.confettiController.showConfetti(from: manualOrigin, shootingDown: false)
            } else {
                // Provider restoration — shoot downward from menu bar bubble
                let point = self?.screenPositionForProvider(providerId)
                self?.confettiController.showConfetti(from: point, shootingDown: true)
            }
        }

        setupStatusItem()
        providerManager.performStartup()

        // Fetch web favicons for providers that lack a local .app or extension icon.
        // Runs in background; refreshes menu bar when new icons arrive.
        ProviderCatalog.downloadMissingIcons { [weak self] in
            self?.updateMenuBarIcon()
        }
    }

    // MARK: - Single Status Item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.image = StatusItemController.renderMenuBarImage(
                iconSymbol: "gauge.with.dots.needle.bottom.50percent",
                text: "",
                textColor: .secondaryLabelColor,
                isDark: button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            )
            button.toolTip = "TokenBar"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let enabledConfigs = providerManager.sortedEnabledConfigs

        // Build items for each enabled provider — show short/long term windows
        var items: [(iconSymbol: String, name: String, text: String, textColor: NSColor, appIcon: NSImage?)] = []
        for config in enabledConfigs {
            let typeInfo = ProviderCatalog.type(for: config.typeId)
            let icon = typeInfo?.iconSymbol ?? "questionmark.circle"
            let name = shortName(for: config)
            let appImg = ProviderCatalog.appIcon(for: config.typeId)

            if let snapshot = providerManager.snapshots[config.id] {
                let (text, color, _) = menuBarText(for: snapshot)
                items.append((icon, name, text, color, appImg))
            } else if providerManager.errors[config.id] != nil {
                items.append((icon, name, "!", .systemRed, appImg))
            } else if providerManager.loadingProviders.contains(config.id) {
                items.append((icon, name, "...", .secondaryLabelColor, appImg))
            } else if typeInfo?.category == .detectedOnly {
                items.append((icon, name, "", .secondaryLabelColor, appImg))
            } else {
                items.append((icon, name, "...", .secondaryLabelColor, appImg))
            }
        }

        let image: NSImage
        if items.isEmpty {
            image = StatusItemController.renderMenuBarImage(
                iconSymbol: "gauge.with.dots.needle.bottom.50percent",
                text: "",
                textColor: .secondaryLabelColor,
                isDark: isDark
            )
        } else {
            image = StatusItemController.renderCombinedMenuBarImage(
                items: items,
                isDark: isDark,
                showIcon: providerManager.showIconInMenuBar,
                showName: providerManager.showNameInMenuBar
            )
        }

        button.image = image
        // Explicitly set the status item width to match the rendered image.
        // variableLength (-1) doesn't reliably resize when the image changes dynamically.
        let targetWidth = image.size.width + 4
        statusItem?.length = targetWidth
        TBLog.log("updateMenuBarIcon: \(items.count) items, image=\(Int(image.size.width))pt, statusItem.length=\(Int(targetWidth))", category: "render")
    }

    /// Labels for supplementary quotas that don't block primary access.
    private static let supplementaryLabels: Set<String> = ["Credits", "On-Demand"]

    /// Builds compact text for a provider's menu bar display.
    /// If blocked: shows "↻2h" countdown to reset.
    /// If available: shows the most constraining primary quota percentage.
    private func menuBarText(for snapshot: UsageSnapshot) -> (text: String, color: NSColor, useTimerIcon: Bool) {
        let trackable = snapshot.quotas.filter { $0.percentUsed >= 0 }
        let primary = trackable.filter { !Self.supplementaryLabels.contains($0.label) }
        let exhaustedPrimary = primary.filter { $0.percentUsed >= 100 }

        // If any primary quota is exhausted, user is blocked — show countdown
        if !exhaustedPrimary.isEmpty {
            let blocking = exhaustedPrimary.max(by: { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) })
                ?? exhaustedPrimary[0]
            if let resetsAt = blocking.resetsAt, resetsAt.timeIntervalSinceNow > 0 {
                return ("↻" + formatCountdown(resetsAt), nsColor(for: .critical), true)
            }
            return ("↻...", nsColor(for: .critical), true)
        }

        // Not blocked — show the most constraining primary quota
        if let mostConstrained = primary.max(by: { $0.percentUsed < $1.percentUsed }) {
            return (quotaText(mostConstrained), nsColor(for: mostConstrained.statusColor), false)
        }

        // Fallback: info-only quotas
        if let override = snapshot.quotas.first?.menuBarOverride {
            return (override, .secondaryLabelColor, false)
        }
        return ("--", .secondaryLabelColor, false)
    }

    private func quotaText(_ quota: UsageQuota) -> String {
        if quota.percentUsed >= 100, let resetsAt = quota.resetsAt {
            if resetsAt.timeIntervalSinceNow <= 0 { return "100%" }
            return "↻" + formatCountdown(resetsAt)
        }
        return "\(Int(quota.percentUsed))%"
    }

    private func formatCountdown(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "now" }
        let totalMinutes = Int(remaining / 60)
        let hours = totalMinutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(totalMinutes)m"
    }

    private func worstColor(_ quotas: [UsageQuota]) -> NSColor {
        var worst: StatusColor = .unknown
        for q in quotas {
            let s = q.statusColor
            if s == .critical { return nsColor(for: .critical) }
            if s == .warning { worst = .warning }
            else if s == .good && worst == .unknown { worst = .good }
        }
        return nsColor(for: worst)
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let enabledConfigs = providerManager.sortedEnabledConfigs

        if enabledConfigs.isEmpty {
            let noProviders = NSMenuItem(title: "No providers enabled", action: nil, keyEquivalent: "")
            noProviders.isEnabled = false
            menu.addItem(noProviders)
        } else {
            let providerData = enabledConfigs.map { config -> (id: String, name: String, icon: String, appIcon: NSImage?, snapshot: UsageSnapshot?, error: String?, isLoading: Bool) in
                let typeInfo = ProviderCatalog.type(for: config.typeId)
                return (
                    id: config.id,
                    name: config.label,
                    icon: typeInfo?.iconSymbol ?? "questionmark.circle",
                    appIcon: ProviderCatalog.appIcon(for: config.typeId),
                    snapshot: providerManager.snapshots[config.id],
                    error: providerManager.errors[config.id],
                    isLoading: providerManager.loadingProviders.contains(config.id)
                )
            }

            let gridView = MenuBarDropdownGridView(providers: providerData)
            let hosting = SelfSizingHostingView(rootView: gridView)
            let menuItem = NSMenuItem()
            menuItem.view = hosting
            menu.addItem(menuItem)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh All", action: #selector(refreshAll), keyEquivalent: "r")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings...", action: #selector(handleOpenSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit TokenBar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Settings Window

    @objc private func handleOpenSettings(_ notification: Any) {
        showSettings()
    }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView().environmentObject(providerManager)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: view)
            window.title = "TokenBar Settings"
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.appearance = providerManager.appearanceMode.nsAppearance
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleAppearanceChanged() {
        settingsWindow?.appearance = providerManager.appearanceMode.nsAppearance
        updateMenuBarIcon()
    }

    // MARK: - Actions

    @objc private func refreshAll() {
        Task { await providerManager.pollAllProviders() }
    }

    @objc private func handleReauthenticate(_ notification: Notification) {
        let providerId = notification.userInfo?["providerId"] as? String ?? "claude-code"
        guard providerId == "claude-code" else { return }

        // Close the menu before opening browser
        statusItem?.menu?.cancelTracking()

        let authenticator = ClaudeOAuthAuthenticator()
        oauthAuthenticator = authenticator
        authenticator.authenticate { [weak self] success in
            self?.oauthAuthenticator = nil
            if success {
                TBLog.log("OAuth re-auth succeeded, refreshing \(providerId)", category: "oauth")
                self?.providerManager.refreshProvider(providerId)
            } else {
                TBLog.log("OAuth re-auth failed for \(providerId)", category: "oauth")
            }
        }
    }

    @objc private func handleTestConfetti() {
        let enabledConfigs = providerManager.sortedEnabledConfigs
        for (i, config) in enabledConfigs.enumerated() {
            let delay = Double(i) * 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if let point = self?.screenPositionForProvider(config.id) {
                    TBLog.log("Test confetti for \(config.id) at (\(Int(point.x)), \(Int(point.y)))", category: "confetti")
                    self?.confettiController.showConfetti(from: point, shootingDown: true)
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func shortName(for config: ProviderInstanceConfig) -> String {
        switch config.typeId {
        case "claude-code": return "Claude"
        case "github-copilot": return "Copilot"
        case "openai": return "OpenAI"
        default: return config.label
        }
    }

    /// Screen coordinate of the status item button center (for confetti origin).
    private var statusItemScreenCenter: CGPoint? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = window.convertToScreen(buttonFrame)
        return CGPoint(x: screenFrame.midX, y: screenFrame.midY)
    }

    /// Computes the screen center of a specific provider's pill in the menu bar.
    /// Replicates the layout math from `renderCombinedMenuBarImage`.
    func screenPositionForProvider(_ providerId: String) -> CGPoint? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenOrigin = window.convertToScreen(buttonFrame)

        let enabledConfigs = providerManager.sortedEnabledConfigs
        guard let targetIndex = enabledConfigs.firstIndex(where: { $0.id == providerId }) else {
            return statusItemScreenCenter
        }

        // Replicate the layout constants from renderCombinedMenuBarImage
        let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let nameFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let iconWidth: CGFloat = 16
        let iconNameSpacing: CGFloat = 3
        let nameTextSpacing: CGFloat = 4
        let itemGap: CGFloat = 6
        let pillPadH: CGFloat = 7
        let showIcon = providerManager.showIconInMenuBar
        let showName = providerManager.showNameInMenuBar

        var x: CGFloat = 0
        for (i, config) in enabledConfigs.enumerated() {
            let typeInfo = ProviderCatalog.type(for: config.typeId)
            let name = shortName(for: config)

            let nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: NSColor.white]
            let nameSize = (showName && !name.isEmpty) ? (name as NSString).size(withAttributes: nameAttrs) : CGSize.zero

            // Compute status text the same way updateMenuBarIcon does
            var text = "..."
            if let snapshot = providerManager.snapshots[config.id] {
                let (t, _, _) = menuBarText(for: snapshot)
                text = t
            } else if providerManager.errors[config.id] != nil {
                text = "!"
            } else if typeInfo?.category == .detectedOnly {
                text = ""
            }

            let textAttrs: [NSAttributedString.Key: Any] = [.font: statusFont, .foregroundColor: NSColor.white]
            let textSize = text.isEmpty ? CGSize.zero : (text as NSString).size(withAttributes: textAttrs)

            var contentWidth: CGFloat = 0
            if showIcon { contentWidth += iconWidth }
            if showName && !name.isEmpty {
                if contentWidth > 0 { contentWidth += iconNameSpacing }
                contentWidth += nameSize.width
            }
            if !text.isEmpty {
                if contentWidth > 0 { contentWidth += nameTextSpacing }
                contentWidth += textSize.width
            }

            let pillW = pillPadH + contentWidth + pillPadH

            if i == targetIndex {
                let pillCenterX = x + pillW / 2
                // screenOrigin is the button frame in screen coords (bottom-left origin)
                return CGPoint(x: screenOrigin.minX + pillCenterX, y: screenOrigin.midY)
            }

            x += pillW
            if i < enabledConfigs.count - 1 { x += itemGap }
        }

        return statusItemScreenCenter
    }

    private func nsColor(for status: StatusColor) -> NSColor {
        switch status {
        case .good: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }
}
