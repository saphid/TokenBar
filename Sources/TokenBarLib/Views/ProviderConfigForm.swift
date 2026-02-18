import SwiftUI

/// Auto-generated form from a provider's `configFields` array.
/// Renders the appropriate SwiftUI control for each `FieldType`.
struct ProviderConfigForm: View {
    let fields: [ConfigFieldDescriptor]
    @Binding var values: [String: AnyCodableValue]

    /// For secureText fields: track which ones already have a keychain value
    var existingSecrets: Set<String> = []
    /// Callback when a secret field's "Remove" button is tapped
    var onRemoveSecret: ((String) -> Void)?

    var body: some View {
        ForEach(fields, id: \.id) { field in
            fieldView(for: field)
        }
    }

    @ViewBuilder
    private func fieldView(for field: ConfigFieldDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.fieldType {
            case .text:
                TextField(field.placeholder ?? "", text: stringBinding(for: field.id))
                    .textFieldStyle(.roundedBorder)

            case .secureText:
                if existingSecrets.contains(field.id) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(field.label) saved")
                        Spacer()
                        Button("Remove") {
                            onRemoveSecret?(field.id)
                        }
                        .foregroundStyle(.red)
                    }
                } else {
                    SecureField(field.placeholder ?? "", text: stringBinding(for: field.id))
                        .textFieldStyle(.roundedBorder)
                }

            case .currency:
                HStack {
                    Text(field.label)
                    Spacer()
                    TextField(field.placeholder ?? "$", text: currencyStringBinding(for: field.id))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("USD")
                        .foregroundStyle(.secondary)
                }

            case .toggle:
                Toggle(field.label, isOn: boolBinding(for: field.id))

            case .picker(let options):
                Picker(field.label, selection: stringBinding(for: field.id)) {
                    Text("None").tag("")
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
            }

            if let helpText = field.helpText {
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key]?.stringValue ?? "" },
            set: { values[key] = $0.isEmpty ? nil : .string($0) }
        )
    }

    private func currencyStringBinding(for key: String) -> Binding<String> {
        Binding(
            get: {
                guard let val = values[key]?.doubleValue, val > 0 else { return "" }
                return String(Int(val))
            },
            set: {
                if let v = Double($0), v > 0 {
                    values[key] = .double(v)
                } else {
                    values[key] = nil
                }
            }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { values[key]?.boolValue ?? false },
            set: { values[key] = .bool($0) }
        )
    }
}
