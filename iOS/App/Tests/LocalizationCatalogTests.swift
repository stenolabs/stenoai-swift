import Foundation
import StenoDomain
import StenoIntelligence
import Testing
@testable import Steno

@Suite("iOS localization catalogs")
struct LocalizationCatalogTests {
    @Test("catalogs use English as source and provide German and Traditional Chinese translations")
    func catalogsHaveCompleteTranslations() throws {
        let localizable = try catalog(named: "Localizable")
        let infoPlist = try catalog(named: "InfoPlist")

        #expect(localizable.sourceLanguage == "en")
        #expect(infoPlist.sourceLanguage == "en")
        #expect(localizable.version == "1.0")
        #expect(infoPlist.version == "1.0")
        expectGermanTranslations(in: localizable)
        expectGermanTranslations(in: infoPlist)
        expectTraditionalChineseTranslations(in: localizable)
        expectTraditionalChineseTranslations(in: infoPlist)
    }

    @Test("InfoPlist catalog contains iOS privacy usage descriptions")
    func infoPlistContainsPlatformPrivacyKeys() throws {
        let catalog = try catalog(named: "InfoPlist")
        let expected: [String: (english: String, german: String, traditionalChinese: String)] = [
            "NSMicrophoneUsageDescription": (
                "Steno records your microphone so it can transcribe conversations locally on this device.",
                "Steno zeichnet dein Mikrofon auf, damit Gespräche lokal auf diesem Gerät transkribiert werden können.",
                "Steno 錄製您的麥克風以在此裝置本機轉錄對話。"
            ),
            "NSLocalNetworkUsageDescription": (
                "Steno connects to a language model server only when you test it or explicitly generate minutes with it.",
                "Steno verbindet sich mit einem Sprachmodellserver nur, wenn du ihn testest oder ausdrücklich ein Protokoll erstellst.",
                "Steno 僅在您測試連線或明確生成會議紀錄時連接語言模型伺服器。"
            ),
        ]

        for (key, values) in expected {
            let entry = try #require(catalog.strings[key], "Missing InfoPlist key: \(key)")
            #expect(entry.localizations["en"]?.stringUnit?.value == values.english)
            #expect(entry.localizations["de"]?.stringUnit?.value == values.german)
            #expect(entry.localizations["zh-Hant"]?.stringUnit?.value == values.traditionalChinese)
        }
    }

    @Test("dynamic presentation copy localizes with interpolation")
    func dynamicPresentationCopyLocalizes() throws {
        let german = Locale(identifier: "de")
        let endpoint = TextModelEndpoint(
            name: "Lokal",
            baseURL: try #require(URL(string: "https://models.example.com/v1")),
            modelID: "gemma",
            requiresAPIKey: false,
            hosting: .selfHosted,
            dialect: .openAICompatible,
            contextWindowTokens: TextModelEndpoint.defaultContextWindowTokens
        )

        #expect(
            localized(
                MeetingActionCopy.retranscriptionTitle(
                    meetingTitle: "Projektauftakt"
                ),
                locale: german
            ) == "„Projektauftakt“ erneut transkribieren?"
        )
        #expect(
            localized(MeetingActionCopy.retranscriptionMessage, locale: german)
                == "Steno fügt eine neue Transkriptrevision hinzu und behält das aktuelle Transkript und die Korrekturen als frühere Revisionen.\nDie Sprechertrennung läuft mit neuen Cluster-Kennungen erneut, daher müssen Sprecher danach erneut bestätigt werden.\nDeine Korrekturen werden niemals stillschweigend überschrieben."
        )
        #expect(
            localized(
                TextModelEndpointPresentation.deletionTitle(for: endpoint),
                locale: german
            ) == "Endpunkt „Lokal“ löschen?"
        )
        #expect(
            localized(
                TextModelEndpointPresentation.deletionMessage(for: endpoint),
                locale: german
            ).contains("gespeicherten API-Schlüssel")
        )
        #expect(
            localized(
                IOSStartupFailure.runtimeOpening("Datenträgerfehler").explanation,
                locale: german
            ) == "Steno konnte die lokale Bibliothek nicht öffnen. Datenträgerfehler"
        )
        #expect(
            localized(DemoDataPresentation.installAction, locale: german)
                == "Demo-Meetings installieren"
        )
        #expect(
            localized(ReportShareDisclosurePresentation.message, locale: german)
                == "Der ausgewählte Protokolltext wird an die gewählte App oder den gewählten Dienst übergeben. Audio, Stimmbelege und Einbettungen sind nicht enthalten."
        )

        let running = try #require(MeetingJobPresentation.make([
            Job(kind: .finalASR, meetingID: MeetingID(), status: .running)
        ]))
        #expect(
            localized(running.title, locale: german)
                == "Auf diesem Gerät transkribieren"
        )
        #expect(
            localized(running.message, locale: german)
                == "Schritt 1 von 3. Steno erstellt aus der Originalaufnahme ein neues Transkript."
        )

        let traditionalChinese = Locale(identifier: "zh-Hant")
        #expect(
            localized(
                IOSStartupFailure.runtimeOpening("磁碟錯誤").explanation,
                locale: traditionalChinese
            ) == "Steno 無法開啟本機資料庫。磁碟錯誤"
        )
        #expect(
            localized(DemoDataPresentation.installAction, locale: traditionalChinese)
                == "安裝示範會議"
        )
    }

    private func expectGermanTranslations(in catalog: StringCatalog) {
        expectTranslations(in: catalog, language: "de", requiredPluralForms: ["one", "other"])
    }

    private func expectTraditionalChineseTranslations(in catalog: StringCatalog) {
        expectTranslations(in: catalog, language: "zh-Hant", requiredPluralForms: ["other"])
    }

    private func expectTranslations(
        in catalog: StringCatalog,
        language: String,
        requiredPluralForms: Set<String>
    ) {
        for (key, entry) in catalog.strings where entry.shouldTranslate != false {
            let localization = entry.localizations[language]
            let units: [StringCatalogStringUnit]
            if let plural = localization?.variations?.plural {
                #expect(requiredPluralForms.isSubset(of: Set(plural.keys)),
                        "Missing \(language) plural forms for \(key)")
                #expect(plural.values.allSatisfy { $0.stringUnit != nil },
                        "Missing \(language) plural value for \(key)")
                units = plural.values.compactMap(\.stringUnit)
            } else {
                units = [localization?.stringUnit].compactMap { $0 }
            }
            #expect(!units.isEmpty, "Missing \(language) translation for \(key)")
            for unit in units {
                #expect(unit.state == "translated", "Untranslated \(language) value for \(key)")
                #expect(!unit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "Empty \(language) value for \(key)")
            }
        }
    }

    @Test("meeting counts use singular and plural translations")
    func meetingCountsUseLocalizedPlurals() {
        let german = Locale(identifier: "de")
        let one = 1
        let two = 2
        #expect(localized("\(one) selected meetings", locale: german) == "1 ausgewähltes Meeting")
        #expect(localized("\(two) selected meetings", locale: german) == "2 ausgewählte Meetings")
        #expect(localized("\(one) turns", locale: german) == "1 Redebeitrag")
        #expect(localized("\(two) turns", locale: german) == "2 Redebeiträge")
    }
    private func catalog(named name: String) throws -> StringCatalog {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let url = resources.appendingPathComponent("\(name).xcstrings")
        return try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: url))
    }

    private func localized(
        _ resource: LocalizedStringResource,
        locale: Locale
    ) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }
}

private struct StringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: StringCatalogEntry]
    let version: String
}

private struct StringCatalogEntry: Decodable {
    let shouldTranslate: Bool?
    let localizations: [String: StringCatalogLocalization]

    private enum CodingKeys: String, CodingKey {
        case shouldTranslate
        case localizations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shouldTranslate = try container.decodeIfPresent(Bool.self, forKey: .shouldTranslate)
        localizations = try container.decodeIfPresent(
            [String: StringCatalogLocalization].self,
            forKey: .localizations
        ) ?? [:]
    }
}

private struct StringCatalogLocalization: Decodable {
    let stringUnit: StringCatalogStringUnit?
    let variations: StringCatalogVariations?
}

private struct StringCatalogVariations: Decodable {
    let plural: [String: StringCatalogPluralForm]?
}

private struct StringCatalogPluralForm: Decodable {
    let stringUnit: StringCatalogStringUnit?
}

private struct StringCatalogStringUnit: Decodable {
    let state: String
    let value: String
}
