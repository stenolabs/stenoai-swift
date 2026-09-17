import Foundation
import Testing
@testable import steno_macos
import StenoDomain

@Suite("Chat recipes")
@MainActor
struct ChatRecipesTests {
    private func freshDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Validation

    @Test("label and prompt must be non-empty after trimming")
    func emptyFieldsRejected() {
        #expect(ChatRecipeStore.validate(label: "   ", prompt: "p") == .emptyLabel)
        #expect(ChatRecipeStore.validate(label: "L", prompt: "") == .emptyPrompt)
    }

    @Test("character caps are 200 for the label and 8000 for the prompt")
    func capsEnforced() {
        #expect(
            ChatRecipeStore.validate(
                label: String(repeating: "x", count: 201), prompt: "p"
            ) == .labelTooLong(limit: 200)
        )
        #expect(ChatRecipeStore.validate(label: "ok", prompt: String(repeating: "y", count: 8_001)) == .promptTooLong(limit: 8_000))
        #expect(ChatRecipeStore.validate(label: String(repeating: "x", count: 200), prompt: String(repeating: "y", count: 8_000)) == nil)
    }

    // MARK: Persistence

    @Test("recipes persist as JSON under steno.chat.recipes and reload")
    func persistenceRoundTrip() throws {
        let defaults = freshDefaults()
        let controller = ChatRecipeController(defaults: defaults)
        try controller.saveRecipe(label: "Standup Summary", prompt: "Summarize yesterday's standups.")
        let reloaded = ChatRecipeController(defaults: defaults)
        #expect(reloaded.recipes.count == 1)
        #expect(reloaded.recipes[0].label == "Standup Summary")
        #expect(reloaded.recipes[0].prompt == "Summarize yesterday's standups.")
        // Raw key check: the store owns steno.chat.recipes exactly.
        #expect(defaults.data(forKey: ChatRecipeStore.defaultsKey) != nil)
    }

    @Test("slug-derived ids dedupe: re-saving a label replaces the entry")
    func slugDedupe() throws {
        let defaults = freshDefaults()
        let controller = ChatRecipeController(defaults: defaults)
        #expect(ChatRecipeStore.slug("Standup Summary!") == "standup-summary")
        try controller.saveRecipe(label: "Standup Summary!", prompt: "v1")
        try controller.saveRecipe(label: "Standup Summary", prompt: "v2")
        #expect(controller.recipes.count == 1)
        #expect(controller.recipes[0].id == "standup-summary")
        #expect(controller.recipes[0].prompt == "v2")
    }

    @Test("builtins come first and cannot be deleted or persisted over")
    func builtinsFirstAndProtected() {
        let controller = ChatRecipeController(defaults: freshDefaults())
        #expect(controller.entries.prefix(2).map(\.label) == ["List recent todos", "Coach me"])
        #expect(
            controller.entries[0].prompt == "List my action items from the last week."
        )
        let count = controller.entries.count
        controller.deleteRecipe(ChatRecipeStore.builtins[0].id)
        #expect(controller.entries.count == count)
    }

    @Test("deleting a saved recipe persists the removal")
    func deletePersists() throws {
        let defaults = freshDefaults()
        let controller = ChatRecipeController(defaults: defaults)
        try controller.saveRecipe(label: "Temp", prompt: "p")
        let id = controller.recipes[0].id
        controller.deleteRecipe(id)
        #expect(ChatRecipeStore.load(defaults).isEmpty)
    }

    // MARK: Menu behavior

    @Test("menu opens only when an EMPTY composer types '/'")
    func slashOnlyOnEmptyComposer() {
        let controller = ChatRecipeController(defaults: freshDefaults())
        controller.composerChanged("/")
        #expect(controller.menuVisible)
        controller.composerChanged("/x") // any further text closes it
        #expect(!controller.menuVisible)

        controller.composerChanged("what changed? /")
        #expect(!controller.menuVisible) // mid-sentence slash never opens

        controller.composerChanged("")
        #expect(!controller.menuVisible) // clearing alone never opens
    }

    @Test("keyboard navigation wraps and Enter selects, filling the composer prompt")
    func keyboardSelection() {
        let controller = ChatRecipeController(defaults: freshDefaults())
        controller.composerChanged("/")
        let total = controller.entries.count
        controller.moveSelection(-1)
        #expect(controller.selectedIndex == total - 1) // wraps backwards
        controller.moveSelection(1)
        #expect(controller.selectedIndex == 0)
        let prompt = controller.selectCurrent()
        #expect(prompt == ChatRecipeStore.builtins[0].prompt)
        #expect(!controller.menuVisible)
    }
}

@Suite("Library chat scope")
@MainActor
struct LibraryChatScopeTests {
    private func meeting(_ title: String, folder: FolderID? = nil, status: Meeting.Status = .ready) -> Meeting {
        Meeting(title: title, status: status, folderID: folder)
    }

    @Test("scope round-trips through the session store JSON")
    func scopePersistence() throws {
        let folderID = FolderID()
        let sessionAll = LibraryChatSession(title: "a")
        let sessionFolder = LibraryChatSession(title: "b", scope: .folder(folderID))
        let sessionMeetings = LibraryChatSession(title: "c", scope: .meetings([MeetingID(), MeetingID()]))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(LibraryChatSession.self, from: encoder.encode(sessionAll)).scope == .all)
        #expect(try decoder.decode(LibraryChatSession.self, from: encoder.encode(sessionFolder)).scope == .folder(folderID))
        if case .meetings(let ids) = sessionMeetings.scope {
            let decoded = try decoder.decode(LibraryChatSession.self, from: encoder.encode(sessionMeetings))
            #expect(decoded.scope == .meetings(ids))
        }
    }

    @Test("sessions written before scoping decode with scope = all")
    func legacySessionsDecodeAsAll() throws {
        struct LegacySession: Codable {
            var id: UUID
            var title: String
            var createdAt: Date
            var messages: [LibraryChatMessage]
        }
        let legacy = LegacySession(id: UUID(), title: "old", createdAt: Date(), messages: [])
        let session = try JSONDecoder().decode(LibraryChatSession.self, from: JSONEncoder().encode(legacy))
        #expect(session.scope == .all)
    }

    @Test("healing a deleted folder requires a new explicit selection")
    func healsDeletedFolder() {
        let live = Folder(name: "Live", sortIndex: 0)
        let healed = LibraryChatScope.healed(.folder(live.id), folders: [], meetings: [])
        #expect(healed == .meetings([]))
        #expect(healed.requiresExplicitSelection)
        let kept = LibraryChatScope.healed(.folder(live.id), folders: [live], meetings: [])
        #expect(kept == .folder(live.id))
        #expect(!kept.requiresExplicitSelection)
    }

    @Test("healing removes deleted meetings without broadening the scope")
    func healsDeletedMeetings() {
        let survivor = meeting("kept")
        let ghost = MeetingID()
        let healed = LibraryChatScope.healed(.meetings([survivor.id, ghost]), folders: [], meetings: [survivor])
        #expect(healed == .meetings([survivor.id]))
        let emptied = LibraryChatScope.healed(.meetings([ghost]), folders: [], meetings: [])
        #expect(emptied == .meetings([]))
        #expect(emptied.requiresExplicitSelection)
        #expect(LibraryChatScope.healed(.all, folders: [], meetings: []) == .all)
    }
}
