import AppKit
import SightsAndSoundsKit

/// Hands the app's own windows and menus to someone who cannot see the
/// screen — a reviewer working over a terminal, or a design pass run
/// from a script.
///
/// macOS grants Screen Recording per app and all-or-nothing: a terminal
/// allowed to capture one window of this app is thereby allowed to
/// capture every window on the display, mail and messages included.
/// Nothing here asks for it. A window draws ITSELF into a bitmap, which
/// needs no permission at all because the app already owns those pixels.
/// The menu bar lives outside every window and cannot be drawn that way,
/// so it is written out as text instead — which reads better for
/// reviewing structure than a picture of an open menu ever did, and
/// carries the key equivalents and the icons with it.
///
/// Two ways in: Window ▸ Capture UI Snapshot, and `SAS_UI_SNAPSHOT_DIR` on
/// the environment, which captures a few seconds after launch and is how
/// a scripted review drives it.
///
/// What it writes can name real files and real tags, so the default
/// folder is under Application Support and never the repo — private
/// library data must not enter history (`scripts/check-no-private-data.sh`).
@MainActor
enum UISnapshot {
    /// Where to write. Set on the environment, a snapshot is taken
    /// shortly after launch with nobody touching a menu.
    static let directoryKey = "SAS_UI_SNAPSHOT_DIR"

    /// Seconds to wait for the windows to come up first.
    static let delayKey = "SAS_UI_SNAPSHOT_DELAY"

    /// Set to quit once the files are written, so a script gets its
    /// prompt back instead of an app sitting open.
    static let exitKey = "SAS_UI_SNAPSHOT_EXIT"

    /// Long enough for the picker — and any window the system restored —
    /// to have drawn a first frame. Capturing sooner caught empty
    /// content views.
    static let defaultDelay: TimeInterval = 3

    /// The name of the written index, beside the images.
    static let inventoryName = "ui-inventory.md"

    struct Report {
        var directory: URL
        var images: [String] = []
        var skipped: [String] = []
    }

    // MARK: - Entry points

    /// Called once from `applicationDidFinishLaunching`. Does nothing
    /// unless the environment asks, so a normal launch is untouched.
    static func captureIfEnvironmentAsks() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[directoryKey], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                            isDirectory: true)
        let delay = environment[delayKey].flatMap(TimeInterval.init) ?? defaultDelay
        let shouldExit = environment[exitKey] != nil

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            do {
                let report = try capture(into: directory)
                AppLog.shared.info(
                    "ui-snapshot",
                    "wrote \(report.images.count) window image(s) and \(inventoryName) to \(directory.path)")
            } catch {
                AppLog.shared.error("ui-snapshot", "failed: \(error.localizedDescription)")
            }
            if shouldExit {
                // Straight out, not `NSApp.terminate`: the terminate path
                // puts up the running-tasks alert, and a script has
                // nobody to answer it. A snapshot run writes nothing to a
                // library, so there is nothing in flight to lose.
                exit(EXIT_SUCCESS)
            }
        }
    }

    /// The menu item: writes a folder under Application Support and
    /// opens it, so the files can be dragged wherever they are wanted.
    static func captureAndReveal() {
        do {
            let report = try capture(into: defaultDirectory())
            NSWorkspace.shared.activateFileViewerSelecting(
                [report.directory.appendingPathComponent(inventoryName)])
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not write the UI snapshot."
            alert.runModal()
        }
    }

    /// A fresh folder per capture, named by the moment, so two in a row
    /// do not overwrite each other.
    static func defaultDirectory(at moment: Date = Date()) -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return AppModel.supportDirectory()
            .appendingPathComponent("UI Snapshots", isDirectory: true)
            .appendingPathComponent(stamp.string(from: moment), isDirectory: true)
    }

    // MARK: - Capture

    @discardableResult
    static func capture(into directory: URL) throws -> Report {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        var report = Report(directory: directory)
        var lines: [String] = []
        lines.append("# UI snapshot")
        lines.append("")
        lines.append("Written \(Self.timestamp()) by Window ▸ Capture UI Snapshot (`UISnapshot`).")
        lines.append("No screen recording was involved: each window drew itself, and the")
        lines.append("menu bar below is read from `NSApp.mainMenu` rather than photographed.")
        lines.append("")
        lines.append("- Appearance: \(NSApp.effectiveAppearance.name.rawValue)")
        lines.append("- Interface zoom: \(String(format: "%.2f", UIZoom.shared.scale))×")
        lines.append("")

        // Front to back, which is also how they are stacked on screen, so
        // the numbering matches what someone would describe.
        let windows = NSApp.windows.filter(\.isVisible)
        lines.append("## Windows (\(windows.count))")
        lines.append("")
        for (index, window) in windows.enumerated() {
            let number = String(format: "%02d", index + 1)
            let title = window.title.isEmpty ? "(untitled)" : window.title
            lines.append("### \(index + 1). \(title)")
            lines.append("")
            lines.append("- Frame: \(describe(window.frame))")
            lines.append("- Identifier: \(window.identifier?.rawValue ?? "—")")
            lines.append("- Key window: \(window.isKeyWindow ? "yes" : "no")")

            let name = "\(number)-\(slug(title)).png"
            if let data = png(of: window) {
                try data.write(to: directory.appendingPathComponent(name))
                report.images.append(name)
                lines.append("- Image: `\(name)`")
            } else {
                report.skipped.append(title)
                lines.append("- Image: none — the window had nothing to draw into a bitmap.")
            }
            lines.append("")
            lines.append(contentsOf: toolbarLines(for: window))
            lines.append("")
        }

        lines.append("## Menu bar")
        lines.append("")
        lines.append("Enabled state is as of the capture, for whichever window was key.")
        lines.append("")
        lines.append("```")
        if let main = NSApp.mainMenu {
            // Without this the items carry whatever enabled state they
            // were last left with; `update()` runs the same validation
            // pass that opening the menu would.
            appendOutline(of: main, depth: 0, into: &lines)
        } else {
            lines.append("(no main menu)")
        }
        lines.append("```")
        lines.append("")

        try lines.joined(separator: "\n")
            .write(to: directory.appendingPathComponent(inventoryName),
                   atomically: true, encoding: .utf8)
        return report
    }

    // MARK: - Drawing a window into a bitmap

    /// The window's own pixels, title bar and toolbar included.
    ///
    /// The frame view, not the content view: the toolbar and the title
    /// live above the content view, and they are most of what a review of
    /// buttons and their labels is about.
    private static func png(of window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let drawn = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        view.cacheDisplay(in: bounds, to: drawn)

        // Vibrancy samples what is BEHIND the window, so an
        // NSVisualEffectView contributes nothing to a bitmap of the
        // window alone and leaves its area transparent. Over the window's
        // own background colour those areas read as they look on screen
        // instead of as a hole.
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: drawn.pixelsWide, pixelsHigh: drawn.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        canvas.size = bounds.size

        let context = NSGraphicsContext(bitmapImageRep: canvas)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let area = NSRect(origin: .zero, size: bounds.size)
        (window.backgroundColor ?? .windowBackgroundColor).setFill()
        area.fill()
        drawn.draw(in: area)
        NSGraphicsContext.restoreGraphicsState()

        return canvas.representation(using: .png, properties: [:])
    }

    // MARK: - Toolbars

    /// A toolbar is where an icon most often ends up without a word under
    /// it, so the display mode and every item's label are spelled out —
    /// an item with an image and an empty label is the thing to find.
    private static func toolbarLines(for window: NSWindow) -> [String] {
        guard let toolbar = window.toolbar else { return ["- Toolbar: none"] }
        var lines = ["- Toolbar display mode: \(describe(toolbar.displayMode))"]
        guard !toolbar.items.isEmpty else {
            lines.append("- Toolbar items: none")
            return lines
        }
        lines.append("")
        lines.append("| # | Identifier | Label | Palette label | Icon | Tooltip |")
        lines.append("| - | ---------- | ----- | ------------- | ---- | ------- |")
        for (index, item) in toolbar.items.enumerated() {
            let cells = [
                "\(index + 1)",
                "`\(item.itemIdentifier.rawValue)`",
                item.label.isEmpty ? "**(none)**" : item.label,
                item.paletteLabel.isEmpty ? "—" : item.paletteLabel,
                item.image.map { symbolName($0) } ?? "—",
                item.toolTip ?? "—",
            ]
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines
    }

    // MARK: - The menu bar, as text

    private static func appendOutline(of menu: NSMenu, depth: Int, into lines: inout [String]) {
        menu.update()
        let indent = String(repeating: "    ", count: depth)
        for item in menu.items {
            if item.isSeparatorItem {
                lines.append(indent + "────────")
                continue
            }
            var row = indent + item.title
            if let image = item.image {
                row += "  [icon: \(symbolName(image))]"
            }
            let key = shortcut(for: item)
            if !key.isEmpty { row += "  \(key)" }
            if item.state == .on { row += "  ✓" }
            if item.state == .mixed { row += "  –" }
            if !item.isEnabled { row += "  (disabled)" }
            if item.isHidden { row += "  (hidden)" }
            lines.append(row)
            if let submenu = item.submenu {
                appendOutline(of: submenu, depth: depth + 1, into: &lines)
            }
        }
    }

    /// The shortcut as macOS draws it in the menu, so it can be compared
    /// against the menu on screen without decoding modifier masks.
    private static func shortcut(for item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        var out = ""
        if mask.contains(.control) { out += "⌃" }
        if mask.contains(.option) { out += "⌥" }
        // A capital letter in a key equivalent IS the shift; macOS shows
        // it as ⇧ plus the unshifted letter rather than as a capital.
        let isCapital = key.count == 1 && key.first!.isUppercase
        if mask.contains(.shift) || isCapital { out += "⇧" }
        if mask.contains(.command) { out += "⌘" }
        return out + glyph(for: key)
    }

    private static func glyph(for key: String) -> String {
        switch key {
        case "\u{8}", "\u{7F}": return "⌫"
        case "\r", "\u{3}": return "↩"
        case "\t": return "⇥"
        case "\u{1B}": return "⎋"
        case " ": return "Space"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "→"
        default: return key.uppercased()
        }
    }

    // MARK: - Small helpers

    /// An SF Symbol carries its name on the image; anything else is
    /// described by whatever it was given for VoiceOver.
    private static func symbolName(_ image: NSImage) -> String {
        if let name = image.name(), !name.isEmpty { return "`\(name)`" }
        if let described = image.accessibilityDescription, !described.isEmpty { return described }
        return "(unnamed image)"
    }

    private static func describe(_ mode: NSToolbar.DisplayMode) -> String {
        switch mode {
        case .iconAndLabel: "icon and label"
        case .iconOnly: "**icon only — no text under the icons**"
        case .labelOnly: "label only"
        case .default: "system default (icon only)"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ frame: NSRect) -> String {
        let number = { (value: CGFloat) in String(format: "%.0f", value) }
        return "\(number(frame.width)) × \(number(frame.height))"
            + " at (\(number(frame.minX)), \(number(frame.minY)))"
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.string(from: Date())
    }

    private static func slug(_ title: String) -> String {
        let reduced = title.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let parts = String(reduced).split(separator: "-", omittingEmptySubsequences: true)
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "window" : String(joined.prefix(48))
    }
}
