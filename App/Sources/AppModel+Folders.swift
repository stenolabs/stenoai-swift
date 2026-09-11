import Foundation
import StenoDomain
import StenoLibrary

/// Ordner der Bibliothek. Ein Meeting gehoert weiterhin in genau einen; die
/// Hierarchieinvarianten prueft ausschliesslich der langlebige Store.
@MainActor
extension AppModel {
    @discardableResult
    func createFolder(
        named name: String,
        parentFolderID: FolderID? = nil
    ) async -> Folder? {
        guard let folderStore else { return nil }
        do {
            let folder = try await folderStore.createFolder(
                name: name,
                parentFolderID: parentFolderID
            )
            await refreshMeetings()
            return folder
        } catch {
            report(verbatim: AppModel.message("The folder could not be created.", error))
            return nil
        }
    }

    func renameFolder(_ folderID: FolderID, to name: String) async {
        guard let folderStore else { return }
        do {
            _ = try await folderStore.renameFolder(folderID, to: name)
            await refreshMeetings()
        } catch {
            report(verbatim: AppModel.message("The folder could not be renamed.", error))
        }
    }

    /// Sets or clears a folder's sidebar color token.
    func setFolderColor(
        _ colorToken: FolderColorToken?,
        of folderID: FolderID
    ) async {
        guard let folderStore else { return }
        do {
            _ = try await folderStore.setColorToken(colorToken, of: folderID)
            await refreshMeetings()
        } catch {
            report(verbatim: AppModel.message("The folder color could not be changed.", error))
        }
    }

    /// Sets or clears a folder's sidebar SF Symbol icon.
    func setFolderIcon(
        _ icon: FolderIcon?,
        of folderID: FolderID
    ) async {
        guard let folderStore else { return }
        do {
            _ = try await folderStore.setIcon(icon, of: folderID)
            await refreshMeetings()
        } catch {
            report(verbatim: AppModel.message("The folder icon could not be changed.", error))
        }
    }

    /// Loescht den Ordner und raeumt die Zuordnung an seinen Meetings ab.
    /// Die Meetings selbst bleiben - ein Ordner ist eine Ablage, kein
    /// Behaelter, dessen Verschwinden Inhalt mitnimmt.
    func deleteFolder(_ folderID: FolderID) async -> Bool {
        guard let runtime, let folderStore else { return false }
        let directMeetingIDs: Set<MeetingID>
        do {
            let currentMeetings = try await runtime.library.listMeetings()
            directMeetingIDs = Set(currentMeetings.compactMap {
                $0.folderID == folderID ? $0.id : nil
            })
            guard try await folderStore.folder(folderID) != nil else {
                throw LibraryError.folderNotFound(folderID)
            }
            _ = try await runtime.library.setMeetingFolders(
                directMeetingIDs,
                folderID: nil
            )
        } catch {
            await refreshMeetings()
            report(verbatim: AppModel.message("The folder could not be deleted.", error))
            return false
        }

        do {
            guard try await folderStore.deleteFolder(folderID) != nil else {
                await refreshMeetings()
                report(
                    "The folder no longer exists and the current library state was reloaded."
                )
                return false
            }
            await refreshMeetings()
            report(
                directMeetingIDs.isEmpty
                    ? "Folder deleted."
                    : "Folder deleted. \(directMeetingIDs.count) meeting\(directMeetingIDs.count == 1 ? "" : "s") moved back to the date list.",
                isError: false
            )
            return true
        } catch {
            do {
                _ = try await runtime.library.setMeetingFolders(
                    directMeetingIDs,
                    folderID: folderID
                )
            } catch let restorationError {
                await refreshMeetings()
                report(
                    "The folder could not be deleted and some meeting assignments could not be restored. \(restorationError.localizedDescription)"
                )
                return false
            }
            await refreshMeetings()
            report(verbatim: AppModel.message("The folder could not be deleted.", error))
            return false
        }
    }

    @discardableResult
    func moveFolder(
        _ folderID: FolderID,
        to parentFolderID: FolderID?
    ) async -> Bool {
        guard let folderStore else { return false }
        do {
            _ = try await folderStore.moveFolder(
                folderID,
                toParentFolderID: parentFolderID
            )
            await refreshMeetings()
            return true
        } catch {
            report(verbatim: AppModel.message("The folder could not be moved.", error))
            return false
        }
    }

    /// Verschiebt einen Ordner um eine Position innerhalb seiner
    /// Geschwistergruppe. Drag-and-drop und Menueaktion nutzen denselben
    /// Storevertrag.
    func moveFolder(_ folderID: FolderID, up: Bool) async {
        guard let folderStore else { return }
        guard let folder = folders.first(where: { $0.id == folderID }) else {
            return
        }
        let siblings = folders.filter {
            $0.parentFolderID == folder.parentFolderID
        }
        guard let index = siblings.firstIndex(where: { $0.id == folderID }) else {
            return
        }
        let target = up ? index - 1 : index + 1
        guard siblings.indices.contains(target) else { return }
        var order = siblings.map(\.id)
        order.swapAt(index, target)
        do {
            try await folderStore.reorderFolders(
                parentFolderID: folder.parentFolderID,
                order: order
            )
            await refreshMeetings()
        } catch {
            report(verbatim: AppModel.message("The folders could not be reordered.", error))
        }
    }

    @discardableResult
    func moveMeetings(
        _ meetingIDs: Set<MeetingID>,
        to folderID: FolderID?
    ) async -> Bool {
        guard !meetingIDs.isEmpty, let runtime, let folderStore else {
            return false
        }
        do {
            if let folderID,
               try await folderStore.folder(folderID) == nil
            {
                throw LibraryError.folderNotFound(folderID)
            }
            _ = try await runtime.library.setMeetingFolders(
                meetingIDs,
                folderID: folderID
            )
            await refreshMeetings()
            return true
        } catch {
            await refreshMeetings()
            report(verbatim: AppModel.message("The meetings could not be moved.", error))
            return false
        }
    }

    @discardableResult
    func moveMeeting(
        _ meetingID: MeetingID,
        to folderID: FolderID?
    ) async -> Bool {
        await moveMeetings(Set([meetingID]), to: folderID)
    }
}
