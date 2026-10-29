import Foundation
import StenoDomain

public enum OpenAICompatibleProviderError: Error, Equatable, LocalizedError, Sendable {
    case endpointUnreachable(URL)
    case requestTimedOut(URL)
    case redirectBlocked
    case authenticationRejected
    case apiKeyRequired
    case modelNotFound(String)
    case serverError(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .endpointUnreachable(let url):
            "The text-model endpoint at \(url.absoluteString) is unreachable."
        case .requestTimedOut(let url):
            "The text-model endpoint at \(url.absoluteString) did not respond in time."
        case .redirectBlocked:
            "The text-model endpoint tried to redirect the request. Steno blocks redirects to protect your data."
        case .authenticationRejected:
            "The text-model endpoint rejected the API key."
        case .apiKeyRequired:
            "This text-model endpoint requires an API key."
        case .modelNotFound(let modelID):
            "Model \u{201C}\(modelID)\u{201D} is not available at the text-model endpoint."
        case .serverError(let statusCode):
            "The text-model endpoint responded with HTTP \(statusCode)."
        case .invalidResponse:
            "The text-model endpoint did not return a valid structured response."
        }
    }
}

extension OpenAICompatibleProviderError: TextModelDiagnosticProviding {
    public var textModelDiagnostic: TextModelRunDiagnostic {
        let status: Int?
        let code: String
        switch self {
        case .endpointUnreachable: (status, code) = (nil, "endpoint_unreachable")
        case .requestTimedOut: (status, code) = (nil, "request_timed_out")
        case .redirectBlocked: (status, code) = (nil, "redirect_blocked")
        case .authenticationRejected: (status, code) = (nil, "authentication_rejected")
        case .apiKeyRequired: (status, code) = (nil, "api_key_required")
        case .modelNotFound: (status, code) = (404, "model_not_found")
        case .serverError(let statusCode): (status, code) = (statusCode, "server_error")
        case .invalidResponse: (status, code) = (nil, "invalid_response")
        }
        return TextModelRunDiagnostic(
            dialect: TextModelAPIDialect.openAICompatible.rawValue,
            stage: "",
            httpStatus: status,
            providerCode: code,
            parsingFailure: code == "invalid_response" ? "structured_response" : nil
        )
    }
}

public struct TextModelProbeResult: Equatable, Sendable {
    public let isReachable: Bool
    public let isModelAvailable: Bool
    /// Ob der Endpunkt die synthetische strukturierte Generierung von
    /// ExternalTextModelProviderFactory.probe erfolgreich beantwortet hat.
    /// Bei einer reinen Modellisten-Pruefung (kein Aufruf ueber die
    /// Factory) bleibt der Default false.
    public let supportsStructuredGeneration: Bool
    public let configuredContextWindowTokens: Int?
    public let reportedContextWindowTokens: Int?
    public let durationMilliseconds: Int?

    public init(
        isReachable: Bool,
        isModelAvailable: Bool,
        supportsStructuredGeneration: Bool = false,
        configuredContextWindowTokens: Int? = nil,
        reportedContextWindowTokens: Int? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.isReachable = isReachable
        self.isModelAvailable = isModelAvailable
        self.supportsStructuredGeneration = supportsStructuredGeneration
        self.configuredContextWindowTokens = configuredContextWindowTokens
        self.reportedContextWindowTokens = reportedContextWindowTokens
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct OpenAICompatibleProvider: StructuredTextModelProvider {
    public let descriptor: EngineDescriptor
    public let availability: TextModelAvailability = .available

    private let endpoint: TextModelEndpoint
    private let resolvingSecret: TextModelSecretResolving
    private let client: TextModelHTTPClient
    /// Legacy Steno hat das schon einmal gelernt: ein Modell auf das volle
    /// beworbene Kontextfenster laufen zu lassen macht lokale Berichte
    /// langsamer und unzuverlaessiger als mehrere begrenzte Map-Anfragen.
    /// Cloud-Endpunkte behalten ihr konfiguriertes Fenster, weil Latenz und
    /// Speicher dort der Dienst verwaltet, nicht das Geraet des Nutzers.
    private let safetyTokens = 128

    public init(
        endpoint: TextModelEndpoint,
        resolvingSecret: @escaping TextModelSecretResolving = { _ in nil },
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.endpoint = endpoint
        self.resolvingSecret = resolvingSecret
        // Kein automatisches HTTP-Retry in diesem Schritt: das waere eine
        // Verhaltensaenderung. Die Retry-Logik des Clients bleibt fuer die
        // spaeteren Provider (S5/S6) verfuegbar, die sie explizit anfordern.
        self.client = TextModelHTTPClient(
            sessionConfiguration: sessionConfiguration,
            maximumRetries: 0
        )
        self.descriptor = EngineDescriptor(
            name: endpoint.name,
            version: "openai-compat",
            modelVersion: endpoint.modelID
        )
    }

    public var contextWindow: TextModelContextWindow {
        // Der eingetragene Wert gilt, wie er eingetragen ist. Frueher deckelte
        // ein `hosting == .selfHosted` ihn auf 32K, doch `hosting` sagt, wo ein
        // Server steht, nicht wie gross sein Fenster ist: ein Ollama im eigenen
        // Netz gilt als `.cloud` und entkam der Deckelung, ein Loopback-Server
        // bekam sie. Solange das Feld gar nicht einstellbar war, trug jeder
        // Endpunkt den Standard von 4096 und die Deckelung lief leer. Jetzt ist
        // der Wert eine bewusste Angabe des Nutzers, und still etwas anderes zu
        // verwenden waere schlimmer als jede Grenze.
        let maximumTokens = endpoint.contextWindowTokens
        return TextModelContextWindow(
            maximumTokens: maximumTokens,
            reservedResponseTokens: min(4_096, max(1_024, maximumTokens / 8)),
            safetyTokens: safetyTokens
        )
    }

    public func inputTokenCount(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> Int {
        let body = requestBody(
            template: template,
            request: request,
            context: context,
            includesResponseFormat: true
        )
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return max(1, (data.count + 1) / 2)
    }

    public func generate(
        template: Template,
        request: TextModelRequest,
        context: RenderContext
    ) async throws -> StructuredTemplateOutput {
        try Task.checkCancellation()
        // Konservativ und ohne Reparatur-Roundtrip: ein Modell, das bereits
        // etwas Ungueltiges geliefert hat, wird nicht mit einem
        // Nachfassprompt zu etwas Plausiblem ueberredet - die Herkunft
        // dieses Textes waere danach nicht mehr beurteilbar. Ein ungueltiges
        // Ergebnis ist ein Fehler, keine zweite Chance.
        let result = try await completionData(
            template: template,
            request: request,
            context: context,
            startsWithResponseFormat: true
        )
        do {
            return try decodeOutput(
                result.data,
                template: template,
                allowsOuterJSONCodeFence: result.usedResponseFormatFallback
            )
        } catch let error as TextModelProviderError {
            // Die Befunde ueber den Lauf selbst - abgeschnitten, leer, zu
            // gross - reisen unveraendert weiter. Nur sie sagen dem Aufrufer,
            // ob Teilen hilft; als `invalidResponse` waeren sie ununterscheidbar.
            throw error
        } catch {
            throw OpenAICompatibleProviderError.invalidResponse
        }
    }

    public func probe(endpoint: TextModelEndpoint) async throws -> TextModelProbeResult {
        try Task.checkCancellation()
        let secret = try resolvedSecret(for: endpoint)
        // Kurzer Timeout: probe hängt sonst am "Verbindung testen"-Knopf
        // minutenlang an einem stillen Host; Generierung darf dagegen lange dauern.
        let url = endpoint.baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        let result: TextModelHTTPResponse
        do {
            result = try await client.send(request)
        } catch TextModelHTTPClientError.redirectBlocked {
            throw OpenAICompatibleProviderError.redirectBlocked
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw OpenAICompatibleProviderError.endpointUnreachable(
                safeEndpointURL(endpoint)
            )
        }
        guard (200..<300).contains(result.response.statusCode) else {
            throw mappedHTTPError(
                statusCode: result.response.statusCode,
                endpoint: endpoint
            )
        }
        do {
            let models = try JSONDecoder().decode(ModelListResponse.self, from: result.data)
            return TextModelProbeResult(
                isReachable: true,
                isModelAvailable: models.data.contains { $0.id == endpoint.modelID }
            )
        } catch {
            throw OpenAICompatibleProviderError.invalidResponse
        }
    }

    private func requestBody(
        template: Template,
        request: TextModelRequest,
        context: RenderContext,
        includesResponseFormat: Bool,
        usesJSONMode: Bool = false,
        usesCompletionTokenBudget: Bool = false
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": endpoint.modelID,
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content": StructuredTemplatePrompt.instructions(for: template, context: context)],
                [
                    "role": "user",
                    "content": StructuredTemplatePrompt.prompt(
                        for: request,
                        template: template,
                        context: context
                    ),
                ],
            ],
        ]
        // Das Antwortbudget geht immer mit. Frueher hing es an
        // `hosting == .selfHosted`, aber `hosting` beantwortet die
        // Datenschutzfrage, wo ein Server steht, nicht die technische, ob er
        // seine Antwortlaenge selbst begrenzt. Da `inferredHosting` nur
        // Loopback beweisen kann, kommt ein Ollama im eigenen Netz als
        // `.cloud` an und blieb ohne Grenze: es schrieb bis der Kontext voll
        // war, die abgeschnittene Antwort war kein gueltiges JSON, und der
        // TemplateRenderer teilte den Chunk und begann von vorn.
        //
        // Dieser Provider bedient ausschliesslich den generischen Dialekt
        // `openAICompatible`; OpenAI, Anthropic und Bedrock haben eigene
        // Provider und sind von der Grenze nicht betroffen. max_tokens ist
        // Bestandteil der Chat-Completions-API - ein Server, der ihn nicht
        // kennt, ist nicht OpenAI-kompatibel. Und laenger als das reservierte
        // Budget darf die Antwort ohnehin nicht werden: sie muss in die
        // naechste Reduce-Stufe passen.
        //
        // Neuere Reasoning-Modelle, etwa hinter Azure OpenAI, kennen nur noch
        // max_completion_tokens. Welcher der beiden Namen gilt, sagt nur der
        // Server - `completionData` faellt darauf zurueck, wenn er den ersten
        // ausdruecklich ablehnt.
        body[usesCompletionTokenBudget ? "max_completion_tokens" : "max_tokens"]
            = contextWindow.reservedResponseTokens
        if includesResponseFormat {
            body["response_format"] = usesJSONMode
                ? ["type": "json_object"]
                : StructuredTemplateCodec.openAIResponseFormat(for: template)
        }
        return body
    }

    private func completionData(
        template: Template,
        request: TextModelRequest,
        context: RenderContext,
        startsWithResponseFormat: Bool
    ) async throws -> (data: Data, usedResponseFormatFallback: Bool) {
        var result = try await completionWithBudgetFallback(
            template: template,
            request: request,
            context: context,
            includesResponseFormat: startsWithResponseFormat
        )
        var usedResponseFormatFallback = false
        // Der Rueckfall ohne response_format greift nur, wenn beides
        // zutrifft: der Status liegt in 400..<500, UND der Fehlerkoerper
        // benennt response_format/json_schema/structured output ausdruecklich
        // als nicht unterstuetzt. Ein Server, der aus einem anderen Grund
        // 400 liefert (falscher API-Key, ungueltiger Parameter, Kontingent),
        // loest damit keinen stillen Formatwechsel mehr aus.
        if startsWithResponseFormat,
           (400..<500).contains(result.response.statusCode),
           Self.isResponseFormatUnsupported(result.data)
        {
            // Some servers explicitly offer JSON mode instead of schema mode.
            // Keep that constraint before trying an unconstrained response.
            if Self.suggestsJSONMode(result.data) {
                try Task.checkCancellation()
                result = try await completionWithBudgetFallback(
                    template: template,
                    request: request,
                    context: context,
                    includesResponseFormat: true,
                    usesJSONMode: true,
                    usesCompletionTokenBudget: result.usesCompletionTokenBudget
                )
                usedResponseFormatFallback = true
            }
        }
        if startsWithResponseFormat,
           (400..<500).contains(result.response.statusCode),
           Self.isResponseFormatUnsupported(result.data),
           !Self.isContextWindowError(result.data)
        {
            try Task.checkCancellation()
            result = try await completionWithBudgetFallback(
                template: template,
                request: request,
                context: context,
                includesResponseFormat: false,
                usesCompletionTokenBudget: result.usesCompletionTokenBudget
            )
            usedResponseFormatFallback = true
        }
        guard (200..<300).contains(result.response.statusCode) else {
            if Self.isContextWindowError(result.data) {
                throw TextModelProviderError.contextWindowExceeded
            }
            throw mappedHTTPError(
                statusCode: result.response.statusCode,
                endpoint: endpoint
            )
        }
        return (result.data, usedResponseFormatFallback)
    }

    /// Rename an explicitly rejected budget parameter at most once across all format retries.
    private func completionWithBudgetFallback(
        template: Template,
        request: TextModelRequest,
        context: RenderContext,
        includesResponseFormat: Bool,
        usesJSONMode: Bool = false,
        usesCompletionTokenBudget: Bool = false
    ) async throws -> (data: Data, response: HTTPURLResponse, usesCompletionTokenBudget: Bool) {
        try Task.checkCancellation()
        var result = try await completion(
            template: template, request: request, context: context,
            includesResponseFormat: includesResponseFormat,
            usesJSONMode: usesJSONMode,
            usesCompletionTokenBudget: usesCompletionTokenBudget
        )
        if !(200..<300).contains(result.response.statusCode), Self.isContextWindowError(result.data) {
            throw TextModelProviderError.contextWindowExceeded
        }
        var renamed = usesCompletionTokenBudget
        if !renamed, (400..<500).contains(result.response.statusCode),
           Self.isTokenBudgetParameterUnsupported(result.data) {
            try Task.checkCancellation()
            renamed = true
            result = try await completion(
                template: template, request: request, context: context,
                includesResponseFormat: includesResponseFormat,
                usesJSONMode: usesJSONMode,
                usesCompletionTokenBudget: true
            )
        }
        if !(200..<300).contains(result.response.statusCode), Self.isContextWindowError(result.data) {
            throw TextModelProviderError.contextWindowExceeded
        }
        return (result.data, result.response, renamed)
    }

    private func completion(
        template: Template,
        request: TextModelRequest,
        context: RenderContext,
        includesResponseFormat: Bool,
        usesJSONMode: Bool = false,
        usesCompletionTokenBudget: Bool = false
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let secret = try resolvedSecret(for: endpoint)
        let url = endpoint.baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url, timeoutInterval: 300)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret {
            urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(
            template: template,
            request: request,
            context: context,
            includesResponseFormat: includesResponseFormat,
            usesJSONMode: usesJSONMode,
            usesCompletionTokenBudget: usesCompletionTokenBudget
        ))
        let result: TextModelHTTPResponse
        do {
            result = try await client.send(urlRequest)
        } catch TextModelHTTPClientError.redirectBlocked {
            throw OpenAICompatibleProviderError.redirectBlocked
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if (error as? URLError)?.code == .timedOut {
                throw OpenAICompatibleProviderError.requestTimedOut(
                    safeEndpointURL(endpoint)
                )
            }
            throw OpenAICompatibleProviderError.endpointUnreachable(
                safeEndpointURL(endpoint)
            )
        }
        return (result.data, result.response)
    }

    private func resolvedSecret(for endpoint: TextModelEndpoint) throws -> String? {
        let secret = try resolvingSecret(endpoint.id)
        guard !endpoint.requiresAPIKey || secret?.isEmpty == false else {
            throw OpenAICompatibleProviderError.apiKeyRequired
        }
        return secret
    }

    private func mappedHTTPError(
        statusCode: Int,
        endpoint: TextModelEndpoint
    ) -> OpenAICompatibleProviderError {
        switch statusCode {
        case 401, 403:
            .authenticationRejected
        case 404:
            .modelNotFound(endpoint.modelID)
        default:
            .serverError(statusCode: statusCode)
        }
    }

    private func safeEndpointURL(_ endpoint: TextModelEndpoint) -> URL {
        guard var components = URLComponents(
            url: endpoint.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return endpoint.baseURL
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url ?? endpoint.baseURL
    }

    /// Der Fehlerkoerper benennt max_tokens ausdruecklich als nicht
    /// unterstuetzt, oder verweist auf max_completion_tokens. Beides heisst
    /// dasselbe: der Server kennt den Parameter nur unter dem anderen Namen.
    private static func isTokenBudgetParameterUnsupported(_ data: Data) -> Bool {
        guard let error = try? JSONDecoder().decode(
            APIErrorResponse.self,
            from: data
        ).error else {
            return false
        }
        let message = error.message.lowercased()
        // Der Verweis auf den Nachfolger genuegt fuer sich: kein Server nennt
        // ihn, wenn nicht genau dieser Parameter das Problem ist.
        if message.contains("max_completion_tokens") { return true }
        let identifiesParameter = error.param?.lowercased() == "max_tokens"
            || message.contains("max_tokens")
        let namesUnsupported = error.code?.lowercased() == "unsupported_parameter"
            || message.contains("not supported")
            || message.contains("unsupported")
        return identifiesParameter && namesUnsupported
    }

    /// Der Fehlerkoerper benennt response_format, json_schema oder
    /// structured output ausdruecklich als nicht unterstuetzt. Das ist die
    /// zweite Haelfte der kombinierten Rueckfall-Bedingung: der Statusbereich
    /// allein (400..<500) sagt nichts darueber, woran die Anfrage
    /// gescheitert ist.
    private static func isResponseFormatUnsupported(_ data: Data) -> Bool {
        guard let error = try? JSONDecoder().decode(
            APIErrorResponse.self,
            from: data
        ).error else {
            return false
        }
        let message = error.message.lowercased()
        let identifiesFeature = error.param?.lowercased() == "response_format"
            || message.contains("response_format")
            || message.contains("json_schema")
            || message.contains("structured output")
        let namesUnsupported = error.code?.lowercased() == "unsupported_parameter"
            || message.contains("not supported")
            || message.contains("unsupported")
        return identifiesFeature && namesUnsupported
    }

    private static func suggestsJSONMode(_ data: Data) -> Bool {
        guard let error = try? JSONDecoder().decode(APIErrorResponse.self, from: data).error else {
            return false
        }
        let message = error.message.lowercased()
        let recommendsJSONMode = message.contains("use 'json_object'")
            || message.contains("use json_object")
            || message.contains("try 'json_object'")
            || message.contains("try json_object")
        return message.contains("json_schema") && recommendsJSONMode
    }

    /// Der Fehlerkoerper benennt das Kontextfenster ausdruecklich als Grund
    /// der Ablehnung. Beide Haelften muessen zutreffen: ein Begriff, der das
    /// Kontextfenster benennt, UND ein Begriff, der eine Ueberschreitung
    /// meldet - ein Kontingentfehler erwaehnt zwar "maximum", aber nie das
    /// Kontextfenster, und eine Erwaehnung des Kontextfensters im
    /// Transkriptinhalt selbst kommt hier nicht an, weil dieser Text nur bei
    /// einem Nicht-2xx-Status geprueft wird.
    private static func isContextWindowError(_ data: Data) -> Bool {
        guard let error = try? JSONDecoder().decode(
            APIErrorResponse.self,
            from: data
        ).error else {
            return false
        }
        // Unterstriche wie in "context_length_exceeded" auf Leerzeichen
        // normalisieren: manche Server melden Fehlercodes statt Prosa, die
        // Begriffe sind dieselben.
        let message = error.message.lowercased().replacingOccurrences(of: "_", with: " ")
        let namesContext = message.contains("context window")
            || message.contains("context length")
            || message.contains("context size")
            || message.contains("maximum context")
            || message.contains("max context")
        let namesOverflow = message.contains("exceed")
            || message.contains("maximum")
            || message.contains("too long")
            || message.contains("greater than")
            || message.contains("larger than")
            || message.contains("overflow")
            || message.contains("too many tokens")
        return namesContext && namesOverflow
    }

    private func decodeOutput(
        _ data: Data,
        template: Template,
        allowsOuterJSONCodeFence: Bool
    ) throws -> StructuredTemplateOutput {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let choice = response.choices.first else {
            throw OpenAICompatibleProviderError.invalidResponse
        }
        // Ein abgeschnittenes Protokoll ist kein Formatfehler: das Modell
        // hat gueltig geantwortet, aber nicht zu Ende. Der Aufrufer soll das
        // von einem tatsaechlich ungueltigen Ergebnis unterscheiden koennen.
        //
        // Leerer Inhalt trennt dabei zwei sehr verschiedene Faelle. Hoert das
        // Modell mitten im Ergebnis auf, war der Abschnitt zu gross, und ihn
        // zu teilen hilft. Kommt gar kein Inhalt, ist das Budget woanders
        // hingegangen - bei einem Modell mit Denkmodus, den dieser Dialekt
        // nicht abschalten kann, in die Gedanken. Ein kleinerer Abschnitt
        // aendert daran nichts, gemessen an gemma4:12b ueber Ollamas
        // /v1-Schicht: 1024 Token Budget, davon 4077 Zeichen Gedanken und
        // null Zeichen Inhalt.
        if choice.finishReason == "length" {
            let content = choice.message.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            throw content.isEmpty
                ? TextModelProviderError.responseEmpty
                : TextModelProviderError.responseTruncated
        }
        guard let contentData = choice.message.content.data(using: .utf8) else {
            throw OpenAICompatibleProviderError.invalidResponse
        }
        do {
            return try StructuredTemplateCodec.decode(
                contentData,
                template: template,
                allowsOuterJSONCodeFence: allowsOuterJSONCodeFence
            )
        } catch {
            throw OpenAICompatibleProviderError.invalidResponse
        }
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String
    }
}

private struct APIErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
        let type: String?
        let param: String?
        let code: String?
    }
}

private struct ModelListResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}
