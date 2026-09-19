import SwiftUI
import SightsAndSoundsKit

/// The search strings as a panel in the player's right rail (spec 17,
/// decision 9): every format the library has, rendered for the shown
/// item. A click on a string copies it; the ⌘⇧C marker names the
/// format the menu commands use, and a click on a marker moves it.
struct SearchPanel: View {
    @Environment(PlayerModel.self) private var model
    @Environment(BrowseModel.self) private var browse

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Search").modifier(Theme.sectionLabel())
                Spacer()
                Text(model.searchFormats.formats.isEmpty ? "" : "\(model.searchFormats.formats.count)")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if model.searchFormats.formats.isEmpty {
                Text("No search formats yet — add one in Settings › Search String.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.searchFormats.formats) { row($0) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                Text("Click a string to copy it · ⌘⇧C marks the menu's format")
                    .font(Theme.ui(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ format: SearchRecipe) -> some View {
        let string = model.searchSubject.map { SearchStringBuilder.string(recipe: format, subject: $0) } ?? ""
        let isDefault = model.searchFormats.defaultFormat?.id == format.id
        return HStack(alignment: .top, spacing: 6) {
            Button {
                guard !string.isEmpty else { return }
                Clipboard.copy(string)
                browse.showSearchNotice("Copied: \(string)")
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(format.name.isEmpty ? "Untitled" : format.name)
                        .font(Theme.ui(10, .semibold))
                        .foregroundStyle(Theme.Text.quaternary)
                    Text(string.isEmpty ? "(nothing for this item)" : string)
                        .font(Theme.mono(11))
                        .foregroundStyle(string.isEmpty ? Theme.Text.disabled : Theme.Text.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(string.isEmpty)
            .help(string.isEmpty ? "The format yields nothing for this item" : "Copy this string")

            Button {
                model.setDefaultSearchFormat(format.id)
            } label: {
                Text("⌘⇧C")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(isDefault ? Theme.Accent.amber : Theme.Text.disabled)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 5)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(isDefault ? Theme.Surface.iconTileSelected : .clear)
                            .stroke(isDefault ? Theme.Accent.amber : Theme.Border.subtleButton, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(isDefault ? "The format ⌘⇧C, ⌘⇧F and ⌘⇧B use" : "Use this format for ⌘⇧C, ⌘⇧F and ⌘⇧B")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Surface.well)
                .stroke(isDefault ? Theme.Border.activeCard : Theme.Border.standard, lineWidth: 1))
    }
}
