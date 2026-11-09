import XCTest
@testable import DrawBook

final class AIClientTests: XCTestCase {
    private let tools = [AIToolDefinition(
        name: "apply_patch", description: "Apply a JSON patch to the page.",
        parameters: ["type": "object", "properties": ["ops": ["type": "array"]], "required": ["ops"]]
    )]

    @MainActor
    func testProviderRoutingSendsToolsInTheExpectedProtocol() async throws {
        for provider in AIProvider.allCases {
            let reply = try await AIClient.complete(
                provider: provider, apiKey: " fixture-key ", model: provider.defaultModel,
                messages: [AIChatMessage(role: .system, content: "sys"), AIChatMessage(role: .user, content: "Add a box")],
                tools: tools
            ) { request in
                let url = try XCTUnwrap(request.url)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.timeoutInterval, 90)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
                let body = try Self.body(request)
                XCTAssertEqual(body["model"] as? String, provider.defaultModel)
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
                XCTAssertEqual(messages.last?["content"] as? String, "Add a box")
                let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
                XCTAssertEqual(tool["type"] as? String, "function")
                let function = try XCTUnwrap(tool["function"] as? [String: Any])
                XCTAssertEqual(function["name"] as? String, "apply_patch")
                XCTAssertEqual((function["parameters"] as? [String: Any])?["type"] as? String, "object")

                XCTAssertEqual(url, provider.endpoint)
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), provider == .anthropic ? "fixture-key" : nil)
                switch provider.wireFormat {
                case .openAICompatible:
                    XCTAssertEqual(body["tool_choice"] as? String, "auto")
                    XCTAssertEqual(body[provider.maxTokensField] as? Int, 16_384)
                    XCTAssertNil(body[provider == .openAI ? "max_tokens" : "max_completion_tokens"])
                    XCTAssertNil(body["stream"])
                    return try Self.response(["choices": [["finish_reason": "stop", "message": ["content": "Done."]]]], url: url)
                case .ollama:
                    XCTAssertEqual(body["stream"] as? Bool, false)
                    XCTAssertEqual((body["options"] as? [String: Any])?["num_predict"] as? Int, 16_384)
                    XCTAssertNil(body["max_tokens"])
                    XCTAssertNil(body["tool_choice"])
                    return try Self.response(["done": true, "done_reason": "stop",
                                              "message": ["role": "assistant", "content": "Done.", "thinking": "hmm"]], url: url)
                }
            }
            XCTAssertEqual(reply, AIChatMessage(role: .assistant, content: "Done."))
        }
    }

    @MainActor
    func testAgentLoopRunsToolsAndEchoesThemInProviderFormat() async throws {
        for provider in AIProvider.allCases {
            var requests: [[String: Any]] = []
            var executed: [AIToolCall] = []
            var events: [AIAgentEvent] = []
            let result = try await AIClient.runAgent(
                provider: provider, apiKey: "key", model: "model", system: "You draw.",
                history: [], prompt: "Add a box", tools: tools,
                onEvent: { events.append($0) },
                execute: { call in
                    executed.append(call)
                    return AIToolOutcome(result: #"{"ok":true}"#, summary: "Applied 1 change")
                }
            ) { request in
                let url = try XCTUnwrap(request.url)
                requests.append(try Self.body(request))
                if requests.count == 2 {
                    return provider.wireFormat == .openAICompatible
                        ? try Self.response(["choices": [["finish_reason": "stop", "message": ["content": "Added a box."]]]], url: url)
                        : try Self.response(["done": true, "message": ["content": "Added a box."]], url: url)
                }
                switch provider.wireFormat {
                case .openAICompatible:
                    return try Self.response(["choices": [["finish_reason": "tool_calls", "message": [
                        "content": NSNull(),
                        "tool_calls": [["id": "call_abc", "type": "function",
                                        "function": ["name": "apply_patch", "arguments": #"{"ops":[1]}"#]]]
                    ]]]], url: url)
                case .ollama:
                    return try Self.response(["done": true, "message": [
                        "content": "", "tool_calls": [["function": ["name": "apply_patch", "arguments": ["ops": [1]]]]]
                    ]], url: url)
                }
            }

            XCTAssertEqual(result.reply, "Added a box.")
            XCTAssertEqual(executed.map(\.name), ["apply_patch"])
            XCTAssertEqual(executed.first?.arguments, ["ops": [1]])
            XCTAssertEqual(events, [.toolStarted(name: "apply_patch"),
                                    .toolFinished(name: "apply_patch", summary: "Applied 1 change")])
            XCTAssertEqual(result.newMessages.map(\.role), [.user, .assistant, .tool, .assistant])
            XCTAssertEqual(result.newMessages[2].content, #"{"ok":true}"#)
            XCTAssertEqual(result.newMessages[2].toolCallID, executed.first?.id)

            XCTAssertEqual(requests.count, 2)
            let messages = try XCTUnwrap(requests[1]["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
            let assistant = messages[2], tool = messages[3]
            let call = try XCTUnwrap((assistant["tool_calls"] as? [[String: Any]])?.first)
            let function = try XCTUnwrap(call["function"] as? [String: Any])
            XCTAssertEqual(function["name"] as? String, "apply_patch")
            XCTAssertEqual(tool["content"] as? String, #"{"ok":true}"#)
            switch provider.wireFormat {
            case .openAICompatible:
                XCTAssertTrue(assistant["content"] is NSNull)
                XCTAssertEqual(call["id"] as? String, "call_abc")
                XCTAssertEqual(call["type"] as? String, "function")
                XCTAssertEqual(function["arguments"] as? String, #"{"ops":[1]}"#)
                XCTAssertEqual(tool["tool_call_id"] as? String, "call_abc")
                XCTAssertNil(tool["tool_name"])
            case .ollama:
                XCTAssertEqual(assistant["content"] as? String, "")
                XCTAssertEqual((function["arguments"] as? [String: Any])?["ops"] as? [Int], [1])
                XCTAssertEqual(tool["tool_name"] as? String, "apply_patch")
                XCTAssertNil(tool["tool_call_id"])
            }
        }
    }

    @MainActor
    func testUnparsableArgumentsReachExecuteAsRawString() async throws {
        var received: JSONValue?
        var round = 0
        _ = try await AIClient.runAgent(
            provider: .openRouter, apiKey: "key", model: "model", system: "s", history: [], prompt: "p", tools: tools,
            execute: { call in received = call.arguments; return AIToolOutcome(result: "error: invalid JSON", summary: "Failed") }
        ) { request in
            round += 1
            let message: [String: Any] = round == 1
                ? ["tool_calls": [["id": "c1", "function": ["name": "apply_patch", "arguments": "{ops:"]]]]
                : ["content": "Sorry, fixed."]
            // Some providers report "stop" even with tool calls.
            return try Self.response(["choices": [["finish_reason": "stop", "message": message]]], url: request.url!)
        }
        XCTAssertEqual(received, .string("{ops:"))
    }

    @MainActor
    func testLoopStopsAfterMaxSteps() async throws {
        var calls = 0
        do {
            _ = try await AIClient.runAgent(
                provider: .ollamaCloud, apiKey: "key", model: "model", system: "s", history: [], prompt: "p",
                tools: tools, maxSteps: 3, execute: { _ in AIToolOutcome(result: "{}", summary: "ok") }
            ) { request in
                calls += 1
                return try Self.response(["done": true, "message": [
                    "content": "", "tool_calls": [["function": ["name": "get_page_state", "arguments": [:]]]]
                ]], url: request.url!)
            }
            XCTFail("Expected tooManySteps")
        } catch {
            XCTAssertEqual(error as? AIClient.Failure, .tooManySteps)
        }
        XCTAssertEqual(calls, 3)
    }

    @MainActor
    func testFailuresMapToClearErrors() async throws {
        let cases: [(AIProvider, Int, String, AIClient.Failure)] = [
            (.openRouter, 404, #"{"error":{"message":"No endpoints found that support tool use","code":404}}"#, .toolsUnsupported(.openRouter)),
            (.ollamaCloud, 400, #"{"error":"gemma does not support tools"}"#, .toolsUnsupported(.ollamaCloud)),
            (.openRouter, 404, #"{"error":{"message":"No such model"}}"#, .requestFailed(.openRouter, 404)),
            (.openRouter, 200, #"{"error":{"message":"Rate limited","code":429}}"#, .requestFailed(.openRouter, 429)),
            (.openRouter, 200, #"{"choices":[{"finish_reason":"length","message":{"content":"Half"}}]}"#, .replyTooLong),
            (.ollamaCloud, 200, #"{"done":true,"done_reason":"length","message":{"content":"Half"}}"#, .replyTooLong),
            (.ollamaCloud, 200, #"{"error":"boom"}"#, .requestFailed(.ollamaCloud, 500)),
            (.openAI, 404, #"{"error":{"message":"The model `gpt-x` does not exist","type":"invalid_request_error","code":"model_not_found"}}"#, .requestFailed(.openAI, 404)),
            (.anthropic, 401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, .requestFailed(.anthropic, 401)),
            (.anthropic, 200, #"{"choices":[{"finish_reason":"length","message":{"content":"Half"}}]}"#, .replyTooLong),
            (.openRouter, 200, #"{"choices":[{"finish_reason":"stop","message":{"content":"  "}}]}"#, .invalidResponse),
        ]
        for (provider, status, body, expected) in cases {
            do {
                _ = try await AIClient.complete(
                    provider: provider, apiKey: "key", model: "model",
                    messages: [AIChatMessage(role: .user, content: "Hi")], tools: tools
                ) { request in
                    let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil))
                    return (Data(body.utf8), response)
                }
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AIClient.Failure, expected, body)
            }
        }
    }

    @MainActor
    func testMalformedErrorCodeInSuccessfulResponseDoesNotCrash() async throws {
        for code: Any in [1e100, 0.5, Double.greatestFiniteMagnitude] {
            do {
                _ = try await AIClient.complete(
                    provider: .openRouter, apiKey: "key", model: "model",
                    messages: [AIChatMessage(role: .user, content: "hi")], tools: []
                ) { request in try Self.response(["error": ["code": code, "message": "bad"]], url: request.url!) }
                XCTFail("Expected an error")
            } catch {
                XCTAssertEqual(error as? AIClient.Failure, .requestFailed(.openRouter, 500))
            }
        }
    }

    func testCompactedHistoryKeepsNoImages() {
        let messages = [AIChatMessage(role: .user, content: "p"),
                        AIChatMessage(role: .tool, content: String(repeating: "x", count: 5_000), images: [Data([1, 2])])]
        let compact = AIClient.compacted(messages)
        XCTAssertTrue(compact.allSatisfy { $0.images.isEmpty })
        XCTAssertEqual(compact[1].content, AIClient.omittedToolResult)
    }

    @MainActor
    func testRejectsInvalidSettingsAndLongPrompts() async {
        for (key, prompt, expected) in [(" ", "Hi", AIClient.Failure.invalidSettings),
                                        ("key", String(repeating: "a", count: 8_001), .promptTooLarge)] {
            do {
                _ = try await AIClient.runAgent(
                    provider: .openRouter, apiKey: key, model: "model", system: "s", history: [], prompt: prompt,
                    tools: tools, execute: { _ in AIToolOutcome(result: "", summary: "") }
                ) { _ in XCTFail("Should not send"); throw URLError(.badURL) }
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AIClient.Failure, expected)
            }
        }
    }

    func testHistoryTrimmingKeepsWholeTurnsAndShortensOldPageState() {
        let filler = String(repeating: "x", count: 30_000)
        let call = AIToolCall(id: "c1", name: "get_page_state", arguments: [:])
        let history = [
            AIChatMessage(role: .system, content: "old system"),
            AIChatMessage(role: .user, content: filler),
            AIChatMessage(role: .assistant, content: "Old answer"),
            AIChatMessage(role: .user, content: "Read the page"),
            AIChatMessage(role: .assistant, content: "", toolCalls: [call]),
            AIChatMessage(role: .tool, content: String(repeating: "p", count: 20_000), toolCallID: "c1", toolName: "get_page_state"),
            AIChatMessage(role: .assistant, content: "It has a box."),
            AIChatMessage(role: .user, content: filler),
            AIChatMessage(role: .assistant, content: "Recent answer"),
        ]
        let trimmed = AIClient.trimmedHistory(history)
        XCTAssertEqual(trimmed.map(\.role), [.user, .assistant, .tool, .assistant, .user, .assistant])
        XCTAssertEqual(trimmed.first?.content, "Read the page")
        XCTAssertEqual(trimmed[1].toolCalls, [call])
        XCTAssertEqual(trimmed[2].content, AIClient.omittedToolResult)
        XCTAssertEqual(trimmed[2].toolCallID, "c1")
        XCTAssertEqual(trimmed.last?.content, "Recent answer")
    }

    @MainActor
    func testToolImagesFollowToolResultsAsOneUserMessage() async throws {
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let calls = [AIToolCall(id: "c1", name: "view_page", arguments: [:]),
                     AIToolCall(id: "c2", name: "get_page_state", arguments: [:])]
        for provider in AIProvider.allCases {
            let messages = [
                AIChatMessage(role: .user, content: "Look"),
                AIChatMessage(role: .assistant, content: "", toolCalls: calls),
                AIChatMessage(role: .tool, content: "{}", toolCallID: "c1", toolName: "view_page", images: [image]),
                AIChatMessage(role: .tool, content: "{}", toolCallID: "c2", toolName: "get_page_state"),
            ]
            _ = try await AIClient.complete(provider: provider, apiKey: "key", model: "model",
                                                    messages: messages, tools: tools) { request in
                let sent = try XCTUnwrap(Self.body(request)["messages"] as? [[String: Any]])
                // Tool results stay adjacent to their call; the image follows them.
                XCTAssertEqual(sent.map { $0["role"] as? String }, ["user", "assistant", "tool", "tool", "user"])
                let last = try XCTUnwrap(sent.last)
                switch provider.wireFormat {
                case .openAICompatible:
                    let parts = try XCTUnwrap(last["content"] as? [[String: Any]])
                    XCTAssertEqual(parts.first?["text"] as? String, AIClient.imageNote)
                    let url = (parts.last?["image_url"] as? [String: Any])?["url"] as? String
                    XCTAssertEqual(url, "data:image/jpeg;base64," + image.base64EncodedString())
                    return try Self.response(["choices": [["finish_reason": "stop", "message": ["content": "A box."]]]],
                                             url: request.url!)
                case .ollama:
                    XCTAssertEqual(last["content"] as? String, AIClient.imageNote)
                    XCTAssertEqual(last["images"] as? [String], [image.base64EncodedString()])
                    return try Self.response(["done": true, "message": ["content": "A box."]], url: request.url!)
                }
            }
        }
    }

    @MainActor
    func testOnlyNewestImagesAreSent() async throws {
        let images = (0..<3).map { Data([UInt8($0)]) }
        var messages = [AIChatMessage(role: .user, content: "Look")]
        for (index, image) in images.enumerated() {
            let id = "c\(index)"
            messages.append(AIChatMessage(role: .assistant, content: "",
                                          toolCalls: [AIToolCall(id: id, name: "view_page", arguments: [:])]))
            messages.append(AIChatMessage(role: .tool, content: "{}", toolCallID: id, toolName: "view_page", images: [image]))
        }
        _ = try await AIClient.complete(provider: .ollamaCloud, apiKey: "key", model: "model",
                                                messages: messages, tools: tools) { request in
            let sent = try XCTUnwrap(Self.body(request)["messages"] as? [[String: Any]])
            let imageMessages = sent.filter { $0["role"] as? String == "user" }.dropFirst()
            XCTAssertEqual(imageMessages.map { $0["content"] as? String },
                           [AIClient.omittedImageNote, AIClient.imageNote, AIClient.imageNote])
            XCTAssertEqual(imageMessages.compactMap { $0["images"] as? [String] },
                           images.suffix(2).map { [$0.base64EncodedString()] })
            return try Self.response(["done": true, "message": ["content": "ok"]], url: request.url!)
        }
    }

    @MainActor
    func testImageRejectionMapsToImagesUnsupported() async throws {
        let messages = [AIChatMessage(role: .user, content: "Look"),
                        AIChatMessage(role: .tool, content: "{}", toolCallID: "c1", toolName: "view_page", images: [Data([1])])]
        let cases: [(AIProvider, Int, String)] = [
            (.openRouter, 404, #"{"error":{"message":"No endpoints found that support image input","code":404}}"#),
            (.ollamaCloud, 400, #"{"error":"model does not support images"}"#),
            (.openAI, 400, #"{"error":{"message":"Invalid content type. image_url is only supported by certain models.","type":"invalid_request_error"}}"#),
        ]
        for (provider, status, body) in cases {
            do {
                _ = try await AIClient.complete(provider: provider, apiKey: "key", model: "model",
                                                        messages: messages, tools: tools) { request in
                    let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil))
                    return (Data(body.utf8), response)
                }
                XCTFail("Expected imagesUnsupported")
            } catch {
                XCTAssertEqual(error as? AIClient.Failure, .imagesUnsupported(provider), body)
            }
        }
    }

    func testEveryProviderHasDistinctStorageAndOpenAICompatibleProvidersShareTheWireFormat() {
        XCTAssertEqual(Set(AIProvider.allCases.map(\.endpoint)).count, AIProvider.allCases.count)
        XCTAssertEqual(AIProvider.allCases.filter { $0.wireFormat == .ollama }, [.ollamaCloud])
        XCTAssertEqual(AIProvider.anthropic.defaultModel, "claude-opus-5-5")
        XCTAssertEqual(AIProvider.openAI.maxTokensField, "max_completion_tokens")
        // A low cap cuts off large patch tool calls and reasoning models' replies ("ran out of room").
        for provider in AIProvider.allCases { XCTAssertEqual(provider.maxOutputTokens, 16_384) }
    }

    func testHistoryTrimmingDropsImages() {
        let history = [AIChatMessage(role: .user, content: "Look"),
                       AIChatMessage(role: .tool, content: "{}", toolCallID: "c1", toolName: "view_page", images: [Data([1])]),
                       AIChatMessage(role: .assistant, content: "A box.")]
        XCTAssertEqual(AIClient.trimmedHistory(history).flatMap(\.images), [])
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private static func response(_ payload: [String: Any], url: URL) throws -> (Data, URLResponse) {
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (try JSONSerialization.data(withJSONObject: payload), response)
    }
}
