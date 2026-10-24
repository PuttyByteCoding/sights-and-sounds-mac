import SightsAndSoundsKit
import SwiftUI

/// Every place the toolbar, the menu bar and the command palette can
/// send you, with the one name and the one symbol each is allowed to
/// wear.
///
/// The three surfaces used to name these independently, and they drifted:
/// Tag Manager and Tag Analysis both drew `tag.square`, Background Tasks
/// was a gear in the palette and a list in the toolbar, and the Log was
/// `doc.text` in one place and `text.alignleft` in the other. Same
/// destination, different icon, depending on how you got there.
///
/// `DestinationIconsTests` holds the line: no two destinations may share
/// a symbol, and a destination's title must match the title its window
/// gives itself.
enum Destination: CaseIterable {
    case tagManager
    case importMedia
    case review
    case organise
    case maintenance
    case tagAnalysis
    case history
    case libraryProperties
    case backgroundTasks
    case log

    /// The window this opens, where it is one of the auxiliary
    /// workspaces. Nil for the app-wide windows, which are their own
    /// scenes rather than an `aux` request.
    var auxKind: AuxWindowRequest.Kind? {
        switch self {
        case .tagManager: .categories
        case .importMedia: .importMedia
        case .review: .review
        case .organise: .organise
        case .maintenance: .maintenance
        case .tagAnalysis: .tagAnalysis
        case .history: .watched
        case .libraryProperties, .backgroundTasks, .log: nil
        }
    }

    var title: String {
        switch self {
        case .tagManager: "Tag Manager"
        case .importMedia: "Import"
        case .review: "Review"
        case .organise: "Organise"
        case .maintenance: "Maintenance"
        case .tagAnalysis: "Tag Analysis"
        case .history: "History"
        case .libraryProperties: "Library Properties"
        case .backgroundTasks: "Background Tasks"
        case .log: "Log"
        }
    }

    var symbol: String {
        switch self {
        case .tagManager: "tag.square"
        case .importMedia: "square.and.arrow.down"
        case .review: "checklist"
        case .organise: "folder.badge.gearshape"
        case .maintenance: "wrench.and.screwdriver"
        case .tagAnalysis: "sparkle.magnifyingglass"
        case .history: "clock.arrow.circlepath"
        case .libraryProperties: "info.circle"
        case .backgroundTasks: "list.bullet.rectangle"
        case .log: "doc.text"
        }
    }

    /// The one way any surface should draw this destination.
    var label: Label<Text, Image> {
        Label(title, systemImage: symbol)
    }
}

/// How the player's four flags present themselves.
///
/// They used to be bare Unicode in the toolbar — ★ ⟳ ⚠ ⌫ — four of the
/// most-used controls in the app with no text and no symbol, identifiable
/// only by hovering. The symbols match what the command palette already
/// calls the same flags, so a filter and the button that sets it look
/// alike.
///
/// Presentation, so it lives in the app rather than the Kit, which stays
/// free of anything that draws.
extension PlayerToggleFlag {
    var buttonTitle: String {
        switch self {
        case .favorite: "Favourite"
        case .needsReview: "Needs Review"
        case .playbackIssue: "Won't Play"
        case .markedForDeletion: "Delete"
        }
    }

    var symbol: String {
        switch self {
        case .favorite: "star"
        case .needsReview: "eye.trianglebadge.exclamationmark"
        case .playbackIssue: "play.slash"
        case .markedForDeletion: "trash"
        }
    }

    /// The filled counterpart, drawn while the flag is on.
    var onSymbol: String {
        switch self {
        case .favorite: "star.fill"
        case .needsReview: "eye.trianglebadge.exclamationmark"
        case .playbackIssue: "play.slash.fill"
        case .markedForDeletion: "trash.fill"
        }
    }
}
