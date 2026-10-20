import AppKit
import Foundation
import SightsAndSoundsKit
import SwiftUI
import Testing

@testable import SightsAndSoundsApp

@Observable @MainActor private final class Presentation {
    var keyMap = false
    var bindings = false
}

/// A sheet the player presents is a layer, and Esc unwinds exactly one
/// layer — so Esc must leave every sheet, from wherever the keyboard
/// landed when it opened. The key-map sheet hands focus to its search
/// field on open; before, its only exit was a Done button, and `?` put
/// you somewhere Esc could not leave.
///
/// The sheets are presented for real here, in an off-screen window, and
/// the key goes through the window the way a press does.
@Suite(.serialized) @MainActor struct PlayerSheetKeysTests {
    private struct Host: View {
        @Bindable var presentation: Presentation
        let model: PlayerModel

        var body: some View {
            Color.clear
                .frame(width: 200, height: 120)
                .sheet(isPresented: $presentation.keyMap) {
                    KeyMapSheet().environment(model)
                }
                .sheet(isPresented: $presentation.bindings) {
                    KeyBindingsEditor().environment(model)
                }
        }
    }

    private func makeModel() throws -> PlayerModel {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Sheets")
        return PlayerModel(
            request: PlayerRequest(
                libraryID: UUID(), itemID: UUID(),
                definition: .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath),
                playlist: []),
            library: library, appDatabase: nil)
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeWindow(_ host: Host) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: host)
        window.orderFront(nil)
        return window
    }

    /// Waits for the host window to have a sheet attached and returns it.
    private func attachedSheet(of window: NSWindow) -> NSWindow? {
        for _ in 0..<20 where window.attachedSheet == nil { spin(0.1) }
        return window.attachedSheet
    }

    /// Waits for the sheet to go, its animation included.
    private func waitForDetach(of window: NSWindow) {
        for _ in 0..<30 where window.attachedSheet != nil { spin(0.1) }
    }

    /// Presses the key the way a real press arrives: key equivalents
    /// first — where a button's shortcut answers — then the first
    /// responder. Returns whether a control claimed it as its shortcut.
    ///
    /// That claim is the assertion that matters. SwiftUI already lets a
    /// macOS sheet go on Esc when nothing else takes the key, so a sheet
    /// closing proves little; a close control that CARRIES the shortcut
    /// is what keeps a focused field, or a future `onKeyPress`, from
    /// swallowing it.
    @discardableResult
    private func press(_ key: String, keyCode: UInt16, in sheet: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: keyCode)
        else {
            Issue.record("could not make the key event")
            return false
        }
        if sheet.performKeyEquivalent(with: event) { return true }
        sheet.sendEvent(event)
        return false
    }

    @discardableResult
    private func pressEscape(in sheet: NSWindow) -> Bool { press("\u{1b}", keyCode: 53, in: sheet) }
    @discardableResult
    private func pressReturn(in sheet: NSWindow) -> Bool { press("\r", keyCode: 36, in: sheet) }

    @Test func thePresentedKeyMapSheetClosesOnEscape() throws {
        let model = try makeModel()
        let presentation = Presentation()
        let window = makeWindow(Host(presentation: presentation, model: model))
        defer { window.close() }

        presentation.keyMap = true
        let sheet = try #require(attachedSheet(of: window), "the key-map sheet is presented")
        #expect(sheet.firstResponder is NSTextView, "the search field took the keyboard on open")

        let claimed = pressEscape(in: sheet)
        waitForDetach(of: window)

        #expect(claimed, "Cancel carries the cancel shortcut")
        #expect(!presentation.keyMap, "Esc leaves the sheet")
        #expect(window.attachedSheet == nil)
    }

    @Test func thePresentedKeyBindingsEditorClosesOnEscape() throws {
        let model = try makeModel()
        let presentation = Presentation()
        let window = makeWindow(Host(presentation: presentation, model: model))
        defer { window.close() }

        presentation.bindings = true
        let sheet = try #require(attachedSheet(of: window), "the bindings editor is presented")

        let claimed = pressEscape(in: sheet)
        waitForDetach(of: window)

        #expect(claimed, "the close control carries the cancel shortcut")
        #expect(!presentation.bindings, "Esc leaves the sheet")
        #expect(window.attachedSheet == nil)
    }

    /// Return still closes the bindings editor: Done is its one button,
    /// so it answers to both keys.
    @Test func thePresentedKeyBindingsEditorClosesOnReturn() throws {
        let model = try makeModel()
        let presentation = Presentation()
        let window = makeWindow(Host(presentation: presentation, model: model))
        defer { window.close() }

        presentation.bindings = true
        let sheet = try #require(attachedSheet(of: window), "the bindings editor is presented")

        let claimed = pressReturn(in: sheet)
        waitForDetach(of: window)

        #expect(claimed, "Done carries the default shortcut")
        #expect(!presentation.bindings, "Return is Done")
    }

    /// `?` reaches the sheet-opening path from inside a tag field. The
    /// player's text-input guard consults this rule ahead of handing
    /// the key to the field — the same way it lets the F-keys through —
    /// and it admits `?` alone: every other printable key still spells
    /// a tag name.
    @Test func questionMarkIsTheOnlyPrintableKeyThroughTheTextInputGuard() {
        #expect(PlayerKeyMap.opensKeyboardMap("?"))

        let printable = (0x20...0x7E).compactMap { UnicodeScalar($0).map(Character.init) }
        let through = printable.filter(PlayerKeyMap.opensKeyboardMap)
        #expect(through == ["?"], "no other printable key leaves the field")
    }
}
