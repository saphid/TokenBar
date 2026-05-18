import Foundation

// MARK: - AnyCodableValue

/// A type-erased Codable value for storing provider-specific configuration.
enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: Int before Double (to preserve integer precision),
        // and Bool AFTER numeric types (JSON 0/1 can decode as Bool in Swift).
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

// MARK: - ProviderConfig

/// Typed accessor wrapper around a `[String: AnyCodableValue]` dictionary.
/// Provides convenience methods for common field types.
struct ProviderConfig {
    var values: [String: AnyCodableValue]

    init(_ values: [String: AnyCodableValue] = [:]) {
        self.values = values
    }

    func string(_ key: String) -> String? {
        values[key]?.stringValue
    }

    func int(_ key: String) -> Int? {
        values[key]?.intValue
    }

    func double(_ key: String) -> Double? {
        values[key]?.doubleValue
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.boolValue
    }

    /// Resolves a keychain reference. The stored value is the keychain key name;
    /// this method loads the actual secret from the keychain.
    func secret(_ key: String) -> String? {
        guard let keychainKey = string(key) else { return nil }
        return KeychainHelper.load(key: keychainKey)
    }

    mutating func set(_ key: String, _ value: AnyCodableValue) {
        values[key] = value
    }

    mutating func set(_ key: String, string value: String?) {
        values[key] = value.map { .string($0) } ?? .null
    }

    mutating func set(_ key: String, double value: Double?) {
        values[key] = value.map { .double($0) } ?? .null
    }
}

// MARK: - Config Field Schema

/// Describes a single configurable field for a provider type.
/// Used to auto-generate the config UI and validate user input.
struct ConfigFieldDescriptor {
    let id: String             // dictionary key in providerConfig
    let label: String          // UI label
    let fieldType: FieldType
    let placeholder: String?
    let helpText: String?
    let isRequired: Bool

    init(
        id: String,
        label: String,
        fieldType: FieldType,
        placeholder: String? = nil,
        helpText: String? = nil,
        isRequired: Bool = false
    ) {
        self.id = id
        self.label = label
        self.fieldType = fieldType
        self.placeholder = placeholder
        self.helpText = helpText
        self.isRequired = isRequired
    }
}

/// The kind of input control to render for a config field.
enum FieldType {
    case text
    case secureText
    case currency
    case toggle
    case picker([String])

    var isSecureText: Bool {
        if case .secureText = self { return true }
        return false
    }
}
