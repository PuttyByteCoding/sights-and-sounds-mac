import SwiftUI
import SightsAndSoundsKit

extension View {
    /// A paste into a tag field that looks like title case without its
    /// spaces — "BenFolds" off a file name — gets them back:
    /// "Ben Folds". A SwiftUI text field does not say what was pasted,
    /// but typing changes the text by one character and a paste by
    /// several, so a change that grows the text by two or more is
    /// treated as one, and the whole value is run through the Kit's
    /// rule — which leaves anything that does not look like title
    /// case alone, so typed text and ordinary pastes come through
    /// untouched.
    func splitsPastedTitleCase(_ text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { old, new in
            guard new.count - old.count >= 2 else { return }
            let split = new.splittingTitleCaseWords
            if split != new { text.wrappedValue = split }
        }
    }
}
