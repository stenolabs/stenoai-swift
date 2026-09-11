import Foundation
import Testing
@testable import steno_macos

/// The notice line is where the app says something went wrong. It has to speak
/// the language the app runs in, which means the catalogue must actually carry
/// these strings - a `String(localized:)` call with no translation behind it
/// silently returns English and looks exactly like a working one.
@Suite("Notice localization")
struct NoticeLocalizationTests {
    /// The built German resources, or nil if the app ships without them.
    private var germanBundle: Bundle? {
        Bundle.main.path(forResource: "de", ofType: "lproj")
            .flatMap(Bundle.init(path:))
    }

    @Test("notice literals reach the German catalogue")
    func noticeLiteralsAreTranslated() throws {
        let bundle = try #require(
            germanBundle,
            "the app is built without German resources"
        )

        let started = String(
            localized: "The recording could not be started.",
            bundle: bundle
        )
        let partial = String(
            localized: "Recording without %@: %@ Everything else is still being recorded.",
            bundle: bundle
        )

        #expect(started == "Die Aufnahme konnte nicht gestartet werden.")
        #expect(partial.contains("Aufnahme ohne"))
        // Both placeholders must survive, and in a fixed order: the German
        // sentence puts them where the English one does not.
        #expect(partial.contains("%1$@"))
        #expect(partial.contains("%2$@"))
    }

    @Test("the caveat about a missing track is translated")
    func caveatIsTranslated() throws {
        let bundle = try #require(germanBundle)

        let caveat = String(
            localized: "%@ was not recorded, so these minutes do not cover %@.",
            bundle: bundle
        )
        let side = String(localized: "Microphone track", bundle: bundle)
        let whose = String(localized: "what you said yourself", bundle: bundle)

        #expect(caveat.contains("nicht aufgenommen"))
        #expect(side == "Die Mikrofonspur")
        #expect(whose == "was du selbst gesagt hast")
    }
}
