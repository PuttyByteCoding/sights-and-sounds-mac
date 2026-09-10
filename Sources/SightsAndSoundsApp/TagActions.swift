import SwiftUI
import SightsAndSoundsKit

/// One right-click menu for every drawn tag — a pill in the player, a
/// badge on a tile, a row in the sidebar or the Tag Manager, a
/// suggestion in a field. The buttons are `TagActionButtons`; the
/// sheets and the confirmation they open live on ONE host view through
/// `.tagActions(...)`, driven by a single pending action, so a list of
/// a thousand rows carries one sheet, not a thousand.
enum TagAction: Identifiable {
    case edit(Tag)
    case delete(Tag)
    case alias(Tag)

    var tag: Tag {
        switch self {
        case .edit(let tag), .delete(let tag), .alias(let tag): tag
        }
    }

    var id: String {
        switch self {
        case .edit(let tag): "edit-\(tag.id)"
        case .delete(let tag): "delete-\(tag.id)"
        case .alias(let tag): "alias-\(tag.id)"
        }
    }
}

/// "Take the tag off the item it is drawn on" — offered only where the
/// tag IS on an item. The label names the kind of thing, since a tag on
/// an audio track is not on a video.
struct TagRemoval {
    let label: String
    let action: () -> Void

    static func label(for kind: MediaKind) -> String {
        kind == .video ? "Remove from This Video" : "Remove from This Item"
    }
}

/// The menu items. Edit and Show Items are what the pill always had;
/// the removal, the alias conversion and the delete are the three the
/// operator otherwise had to open the Tag Manager for.
struct TagActionButtons: View {
    let tag: Tag
    let library: LibraryDatabase
    let libraryID: UUID
    @Binding var pending: TagAction?
    var removal: TagRemoval?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Edit Tag…") { pending = .edit(tag) }
        Button("Show Items with This Tag") {
            openTagPlayerWindow(
                tag: tag, library: library, libraryID: libraryID, openWindow: openWindow)
        }
        if let removal {
            Divider()
            Button(removal.label, action: removal.action)
        }
        Divider()
        Button("Add as Alias to Another Tag…") { pending = .alias(tag) }
        Button("Delete Tag…", role: .destructive) { pending = .delete(tag) }
    }
}

extension View {
    /// Hosts the edit sheet, the alias picker and the delete
    /// confirmation for whichever `TagActionButtons` set `pending`.
    /// `onChange` runs after any write — callers refresh however they
    /// refresh. `onDismiss` runs when a sheet closes, for the field that
    /// wants its keyboard back.
    func tagActions(
        _ pending: Binding<TagAction?>, library: LibraryDatabase, libraryID: UUID,
        categories: [TagCategory], onChange: @escaping () -> Void,
        onDismiss: @escaping () -> Void = {}
    ) -> some View {
        modifier(TagActionHost(
            pending: pending, library: library, libraryID: libraryID,
            categories: categories, onChange: onChange, onDismiss: onDismiss))
    }
}

private struct TagActionHost: ViewModifier {
    @Binding var pending: TagAction?
    let library: LibraryDatabase
    let libraryID: UUID
    let categories: [TagCategory]
    let onChange: () -> Void
    let onDismiss: () -> Void

    private var editing: Binding<Tag?> {
        Binding(
            get: { if case .edit(let tag) = pending { tag } else { nil } },
            set: { if $0 == nil, case .edit = pending { pending = nil } })
    }

    private var aliasing: Binding<Tag?> {
        Binding(
            get: { if case .alias(let tag) = pending { tag } else { nil } },
            set: { if $0 == nil, case .alias = pending { pending = nil } })
    }

    private var confirmingDelete: Binding<Bool> {
        Binding(
            get: { if case .delete = pending { true } else { false } },
            set: { if !$0, case .delete = pending { pending = nil } })
    }

    private var deleting: Tag? {
        if case .delete(let tag) = pending { tag } else { nil }
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: editing, onDismiss: onDismiss) { tag in
                TagSheet(
                    mode: .edit(tag), library: library, libraryID: libraryID,
                    categories: categories
                ) { _ in onChange() }
            }
            .sheet(item: aliasing, onDismiss: onDismiss) { tag in
                AliasTargetSheet(tag: tag, library: library, onChange: onChange)
            }
            // The copy is the Tag Manager's: the count it is about to
            // drop, and the alternative that keeps them.
            .confirmationDialog(
                "Delete \u{201C}\(deleting?.name ?? "")\u{201D}?",
                isPresented: confirmingDelete, presenting: deleting
            ) { tag in
                Button("Delete", role: .destructive) {
                    try? library.deleteTag(tag.id)
                    onChange()
                }
            } message: { tag in
                Text(TagActionCopy.deleteMessage(uses: uses(of: tag)))
            }
    }

    private func uses(of tag: Tag) -> Int {
        (try? library.tagUsageCounts(inCategory: tag.tagCategoryID))?[tag.id] ?? 0
    }
}

enum TagActionCopy {
    static func deleteMessage(uses: Int) -> String {
        "Removes the tag from \(uses) item\(uses == 1 ? "" : "s"). Consider Add as Alias instead — that keeps the taggings and folds the name into another tag."
    }
}

/// Pick the tag this one becomes an alias of: its items move to the
/// pick, its name stays as a way to find it, and it is gone as a tag.
/// Same category only — that is the merge's rule, and the list says so.
struct AliasTargetSheet: View {
    let tag: Tag
    let library: LibraryDatabase
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var targetID: UUID?
    @State private var siblings: [Tag] = []
    @State private var categoryName = ""
    @State private var uses = 0
    @State private var errorText: String?
    @FocusState private var queryFocused: Bool

    /// The pickable tags: the category's others, narrowed by the query
    /// (folded, every term), in name order. Pure, so it is tested.
    static func candidates(_ siblings: [Tag], excluding tagID: UUID, query: String) -> [Tag] {
        let terms = query.split(separator: " ").map { TagSearchEntry.fold(String($0)) }
        return siblings
            .filter { $0.id != tagID }
            .filter { tag in
                let folded = TagSearchEntry.fold(tag.name)
                return terms.allSatisfy { folded.contains($0) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var shown: [Tag] { Self.candidates(siblings, excluding: tag.id, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Add \u{201C}\(tag.name)\u{201D} as an Alias")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)
            Text("Its \(uses) item\(uses == 1 ? "" : "s") move to the tag you pick, and \u{201C}\(tag.name)\u{201D} stays as a way to find it. Only tags in \(categoryName) can take it.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Find a tag…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(
                            queryFocused ? Theme.Border.activeControl : Theme.Border.standard,
                            lineWidth: queryFocused ? 2 : 1))
                .focused($queryFocused)
                .onSubmit { if targetID != nil { commit() } }
                .onChange(of: query) { _, _ in
                    if let targetID, !shown.contains(where: { $0.id == targetID }) {
                        self.targetID = nil
                    }
                }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if shown.isEmpty {
                        Text(siblings.count <= 1
                            ? "No other tag in \(categoryName) to take it."
                            : "No tag matches that.")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.Text.disabled)
                            .padding(10)
                    }
                    ForEach(shown) { candidate in
                        let picked = candidate.id == targetID
                        Button {
                            targetID = candidate.id
                        } label: {
                            Text(candidate.name)
                                .font(Theme.ui(12))
                                .foregroundStyle(Theme.Text.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                        .fill(picked ? Theme.Surface.selectedRow : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Surface.well)
                    .stroke(Theme.Border.standard, lineWidth: 1))

            if let errorText {
                Text(errorText)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Status.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Add Alias") { commit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(targetID == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(Theme.Surface.dialog)
        .onAppear {
            let vocabulary = (try? library.vocabulary()) ?? []
            if let entry = vocabulary.first(where: { $0.category.id == tag.tagCategoryID }) {
                siblings = entry.tags
                categoryName = entry.category.name
            }
            uses = (try? library.tagUsageCounts(inCategory: tag.tagCategoryID))?[tag.id] ?? 0
            queryFocused = true
        }
    }

    private func commit() {
        guard let targetID else { return }
        do {
            try library.convertTagToAlias(tag.id, of: targetID)
            errorText = nil
            onChange()
            dismiss()
        } catch {
            errorText = "\(error)"
        }
    }
}
