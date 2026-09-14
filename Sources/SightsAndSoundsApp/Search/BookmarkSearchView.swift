import AppKit
import SwiftUI
import SightsAndSoundsKit

/// Firefox bookmarks that contain every one of the item's search values
/// (spec 17, decisions 3–4, 8): read from a copy of the profile's
/// places file, listed with everything the profile knows about them.
/// Click a row to open it in Firefox.
struct BookmarkSearchView: View {
    @Environment(BrowseModel.self) private var browse
    let itemID: UUID?

    @State private var terms: [String] = []
    @State private var results: [FirefoxBookmark] = []
    @State private var message: String?
    @State private var loading = true
    @State private var fileName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
            if loading {
                ProgressView("Reading Firefox bookmarks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message {
                ContentUnavailableView(
                    "No Bookmarks", systemImage: "bookmark.slash", description: Text(message))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(results) { BookmarkRow(bookmark: $0) }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task(id: itemID) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fileName.isEmpty ? "Bookmarks" : fileName)
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(loading ? "Searching for" : "\(results.count) matching")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Text.tertiary)
                ForEach(terms, id: \.self) { term in
                    Text(term)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.Accent.amber)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .fill(Theme.Surface.well)
                                .stroke(Theme.Border.standard, lineWidth: 1))
                }
                if terms.isEmpty, !loading {
                    Text("no values — every bookmark listed")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.disabled)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.Surface.toolbar)
    }

    private func load() async {
        loading = true
        message = nil
        results = []
        guard let itemID else {
            message = "Nothing to search for."
            loading = false
            return
        }
        let recipe: SearchRecipe
        let subject: SearchSubject?
        do {
            recipe = try browse.library.searchRecipe()
            subject = try browse.library.searchSubject(for: itemID)
        } catch {
            message = "\(error)"
            loading = false
            return
        }
        guard let subject else {
            message = "The item is gone."
            loading = false
            return
        }
        fileName = subject.fileName
        let values = SearchStringBuilder.bookmarkTerms(recipe: recipe, subject: subject)
        terms = values
        guard let profilePath = AppSettingsStore.shared.current.firefoxProfilePath, !profilePath.isEmpty else {
            message = FirefoxBookmarkError.noProfile.message
            loading = false
            return
        }
        let profile = URL(fileURLWithPath: profilePath, isDirectory: true)
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[FirefoxBookmark], FirefoxBookmarkError> in
            do {
                return .success(try FirefoxBookmarkReader.search(profile: profile, terms: values))
            } catch let error as FirefoxBookmarkError {
                return .failure(error)
            } catch {
                return .failure(.unreadable("\(error)"))
            }
        }.value
        switch outcome {
        case .success(let found):
            results = found
            if found.isEmpty {
                message = values.isEmpty
                    ? "No bookmarks in the profile."
                    : "No bookmarks match \(values.map { "“\($0)”" }.joined(separator: " "))"
            }
        case .failure(let error):
            message = error.message
        }
        loading = false
    }
}

/// One bookmark, every property: title, URL, where it is filed, its
/// tags and keyword, its description, and its three dates.
private struct BookmarkRow: View {
    let bookmark: FirefoxBookmark
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(bookmark.title)
                .font(Theme.ui(12.5, .semibold))
                .foregroundStyle(Theme.Text.primary)
            Text(bookmark.url)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.Status.blueBright)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 10) {
                if !bookmark.folderPath.isEmpty { detail("folder", bookmark.folderPath) }
                if !bookmark.tags.isEmpty { detail("tags", bookmark.tags.joined(separator: ", ")) }
                if let keyword = bookmark.keyword { detail("keyword", keyword) }
            }
            if let description = bookmark.description {
                Text(description)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let date = bookmark.dateAdded { detail("added", date.formatted(date: .abbreviated, time: .omitted)) }
                if let date = bookmark.lastModified { detail("modified", date.formatted(date: .abbreviated, time: .omitted)) }
                if let date = bookmark.lastVisited { detail("visited", date.formatted(date: .abbreviated, time: .shortened)) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(hovering ? Theme.Surface.iconTileSelected : Theme.Surface.well)
                .stroke(Theme.Border.standard, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let url = URL(string: bookmark.url) { FirefoxLauncher.open(url) }
        }
        .help("Open in Firefox")
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(Theme.ui(9.5, .semibold))
                .foregroundStyle(Theme.Text.quaternary)
            Text(value)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.tertiary)
                .lineLimit(1)
        }
    }
}
