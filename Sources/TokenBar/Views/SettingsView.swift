import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var providerManager: ProviderManager

    // API key fields — synced with Keychain
    @State private var openAIKey: String = ""
    @State private var openAIKeySaved = false

    @AppStorage("openai_budget") private var openAIBudget: Double = 0

    var body: some View {
        TabView {
            providersTab
                .tabItem { Label("Providers", systemImage: "list.bullet") }
            apiKeysTab
                .tabItem { Label("API Keys", systemImage: "key") }
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 420, height: 360)
        .onAppear {
            // Load saved key presence (don't show the actual key)
            openAIKeySaved = KeychainHelper.load(key: "openai_api_key") != nil
        }
    }

    // MARK: - Providers Tab

    private var providersTab: some View {
        Form {
            Section("Active Providers") {
                if providerManager.allProviders.isEmpty {
                    Text("No providers registered")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(providerManager.allProviders, id: \.id) { entry in
                        let available = providerManager.availableProviderIds.contains(entry.id)
                        let enabled = providerManager.enabledProviderIds.contains(entry.id)

                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { providerManager.toggleProvider(entry.id, enabled: $0) }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: entry.provider.iconSymbol)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.provider.name)
                                    if !available {
                                        Text("Not configured — add API key in API Keys tab")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if let error = providerManager.errors[entry.id] {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    } else if let snap = providerManager.snapshots[entry.id],
                                              let q = snap.quotas.first {
                                        if q.percentUsed >= 0 {
                                            Text(String(format: "%.1f%% used", q.percentUsed))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else if let detail = q.detailText {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .disabled(!available)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - API Keys Tab

    private var apiKeysTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("OpenAI", systemImage: "brain.head.profile")
                        .font(.headline)

                    if openAIKeySaved {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("API key saved")
                            Spacer()
                            Button("Remove") {
                                KeychainHelper.delete(key: "openai_api_key")
                                openAIKey = ""
                                openAIKeySaved = false
                                providerManager.refreshAvailability()
                            }
                            .foregroundStyle(.red)
                        }
                    } else {
                        SecureField("sk-...", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Save Key") {
                                guard !openAIKey.isEmpty else { return }
                                KeychainHelper.save(key: "openai_api_key", value: openAIKey)
                                openAIKeySaved = true
                                openAIKey = ""
                                providerManager.refreshAvailability()
                            }
                            .disabled(openAIKey.isEmpty)

                            Spacer()

                            Link("Get API Key",
                                 destination: URL(string: "https://platform.openai.com/api-keys")!)
                                .font(.caption)
                        }
                    }

                    Divider()

                    HStack {
                        Text("Monthly Budget")
                        Spacer()
                        TextField("$", value: $openAIBudget, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("USD")
                            .foregroundStyle(.secondary)
                    }
                    Text("Set to 0 to show dollar amount instead of percentage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Text("More providers coming soon: Anthropic, GitHub Copilot, Windsurf")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Refresh") {
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
            }

            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text("TokenBar v0.1")
                        Text("AI usage monitoring for your menu bar")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }
}
