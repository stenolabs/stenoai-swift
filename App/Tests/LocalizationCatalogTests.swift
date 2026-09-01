import Foundation
import StenoDomain
import StenoIntelligence
import Testing
@testable import steno_macos

@Suite("macOS localization catalogs")
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

        let installed = try #require(
            localizable.strings["demo.data.status.installed"],
            "Missing demo.data.status.installed"
        )
        #expect(
            installed.localizations["en"]?.stringUnit?.value
                == "All three demo meetings are installed."
        )
        #expect(
            installed.localizations["zh-Hant"]?.stringUnit?.value
                == "三個示範會議皆已安裝。"
        )
    }

    @Test("InfoPlist catalog contains macOS privacy usage descriptions")
    func infoPlistContainsPlatformPrivacyKeys() throws {
        let catalog = try catalog(named: "InfoPlist")
        let expected: [String: (english: String, german: String, traditionalChinese: String)] = [
            "NSMicrophoneUsageDescription": (
                "Steno records your microphone so it can transcribe conversations locally on this Mac.",
                "Steno verwendet dein Mikrofon, um Gespräche lokal auf diesem Mac zu transkribieren.",
                "Steno 使用您的麥克風在 Mac 本機轉錄對話。"
            ),
            "NSAudioCaptureUsageDescription": (
                "Steno records system audio so it can transcribe the people you talk to in calls, locally on this Mac.",
                "Steno zeichnet Systemaudio auf, um die Personen in deinen Gesprächen lokal auf diesem Mac zu transkribieren.",
                "Steno 錄製系統音訊以在 Mac 本機轉錄通話中的與會者發言。"
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
                MacStartupFailure.runtimeOpening("Datenträgerfehler").title,
                locale: german
            ) == "Die Bibliothek konnte nicht geöffnet werden"
        )
        #expect(
            localized(
                MacStartupFailure.runtimeOpening("Datenträgerfehler").explanation,
                locale: german
            ) == "Steno konnte das Öffnen der lokalen Bibliothek nicht abschließen. Versuche es erneut, um dieselbe lokale Bibliothek zu verwenden. Datenträgerfehler"
        )
        #expect(
            localized(
                MacTextModelEndpointPresentation.deletionMessage(for: endpoint),
                locale: german
            ) == "Beim Löschen von „Lokal“ werden die Konfiguration und der gespeicherte API-Schlüssel von diesem Mac entfernt. Dies kann nicht rückgängig gemacht werden."
        )
        #expect(
            localized(
                DemoDataPresentation.reviewProgressTitle(
                    SpeakerReviewPresentation.ReviewProgress(
                        reviewed: 1,
                        total: 3
                    )
                ),
                locale: german
            ) == "1 von 3 geprüft"
        )
        #expect(
            localized(DemoDataPresentation.installAction, locale: german)
                == "Demo-Meetings installieren"
        )
        let trashRequest = try #require(MeetingTrashRequest(meetings: [
            Meeting(
                title: "Erstes Meeting",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                status: .ready
            ),
            Meeting(
                title: "Zweites Meeting",
                createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                status: .ready
            ),
        ]))
        #expect(
            localized(trashRequest.confirmationTitle, locale: german)
                == "2 Meetings in den Papierkorb legen?"
        )
        #expect(
            localized(trashRequest.menuTitle, locale: german)
                == "2 Meetings in den Papierkorb legen…"
        )

        let traditionalChinese = Locale(identifier: "zh-Hant")
        #expect(
            localized(
                MacStartupFailure.runtimeOpening("磁碟錯誤").title,
                locale: traditionalChinese
            ) == "無法開啟資料庫"
        )
        #expect(
            localized(
                DemoDataPresentation.installAction,
                locale: traditionalChinese
            ) == "安裝示範會議"
        )
        #expect(
            localized(
                LocalizedStringResource(
                    "demo.data.status.installed",
                    defaultValue: "All three demo meetings are installed."
                ),
                locale: traditionalChinese
            ) == "三個示範會議皆已安裝。"
        )
        #expect(
            localized(trashRequest.actionTitle, locale: traditionalChinese)
                == "將 2 場會議移至垃圾桶"
        )
    }
    private func expectGermanTranslations(in catalog: StringCatalog) {
        for (key, entry) in catalog.strings where entry.shouldTranslate != false {
            let german = entry.localizations["de"]?.stringUnit
            #expect(
                german?.state == "translated",
                "Missing translated German value for \(key)"
            )
            #expect(
                !(german?.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                "German value is empty for \(key)"
            )
        }
    }

    private func expectTraditionalChineseTranslations(in catalog: StringCatalog) {
        for (key, entry) in catalog.strings where entry.shouldTranslate != false {
            let zhHant = entry.localizations["zh-Hant"]?.stringUnit
            #expect(
                zhHant?.state == "translated",
                "Missing translated Traditional Chinese value for \(key)"
            )
            #expect(
                !(zhHant?.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                "Traditional Chinese value is empty for \(key)"
            )
        }
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
}

private struct StringCatalogStringUnit: Decodable {
    let state: String
    let value: String
}
