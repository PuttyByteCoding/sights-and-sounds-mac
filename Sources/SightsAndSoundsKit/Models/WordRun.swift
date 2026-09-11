import Foundation

extension String {
    /// The run of letters, numbers and spaces around a position — what a
    /// double-click on a file name selects. Every other character is a
    /// wall: a dash, an underscore, a dot, a bracket. "2019-07-04 Phish -
    /// Alpine Valley - AUD.mp4" clicked on "Alpine" gives "Alpine
    /// Valley"; clicked on "07" gives "07". Spaces at either end of the
    /// run are dropped, so the selection is the words and not the gaps
    /// beside their walls. A click ON a wall selects nothing but the
    /// wall itself.
    public func wordRun(at position: String.Index) -> Range<String.Index> {
        guard position < endIndex else { return endIndex..<endIndex }
        func inside(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == " " }
        guard inside(self[position]) else { return position..<index(after: position) }
        var lower = position
        while lower > startIndex, inside(self[index(before: lower)]) { lower = index(before: lower) }
        var upper = index(after: position)
        while upper < endIndex, inside(self[upper]) { upper = index(after: upper) }
        while lower < upper, self[lower] == " " { lower = index(after: lower) }
        while upper > lower, self[index(before: upper)] == " " { upper = index(before: upper) }
        // A click on a space between two walls: the space itself.
        if lower == upper { return position..<index(after: position) }
        return lower..<upper
    }

    /// The same, by UTF-16 offset — the unit AppKit's text system counts
    /// in. Returns the UTF-16 range.
    public func wordRun(atUTF16Offset offset: Int) -> NSRange {
        guard offset >= 0, offset < utf16.count,
              let position = utf16.index(utf16.startIndex, offsetBy: offset).samePosition(in: self)
        else { return NSRange(location: max(0, min(offset, utf16.count)), length: 0) }
        return NSRange(wordRun(at: position), in: self)
    }
}
