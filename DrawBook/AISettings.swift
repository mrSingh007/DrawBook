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

    /// The output cap. OpenAI counts hidden reasoning tokens against it, so it gets more room.
    var maxOutputTokens: Int { self == .openAI ? 16_384 : 4096 }

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

    fileprivate var keychainAccount: String {
        switch self {
        case .openRouter: return "openrouter-api-key"
        case .ollamaCloud: return "ollama-cloud-api-key"
        case .anthropic: return "anthropic-api-key"
        case .openAI: return "openai-api-key"
        }
    }
}

@MainActor
final class AISettings: ObservableObject {
    @Published private(set) var provider: AIProvider
    @Published private(set) var apiKey: String
    @Published private(set) var model: String
    /// Whether the agent may render the current page as an image (needs a vision model).
    @Published private(set) var imageInput: Bool

    private let defaults: UserDefaults
    private static let providerPreference = "drawingAIProvider"

    var isConfigured: Bool { !apiKey.isEmpty }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let provider = defaults.string(forKey: Self.providerPreference).flatMap(AIProvider.init(rawValue:)) ?? .openRouter
        self.provider = provider
        model = defaults.string(forKey: provider.modelPreference) ?? provider.defaultModel
        imageInput = defaults.bool(forKey: provider.imageInputPreference)
        apiKey = Self.loadKey(for: provider)
    }

    func configuration(for provider: AIProvider) -> (apiKey: String, model: String, imageInput: Bool) {
        if provider == self.provider { return (apiKey, model, imageInput) }
        return (Self.loadKey(for: provider), defaults.string(forKey: provider.modelPreference) ?? provider.defaultModel,
                defaults.bool(forKey: provider.imageInputPreference))
    }

    func save(provider: AIProvider, apiKey: String, model: String, imageInput: Bool = false) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.contains(where: { $0.isWhitespace }) else { throw SettingsError.invalidModel(provider) }
        guard !key.contains(where: { $0.isWhitespace }) else { throw SettingsError.invalidKey(provider) }

        let previousKey = provider == self.provider ? self.apiKey : Self.loadKey(for: provider)
        if key != previousKey { try Self.saveKey(key, for: provider) }
        let activeModel = modelID.isEmpty ? provider.defaultModel : modelID
        defaults.set(activeModel, forKey: provider.modelPreference)
        defaults.set(imageInput, forKey: provider.imageInputPreference)
        defaults.set(provider.rawValue, forKey: Self.providerPreference)
        self.apiKey = key
        self.imageInput = imageInput
        self.model = activeModel
        self.provider = provider
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
        case invalidKey(AIProvider), invalidModel(AIProvider), keychain(AIProvider)

        var errorDescription: String? {
            switch self {
            case .invalidKey(let provider): return "The \(provider.title) API key must be one line with no spaces."
            case .invalidModel(let provider): return "Enter a \(provider.title) model ID with no spaces."
            case .keychain(let provider): return "DrawBook couldn’t update the \(provider.title) API key in Keychain."
            }
        }
    }
}
