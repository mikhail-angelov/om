import AppKit
import MarkdownEngine

/// `⌥↑`/`⌥↓` moves the line(s) under the selection, `⌥⇧↑`/`⌥⇧↓` duplicates
/// them — the convention every other editor the user lives in follows.
///
/// The commands are menu items: menu key equivalents are tried before the key
/// reaches the text view, which would otherwise turn `⌥↑`/`⌥↓` into paragraph
/// navigation. The engine's text view exposes no key-binding hook, so the
/// actions look the focused view up through the responder chain and edit it
/// through `shouldChangeText`/`didChangeText` — the same route the engine's
/// own input helpers take, so every command joins the undo stack and reaches
/// the binding/autosave sync like typed text.
@MainActor
enum EditorLineCommands {
    static func moveFocusedLine(up: Bool) {
        guard let textView = focusedEditor() else { return }
        moveLine(in: textView, up: up)
    }

    static func duplicateFocusedLine(below: Bool) {
        guard let textView = focusedEditor() else { return }
        duplicateLine(in: textView, below: below)
    }

    /// The engine's text view is the responder whose delegate is the engine
    /// coordinator; that check keeps the sidebar and find-bar fields (whose
    /// field editors are plain NSTextViews) on their own keys.
    private static func focusedEditor() -> NSTextView? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable,
              textView.delegate is NativeTextViewCoordinator
        else { return nil }
        return textView
    }

    /// Swaps the selected line block with the neighbor above or below it. A
    /// multi-line selection moves as one block; the caret rides along, staying
    /// on the line it started on.
    private static func moveLine(in textView: NSTextView, up: Bool) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let block = text.lineRange(for: selection)

        let neighbor: NSRange
        let replaceRange: NSRange
        if up {
            guard block.location > 0 else { return }
            neighbor = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            replaceRange = NSRange(
                location: neighbor.location,
                length: NSMaxRange(block) - neighbor.location
            )
        } else {
            guard NSMaxRange(block) < text.length else { return }
            neighbor = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            guard neighbor.length > 0 else { return } // nothing below but the final newline
            replaceRange = NSRange(
                location: block.location,
                length: NSMaxRange(neighbor) - block.location
            )
        }

        let blockText = text.substring(with: block)
        let neighborText = text.substring(with: neighbor)
        // Line ranges end at their newline except at the document's end, so a
        // block moved across that edge takes the neighbor's newline.
        let replacement: String
        if up {
            replacement = blockText.hasSuffix("\n")
                ? blockText + neighborText
                : blockText + "\n" + String(neighborText.dropLast())
        } else {
            replacement = neighborText.hasSuffix("\n")
                ? neighborText + blockText
                : neighborText + "\n" + String(blockText.dropLast())
        }
        // Every branch above produces neighbor.count + block.count characters,
        // but the block's own offset inside the replacement only equals the
        // neighbor's length when the neighbor keeps its newline; the borrowed
        // one adds a character ahead of the block.
        let shift: Int
        if up {
            shift = -neighborText.count
        } else {
            shift = neighborText.hasSuffix("\n") ? neighborText.count : neighborText.count + 1
        }
        apply(
            editIn: textView,
            range: replaceRange,
            replacement: replacement,
            selection: selection
        ) {
            NSRange(location: $0.location + shift, length: $0.length)
        }
    }

    /// Inserts a copy of the selected line block next to itself: below for
    /// `⌥⇧↓`, above for `⌥⇧↑`. The caret lands on the lower copy either way,
    /// so the selection always stays on the same visible line it started on.
    private static func duplicateLine(in textView: NSTextView, below: Bool) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let block = text.lineRange(for: selection)
        let content = text.substring(with: block)
        let endsWithNewline = content.hasSuffix("\n")
        // The document's last line carries no newline; the copy borrows one.
        let inserted = below
            ? (endsWithNewline ? content : "\n" + content)
            : (endsWithNewline ? content : content + "\n")
        let at = below ? NSMaxRange(block) : block.location
        apply(
            editIn: textView,
            range: NSRange(location: at, length: 0),
            replacement: inserted,
            selection: selection
        ) {
            NSRange(location: $0.location + inserted.count, length: $0.length)
        }
    }

    private static func apply(
        editIn textView: NSTextView,
        range: NSRange,
        replacement: String,
        selection: NSRange,
        mappingSelection: (NSRange) -> NSRange
    ) {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        // Map the selection captured BEFORE the edit: didChangeText has already
        // parked the caret at the edited range's end by now.
        let mapped = mappingSelection(selection)
        textView.setSelectedRange(mapped)
        textView.scrollRangeToVisible(mapped)
    }
}
