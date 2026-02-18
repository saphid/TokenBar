import AppKit
import SwiftUI

/// Owns a single NSStatusItem in the menu bar for one provider.
/// Renders a colored non-template image: [SF Symbol icon] [XX%]
/// Click reveals a rich dropdown menu with progress bars and usage details.
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

        if let button = statusItem.button {
            button.image = Self.renderMenuBarImage(
                iconSymbol: iconSymbol, text: "...",
                textColor: .secondaryLabelColor, isDark: true
            )
            button.title = ""
            button.toolTip = providerName
        }

        rebuildMenu()

        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] _, _ in
            guard let self else { return }
            self.update(with: self.currentSnapshot)
        }
    }

    func remove() {
        appearanceObservation?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func update(with snapshot: UsageSnapshot?) {
        self.currentSnapshot = snapshot
        guard let button = statusItem.button else { return }

        let isDark = button.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let isLoading = manager?.loadingProviders.contains(providerId) ?? false

        if isLoading && snapshot == nil {
            // First load — show animated dots
            button.image = Self.renderMenuBarImage(
                iconSymbol: iconSymbol, text: "...",
                textColor: .secondaryLabelColor, isDark: isDark
            )
            button.title = ""
        } else if isLoading {
            // Refreshing with existing data — show sync icon
            button.image = Self.renderMenuBarImage(
                iconSymbol: "arrow.triangle.2.circlepath",
                text: "",
                textColor: .systemBlue, isDark: isDark
            )
            button.title = ""
        } else if let snapshot, let primary = snapshot.quotas.first {
            let text: String
            if let override = primary.menuBarOverride {
                text = override
            } else if primary.percentUsed >= 0 {
                text = "\(Int(primary.percentUsed))%"
            } else {
                text = "--"
            }

            let nsColor = self.nsColor(for: primary.statusColor)
            button.image = Self.renderMenuBarImage(
                iconSymbol: iconSymbol, text: text,
                textColor: nsColor, isDark: isDark
            )
            button.title = ""
        } else if manager?.errors[providerId] != nil {
            button.image = Self.renderMenuBarImage(
                iconSymbol: "exclamationmark.triangle.fill",
                text: "",
                textColor: .systemRed, isDark: isDark
            )
            button.title = ""
        }

        rebuildMenu()
    }

    // MARK: - Menu Bar Icon Rendering

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
        let textSize = text.isEmpty ? .zero : (text as NSString).size(withAttributes: textAttrs)

        let iconWidth: CGFloat = 16
        let spacing: CGFloat = text.isEmpty ? 0 : 2
        let totalWidth = iconWidth + spacing + textSize.width
        let height: CGFloat = 18

        let image = NSImage(size: NSSize(width: totalWidth, height: height))
        image.lockFocus()

        if let symbol = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            let sized = symbol.withSymbolConfiguration(config) ?? symbol
            let symbolRect = NSRect(x: 0, y: (height - 14) / 2, width: 14, height: 14)
            sized.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            iconColor.setFill()
            symbolRect.fill(using: .sourceAtop)
        }

        if !text.isEmpty {
            (text as NSString).draw(
                at: NSPoint(x: iconWidth + spacing, y: (height - textSize.height) / 2),
                withAttributes: textAttrs
            )
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Renders a wide menu bar image with multiple providers side by side,
    /// each inside a rounded pill for contrast against any wallpaper.
    /// Layout per pill: [icon] [name] [status text]
    static func renderCombinedMenuBarImage(
        items: [(iconSymbol: String, name: String, text: String, textColor: NSColor, appIcon: NSImage?)],
        isDark: Bool,
        showIcon: Bool = true,
        showName: Bool = true
    ) -> NSImage {
        let iconColor: NSColor = isDark
            ? NSColor(white: 0.9, alpha: 1.0)
            : NSColor(white: 0.15, alpha: 1.0)
        let nameColor: NSColor = isDark
            ? NSColor(white: 0.6, alpha: 1.0)
            : NSColor(white: 0.35, alpha: 1.0)

        let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let nameFont = NSFont.systemFont(ofSize: 11, weight: .regular)

        let iconWidth: CGFloat = 16
        let iconNameSpacing: CGFloat = 3
        let nameTextSpacing: CGFloat = 4
        let itemGap: CGFloat = 6
        let pillPadH: CGFloat = 7
        let pillPadV: CGFloat = 0
        let pillRadius: CGFloat = 6
        let height: CGFloat = 18

        // Pre-compute each item's layout
        struct ItemMetrics {
            let contentWidth: CGFloat
            let nameSize: CGSize
            let nameAttrs: [NSAttributedString.Key: Any]
            let textSize: CGSize
            let textAttrs: [NSAttributedString.Key: Any]
        }

        var metrics: [ItemMetrics] = []
        for item in items {
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: nameColor]
            let nameSize = (showName && !item.name.isEmpty) ? (item.name as NSString).size(withAttributes: nameAttrs) : CGSize.zero
            let textAttrs: [NSAttributedString.Key: Any] = [.font: statusFont, .foregroundColor: item.textColor]
            let textSize = item.text.isEmpty ? CGSize.zero : (item.text as NSString).size(withAttributes: textAttrs)

            var contentWidth: CGFloat = 0
            if showIcon { contentWidth += iconWidth }
            if showName && !item.name.isEmpty {
                if contentWidth > 0 { contentWidth += iconNameSpacing }
                contentWidth += nameSize.width
            }
            if !item.text.isEmpty {
                if contentWidth > 0 { contentWidth += nameTextSpacing }
                contentWidth += textSize.width
            }

            metrics.append(ItemMetrics(
                contentWidth: contentWidth,
                nameSize: nameSize, nameAttrs: nameAttrs,
                textSize: textSize, textAttrs: textAttrs
            ))
        }

        // Total image width
        var totalWidth: CGFloat = 0
        for (i, m) in metrics.enumerated() {
            totalWidth += pillPadH + m.contentWidth + pillPadH
            if i < metrics.count - 1 { totalWidth += itemGap }
        }

        let pillColor: NSColor = isDark
            ? NSColor(white: 0.0, alpha: 0.55)
            : NSColor(white: 1.0, alpha: 0.55)

        let image = NSImage(size: NSSize(width: totalWidth, height: height))
        image.lockFocus()

        var x: CGFloat = 0
        for (i, item) in items.enumerated() {
            let m = metrics[i]
            let pillW = pillPadH + m.contentWidth + pillPadH
            let pillH = height - pillPadV * 2

            // Draw pill background
            let pillRect = NSRect(x: x, y: pillPadV, width: pillW, height: pillH)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillRadius, yRadius: pillRadius)
            pillColor.setFill()
            pill.fill()

            // Draw icon — prefer real app icon, fall back to SF Symbol
            var cx = x + pillPadH
            if showIcon {
                let iconRect = NSRect(x: cx, y: (height - iconWidth) / 2, width: iconWidth, height: iconWidth)
                if let appImg = item.appIcon {
                    appImg.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                } else if let symbol = NSImage(systemSymbolName: item.iconSymbol, accessibilityDescription: nil) {
                    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    let sized = symbol.withSymbolConfiguration(config) ?? symbol
                    sized.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    iconColor.setFill()
                    iconRect.fill(using: .sourceAtop)
                }
                cx += iconWidth
            }

            // Draw name
            if showName && !item.name.isEmpty {
                if showIcon { cx += iconNameSpacing }
                (item.name as NSString).draw(
                    at: NSPoint(x: cx, y: (height - m.nameSize.height) / 2),
                    withAttributes: m.nameAttrs
                )
                cx += m.nameSize.width
            }

            // Draw status text
            if !item.text.isEmpty {
                if showIcon || (showName && !item.name.isEmpty) { cx += nameTextSpacing }
                (item.text as NSString).draw(
                    at: NSPoint(x: cx, y: (height - m.textSize.height) / 2),
                    withAttributes: m.textAttrs
                )
            }

            x += pillW
            if i < items.count - 1 { x += itemGap }
        }

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

    // MARK: - Dropdown Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let isLoading = manager?.loadingProviders.contains(providerId) ?? false
        let errorMsg = manager?.errors[providerId]

        // Rich SwiftUI content area
        let typeId = ProviderCatalog.allTypes.first { $0.iconSymbol == iconSymbol }?.typeId ?? ""
        let contentView = MenuBarDropdownView(
            providerId: providerId,
            providerName: providerName,
            iconSymbol: iconSymbol,
            appIcon: ProviderCatalog.appIcon(for: typeId),
            snapshot: currentSnapshot,
            error: errorMsg,
            isLoading: isLoading
        )

        let hostingView = SelfSizingHostingView(rootView: contentView)
        let contentItem = NSMenuItem()
        contentItem.view = hostingView
        menu.addItem(contentItem)

        menu.addItem(.separator())

        if dashboardURL != nil {
            let dash = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
            dash.target = self
            dash.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
            menu.addItem(dash)
        }

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refresh)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit TokenBar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func openDashboard() {
        if let url = dashboardURL { NSWorkspace.shared.open(url) }
    }

    @objc private func refreshNow() {
        manager?.refreshProvider(providerId)
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openTokenBarSettings, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
