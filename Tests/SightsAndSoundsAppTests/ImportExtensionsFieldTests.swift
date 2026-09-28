import Testing

@testable import SightsAndSoundsApp

/// The Import pane saves as you type, like every other pane — it used
/// to save only on Return or its Save button, so an edit made and then
/// closed was lost. A field emptied on the way to retyping it keeps the
/// saved list: an empty list would stop every import of that kind.
@Suite struct ImportExtensionsFieldTests {
    @Test func aListIsParsedLowercasedAndTrimmed() {
        #expect(ImportExtensionsField.listToSave(" MP4, mkv ,,MOV ") == ["mp4", "mkv", "mov"])
    }

    @Test func anEmptiedFieldSavesNothing() {
        #expect(ImportExtensionsField.listToSave("") == nil)
        #expect(ImportExtensionsField.listToSave(" , ,") == nil)
    }
}
