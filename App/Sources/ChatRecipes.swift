import SwiftUI
import StenoDomain

// MARK: - Model

/// One saved chat recipe: a short label plus the prompt it fills into a
/// composer. Builtins share the type; only user-saved ones persist.
struct ChatRecipe: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var prompt: String
}

/// Validation caps and persistence for chat recipes, ported from the
/// Electron predecessor (`useRecipes` + `chatPresets`): JSON array under
/// `steno.chat.recipes`, non-empty trimmed label/prompt, 200/8000 character
/// caps, and slug-derived identifiers so re-saving a label replaces the
/// old entry instead of duplicating it.
enum ChatRecipeStore {
    static let defaultsKey = "steno.chat.recipes"
    static let maxLabelCharacters = 200
    static let maxPromptCharacters = 8_000

    /// Builtin presets shown first in every menu.
    static let builtins: [ChatRecipe] = [
        ChatRecipe(
            id: "builtin-list-recent-todos",
            label: "List recent todos",
            prompt: "List my action items from the last week."
        ),
        ChatRecipe(
            id: "builtin-coach-me",
            label: "Coach me",
            prompt: "Coach me on my recent meetings — patterns, blind spots, things to work on."
        ),
    ]

    enum ValidationError: Error, Equatable {
        case emptyLabel
        case emptyPrompt
        case labelTooLong(limit: Int)
        case promptTooLong(limit: Int)
    }

    /// Lowercase, keep alphanumerics, collapse everything else to `-`.
    /// Pure so identifier derivation stays testable.
    static func slug(_ label: String) -> String {
        let lowered = label.lowercased()
        var slug = ""
        var lastWasDash = true // trims leading dashes too
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug += "-"
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    /// Validates one candidate; empty means acceptable after trimming.
    static func validate(label: String, prompt: String) -> ValidationError? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLabel.isEmpty { return .emptyLabel }
        if trimmedPrompt.isEmpty { return .emptyPrompt }
        if trimmedLabel.count > maxLabelCharacters {
            return .labelTooLong(limit: maxLabelCharacters)
        }
        if trimmedPrompt.count > maxPromptCharacters {
            return .promptTooLong(limit: maxPromptCharacters)
        }
        return nil
    }

    static func load(_ defaults: UserDefaults = .standard) -> [ChatRecipe] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        guard let recipes = try? JSONDecoder().decode([ChatRecipe].self, from: data) else {
            return []
        }
        return recipes
    }

    static func save(_ recipes: [ChatRecipe], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(recipes) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Inserts or replaces by slug id; returns the persisted list.
    static func upserting(_ recipe: ChatRecipe, into recipes: [ChatRecipe]) -> [ChatRecipe] {
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            var copy = recipes
            copy[index] = recipe
            return copy
        }
        return recipes + [recipe]
    }
}

// MARK: - Controller

/// Drives the '/'-menu and Save Recipe affordance shared by both composers
/// (recording Ask bar and Library Chat). The menu opens ONLY when the
/// composer is empty and the user types '/'; any other composer content
/// closes it. Arrow keys move the selection, Enter selects, Escape closes;
/// selection fills the composer. Saving is offered when the composer is
/// non-empty and prefills the dialog from its text.
@MainActor
@Observable
final class ChatRecipeController {
    private let defaults: UserDefaults
    private(set) var recipes: [ChatRecipe] = []
    private(set) var menuVisible = false
    private(set) var selectedIndex = 0

    /// Delete confirmation state for the destructive menu row.
    var pendingDeletion: ChatRecipe?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recipes = ChatRecipeStore.load(defaults)
    }

    /// Builtins first, then saved recipes in insertion order.
    var entries: [ChatRecipe] {
        ChatRecipeStore.builtins + recipes
    }

    /// Call on every composer text change.
    func composerChanged(_ newText: String) {
        if newText == "/" {
            menuVisible = true
            selectedIndex = 0
        } else if menuVisible {
            close()
        }
    }

    func moveSelection(_ delta: Int) {
        guard menuVisible, !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + entries.count) % entries.count
    }

    func close() {
        menuVisible = false
        pendingDeletion = nil
    }

    /// The recipe under the current selection, if the menu is open.
    var currentEntry: ChatRecipe? {
        guard menuVisible, entries.indices.contains(selectedIndex) else { return nil }
        return entries[selectedIndex]
    }

    /// Commits the selection; returns the prompt to fill into the composer.
    func selectCurrent() -> String? {
        guard let entry = currentEntry else { return nil }
        close()
        return entry.prompt
    }

    /// Persists a new or replaced recipe (slug-id dedupe). The composer
    /// text arrives pre-trimmed by the caller's dialog.
    func saveRecipe(label: String, prompt: String) throws {
        if let error = ChatRecipeStore.validate(label: label, prompt: prompt) {
            throw error
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipe = ChatRecipe(
            id: ChatRecipeStore.slug(trimmedLabel),
            label: trimmedLabel,
            prompt: trimmedPrompt
        )
        recipes = ChatRecipeStore.upserting(recipe, into: recipes)
        ChatRecipeStore.save(recipes, to: defaults)
    }

    /// Removes a SAVED recipe by id (builtins are not deletable).
    func deleteRecipe(_ id: String) {
        guard !ChatRecipeStore.builtins.contains(where: { $0.id == id }) else { return }
        recipes.removeAll { $0.id == id }
        ChatRecipeStore.save(recipes, to: defaults)
        pendingDeletion = nil
    }
}

// MARK: - Views

/// The '/'-recipe dropdown rendered above a composer. Item identity matches
/// the legacy e2e selectors: `recipe-item-builtin-<n>` then
/// `recipe-item-saved-<i>`.
struct ChatRecipeMenu: View {
    @Bindable var controller: ChatRecipeController
    let onSelect: (ChatRecipe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(controller.entries.enumerated()), id: \.element.id) { index, recipe in
                button(index: index, recipe: recipe)
            }
        }
        .padding(6)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(radius: 6)
        .accessibilityIdentifier("chat-recipes-menu")
    }

    @ViewBuilder
    private func button(index: Int, recipe: ChatRecipe) -> some View {
        if let pending = controller.pendingDeletion, pending.id == recipe.id {
            HStack {
                Text("Delete “\(pending.label)”?").lineLimit(1)
                Spacer()
                Button("Delete", role: .destructive) {
                    controller.deleteRecipe(pending.id)
                }
                Button("Cancel") {
                    controller.pendingDeletion = nil
                }
            }
            .font(.callout)
            .padding(.horizontal, 4)
        } else {
            Button {
                onSelect(recipe)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(recipe.label).fontWeight(controller.selectedIndex == index ? .semibold : .regular)
                    Text(recipe.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(controller.selectedIndex == index ? Color.accentColor.opacity(0.18) : .clear)
            )
            .accessibilityIdentifier(identifier(for: index))
            .contextMenu {
                if !recipe.id.hasPrefix("builtin-") {
                    Button("Delete…", role: .destructive) {
                        controller.pendingDeletion = recipe
                    }
                }
            }
        }
    }

    private func identifier(for index: Int) -> String {
        index < ChatRecipeStore.builtins.count
            ? "recipe-item-builtin-\(index)"
            : "recipe-item-saved-\(index - ChatRecipeStore.builtins.count)"
    }
}

/// Dialog for saving the current composer text as a recipe, prefilled from
/// the composer.
struct ChatRecipeSaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: ChatRecipeController
    let composerText: String
    @State private var label = ""
    @State private var prompt = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.m) {
            Text("Save Recipe").font(.headline)
            TextField("Label", text: $label)
                .accessibilityIdentifier("recipe-label-input")
            TextField("Prompt", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityIdentifier("recipe-prompt-input")
            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(Steno.Colors.uncertain)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("save-recipe-submit")
            }
        }
        .padding(Steno.Space.l)
        .frame(width: 380)
        .onAppear {
            if label.isEmpty { label = composerText }
            if prompt.isEmpty { prompt = composerText }
        }
    }

    private func save() {
        do {
            try controller.saveRecipe(label: label, prompt: prompt)
            dismiss()
        } catch let error as ChatRecipeStore.ValidationError {
            switch error {
            case .emptyLabel:
                validationMessage = "Enter a label first."
            case .emptyPrompt:
                validationMessage = "The prompt must not be empty."
            case .labelTooLong(let limit):
                validationMessage = "The label exceeds \(limit) characters."
            case .promptTooLong(let limit):
                validationMessage = "The prompt exceeds \(limit) characters."
            }
        } catch {
            validationMessage = "The recipe could not be saved."
        }
    }
}

/// Shared keyboard handling for a recipe-aware composer: arrows move the
/// menu selection while it is open, Escape closes it.
struct ChatRecipeKeyboardModifier: ViewModifier {
    let controller: ChatRecipeController

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) {
                guard controller.menuVisible else { return .ignored }
                controller.moveSelection(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard controller.menuVisible else { return .ignored }
                controller.moveSelection(1)
                return .handled
            }
            .onExitCommand {
                if controller.pendingDeletion != nil {
                    controller.pendingDeletion = nil
                } else {
                    controller.close()
                }
            }
    }
}

extension View {
    /// Attaches recipe-menu keyboard navigation to a composer field.
    func chatRecipeKeyboard(_ controller: ChatRecipeController) -> some View {
        modifier(ChatRecipeKeyboardModifier(controller: controller))
    }
}

// MARK: - Library chat scope

// MARK: - Library chat scope pickers

/// Compact scope chip on the Library Chat composer: All notes | folder |
/// specific meetings. The choice persists per session and is forwarded on
/// every turn; dead references heal away before each send.
struct LibraryChatScopePicker: View {
    @Binding var scope: LibraryChatScope
    let folders: [Folder]
    let meetings: [Meeting]
    @Binding var showMeetingPicker: Bool

    private var label: String {
        switch scope {
        case .all:
            return "All notes"
        case .folder(let folderID):
            return folders.first { $0.id == folderID }?.name ?? "All notes"
        case .meetings(let ids):
            return ids.count == 1 ? "1 note" : "\(ids.count) notes"
        }
    }

    var body: some View {
        Menu {
            Button("All notes") { scope = .all }
            if !folders.isEmpty {
                Menu("Folders") {
                    ForEach(folders.sorted { $0.sortIndex < $1.sortIndex }) { folder in
                        Button(folder.name) { scope = .folder(folder.id) }
                    }
                }
            }
            Button("Specific notes…") { showMeetingPicker = true }
        } label: {
            Label(label, systemImage: icon)
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("chat-scope-chip")
        .accessibilityLabel("Chat scope: \(label)")
    }

    private var icon: String {
        switch scope {
        case .all: "tray.full"
        case .folder: "folder"
        case .meetings: "doc.text"
        }
    }
}

/// Multi-select sheet over NON-LIVE meetings (a live recording's transcript
/// is still moving). Selecting none resets the scope to all notes.
struct LibraryChatMeetingScopePicker: View {
    let meetings: [Meeting]
    @Binding var selected: [MeetingID]
    @Environment(\.dismiss) private var dismiss

    /// Live recordings never appear: their transcripts are still moving.
    private var selectable: [Meeting] {
        meetings.filter { $0.status != .recording }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(selectable, id: \.id) { meeting in
                Button {
                    if let index = selected.firstIndex(of: meeting.id) {
                        selected.remove(at: index)
                    } else {
                        selected.append(meeting.id)
                    }
                } label: {
                    HStack {
                        Text(meeting.title.isEmpty ? "Untitled" : meeting.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if selected.contains(meeting.id) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
                }
            }
            .navigationTitle("Choose Notes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 420, height: 480)
    }
}
