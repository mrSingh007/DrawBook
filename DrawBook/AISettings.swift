import Foundation
import Combine
import Security

enum AIProvider: String, CaseIterable, Identifiable {
    case openRouter
    case ollamaCloud
    case anthropic
    case openAI

    /// How requests and replies are shaped on the wire.
    enum WireFormat { case openAICompatible, ollama }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .ollamaCloud: return "Ollama Cloud"
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: return "openrouter/free"
        case .ollamaCloud: return "gpt-oss:120b"
        case .anthropic: return "claude-opus-5-5"
        case .openAI: return "gpt-5"
        }
    }

    var wireFormat: WireFormat { self == .ollamaCloud ? .ollama : .openAICompatible }

    var endpoint: URL {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .ollamaCloud: return URL(string: "https://ollama.com/api/chat")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/chat/completions")!
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    /// The request field that caps output. OpenAI's reasoning models reject `max_tokens`.
    var maxTokensField: String { self == .openAI ? "max_completion_tokens" : "max_tokens" }

    /// The output cap per reply. Large page edits arrive as JSON tool calls, and reasoning models
    /// count hidden thinking against the cap, so every provider gets the same generous room.
    /// Providers bill only the tokens actually generated, so a high cap costs nothing extra.
    var maxOutputTokens: Int { 16_384 }

    /// Where to create an API key, shown in AI configuration.
    var keyURL: URL {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")!
        case .ollamaCloud: return URL(string: "https://ollama.com/settings/keys")!
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    fileprivate var modelPreference: String { rawValue + "Model" }

    fileprivate var imageInputPreference: String { rawValue + "ImageInput" }

    fileprivate var sharingConsentPreference: String { rawValue + "SharingConsentV1" }

    fileprivate var keychainAccount: String {
        switch self {
        case .openRouter: return "openrouter-api-key"
        case .ollamaCloud: return "ollama-cloud-api-key"
        case .anthropic: return "anthropic-api-key"
        case .openAI: return "openai-api-key"
        }
    }
}

struct AISharingScope: Equatable {
    let provider: AIProvider
    let model: String
    let imageInput: Bool

    init(provider: AIProvider, model: String, imageInput: Bool) {
        self.provider = provider
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = modelID.isEmpty ? provider.defaultModel : modelID
        self.imageInput = imageInput
    }
}

@MainActor
final class AISettings: ObservableObject {
    @Published private(set) var provider: AIProvider
    @Published private(set) var apiKey: String
    @Published private(set) var model: String
    /// Whether the agent may render the current page as an image (needs a vision model).
    @Published private(set) var imageInput: Bool
    @Published private(set) var sharingConsent: AISharingScope?

    private let defaults: UserDefaults
    private static let providerPreference = "drawingAIProvider"

    var isConfigured: Bool { !apiKey.isEmpty }
    var canUseChat: Bool { isConfigured && sharingConsent != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let provider = defaults.string(forKey: Self.providerPreference).flatMap(AIProvider.init(rawValue:)) ?? .openRouter
        self.provider = provider
        let scope = Self.savedScope(for: provider, in: defaults)
        model = scope.model
        imageInput = scope.imageInput
        apiKey = Self.loadKey(for: provider)
        sharingConsent = Self.savedConsent(for: scope, in: defaults)
    }

    func configuration(for provider: AIProvider) -> (apiKey: String, scope: AISharingScope) {
        let scope = Self.savedScope(for: provider, in: defaults)
        let key = provider == self.provider ? apiKey : Self.loadKey(for: provider)
        return (key, scope)
    }

    func deactivate() {
        defaults.removeObject(forKey: provider.sharingConsentPreference)
        sharingConsent = nil
    }

    func removeAPIKey(for provider: AIProvider) throws {
        try Self.saveKey("", for: provider)
        defaults.removeObject(forKey: provider.sharingConsentPreference)
        if self.provider == provider {
            sharingConsent = nil
            apiKey = ""
        }
    }

    static func validateActivation(apiKey: String, scope: AISharingScope) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SettingsError.missingKey(scope.provider) }
        guard !scope.model.contains(where: { $0.isWhitespace }) else { throw SettingsError.invalidModel(scope.provider) }
        guard !key.contains(where: { $0.isWhitespace }) else { throw SettingsError.invalidKey(scope.provider) }
        return key
    }

    func activate(apiKey: String, scope: AISharingScope) throws {
        let provider = scope.provider
        let key = try Self.validateActivation(apiKey: apiKey, scope: scope)
        let previousKey = provider == self.provider ? self.apiKey : Self.loadKey(for: provider)
        if key != previousKey { try Self.saveKey(key, for: provider) }
        if provider != self.provider { deactivate() }
        defaults.set(scope.model, forKey: provider.modelPreference)
        defaults.set(scope.imageInput, forKey: provider.imageInputPreference)
        defaults.set(["model": scope.model, "imageInput": scope.imageInput], forKey: provider.sharingConsentPreference)
        defaults.set(provider.rawValue, forKey: Self.providerPreference)
        self.apiKey = key
        self.imageInput = scope.imageInput
        self.model = scope.model
        self.provider = provider
        self.sharingConsent = scope
    }

    private static func savedScope(for provider: AIProvider, in defaults: UserDefaults) -> AISharingScope {
        AISharingScope(provider: provider, model: defaults.string(forKey: provider.modelPreference) ?? provider.defaultModel,
                       imageInput: defaults.bool(forKey: provider.imageInputPreference))
    }

    private static func savedConsent(for scope: AISharingScope, in defaults: UserDefaults) -> AISharingScope? {
        let consent = defaults.dictionary(forKey: scope.provider.sharingConsentPreference)
        guard consent?["model"] as? String == scope.model,
              consent?["imageInput"] as? Bool == scope.imageInput else { return nil }
        return scope
    }

    private static func keychainItem(for provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.local.drawbook",
            kSecAttrAccount as String: provider.keychainAccount
        ]
    }

    private static func loadKey(for provider: AIProvider) -> String {
        var query = keychainItem(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func saveKey(_ key: String, for provider: AIProvider) throws {
        let item = keychainItem(for: provider)
        let query = item as CFDictionary
        if key.isEmpty {
            let status = SecItemDelete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SettingsError.keychain(provider) }
            return
        }

        let data = Data(key.utf8)
        let attributes = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query, attributes)
        if status == errSecItemNotFound {
            var newItem = item
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SettingsError.keychain(provider) }
    }

    private enum SettingsError: LocalizedError {
        case missingKey(AIProvider), invalidKey(AIProvider), invalidModel(AIProvider), keychain(AIProvider)

        var errorDescription: String? {
            switch self {
            case .missingKey(let provider): return "Enter a \(provider.title) API key to activate Drawing AI."
            case .invalidKey(let provider): return "The \(provider.title) API key must be one line with no spaces."
            case .invalidModel(let provider): return "Enter a \(provider.title) model ID with no spaces."
            case .keychain(let provider): return "DrawBook couldn’t update the \(provider.title) API key in Keychain."
            }
        }
    }
}
