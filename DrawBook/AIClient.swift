import Foundation

struct AIToolDefinition: Equatable {
    let name: String
    let description: String
    /// A JSON Schema object describing the arguments.
    let parameters: JSONValue
}

struct AIToolCall: Equatable {
    let id: String
    let name: String
    /// The parsed arguments object, or `.string(raw)` when the model sent text that isn't JSON.
    let arguments: JSONValue
}

struct AIChatMessage: Equatable {
    enum Role: String { case system, user, assistant, tool }

    var role: Role
    var content: String
    var toolCalls: [AIToolCall] = []
    var toolCallID: String? = nil
    var toolName: String? = nil
    /// JPEG images. A tool message's images are sent in a user message right after the tool results,
    /// because chat APIs only accept images from the user.
    var images: [Data] = []
}

struct AIToolOutcome: Equatable {
    var result: String
    var summary: String
    var images: [Data] = []

    init(result: String, summary: String, images: [Data] = []) {
        self.result = result
        self.summary = summary
        self.images = images
    }
}

enum AIAgentEvent: Equatable {
    case toolStarted(name: String)
    case toolFinished(name: String, summary: String)
}

/// Talks to every supported provider. OpenRouter, Claude and OpenAI share the OpenAI-compatible
/// chat-completions format; Ollama Cloud uses its native chat API.
enum AIClient {
    enum Failure: LocalizedError, Equatable {
        case invalidSettings, promptTooLarge, invalidResponse, replyTooLong, tooManySteps
        case toolsUnsupported(AIProvider), imagesUnsupported(AIProvider)
        case requestFailed(AIProvider, Int)

        var errorDescription: String? {
            switch self {
            case .invalidSettings: return "Enter an API key and model for your selected provider in Your Space."
            case .promptTooLarge: return "The request is too long. Try describing one edit at a time."
            case .invalidResponse: return "The model did not return a usable reply. Try again or choose another model."
            case .replyTooLong: return "The model ran out of room to finish. Try a smaller edit or choose another model."
            case .tooManySteps: return "The assistant took too many steps. Try a smaller request."
            case .toolsUnsupported: return "This model can’t use DrawBook’s page tools. Choose a model with tool calling in Your Space."
            case let .imagesUnsupported(provider): return "This model can’t view images. Turn off Send Page as Image to AI for \(provider.title) in Your Space → AI configuration, or choose a vision model."
            case let .requestFailed(provider, status):
                switch status {
                case 401, 403: return "\(provider.title) rejected the request. Check your API key and model access in Your Space."
                case 402: return "\(provider.title) requires payment for this request. Check your model and account."
                case 404: return "\(provider.title) could not find the model. Check its ID in Your Space."
                case 429: return "\(provider.title) reached a rate limit. Wait a moment or choose another model."
                case 502, 503, 504, 529: return "\(provider.title) is unavailable or overloaded (\(status)). Try again in a moment."
                default: return "\(provider.title) returned an error (\(status)). Check the model in Your Space or try again."
                }
            }
        }
    }

    static let promptLimit = 8_000
    static let historyLimit = 48_000
    static let largeToolResultLimit = 4_000
    static let omittedToolResult = "[earlier page state omitted]"
    /// Only the newest images are sent, to keep requests small (a page image is roughly 50-100 KB).
    static let imageLimit = 2
    static let imageNote = "Page image from view_page:"
    static let omittedImageNote = "[earlier page image omitted]"

    typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    // MARK: Agent loop

    @MainActor
    static func runAgent(provider: AIProvider, apiKey: String, model: String,
                         system: String, history: [AIChatMessage], prompt: String,
                         tools: [AIToolDefinition], maxSteps: Int = 12,
                         onEvent: (AIAgentEvent) -> Void = { _ in },
                         execute: (AIToolCall) async -> AIToolOutcome,
                         send: Send = { try await URLSession.shared.data(for: $0) })
        async throws -> (reply: String, newMessages: [AIChatMessage]) {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidSettings }
        guard prompt.utf8.count <= promptLimit else { throw Failure.promptTooLarge }

        let context = [AIChatMessage(role: .system, content: system)] + trimmedHistory(history)
        var turn = [AIChatMessage(role: .user, content: prompt)]
        for _ in 0..<maxSteps {
            let reply = try await complete(provider: provider, apiKey: apiKey, model: model,
                                           messages: context + turn, tools: tools, send: send)
            turn.append(reply)
            guard !reply.toolCalls.isEmpty else { return (reply.content, turn) }
            for call in reply.toolCalls {
                onEvent(.toolStarted(name: call.name))
                let outcome = await execute(call)
                onEvent(.toolFinished(name: call.name, summary: outcome.summary))
                turn.append(AIChatMessage(role: .tool, content: outcome.result, toolCallID: call.id,
                                          toolName: call.name, images: outcome.images))
            }
        }
        throw Failure.tooManySteps
    }

    /// What a finished turn keeps in memory: no images (they are only sent within their own
    /// turn) and large tool results replaced by a placeholder, as `trimmedHistory` would send them.
    static func compacted(_ messages: [AIChatMessage]) -> [AIChatMessage] {
        messages.map { message in
            var compact = message
            compact.images = []
            if message.role == .tool, message.content.utf8.count > largeToolResultLimit {
                compact.content = omittedToolResult
            }
            return compact
        }
    }

    /// Drops system messages, keeps whole turns (a user message and everything after it) newest first
    /// within `historyLimit`, shortens large tool results from earlier turns, and drops their images.
    static func trimmedHistory(_ history: [AIChatMessage]) -> [AIChatMessage] {
        var turns: [[AIChatMessage]] = []
        for message in history where message.role != .system {
            if message.role == .user { turns.append([message]) }
            else if !turns.isEmpty { turns[turns.count - 1].append(message) }
        }
        var kept: [[AIChatMessage]] = []
        var remaining = historyLimit
        for turn in turns.reversed() {
            let compact = compacted(turn)
            let size = compact.reduce(0) { $0 + byteCount($1) }
            guard size <= remaining else { break }
            remaining -= size
            kept.append(compact)
        }
        return kept.reversed().flatMap { $0 }
    }

    private static func byteCount(_ message: AIChatMessage) -> Int {
        message.content.utf8.count + message.toolCalls.reduce(0) {
            $0 + $1.id.utf8.count + $1.name.utf8.count + $1.arguments.jsonString.utf8.count
        }
    }

    // MARK: Transport

    @MainActor
    static func complete(provider: AIProvider, apiKey: String, model: String,
                         messages: [AIChatMessage], tools: [AIToolDefinition],
                         send: Send = { try await URLSession.shared.data(for: $0) }) async throws -> AIChatMessage {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !model.isEmpty else { throw Failure.invalidSettings }

        var body = JSONObject()
        body["model"] = .string(model)
        body["messages"] = .array(encode(messages, for: provider))
        let sendsImages = messages.contains { !$0.images.isEmpty }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                ["type": "function",
                 "function": ["name": .string(tool.name), "description": .string(tool.description),
                              "parameters": tool.parameters]]
            })
        }
        switch provider.wireFormat {
        case .openAICompatible:
            if !tools.isEmpty { body["tool_choice"] = "auto" }
            body[provider.maxTokensField] = .number(Double(provider.maxOutputTokens))
        case .ollama:
            body["stream"] = false
            body["options"] = ["num_predict": .number(Double(provider.maxOutputTokens))]
        }
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if provider == .anthropic { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(JSONValue.object(body).jsonString.utf8)

        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(response.statusCode) else {
            throw failure(provider, status: response.statusCode, body: text, sendsImages: sendsImages)
        }
        guard let json = try? JSONValue(parsing: text), json.objectValue != nil else { throw Failure.invalidResponse }
        let priorCalls = messages.reduce(0) { $0 + $1.toolCalls.count }
        let reply: AIChatMessage
        switch provider.wireFormat {
        case .openAICompatible:
            reply = try decodeOpenAICompatible(json, provider: provider, priorCalls: priorCalls, sendsImages: sendsImages)
        case .ollama:
            reply = try decodeOllama(json, provider: provider, priorCalls: priorCalls, sendsImages: sendsImages)
        }
        guard !reply.toolCalls.isEmpty || !reply.content.isEmpty else { throw Failure.invalidResponse }
        return reply
    }

    private static func failure(_ provider: AIProvider, status: Int, body: String, sendsImages: Bool) -> Failure {
        let text = body.lowercased()
        if sendsImages, [400, 404, 415, 422, 500].contains(status),
           ["image", "vision", "multimodal", "modalit"].contains(where: text.contains) {
            return .imagesUnsupported(provider)
        }
        if status == 400 || status == 404, text.contains("tool") { return .toolsUnsupported(provider) }
        return .requestFailed(provider, status)
    }

    /// Encodes the conversation. Images from a run of tool results follow it as one user message,
    /// and only the newest `imageLimit` images are included.
    private static func encode(_ messages: [AIChatMessage], for provider: AIProvider) -> [JSONValue] {
        var budget = imageLimit
        var kept = [[Data]](repeating: [], count: messages.count)
        for index in messages.indices.reversed() where budget > 0 {
            let images = Array(messages[index].images.suffix(budget))
            kept[index] = images
            budget -= images.count
        }
        var output: [JSONValue] = []
        var pending: [Data] = []
        var omitted = false
        func flush() {
            guard !pending.isEmpty || omitted else { return }
            let note = pending.isEmpty ? omittedImageNote : imageNote
            output.append(userImages(note, pending, for: provider))
            pending = []
            omitted = false
        }
        for (index, message) in messages.enumerated() {
            if message.role != .tool { flush() }
            if message.role == .tool {
                output.append(encode(message, for: provider))
                pending += kept[index]
                if kept[index].isEmpty && !message.images.isEmpty { omitted = true }
            } else if message.images.isEmpty || kept[index].isEmpty {
                output.append(encode(message, for: provider))
            } else {
                output.append(userImages(message.content, kept[index], for: provider, role: message.role))
            }
        }
        flush()
        return output
    }

    private static func userImages(_ text: String, _ images: [Data], for provider: AIProvider,
                                   role: AIChatMessage.Role = .user) -> JSONValue {
        switch provider.wireFormat {
        case .openAICompatible:
            guard !images.isEmpty else { return ["role": .string(role.rawValue), "content": .string(text)] }
            let parts: [JSONValue] = [["type": "text", "text": .string(text)]] + images.map { image in
                ["type": "image_url",
                 "image_url": ["url": .string("data:image/jpeg;base64," + image.base64EncodedString())]]
            }
            return ["role": .string(role.rawValue), "content": .array(parts)]
        case .ollama:
            var object: JSONObject = ["role": .string(role.rawValue), "content": .string(text)]
            if !images.isEmpty { object["images"] = .array(images.map { .string($0.base64EncodedString()) }) }
            return .object(object)
        }
    }

    private static func encode(_ message: AIChatMessage, for provider: AIProvider) -> JSONValue {
        var object = JSONObject()
        object["role"] = .string(message.role.rawValue)
        let hasCalls = message.role == .assistant && !message.toolCalls.isEmpty
        object["content"] = hasCalls && message.content.isEmpty && provider.wireFormat == .openAICompatible ? .null : .string(message.content)
        if hasCalls {
            object["tool_calls"] = .array(message.toolCalls.map { call in
                switch provider.wireFormat {
                case .openAICompatible:
                    let arguments = call.arguments.stringValue ?? call.arguments.jsonString
                    return ["id": .string(call.id), "type": "function",
                            "function": ["name": .string(call.name), "arguments": .string(arguments)]]
                case .ollama:
                    let arguments: JSONValue = call.arguments.objectValue != nil ? call.arguments : .object(JSONObject())
                    return ["function": ["name": .string(call.name), "arguments": arguments]]
                }
            })
        }
        if message.role == .tool {
            switch provider.wireFormat {
            case .openAICompatible: object["tool_call_id"] = message.toolCallID.map(JSONValue.string) ?? ""
            case .ollama: object["tool_name"] = message.toolName.map(JSONValue.string) ?? ""
            }
        }
        return .object(object)
    }

    private static func decodeOpenAICompatible(_ json: JSONValue, provider: AIProvider, priorCalls: Int,
                                         sendsImages: Bool) throws -> AIChatMessage {
        if let error = json["error"], error != .null {
            // The provider controls this value; never trap on a non-integral or out-of-range code.
            let code = error["code"]?.numberValue.flatMap { Int(exactly: $0) }
                ?? error["code"]?.stringValue.flatMap { Int($0) } ?? 500
            let detail = [error["message"]?.stringValue, error["type"]?.stringValue].compactMap { $0 }.joined(separator: " ")
            throw failure(provider, status: code, body: detail, sendsImages: sendsImages)
        }
        guard let choice = json["choices"]?.arrayValue?.first, let message = choice["message"],
              message.objectValue != nil else { throw Failure.invalidResponse }
        if choice["finish_reason"]?.stringValue == "length" { throw Failure.replyTooLong }
        return try decodeMessage(message, priorCalls: priorCalls)
    }

    private static func decodeOllama(_ json: JSONValue, provider: AIProvider, priorCalls: Int,
                                     sendsImages: Bool) throws -> AIChatMessage {
        if let error = json["error"], error != .null {
            throw failure(provider, status: 500, body: error.stringValue ?? "", sendsImages: sendsImages)
        }
        if json["done_reason"]?.stringValue == "length" { throw Failure.replyTooLong }
        guard json["done"]?.boolValue != false, let message = json["message"],
              message.objectValue != nil else { throw Failure.invalidResponse }
        return try decodeMessage(message, priorCalls: priorCalls)
    }

    /// Reads content and tool calls from either wire format. Arguments may be a JSON string or an object.
    private static func decodeMessage(_ message: JSONValue, priorCalls: Int) throws -> AIChatMessage {
        let content = (message["content"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let calls = try (message["tool_calls"]?.arrayValue ?? []).enumerated().map { index, call -> AIToolCall in
            guard let function = call["function"], let name = function["name"]?.stringValue, !name.isEmpty else {
                throw Failure.invalidResponse
            }
            let arguments: JSONValue
            switch function["arguments"] {
            case let .string(raw)?:
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { arguments = .object(JSONObject()) }
                else if let parsed = try? JSONValue(parsing: trimmed), parsed.objectValue != nil { arguments = parsed }
                else { arguments = .string(raw) }
            case nil, .null?: arguments = .object(JSONObject())
            case let value?: arguments = value
            }
            let id = call["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(priorCalls + index + 1)"
            return AIToolCall(id: id, name: name, arguments: arguments)
        }
        return AIChatMessage(role: .assistant, content: content, toolCalls: calls)
    }
}
