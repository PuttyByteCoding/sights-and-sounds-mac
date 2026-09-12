import Foundation

/// A file name written as pieces between underscores —
/// "sdg_BenFoldsFive_OnStage_tonight.mp4" — is a list of things the
/// namer meant separately, and each is a possible tag on its own. The
/// pieces, with the extension dropped from the last, empties dropped,
/// and title case without its spaces given them back, so the piece is
/// offered as the tag it would be typed as: "Ben Folds Five",
/// "On Stage", "tonight", and "sdg". A name with no underscore has no
/// pieces — its words are not a list.
public enum FileNameSegments {
    public static func pieces(of fileName: String) -> [String] {
        guard fileName.contains("_") else { return [] }
        let stem = (fileName as NSString).deletingPathExtension
        return stem
            .split(separator: "_", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces).splittingTitleCaseWords }
            .filter { !$0.isEmpty }
    }
}
