import Foundation
import StenoIntelligence
import Testing
#if os(iOS)
@testable import Steno
#else
@testable import steno_macos
#endif

@Suite("External send consent")
struct ExternalSendConsentTests {
    private func endpoint(id: UUID = UUID(), host: String) -> TextModelEndpoint {
        TextModelEndpoint(id: id, name: "Synthetic endpoint", baseURL: URL(string: "https://\(host)/v1")!, modelID: "fixture", requiresAPIKey: false, hosting: .cloud, dialect: .openAICompatible, contextWindowTokens: 4096)
    }

    @Test("consent follows the exact endpoint and rejects a changed open sheet")
    func endpointSwitch() {
        let first = endpoint(host: "a.example.com")
        let second = endpoint(id: first.id, host: "b.example.com")
        var consent = ExternalSendConsent()
        #expect(consent.permits(nil))
        #expect(!consent.permits(first))
        consent.prepare(first)
        let rejectedChanged = consent.accept(current: second)
        #expect(!rejectedChanged)
        #expect(!consent.permits(second))
        consent.prepare(first)
        let acceptedFirst = consent.accept(current: first)
        #expect(acceptedFirst)
        #expect(consent.permits(first))
        #expect(!consent.permits(second))
        consent.prepare(second)
        let rejectedLocal = consent.accept(current: nil)
        #expect(!rejectedLocal)
    }
}
