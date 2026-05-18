import AppKit
import SwiftUI

/// Grid container that lays providers side by side with equal row heights.
/// Sorts providers by quota count so cards with similar heights share a row.
struct MenuBarDropdownGridView: View {
    let providers: [(id: String, name: String, icon: String, appIcon: NSImage?, snapshot: UsageSnapshot?, error: String?, isLoading: Bool)]

    /// Use the order passed in from the caller (respects the active sort mode).
    private var sorted: [(id: String, name: String, icon: String, appIcon: NSImage?, snapshot: UsageSnapshot?, error: String?, isLoading: Bool)] {
        providers
    }

    private var columnCount: Int {
        switch providers.count {
        case 0...1: return 1
        case 2...4: return 2
        case 5...9: return 3
        default: return 4
        }
    }

    private var rowCount: Int {
        (providers.count + columnCount - 1) / columnCount
    }

    private func indicesForRow(_ row: Int) -> [Int] {
        let start = row * columnCount
        let end = min(start + columnCount, sorted.count)
        return Array(start..<end)
    }

    var body: some View {
        let items = sorted
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<rowCount, id: \.self) { row in
                GridRow {
                    ForEach(indicesForRow(row), id: \.self) { i in
                        providerCard(items[i])
                    }
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func providerCard(_ p: (id: String, name: String, icon: String, appIcon: NSImage?, snapshot: UsageSnapshot?, error: String?, isLoading: Bool)) -> some View {
        MenuBarDropdownView(
            providerId: p.id,
            providerName: p.name,
            iconSymbol: p.icon,
            appIcon: p.appIcon,
            snapshot: p.snapshot,
            error: p.error,
            isLoading: p.isLoading
        )
        .frame(width: 260)
        .gridCellAnchor(.top)
    }
}

/// Rich SwiftUI view embedded in the NSMenu dropdown for each provider.
struct MenuBarDropdownView: View {
    let providerId: String
    let providerName: String
    let iconSymbol: String
    let appIcon: NSImage?
    let snapshot: UsageSnapshot?
    let error: String?
    let isLoading: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.horizontal, 12)

            if isLoading && snapshot == nil {
                loadingSection
            } else if let snapshot {
                usageSection(snapshot)
                if isLoading {
                    refreshBanner
                }
            } else if let error {
                errorSection(error)
            } else {
                loadingSection
            }
        }
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Header

    @ViewBuilder
    private var headerIcon: some View {
        if let nsIcon = appIcon {
            Image(nsImage: nsIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: iconSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            headerIcon

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(providerName)
                        .font(.system(size: 14, weight: .bold))

                    if let tier = snapshot?.accountTier {
                        Text(tier)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.7)))
                    }
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            } else if let snapshot {
                let timeFormatter = {
                    let f = DateFormatter()
                    f.timeStyle = .short
                    return f
                }()
                Text(timeFormatter.string(from: snapshot.capturedAt))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let snapshot, hasHiddenQuotas(snapshot) {
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Refresh Banner

    private var refreshBanner: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
            Text("Refreshing...")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }

    // MARK: - Smart Quota Filtering

    /// Determines what to show the user based on their actual token situation.
    /// Returns either `.blocked` (out of tokens, show reset time) or `.available` (show relevant quotas).
    private enum TokenStatus {
        case blocked(latestReset: Date?, blockingQuota: UsageQuota)
        case available(quotas: [UsageQuota])
    }

    /// Labels for supplementary quotas (credits, on-demand) that don't block primary access.
    private static let supplementaryLabels: Set<String> = ["Credits", "On-Demand"]

    private func tokenStatus(for snapshot: UsageSnapshot) -> TokenStatus {
        let trackable = snapshot.quotas.filter { $0.percentUsed >= 0 }
        let infoOnly = snapshot.quotas.filter { $0.percentUsed < 0 }

        // Separate primary quotas (5h, weekly, monthly) from supplementary (credits, on-demand)
        let primary = trackable.filter { !Self.supplementaryLabels.contains($0.label) }
        let supplementary = trackable.filter { Self.supplementaryLabels.contains($0.label) }

        let exhaustedPrimary = primary.filter { $0.percentUsed >= 100 }

        if !exhaustedPrimary.isEmpty {
            // ANY exhausted primary quota blocks the user — a weekly cap at 100%
            // blocks you even if the 5h window is empty
            let latestReset = exhaustedPrimary.compactMap(\.resetsAt).max()
            let blocking = exhaustedPrimary.max(by: { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) })
                ?? exhaustedPrimary[0]
            return .blocked(latestReset: latestReset, blockingQuota: blocking)
        }

        // No primary quotas exhausted — user has access
        if primary.isEmpty && supplementary.isEmpty {
            return .available(quotas: infoOnly)
        }

        // Show the most constraining primary quota only
        // Supplementary quotas (credits) are irrelevant when primary access is available
        if let mostConstrained = primary.max(by: { $0.percentUsed < $1.percentUsed }) {
            return .available(quotas: [mostConstrained])
        }

        // Only supplementary quotas exist (unusual) — show the most relevant one
        if let mostConstrained = supplementary.max(by: { $0.percentUsed < $1.percentUsed }) {
            return .available(quotas: [mostConstrained])
        }

        let usefulInfo = infoOnly.filter { $0.detailText != nil || $0.menuBarOverride != nil }
        return .available(quotas: usefulInfo)
    }

    // MARK: - Usage

    /// Whether there are hidden quotas the user could expand to see.
    private func hasHiddenQuotas(_ snapshot: UsageSnapshot) -> Bool {
        let status = tokenStatus(for: snapshot)
        switch status {
        case .blocked:
            return !snapshot.quotas.isEmpty
        case .available(let shown):
            return shown.count < snapshot.quotas.count
        }
    }

    private func usageSection(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                // Show all quotas
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(snapshot.quotas.enumerated()), id: \.offset) { _, quota in
                        quotaCard(quota)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                let status = tokenStatus(for: snapshot)
                switch status {
                case .blocked(let latestReset, let blockingQuota):
                    blockedSection(reset: latestReset, quota: blockingQuota)
                case .available(let quotas):
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(quotas.enumerated()), id: \.offset) { _, quota in
                            quotaCard(quota)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }

        }
    }

    private func blockedSection(reset: Date?, quota: UsageQuota) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Out of tokens")
                        .font(.system(size: 14, weight: .bold))

                    if let detail = quota.detailText {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let reset {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(formattedWaitTime(until: reset))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.08))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Human-friendly wait time with enough precision to distinguish different reset times.
    private func formattedWaitTime(until date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "Resetting now..." }

        let totalMinutes = Int(remaining / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let days = hours / 24
        let remainingHours = hours % 24

        if days == 0 {
            if hours > 0 {
                return "Resets in \(hours)h \(minutes)m"
            } else {
                return "Resets in \(minutes)m"
            }
        }

        // Always include a time component so different providers are distinguishable
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        if days == 1 {
            return "Resets tomorrow at \(timeFormatter.string(from: date))"
        } else if days < 7 {
            return "Resets in \(days)d \(remainingHours)h"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        return "Resets \(dateFormatter.string(from: date)) at \(timeFormatter.string(from: date))"
    }

    private func quotaCard(_ quota: UsageQuota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label row
            HStack {
                Text(quota.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if quota.percentUsed >= 0 {
                    Text(String(format: "%.1f%%", quota.percentUsed))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(colorForStatus(quota.statusColor))
                }
            }

            // Progress bar
            if quota.percentUsed >= 0 {
                UsageProgressBar(
                    percent: quota.percentUsed,
                    statusColor: quota.statusColor
                )
            }

            // Detail text
            if let detail = quota.detailText {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.7))
            }

            // Override text (for dollar amounts etc.)
            if let override = quota.menuBarOverride, quota.percentUsed < 0 {
                Text(override)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            // Reset date
            if let resets = quota.resetsAt {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                    Text("Resets \(formattedResetDate(resets))")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Error

    private var isAuthError: Bool {
        guard let error else { return false }
        return error.contains("Authentication") || error.contains("401")
            || error.contains("expired") || error.contains("credentials")
            || error.contains("authenticationRequired")
    }

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Unable to fetch usage data")
                        .font(.system(size: 12, weight: .semibold))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            // Actionable suggestions based on error type
            VStack(alignment: .leading, spacing: 4) {
                if isAuthError {
                    suggestionRow(icon: "key.fill", text: "Authentication failed or expired")
                } else if error.contains("Network") || error.contains("timed out") {
                    suggestionRow(icon: "wifi.slash", text: "Check your internet connection")
                } else if error.contains("403") || error.contains("access") {
                    suggestionRow(icon: "lock.fill", text: "API key may lack required permissions")
                } else if error.contains("sqlite") || error.contains("database") {
                    suggestionRow(icon: "cylinder.split.1x2", text: "The app database may be locked")
                } else {
                    suggestionRow(icon: "arrow.clockwise", text: "Try refreshing — this may be temporary")
                }
            }
            .padding(.top, 2)

            // Re-authenticate button for auth errors
            if isAuthError {
                Button(action: {
                    NotificationCenter.default.post(
                        name: .reauthenticateProvider,
                        object: nil,
                        userInfo: ["providerId": providerId]
                    )
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                        Text("Re-authenticate")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.12))
                    )
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.06))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func suggestionRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .frame(width: 12)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Loading

    private var loadingSection: some View {
        VStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Fetching usage data...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }

    // MARK: - Helpers

    private func colorForStatus(_ status: StatusColor) -> Color {
        switch status {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func formattedResetDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "today at \(formatter.string(from: date))"
        } else if calendar.isDateInTomorrow(date) {
            return "tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Progress Bar

struct UsageProgressBar: View {
    let percent: Double
    let statusColor: StatusColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))

                RoundedRectangle(cornerRadius: 4)
                    .fill(fillGradient)
                    .frame(width: max(0, geo.size.width * min(1, percent / 100)))
            }
        }
        .frame(height: 8)
    }

    private var fillGradient: LinearGradient {
        let color: Color
        switch statusColor {
        case .good: color = .green
        case .warning: color = .orange
        case .critical: color = .red
        case .unknown: color = .gray
        }
        return LinearGradient(
            colors: [color.opacity(0.8), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
