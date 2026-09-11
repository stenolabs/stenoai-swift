import Foundation
import StenoDomain
@testable import StenoIntelligence
import Testing

@Suite("Native cloud text model providers", .serialized)
struct CloudTextModelProviderTests {
    @Test("Anthropic live questions send the key only in x-api-key")
    func anthropicLiveQueryHeader() async throws {
        let recorder = CloudRequestRecorder()
        let configuration = makeCloudConfiguration { request in
            recorder.append(request)
            return try cloudResponse(request, object: ["content": [["type": "text", "text": "Synthetic answer"]]])
        }
        let provider = ExternalChatCompletionsLiveQueryStreamer(
            endpoint: cloudTestEndpoint(.anthropic),
            resolvingSecret: { _ in "synthetic-test-key" },
            sessionConfiguration: configuration
        )
        var answer = ""
        for try await chunk in provider.stream(systemInstructions: "Synthetic instruction", userPrompt: "Synthetic question") { answer += chunk }
        #expect(answer == "Synthetic answer")
        let request = try #require(recorder.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "synthetic-test-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test("OpenAI Responses uses strict structured output without storage")
    func openAIContract() async throws {
        let recorder = CloudRequestRecorder()
        let configuration = makeCloudConfiguration { request in
            recorder.append(request)
            return try cloudResponse(request, object: [
                "status": "completed",
                "output": [["content": [[
                    "type": "output_text",
                    "text": validCloudContent("OpenAI"),
                ]]]],
            ])
        }
        let provider = OpenAIResponsesProvider(
            endpoint: cloudTestEndpoint(.openAI, model: "gpt-5-mini"),
            resolvingSecret: { _ in "secret" },
            sessionConfiguration: configuration
        )

        let output = try await provider.generate(
            template: .meetingMinutes,
            request: .reduce([]),
            context: .empty
        )

        #expect(output.sections.first?.markdown == "OpenAI")
        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try cloudRequestJSON(request)
        #expect(body["store"] as? Bool == false)
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
    }

    @Test("OpenAI expands reasoning budget once without splitting content")
    func openAIReasoningBudgetRetriesOnce() async throws {
        let recorder = CloudRequestRecorder()
        let configuration = makeCloudConfiguration { request in
            let call = recorder.append(request)
            if call == 1 {
                return try cloudResponse(request, object: [
                    "status": "incomplete",
                    "incomplete_details": ["reason": "max_output_tokens"],
                    "usage": [
                        "output_tokens_details": ["reasoning_tokens": 2_048],
                    ],
                ])
            }
            return try cloudResponse(request, object: [
                "status": "completed",
                "output": [["content": [[
                    "type": "output_text",
                    "text": validCloudContent("Reasoned"),
                ]]]],
            ])
        }
        let provider = OpenAIResponsesProvider(
            endpoint: cloudTestEndpoint(.openAI),
            sessionConfiguration: configuration
        )

        let output = try await provider.generate(
            template: .meetingMinutes,
            request: .reduce([]),
            context: .empty
        )

        #expect(output.sections.first?.markdown == "Reasoned")
        #expect(recorder.requests.count == 2)
    }

    @Test("repeated OpenAI reasoning exhaustion is not visible truncation")
    func openAIReasoningBudgetStopsAfterOneRetry() async {
        let recorder = CloudRequestRecorder()
        let configuration = makeCloudConfiguration { request in
            recorder.append(request)
            return try cloudResponse(request, object: [
                "status": "incomplete",
                "incomplete_details": ["reason": "max_output_tokens"],
                "usage": [
                    "output_tokens_details": ["reasoning_tokens": 2_048],
                ],
            ])
        }
        let provider = OpenAIResponsesProvider(
            endpoint: cloudTestEndpoint(.openAI),
            sessionConfiguration: configuration
        )

        await #expect(
            throws: OpenAIResponsesProviderError.reasoningBudgetExceeded
        ) {
            _ = try await provider.generate(
                template: .meetingMinutes,
                request: .reduce([]),
                context: .empty
            )
        }
        #expect(recorder.requests.count == 2)
    }

    @Test("OpenAI incomplete output is truncation")
    func openAITruncation() async {
        let configuration = makeCloudConfiguration { request in
            try cloudResponse(request, object: [
                "status": "incomplete",
                "incomplete_details": ["reason": "max_output_tokens"],
            ])
        }
        let provider = OpenAIResponsesProvider(
            endpoint: cloudTestEndpoint(.openAI),
            sessionConfiguration: configuration
        )

        await #expect(throws: TextModelProviderError.responseTruncated) {
            _ = try await provider.generate(
                template: .meetingMinutes,
                request: .reduce([]),
                context: .empty
            )
        }
    }

    @Test("Anthropic counts tokens before using structured output")
    func anthropicContract() async throws {
        let recorder = CloudRequestRecorder()
        let configuration = makeCloudConfiguration { request in
            let call = recorder.append(request)
            if call == 1 {
                return try cloudResponse(request, object: ["input_tokens": 321])
            }
            return try cloudResponse(request, object: [
                "stop_reason": "end_turn",
                "content": [["type": "text", "text": validCloudContent("Anthropic")]],
            ])
        }
        let provider = AnthropicMessagesProvider(
            endpoint: cloudTestEndpoint(.anthropic, model: "claude-sonnet-4-5"),
            resolvingSecret: { _ in "secret" },
            sessionConfiguration: configuration
        )

        let output = try await provider.generate(
            template: .meetingMinutes,
            request: .reduce([]),
            context: .empty
        )

        #expect(output.sections.first?.markdown == "Anthropic")
        #expect(recorder.requests.map(\.url?.path) == [
            "/v1/messages/count_tokens", "/v1/messages",
        ])
        let request = recorder.requests[1]
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        let body = try cloudRequestJSON(request)
        #expect(body["temperature"] as? Int == 0)
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        let format = try #require(outputConfig["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
    }

    @Test("Anthropic rejects oversized input before generation")
    func anthropicContextLimit() async {
        let recorder = CloudRequestRecorder()
        let configuration = makeCloudConfiguration { request in
            recorder.append(request)
            return try cloudResponse(request, object: ["input_tokens": 99_999])
        }
        let provider = AnthropicMessagesProvider(
            endpoint: cloudTestEndpoint(.anthropic),
            sessionConfiguration: configuration
        )

        await #expect(throws: TextModelProviderError.contextWindowExceeded) {
            _ = try await provider.generate(
                template: .meetingMinutes,
                request: .reduce([]),
                context: .empty
            )
        }
        #expect(recorder.requests.count == 1)
    }

    @Test("Bedrock Converse uses an encoded model path and text format schema")
    func bedrockContract() async throws {
        let recorder = CloudRequestRecorder()
        let configuration = makeCloudConfiguration { request in
            recorder.append(request)
            return try cloudResponse(request, object: [
                "stopReason": "end_turn",
                "output": ["message": ["content": [
                    ["text": validCloudContent("Bedrock")],
                ]]],
            ])
        }
        let provider = AmazonBedrockProvider(
            endpoint: cloudTestEndpoint(
                .amazonBedrock,
                model: "eu.anthropic.claude/sonnet"
            ),
            resolvingSecret: { _ in "secret" },
            sessionConfiguration: configuration
        )

        let output = try await provider.generate(
            template: .meetingMinutes,
            request: .reduce([]),
            context: .empty
        )

        #expect(output.sections.first?.markdown == "Bedrock")
        let request = try #require(recorder.requests.first)
        let path = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
        }
        #expect(path == "/model/eu.anthropic.claude%2Fsonnet/converse")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try cloudRequestJSON(request)
        #expect(body["outputConfig"] != nil)
        let inferenceConfig = try #require(body["inferenceConfig"] as? [String: Any])
        #expect(inferenceConfig["temperature"] as? Int == 0)
    }

    @Test("Bedrock guardrail and content filtering are refusals")
    func bedrockFilteringIsRefusal() async {
        let configuration = makeCloudConfiguration { request in
            try cloudResponse(request, object: [
                "stopReason": "guardrail_intervened",
                "output": ["message": ["content": []]],
            ])
        }
        let provider = AmazonBedrockProvider(
            endpoint: cloudTestEndpoint(.amazonBedrock),
            sessionConfiguration: configuration
        )

        await #expect(throws: AmazonBedrockProviderError.refused) {
            _ = try await provider.generate(
                template: .meetingMinutes,
                request: .reduce([]),
                context: .empty
            )
        }
    }

    @Test("Bedrock context window exhaustion is distinct from truncation")
    func bedrockContextWindowExceeded() async {
        let configuration = makeCloudConfiguration { request in
            try cloudResponse(request, object: [
                "stopReason": "model_context_window_exceeded",
                "output": ["message": ["content": []]],
            ])
        }
        let provider = AmazonBedrockProvider(
            endpoint: cloudTestEndpoint(.amazonBedrock),
            sessionConfiguration: configuration
        )

        await #expect(throws: TextModelProviderError.contextWindowExceeded) {
            _ = try await provider.generate(
                template: .meetingMinutes,
                request: .reduce([]),
                context: .empty
            )
        }
    }

    @Test(
        "cloud connection probes contain only synthetic data",
        arguments: TextModelAPIDialect.configurableCloudCases
    )
    func cloudProbeIsSynthetic(_ dialect: TextModelAPIDialect) async throws {
        let recorder = CloudRequestRecorder()
        let configuration = makeCloudConfiguration { request in
            recorder.append(request)
            switch request.url?.path {
            case "/v1/messages/count_tokens":
                return try cloudResponse(request, object: ["input_tokens": 12])
            case "/v1/messages":
                return try cloudResponse(request, object: [
                    "stop_reason": "end_turn",
                    "content": [[
                        "type": "text",
                        "text": validCloudContent("Probe"),
                    ]],
                ])
            case "/v1/responses":
                return try cloudResponse(request, object: [
                    "status": "completed",
                    "output": [["content": [[
                        "type": "output_text",
                        "text": validCloudContent("Probe"),
                    ]]]],
                ])
            default:
                return try cloudResponse(request, object: [
                    "stopReason": "end_turn",
                    "output": ["message": ["content": [[
                        "text": validCloudContent("Probe"),
                    ]]]],
                ])
            }
        }

        let result = try await ExternalTextModelProviderFactory.probe(
            endpoint: cloudTestEndpoint(dialect),
            resolvingSecret: { _ in "top-secret-api-key" },
            sessionConfiguration: configuration
        )

        #expect(result.supportsStructuredGeneration)
        let bodies = try recorder.requests.map(cloudRequestBodyData)
        let joined = String(decoding: bodies.joined(), as: UTF8.self)
        #expect(joined.contains("Synthetic connection test"))
        #expect(!joined.contains("PRIVATE-MEETING-CONTENT"))
        #expect(!joined.contains("top-secret-api-key"))
    }

    @Test(
        "cloud errors and diagnostics exclude provider bodies and secrets",
        arguments: TextModelAPIDialect.configurableCloudCases
    )
    func cloudFailuresAreSafe(_ dialect: TextModelAPIDialect) async throws {
        let configuration = makeCloudConfiguration { request in
            try cloudResponse(
                request,
                status: 400,
                object: ["error": "RAW-PRIVATE-RESPONSE top-secret-api-key"]
            )
        }
        let provider = try ExternalTextModelProviderFactory.makeProvider(
            for: cloudTestEndpoint(dialect),
            resolvingSecret: { _ in "top-secret-api-key" },
            sessionConfiguration: configuration
        )
        var caught: (any Error)?

        do {
            _ = try await provider.generate(
                template: .meetingMinutes,
                request: .map(TranscriptChunk(turns: [
                    TranscriptChunkTurn(
                        speakerName: "Private speaker",
                        start: 0,
                        end: 1,
                        text: "PRIVATE-MEETING-CONTENT"
                    ),
                ])),
                context: .empty
            )
        } catch {
            caught = error
        }

        let error = try #require(caught)
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        #expect(!message.contains("RAW-PRIVATE-RESPONSE"))
        #expect(!message.contains("PRIVATE-MEETING-CONTENT"))
        #expect(!message.contains("top-secret-api-key"))
        let diagnostic = try #require(
            (error as? any TextModelDiagnosticProviding)?.textModelDiagnostic
        )
        let diagnosticJSON = String(
            decoding: try JSONEncoder().encode(diagnostic),
            as: UTF8.self
        )
        #expect(!diagnosticJSON.contains("RAW-PRIVATE-RESPONSE"))
        #expect(!diagnosticJSON.contains("PRIVATE-MEETING-CONTENT"))
        #expect(!diagnosticJSON.contains("top-secret-api-key"))
    }
}

private final class CloudRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { storage } }

    @discardableResult
    func append(_ request: URLRequest) -> Int {
        lock.withLock {
            storage.append(request)
            return storage.count
        }
    }
}

private func cloudTestEndpoint(
    _ dialect: TextModelAPIDialect,
    model: String = "model"
) -> TextModelEndpoint {
    makeTextModelEndpoint(
        name: dialect.displayName,
        baseURL: dialect == .amazonBedrock
            ? URL(string: "https://bedrock-runtime.eu-central-1.amazonaws.com")!
            : dialect.defaultBaseURL!,
        modelID: model,
        requiresAPIKey: true,
        hosting: .cloud,
        dialect: dialect,
        contextWindowTokens: 16_384,
        bedrock: dialect == .amazonBedrock
            ? AmazonBedrockConfiguration(region: "eu-central-1", inferenceProfile: nil)
            : nil
    )
}

private func validCloudContent(_ value: String) -> String {
    """
    {"sections":{"summary":"\(value)","key-topics":"\(value)","decisions":"\(value)","action-items":"\(value)"}}
    """
}

private func makeCloudConfiguration(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSessionConfiguration {
    CloudURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudURLProtocol.self]
    return configuration
}

private func cloudResponse(
    _ request: URLRequest,
    status: Int = 200,
    object: Any
) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, try JSONSerialization.data(withJSONObject: object))
}

private func cloudRequestJSON(_ request: URLRequest) throws -> [String: Any] {
    let data = try cloudRequestBodyData(request)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func cloudRequestBodyData(_ request: URLRequest) throws -> Data {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else {
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if count == 0 { break }
            collected.append(buffer, count: count)
        }
        data = collected
    }
    return data
}

private final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
