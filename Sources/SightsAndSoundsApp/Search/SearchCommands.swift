import AppKit
import SwiftUI
import SightsAndSoundsKit

/// The item the Search menu acts on, published by the focused window:
/// the playing item when a player is up, else the grid's single
/// selection (spec 17, decision 5).
struct SearchSubjectRef: Equatable {
    let libraryID: UUID
    let itemID: UUID
}

struct SearchSubjectFocusKey: FocusedValueKey {
    typealias Value = SearchSubjectRef
}

extension FocusedValues {
    var searchSubject: SearchSubjectRef? {
        get { self[SearchSubjectFocusKey.self] }
        set { self[SearchSubjectFocusKey.self] = newValue }
    }
}

/// The web search URL: the template's `{query}` takes the string,
/// percent-encoded so quotes, spaces and ampersands survive. A template
/// without the placeholder gets the query appended.
enum SearchWebURL {
    static let placeholder = "{query}"

    static func resolve(template: String, query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.contains(placeholder)
            ? trimmed.replacingOccurrences(of: placeholder, with: encoded)
            : trimmed + encoded
        guard let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty, url.host != nil
        else { return nil }
        return url
    }
}

/// Opens a URL in Firefox when it is installed, else wherever the
/// system sends it. Returns whether Firefox took it.
enum FirefoxLauncher {
    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.mozilla.firefox")
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        if let app = appURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        NSWorkspace.shared.open(url)
        return false
    }
}

/// The Search menu (spec 17, decision 5). Every command builds the
/// string from the library's recipe and the subject; none is enabled
/// without a subject.
struct SearchMenuCommands: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.searchSubject) private var subject
    @FocusedValue(\.browseModel) private var browse

    var body: some View {
        Group {
            Button("Copy Search String") { copyString() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Search Firefox Bookmarks") { searchBookmarks() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Search the Web in Firefox") { searchWeb() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .disabled(subject == nil)
    }

    /// The string for the subject, or the reason there is none — shown
    /// in the footer either way, so a silent shortcut never happens.
    private enum Built {
        case string(String)
        case problem(String)
    }

    private func buildString() -> Built {
        guard let subject, let library = try? model.library(for: subject.libraryID) else {
            return .problem("Nothing to search for.")
        }
        do {
            let recipe = try library.searchRecipe()
            guard !recipe.parts.isEmpty else {
                return .problem("The search string has no parts yet — set it up in Settings › Search String.")
            }
            guard let item = try library.searchSubject(for: subject.itemID) else {
                return .problem("The item is gone.")
            }
            let string = SearchStringBuilder.string(recipe: recipe, subject: item)
            return string.isEmpty ? .problem("The recipe yields nothing for this item.") : .string(string)
        } catch {
            return .problem("\(error)")
        }
    }

    private func copyString() {
        switch buildString() {
        case .string(let string):
            Clipboard.copy(string)
            browse?.showSearchNotice("Copied: \(string)")
        case .problem(let reason):
            browse?.showSearchNotice(reason)
        }
    }

    private func searchWeb() {
        switch buildString() {
        case .string(let string):
            guard let url = SearchWebURL.resolve(template: AppSettingsStore.shared.current.webSearchURL, query: string)
            else {
                browse?.showSearchNotice("The web search URL in Settings › Search String is not a URL.")
                return
            }
            let inFirefox = FirefoxLauncher.open(url)
            browse?.showSearchNotice(inFirefox ? "Searching: \(string)" : "Firefox is not installed — opened in the default browser: \(string)")
        case .problem(let reason):
            browse?.showSearchNotice(reason)
        }
    }

    private func searchBookmarks() {
        guard let subject else { return }
        openWindow(
            id: "aux",
            value: AuxWindowRequest(
                libraryID: subject.libraryID, kind: .bookmarkSearch, itemIDs: [subject.itemID]))
    }
}
