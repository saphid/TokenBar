import SwiftUI

// MARK: - Navigation State

enum ProvidersPanel: Hashable {
    case empty
    case provider(String)
    case addPicker
    case addConfig(String) // stores the config ID for the new provider being configured

    func hash(into hasher: inout Hasher) {
        switch self {
        case .empty: hasher.combine(0)
        case .provider(let id): hasher.combine(1); hasher.combine(id)
        case .addPicker: hasher.combine(2)
        case .addConfig(let id): hasher.combine(3); hasher.combine(id)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var providerManager: ProviderManager
    @State private var selectedTab = 0
    @State private var panelMode: ProvidersPanel = .empty
    @State private var pendingNewConfig: ProviderInstanceConfig?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Label("Providers", systemImage: "square.stack.3d.up").tag(0)
                Label("General", systemImage: "gearshape").tag(1)
                if providerManager.devModeUnlocked {
                    Label("Dev", systemImage: "hammer").tag(2)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Group {
                switch selectedTab {
                case 0: providersTab
                case 1: generalTab
                case 2: devTab
                default: generalTab
                }
            }
        }
        .frame(width: 660, height: 480)
        .onChange(of: providerManager.devModeUnlocked) { _, unlocked in
            if !unlocked && selectedTab == 2 {
                selectedTab = 1
            }
        }
    }

    // MARK: - Providers Tab (Sidebar + Detail)

    private var providersTab: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { sidebarSelection },
                    set: { newValue in
                        if let newValue {
                            panelMode = newValue
                        }
                    }
                )) {
                    ForEach(providerManager.instanceConfigs) { config in
                        SidebarProviderRow(
                            config: config,
                            providerManager: providerManager
                        )
                        .tag(ProvidersPanel.provider(config.id))
                    }
                    .onMove { source, destination in
                        providerManager.moveProviders(from: source, to: destination)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                Button(action: { panelMode = .addPicker }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Add Provider")
                    }
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            .frame(width: 180)

            Divider()

            // Detail panel
            Group {
                switch panelMode {
                case .empty:
                    emptyDetailPanel

                case .provider(let id):
                    if let config = providerManager.instanceConfigs.first(where: { $0.id == id }) {
                        ProviderDetailPanel(
                            config: config,
                            providerManager: providerManager,
                            onRemove: {
                                // Clean up keychain secrets before removing
                                if let fields = ProviderRegistry.type(for: config.typeId)?.configFields {
                                    for field in fields where field.fieldType.isSecureText {
                                        if let keychainKey = config.providerConfig[field.id]?.stringValue {
                                            KeychainHelper.delete(key: keychainKey)
                                        }
                                    }
                                }
                                providerManager.removeInstance(id)
                                panelMode = .empty
                            }
                        )
                    } else {
                        emptyDetailPanel
                            .onAppear { panelMode = .empty }
                    }

                case .addPicker:
                    AddProviderPicker(
                        providerManager: providerManager,
                        onAddZeroConfig: { config in
                            providerManager.addInstance(config)
                            panelMode = .provider(config.id)
                        },
                        onAddWithConfig: { config in
                            pendingNewConfig = config
                            panelMode = .addConfig(config.id)
                        }
                    )

                case .addConfig(let configId):
                    if let config = pendingNewConfig, config.id == configId {
                        NewProviderConfigPanel(
                            config: config,
                            providerManager: providerManager,
                            onAdd: { savedConfig in
                                pendingNewConfig = nil
                                panelMode = .provider(savedConfig.id)
                            },
                            onCancel: {
                                pendingNewConfig = nil
                                panelMode = .addPicker
                            }
                        )
                    } else {
                        emptyDetailPanel
                            .onAppear { panelMode = .addPicker }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: providerManager.instanceConfigs) { _, newConfigs in
            // If selected provider was removed, reset to empty
            if case .provider(let id) = panelMode {
                if !newConfigs.contains(where: { $0.id == id }) {
                    panelMode = .empty
                }
            }
        }
    }

    private var sidebarSelection: ProvidersPanel? {
        switch panelMode {
        case .provider: return panelMode
        default: return nil
        }
    }

    private var emptyDetailPanel: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select a provider")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - General Tab

    @State private var easterEggTaps = 0
    @State private var lastTapTime = Date.distantPast
    @State private var devModeJustUnlocked = false

    private var generalTab: some View {
        VStack(spacing: 0) {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: Binding(
                        get: { providerManager.appearanceMode },
                        set: {
                            providerManager.appearanceMode = $0
                            providerManager.saveAppearance()
                            NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
                        }
                    )) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker("Sort Order", selection: Binding(
                        get: { providerManager.sortMode },
                        set: {
                            providerManager.sortMode = $0
                            providerManager.saveSortSettings()
                        }
                    )) {
                        ForEach(SortMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if providerManager.sortMode != .manual {
                        Toggle("Ascending", isOn: Binding(
                            get: { providerManager.sortAscending },
                            set: {
                                providerManager.sortAscending = $0
                                providerManager.saveSortSettings()
                            }
                        ))
                    }
                }

                Section("Menu Bar") {
                    Picker("Poll Interval", selection: Binding(
                        get: { providerManager.pollInterval },
                        set: { providerManager.setPollInterval($0) }
                    )) {
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                        Text("15 minutes").tag(900.0)
                        Text("30 minutes").tag(1800.0)
                    }

                    Toggle("Show provider icon", isOn: Binding(
                        get: { providerManager.showIconInMenuBar },
                        set: {
                            providerManager.showIconInMenuBar = $0
                            providerManager.saveMenuBarSettings()
                        }
                    ))

                    Toggle("Show provider name", isOn: Binding(
                        get: { providerManager.showNameInMenuBar },
                        set: {
                            providerManager.showNameInMenuBar = $0
                            providerManager.saveMenuBarSettings()
                        }
                    ))
                }
            }
            .formStyle(.grouped)

            Button(action: handleEasterEggTap) {
                if devModeJustUnlocked {
                    Text("Developer mode enabled!")
                        .foregroundStyle(.orange)
                        .fontWeight(.medium)
                } else {
                    HStack(spacing: 4) {
                        Text("TokenBar v0.2")
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(easterEggTaps >= 3 && !providerManager.devModeUnlocked
                             ? "\(7 - easterEggTaps) taps to developer mode"
                             : "AI usage monitoring")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
    }

    private func handleEasterEggTap() {
        let now = Date()
        if now.timeIntervalSince(lastTapTime) > 3.0 {
            easterEggTaps = 0
        }
        lastTapTime = now
        easterEggTaps += 1

        if providerManager.devModeUnlocked {
            if easterEggTaps >= 5 {
                easterEggTaps = 0
                providerManager.triggerConfetti(from: NSEvent.mouseLocation)
            }
            return
        }

        TBLog.log("Dev mode tap \(easterEggTaps)/7", category: "settings")
        if easterEggTaps >= 7 {
            easterEggTaps = 0
            providerManager.devModeUnlocked = true
            providerManager.saveDevMode()
            devModeJustUnlocked = true
            providerManager.triggerConfetti(from: NSEvent.mouseLocation)
            TBLog.log("Developer mode unlocked!", category: "settings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                devModeJustUnlocked = false
            }
        }
    }

    // MARK: - Dev Tab

    @State private var templateName: String = ""
    @State private var templateDetectionOnly: Bool = true

    private var devTab: some View {
        Form {
            Section("Confetti") {
                Button("Test Confetti from All Bubbles") {
                    NotificationCenter.default.post(name: .testConfettiAllBubbles, object: nil)
                }

                Button("Test Confetti (Upward)") {
                    providerManager.triggerConfetti(from: NSEvent.mouseLocation)
                }
            }

            Section("Provider Template") {
                TextField("Provider Name", text: $templateName)
                    .textFieldStyle(.roundedBorder)
                Toggle("Detection Only", isOn: $templateDetectionOnly)

                Button("Generate Template") {
                    generateProviderTemplate()
                }
                .disabled(templateName.isEmpty)
            }

            Section("Registry") {
                LabeledContent("Registered types") {
                    Text("\(ProviderRegistry.all.count)")
                }
                LabeledContent("Trackable") {
                    Text("\(ProviderRegistry.all.filter { $0.category == .trackable }.count)")
                }
                LabeledContent("Detection-only") {
                    Text("\(ProviderRegistry.all.filter { $0.category == .detectedOnly }.count)")
                }
            }

            Section("Debug") {
                LabeledContent("Enabled providers") {
                    Text("\(providerManager.sortedEnabledConfigs.count)")
                }
                LabeledContent("Snapshots loaded") {
                    Text("\(providerManager.snapshots.count)")
                }
                LabeledContent("Errors") {
                    Text("\(providerManager.errors.count)")
                }

                Button("Hide Developer Mode") {
                    providerManager.devModeUnlocked = false
                    providerManager.saveDevMode()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func generateProviderTemplate() {
        let sanitized = templateName.replacingOccurrences(of: " ", with: "")
        let typeId = templateName.lowercased().replacingOccurrences(of: " ", with: "-")

        let template: String
        if templateDetectionOnly {
            template = """
            import Foundation

            enum \(sanitized)ProviderDef: DetectionOnlyProvider {
                static let typeId = "\(typeId)"
                static let defaultName = "\(templateName)"
                static let iconSymbol = "questionmark.app"
                static let dashboardURL: URL? = nil

                static let detection = DetectionSpec(
                    paths: ["/Applications/\(templateName).app"],
                    commands: ["\(typeId)"]
                )
                static let iconSpec = IconSpec(
                    appBundlePaths: ["/Applications/\(templateName).app"],
                    faviconDomain: "\(typeId).com"
                )
            }
            """
        } else {
            template = """
            import Foundation

            // TODO: Implement \(sanitized)Provider conforming to UsageProvider

            enum \(sanitized)ProviderDef: RegisteredProvider {
                static let typeId = "\(typeId)"
                static let defaultName = "\(templateName)"
                static let iconSymbol = "questionmark.app"
                static let dashboardURL: URL? = nil
                static let category: ProviderCategory = .trackable
                static let dataSourceDescription: String? = nil

                static let detection = DetectionSpec(
                    paths: ["/Applications/\(templateName).app"],
                    commands: ["\(typeId)"]
                )
                static let iconSpec = IconSpec(
                    appBundlePaths: ["/Applications/\(templateName).app"],
                    faviconDomain: "\(typeId).com"
                )

                static let configFields: [ConfigFieldDescriptor] = [
                    // Add fields here
                ]

                static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
                    // TODO: Return your provider implementation
                    DetectedProvider(id: instanceId, name: label, iconSymbol: iconSymbol, dashboardURL: dashboardURL)
                }
            }
            """
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitized)Detection.swift"
        panel.allowedContentTypes = [.sourceCode]
        if panel.runModal() == .OK, let url = panel.url {
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Sidebar Provider Row

struct SidebarProviderRow: View {
    let config: ProviderInstanceConfig
    @ObservedObject var providerManager: ProviderManager

    var body: some View {
        HStack(spacing: 8) {
            providerIcon
                .frame(width: 20, height: 20)

            Text(config.label)
                .lineLimit(1)
                .foregroundStyle(config.enabled ? .primary : .secondary)

            Spacer()

            Toggle("", isOn: Binding(
                get: { config.enabled },
                set: { newValue in
                    if let idx = providerManager.instanceConfigs.firstIndex(where: { $0.id == config.id }) {
                        providerManager.instanceConfigs[idx].enabled = newValue
                        providerManager.handleEnabledChanged(config.id, enabled: newValue)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let appIcon = ProviderCatalog.appIcon(for: config.typeId) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .opacity(config.enabled ? 1.0 : 0.5)
        } else {
            let typeInfo = ProviderCatalog.type(for: config.typeId)
            Image(systemName: typeInfo?.iconSymbol ?? "questionmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(config.enabled ? .primary : .secondary)
        }
    }
}

// MARK: - Provider Detail Panel

struct ProviderDetailPanel: View {
    let config: ProviderInstanceConfig
    @ObservedObject var providerManager: ProviderManager
    var onRemove: () -> Void

    private var registeredType: (any RegisteredProvider.Type)? {
        ProviderRegistry.type(for: config.typeId)
    }

    private var fields: [ConfigFieldDescriptor] {
        registeredType?.configFields ?? []
    }

    @State private var editLabel: String = ""
    @State private var editValues: [String: AnyCodableValue] = [:]
    @State private var existingSecrets: Set<String> = []
    @State private var originalLabel: String = ""
    @State private var originalValues: [String: AnyCodableValue] = [:]
    /// Snapshot of the config we're currently editing, so auto-save can
    /// persist changes even after `config` has swapped to a new provider.
    @State private var activeConfig: ProviderInstanceConfig?

    private var isDirty: Bool {
        editLabel != originalLabel || editValues != originalValues
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                headerSection

                Divider()

                // Status info
                statusSection

                // Config fields (if any)
                if !fields.isEmpty {
                    Divider()
                    configSection
                }

                Spacer()

                // Action bar
                actionBar
            }
            .padding(20)
        }
        .onAppear { loadConfig() }
        .onChange(of: config.id) { _, _ in
            // Auto-save pending changes before switching to the new provider
            if isDirty, let previous = activeConfig {
                saveConfig(for: previous)
            }
            loadConfig()
        }
    }

    private func loadConfig() {
        activeConfig = config
        editLabel = config.label
        originalLabel = config.label

        var values = config.providerConfig
        var secrets: Set<String> = []

        for field in fields where field.fieldType.isSecureText {
            if let keychainKey = config.providerConfig[field.id]?.stringValue,
               KeychainHelper.load(key: keychainKey) != nil {
                secrets.insert(field.id)
            }
            values[field.id] = nil
        }

        editValues = values
        originalValues = values
        existingSecrets = secrets
    }

    // MARK: Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 12) {
            if let appIcon = ProviderCatalog.appIcon(for: config.typeId) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
            } else {
                let typeInfo = ProviderCatalog.type(for: config.typeId)
                Image(systemName: typeInfo?.iconSymbol ?? "questionmark.circle")
                    .font(.system(size: 24))
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.label)
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let tier = providerManager.snapshots[config.id]?.accountTier {
                        Text(tier)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.7)))
                    }
                }

                let typeInfo = ProviderCatalog.type(for: config.typeId)
                Text(typeInfo?.category == .detectedOnly ? "Detection Only" : "Usage Tracking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot = providerManager.snapshots[config.id] {
                let quotaLabels = snapshot.quotas.map { q in
                    if q.percentUsed >= 0 {
                        return "\(q.label): \(String(format: "%.1f%%", q.percentUsed))"
                            + (q.detailText.map { " · \($0)" } ?? "")
                    } else if let override = q.menuBarOverride {
                        return "\(q.label): \(override)"
                    } else {
                        return q.label
                    }
                }
                if !quotaLabels.isEmpty {
                    ForEach(quotaLabels, id: \.self) { text in
                        detailRow(icon: "chart.bar.fill", text: text)
                    }
                }
            }

            if let source = dataSourceDescription {
                detailRow(icon: "folder.fill", text: source)
            }

            detailRow(icon: "circle.fill", text: connectionStatus)
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var dataSourceDescription: String? {
        switch config.typeId {
        case "codex":
            if let org = config.codexOrgId {
                return "Codex CLI · org: \(org)"
            }
        case "openai":
            if let org = config.organizationId {
                return "OpenAI API · org: \(org)"
            }
            let hasKey = KeychainHelper.load(key: config.keychainKey ?? "openai_api_key") != nil
            return hasKey ? "OpenAI API · key saved" : "OpenAI API · no key"
        default:
            break
        }

        if let registeredType {
            return registeredType.dataSourceDescription
        }
        return nil
    }

    private var connectionStatus: String {
        if let error = providerManager.errors[config.id] {
            return "Error: \(error)"
        }
        if providerManager.loadingProviders.contains(config.id) {
            return "Refreshing..."
        }
        if providerManager.snapshots[config.id] != nil {
            return "Connected"
        }
        if !config.enabled {
            return "Disabled"
        }
        return "Waiting for data..."
    }

    // MARK: Config Section

    @ViewBuilder
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Label")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                TextField("Provider name", text: $editLabel)
                    .textFieldStyle(.roundedBorder)
            }

            ProviderConfigForm(
                fields: fields,
                values: $editValues,
                existingSecrets: existingSecrets,
                onRemoveSecret: { fieldId in
                    if let keychainKey = config.providerConfig[fieldId]?.stringValue ?? editValues[fieldId]?.stringValue {
                        KeychainHelper.delete(key: keychainKey)
                    }
                    existingSecrets.remove(fieldId)
                    editValues[fieldId] = nil
                }
            )
        }
    }

    // MARK: Action Bar

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            if let url = ProviderCatalog.type(for: config.typeId)?.dashboardURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                        Text("Dashboard")
                    }
                    .foregroundStyle(.blue)
                }
            }

            Spacer()

            if isDirty {
                Button("Revert") { loadConfig() }
                Button("Save") { saveConfig(for: config) }
                    .buttonStyle(.borderedProminent)
            }
        }

        HStack {
            Spacer()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Text("Remove Provider")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Save

    /// Saves current edits against the given config. Called explicitly via Save
    /// button (passing `config`) or automatically when switching providers
    /// (passing the stashed `activeConfig` so unsaved work isn't lost).
    private func saveConfig(for targetConfig: ProviderInstanceConfig) {
        let targetFields = ProviderRegistry.type(for: targetConfig.typeId)?.configFields ?? []

        var updated = targetConfig
        updated.label = editLabel.isEmpty
            ? (ProviderRegistry.type(for: targetConfig.typeId)?.defaultName ?? targetConfig.label)
            : editLabel

        var finalValues = editValues

        for field in targetFields where field.fieldType.isSecureText {
            if let rawValue = finalValues[field.id]?.stringValue, !rawValue.isEmpty {
                let keychainKey = targetConfig.providerConfig[field.id]?.stringValue
                    ?? "\(targetConfig.typeId)_\(field.id)_\(targetConfig.id)"
                KeychainHelper.save(key: keychainKey, value: rawValue)
                finalValues[field.id] = .string(keychainKey)
            } else if existingSecrets.contains(field.id),
                      let originalKeychainKey = targetConfig.providerConfig[field.id]?.stringValue {
                finalValues[field.id] = .string(originalKeychainKey)
            }
        }

        for field in targetFields {
            if case .currency = field.fieldType {
                let budgetKey = "\(targetConfig.typeId)_budget_\(targetConfig.id)"
                let val = finalValues[field.id]?.doubleValue ?? 0
                UserDefaults.standard.set(val, forKey: budgetKey)
            }
        }

        updated.providerConfig = finalValues
        providerManager.updateInstance(updated)

        // Reset dirty tracking to match saved state
        activeConfig = updated
        originalLabel = updated.label
        var cleanValues = finalValues
        for field in targetFields where field.fieldType.isSecureText {
            cleanValues[field.id] = nil
        }
        originalValues = cleanValues
        editValues = cleanValues

        // Re-check existing secrets after save
        var secrets: Set<String> = []
        for field in targetFields where field.fieldType.isSecureText {
            if let keychainKey = updated.providerConfig[field.id]?.stringValue,
               KeychainHelper.load(key: keychainKey) != nil {
                secrets.insert(field.id)
            }
        }
        existingSecrets = secrets
    }
}

// MARK: - Add Provider Picker

struct AddProviderPicker: View {
    @ObservedObject var providerManager: ProviderManager
    var onAddZeroConfig: (ProviderInstanceConfig) -> Void
    var onAddWithConfig: (ProviderInstanceConfig) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Provider")
                    .font(.title3)
                    .fontWeight(.semibold)

                let trackable = ProviderCatalog.allTypes.filter { $0.category == .trackable }
                let detected = ProviderCatalog.allTypes.filter { $0.category == .detectedOnly }

                if !trackable.isEmpty {
                    Text("Usage Tracking")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    ForEach(trackable) { typeInfo in
                        addableRow(typeInfo)
                    }
                }

                if !detected.isEmpty {
                    Text("App Detection")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)

                    ForEach(detected) { typeInfo in
                        addableRow(typeInfo)
                    }
                }
            }
            .padding(20)
        }
    }

    private func addableRow(_ typeInfo: ProviderTypeInfo) -> some View {
        let existingIds = Set(providerManager.instanceConfigs.map(\.typeId))
        let alreadyAdded = !typeInfo.supportsMultipleInstances && existingIds.contains(typeInfo.typeId)
        let isDetected = providerManager.detectedTypeIds.contains(typeInfo.typeId)

        return HStack(spacing: 10) {
            if let appIcon = ProviderCatalog.appIcon(for: typeInfo.typeId) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .opacity(alreadyAdded ? 0.5 : 1.0)
            } else {
                Image(systemName: typeInfo.iconSymbol)
                    .font(.system(size: 16))
                    .frame(width: 24)
                    .foregroundStyle(alreadyAdded ? .secondary : .primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(typeInfo.defaultName)
                        .foregroundStyle(alreadyAdded ? .secondary : .primary)

                    if isDetected {
                        Text("Detected")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green))
                    }
                }

                if alreadyAdded {
                    Text("Already configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if typeInfo.category == .trackable {
                    Text("Live usage tracking")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Text("Detects installation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if alreadyAdded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Add") {
                    addProvider(typeInfo)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private func addProvider(_ typeInfo: ProviderTypeInfo) {
        let registeredType = ProviderRegistry.type(for: typeInfo.typeId)
        let hasConfigFields = registeredType.map { !$0.configFields.isEmpty } ?? false
        let isDetected = providerManager.detectedTypeIds.contains(typeInfo.typeId)

        let instanceId: String
        let instanceLabel: String
        if typeInfo.supportsMultipleInstances {
            let instanceCount = providerManager.instanceConfigs.filter { $0.typeId == typeInfo.typeId }.count
            let suffix = instanceCount > 0 ? "-\(instanceCount + 1)" : ""
            instanceId = "\(typeInfo.typeId)\(suffix)"
            instanceLabel = instanceCount > 0 ? "\(typeInfo.defaultName) \(instanceCount + 1)" : typeInfo.defaultName
        } else {
            instanceId = typeInfo.typeId
            instanceLabel = typeInfo.defaultName
        }

        let config = ProviderInstanceConfig(
            id: instanceId,
            typeId: typeInfo.typeId,
            label: instanceLabel,
            enabled: true,
            isAutoDetected: isDetected
        )

        if hasConfigFields {
            onAddWithConfig(config)
        } else {
            onAddZeroConfig(config)
        }
    }
}

// MARK: - New Provider Config Panel

struct NewProviderConfigPanel: View {
    let config: ProviderInstanceConfig
    @ObservedObject var providerManager: ProviderManager
    var onAdd: (ProviderInstanceConfig) -> Void
    var onCancel: () -> Void

    private var registeredType: (any RegisteredProvider.Type)? {
        ProviderRegistry.type(for: config.typeId)
    }

    private var fields: [ConfigFieldDescriptor] {
        registeredType?.configFields ?? []
    }

    @State private var label: String = ""
    @State private var configValues: [String: AnyCodableValue] = [:]
    @State private var existingSecrets: Set<String> = []

    private var hasRequiredFieldsFilled: Bool {
        for field in fields where field.isRequired {
            switch field.fieldType {
            case .secureText:
                if existingSecrets.contains(field.id) { continue }
                if let val = configValues[field.id]?.stringValue, !val.isEmpty { continue }
                return false
            case .text:
                if let val = configValues[field.id]?.stringValue, !val.isEmpty { continue }
                return false
            default:
                continue
            }
        }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    if let appIcon = ProviderCatalog.appIcon(for: config.typeId) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 36, height: 36)
                    } else {
                        let typeInfo = ProviderCatalog.type(for: config.typeId)
                        Image(systemName: typeInfo?.iconSymbol ?? "questionmark.circle")
                            .font(.system(size: 24))
                            .frame(width: 36, height: 36)
                    }

                    Text("Add \(registeredType?.defaultName ?? "Provider")")
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                Divider()

                // Label field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Label")
                        .foregroundStyle(.secondary)
                    TextField("Provider name", text: $label)
                        .textFieldStyle(.roundedBorder)
                }

                // Config fields
                if !fields.isEmpty {
                    ProviderConfigForm(
                        fields: fields,
                        values: $configValues,
                        existingSecrets: existingSecrets,
                        onRemoveSecret: { fieldId in
                            existingSecrets.remove(fieldId)
                            configValues[fieldId] = nil
                        }
                    )
                }

                Spacer()

                // Buttons
                HStack {
                    Button("Cancel") { onCancel() }
                    Spacer()
                    Button("Add") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasRequiredFieldsFilled)
                }
            }
            .padding(20)
        }
        .onAppear {
            label = config.label
            configValues = config.providerConfig
        }
    }

    private func save() {
        var updated = config
        updated.label = label.isEmpty ? (registeredType?.defaultName ?? config.label) : label

        var finalValues = configValues

        for field in fields where field.fieldType.isSecureText {
            if let rawValue = finalValues[field.id]?.stringValue, !rawValue.isEmpty {
                let keychainKey = config.providerConfig[field.id]?.stringValue
                    ?? "\(config.typeId)_\(field.id)_\(config.id)"
                KeychainHelper.save(key: keychainKey, value: rawValue)
                finalValues[field.id] = .string(keychainKey)
            }
        }

        for field in fields {
            if case .currency = field.fieldType {
                let budgetKey = "\(config.typeId)_budget_\(config.id)"
                let val = finalValues[field.id]?.doubleValue ?? 0
                UserDefaults.standard.set(val, forKey: budgetKey)
            }
        }

        updated.providerConfig = finalValues
        providerManager.addInstance(updated)
        onAdd(updated)
    }
}

// MARK: - Notification for theme changes

public extension Notification.Name {
    static let appearanceModeChanged = Notification.Name("com.tokenbar.appearanceModeChanged")
}
