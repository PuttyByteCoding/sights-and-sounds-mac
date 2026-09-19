import SwiftUI
import SightsAndSoundsKit

/// The search strings as a panel in the player's right rail (spec 17,
/// decision 9): every format the library has, rendered for the shown
/// item. The default leads under "⌘⇧C copies" — always the string the
/// shortcut would copy — and the other formats follow, each with a
/// button to make it the default. A click on any string copies it.
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
                    VStack(alignment: .leading, spacing: 6) {
                        // The default leads, and says so: this is the
                        // string ⌘⇧C copies, whatever else is listed.
                        if let primary = model.searchFormats.defaultFormat {
                            Text("⌘⇧C copies")
                                .font(Theme.ui(9.5, .semibold))
                                .foregroundStyle(Theme.Accent.amber)
                                .padding(.horizontal, 4)
                            row(primary, isDefault: true)
                        }
                        let others = model.searchFormats.formats.filter { $0.id != model.searchFormats.defaultFormat?.id }
                        if !others.isEmpty {
                            Text("Other formats")
                                .font(Theme.ui(9.5, .semibold))
                                .foregroundStyle(Theme.Text.quaternary)
                                .padding(.horizontal, 4)
                                .padding(.top, 6)
                            ForEach(others) { row($0, isDefault: false) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                Text("Click a string to copy it · “Use for ⌘⇧C” moves the default")
                    .font(Theme.ui(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ format: SearchRecipe, isDefault: Bool) -> some View {
        let string = model.searchSubject.map { SearchStringBuilder.string(recipe: format, subject: $0) } ?? ""
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

            if !isDefault {
                Button {
                    model.setDefaultSearchFormat(format.id)
                } label: {
                    Text("Use for ⌘⇧C")
                        .font(Theme.ui(9.5))
                        .foregroundStyle(Theme.Text.tertiary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .stroke(Theme.Border.subtleButton, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Make this the format ⌘⇧C, ⌘⇧F and ⌘⇧B use")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Surface.well)
                .stroke(isDefault ? Theme.Accent.amber : Theme.Border.standard, lineWidth: 1))
    }
}
