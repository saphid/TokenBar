import AppKit

/// Owns a single NSStatusItem in the menu bar for one provider.
/// Renders a colored non-template image: [SF Symbol icon] [XX%]
/// Click reveals a dropdown menu with usage details, refresh, settings, quit.
class StatusItemController {
    let providerId: String
    let providerName: String
    let iconSymbol: String
    let dashboardURL: URL?

    private let statusItem: NSStatusItem
    private weak var manager: ProviderManager?
    private var currentSnapshot: UsageSnapshot?
    private var appearanceObservation: NSKeyValueObservation?

    init(provider: any UsageProvider, manager: ProviderManager) {
        self.providerId = provider.id
        self.providerName = provider.name
        self.iconSymbol = provider.iconSymbol
        self.dashboardURL = provider.dashboardURL
        self.manager = manager

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Initial loading state
        if let button = statusItem.button {
            button.image = Self.renderLoading(iconSymbol: iconSymbol, providerName: providerName)
            button.title = ""
            button.toolTip = providerName
        }

        rebuildMenu()

        // Re-render when light/dark mode changes
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] _, _ in
            guard let self, let snapshot = self.currentSnapshot else { return }
            self.update(with: snapshot)
        }
    }

    func remove() {
        appearanceObservation?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func update(with snapshot: UsageSnapshot?) {
        self.currentSnapshot = snapshot

        guard let button = statusItem.button else { return }

        if let snapshot, let primary = snapshot.quotas.first {
            let text: String
            if let override = primary.menuBarOverride {
                text = override
            } else if primary.percentUsed >= 0 {
                text = "\(Int(primary.percentUsed))%"
            } else {
                text = "--"
            }

            let nsColor = self.nsColor(for: primary.statusColor)
            let isDark = button.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            button.image = Self.renderMenuBarImage(
                iconSymbol: iconSymbol,
                text: text,
                textColor: nsColor,
                isDark: isDark
            )
            button.title = ""
        } else if manager?.errors[providerId] != nil {
            button.image = Self.renderMenuBarImage(
                iconSymbol: iconSymbol,
                text: "err",
                textColor: .systemRed,
                isDark: button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            )
            button.title = ""
        }

        rebuildMenu()
    }

    // MARK: - Rendering

    private static func renderLoading(iconSymbol: String, providerName: String) -> NSImage {
        return renderMenuBarImage(iconSymbol: iconSymbol, text: "...", textColor: .secondaryLabelColor, isDark: true)
    }

    /// Renders icon + colored text into a single non-template NSImage.
    /// Non-template images preserve their colors in the menu bar.
    static func renderMenuBarImage(
        iconSymbol: String,
        text: String,
        textColor: NSColor,
        isDark: Bool
    ) -> NSImage {
        let iconColor: NSColor = isDark
            ? NSColor(white: 0.9, alpha: 1.0)
            : NSColor(white: 0.15, alpha: 1.0)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let textSize = (text as NSString).size(withAttributes: textAttrs)

        let iconWidth: CGFloat = 16
        let spacing: CGFloat = 2
        let totalWidth = iconWidth + spacing + textSize.width
        let height: CGFloat = 18

        let image = NSImage(size: NSSize(width: totalWidth, height: height))
        image.lockFocus()

        // Draw SF Symbol and tint it for the current appearance
        if let symbol = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            let sized = symbol.withSymbolConfiguration(config) ?? symbol
            let symbolRect = NSRect(x: 0, y: (height - 14) / 2, width: 14, height: 14)

            sized.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            iconColor.setFill()
            symbolRect.fill(using: .sourceAtop)
        }

        // Draw colored percentage text
        (text as NSString).draw(
            at: NSPoint(x: iconWidth + spacing, y: (height - textSize.height) / 2),
            withAttributes: textAttrs
        )

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func nsColor(for status: StatusColor) -> NSColor {
        switch status {
        case .good: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        // Header
        let headerTitle: String
        if let tier = currentSnapshot?.accountTier {
            headerTitle = "\(providerName) (\(tier))"
        } else {
            headerTitle = providerName
        }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: headerTitle,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(header)
        menu.addItem(.separator())

        // Usage details
        if let snapshot = currentSnapshot {
            for quota in snapshot.quotas {
                if quota.percentUsed >= 0 {
                    let pct = String(format: "%.1f%%", quota.percentUsed)
                    let item = NSMenuItem(title: "\(quota.label): \(pct) used", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                } else {
                    let item = NSMenuItem(title: quota.label, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }

                if let detail = quota.detailText {
                    let detailItem = NSMenuItem(title: "    \(detail)", action: nil, keyEquivalent: "")
                    detailItem.isEnabled = false
                    menu.addItem(detailItem)
                }

                if let resets = quota.resetsAt {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .none
                    let resetItem = NSMenuItem(
                        title: "    Resets: \(formatter.string(from: resets))",
                        action: nil, keyEquivalent: ""
                    )
                    resetItem.isEnabled = false
                    menu.addItem(resetItem)
                }
            }

            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            let updated = NSMenuItem(
                title: "Updated: \(timeFormatter.string(from: snapshot.capturedAt))",
                action: nil, keyEquivalent: ""
            )
            updated.isEnabled = false
            menu.addItem(updated)
        } else if let error = manager?.errors[providerId] {
            let errorItem = NSMenuItem(title: "Error: \(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        } else {
            let loading = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        }

        menu.addItem(.separator())

        if dashboardURL != nil {
            let dash = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
            dash.target = self
            menu.addItem(dash)
        }

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit TokenBar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        if let url = dashboardURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func refreshNow() {
        manager?.refreshProvider(providerId)
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
