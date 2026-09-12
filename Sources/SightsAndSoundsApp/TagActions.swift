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
    /// Swap the tag for another — on the one item it was right-clicked
    /// on, or, from a row that is not on an item, on every item wearing it.
    case replace(Tag, itemID: UUID?)

    var tag: Tag {
        switch self {
        case .edit(let tag), .delete(let tag), .alias(let tag), .replace(let tag, _): tag
        }
    }

    var id: String {
        switch self {
        case .edit(let tag): "edit-\(tag.id)"
        case .delete(let tag): "delete-\(tag.id)"
        case .alias(let tag): "alias-\(tag.id)"
        case .replace(let tag, let itemID): "replace-\(tag.id)-\(itemID?.uuidString ?? "all")"
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
    /// The item the tag is drawn on, when it is drawn on one: Replace
    /// then swaps on that item alone rather than across the library.
    var itemID: UUID?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Edit Tag…") { pending = .edit(tag) }
        Button("Show Items with This Tag") {
            openTagPlayerWindow(
                tag: tag, library: library, libraryID: libraryID, openWindow: openWindow)
        }
        Divider()
        if let removal {
            Button(removal.label, action: removal.action)
        }
        Button(itemID == nil ? "Replace with Another Tag Everywhere…" : "Replace with Another Tag…") {
            pending = .replace(tag, itemID: itemID)
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

    private var replacing: Binding<TagReplacement?> {
        Binding(
            get: {
                if case .replace(let tag, let itemID) = pending {
                    TagReplacement(tag: tag, itemID: itemID)
                } else { nil }
            },
            set: { if $0 == nil, case .replace = pending { pending = nil } })
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
                TagPickerSheet(
                    tag: tag, library: library, scope: .category,
                    title: "Add \u{201C}\(tag.name)\u{201D} as an Alias",
                    blurb: { uses, categoryName in
                        "Its \(uses) item\(uses == 1 ? "" : "s") move to the tag you pick, and \u{201C}\(tag.name)\u{201D} stays as a way to find it. Only tags in \(categoryName) can take it."
                    },
                    confirm: "Add Alias",
                    onPick: { target in try library.convertTagToAlias(tag.id, of: target.id) },
                    onChange: onChange)
            }
            .sheet(item: replacing, onDismiss: onDismiss) { replacement in
                let tag = replacement.tag
                TagPickerSheet(
                    tag: tag, library: library, scope: .library,
                    title: "Replace \u{201C}\(tag.name)\u{201D}",
                    blurb: { uses, _ in
                        replacement.itemID == nil
                            ? "Every item wearing it — \(uses) — gets the tag you pick instead. \u{201C}\(tag.name)\u{201D} stays in the vocabulary, empty."
                            : "On this item only: the tag you pick goes on, \u{201C}\(tag.name)\u{201D} comes off. Any category."
                    },
                    confirm: "Replace",
                    onPick: { target in
                        if let itemID = replacement.itemID {
                            try library.replaceTag(tag.id, with: target.id, on: itemID)
                        } else {
                            try library.replaceTagEverywhere(tag.id, with: target.id)
                        }
                    },
                    onChange: onChange)
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

/// A replace in flight: the tag, and the one item it is on — nil means
/// every item wearing it.
struct TagReplacement: Identifiable {
    let tag: Tag
    let itemID: UUID?
    var id: String { "\(tag.id)-\(itemID?.uuidString ?? "all")" }
}

/// One pickable tag, with the category name the library-wide list shows
/// beside it.
struct TagPick: Identifiable, Equatable {
    let tag: Tag
    let categoryName: String
    /// Folded ONCE, when the pick is made: the fold (case, diacritics,
    /// punctuation) is the expensive half of matching, and folding a
    /// few thousand names again on every keystroke is what made the
    /// bindings editor crawl.
    let foldedName: String
    let foldedWithCategory: String
    var id: UUID { tag.id }

    init(tag: Tag, categoryName: String) {
        self.tag = tag
        self.categoryName = categoryName
        foldedName = TagSearchEntry.fold(tag.name)
        foldedWithCategory = TagSearchEntry.fold(tag.name + " " + categoryName)
    }
}

/// Pick another tag for one of the tag's operations — the alias
/// conversion (same category only, the merge's rule) or the replace
/// (any category). A filter field, a list, Enter on the pick.
struct TagPickerSheet: View {
    enum Scope { case category, library }

    let tag: Tag
    let library: LibraryDatabase
    let scope: Scope
    let title: String
    /// The line under the title, given the tag's use count and its
    /// category's name.
    let blurb: (Int, String) -> String
    let confirm: String
    let onPick: (Tag) throws -> Void
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var targetID: UUID?
    @State private var picks: [TagPick] = []
    @State private var categoryName = ""
    @State private var uses = 0
    @State private var errorText: String?
    @FocusState private var queryFocused: Bool

    /// The pickable tags: everything offered but the tag itself. An empty
    /// query lists them all by name. A query RANKS them — the name
    /// scored by the one rule every tag search uses (exact, then starts
    /// with, then a word starts with, then contains), and a match only
    /// through the category name ("venue red") after every name match —
    /// then names break ties. Never capped: the list scrolls, and a
    /// two-letter tag behind thirty longer names has to be reachable.
    /// Pure, so it is tested.
    static func candidates(_ picks: [TagPick], excluding tagID: UUID, query: String) -> [TagPick] {
        let others = picks.filter { $0.tag.id != tagID }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return others.sorted { $0.tag.name.localizedStandardCompare($1.tag.name) == .orderedAscending }
        }
        return others
            .compactMap { pick -> (Int, TagPick)? in
                if let byName = TagSearchEntry.score(pick.foldedName, query: query) {
                    return (byName, pick)
                }
                return TagSearchEntry.score(pick.foldedWithCategory, query: query).map { ($0 + 4, pick) }
            }
            .sorted {
                $0.0 != $1.0
                    ? $0.0 < $1.0
                    : $0.1.tag.name.localizedStandardCompare($1.1.tag.name) == .orderedAscending
            }
            .map(\.1)
    }

    private var shown: [TagPick] { Self.candidates(picks, excluding: tag.id, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title)
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)
            Text(blurb(uses, categoryName))
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Find a tag…", text: $query)
                .splitsPastedTitleCase($query)
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
                    // The pick follows the list: a narrowed list with
                    // one row picks it, so type · Enter is the whole
                    // gesture; a pick the query dropped is dropped.
                    if shown.count == 1 {
                        targetID = shown[0].id
                    } else if let targetID, !shown.contains(where: { $0.id == targetID }) {
                        self.targetID = nil
                    }
                }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if shown.isEmpty {
                        Text(picks.count <= 1
                            ? (scope == .category
                                ? "No other tag in \(categoryName) to take it."
                                : "No other tag in the library.")
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
                            HStack(spacing: 6) {
                                Text(candidate.tag.name)
                                    .font(Theme.ui(12))
                                    .foregroundStyle(Theme.Text.primary)
                                Spacer(minLength: 6)
                                if scope == .library {
                                    Text(candidate.categoryName)
                                        .font(Theme.ui(10))
                                        .foregroundStyle(Theme.Text.tertiary)
                                }
                            }
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
                Button(confirm) { commit() }
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
            categoryName = vocabulary.first { $0.category.id == tag.tagCategoryID }?.category.name ?? ""
            picks = vocabulary
                .filter { scope == .library || $0.category.id == tag.tagCategoryID }
                .flatMap { entry in entry.tags.map { TagPick(tag: $0, categoryName: entry.category.name) } }
            uses = (try? library.tagUsageCounts(inCategory: tag.tagCategoryID))?[tag.id] ?? 0
            queryFocused = true
        }
    }

    private func commit() {
        guard let targetID, let target = picks.first(where: { $0.id == targetID }) else { return }
        do {
            try onPick(target.tag)
            errorText = nil
            onChange()
            dismiss()
        } catch {
            errorText = "\(error)"
        }
    }
}
