import AppKit

/// Puts text into the focused app: save the clipboard, put the text on it,
/// press ⌘V, then put the old clipboard back. Never presses Enter.
@MainActor
enum Paster {
    private static let vKey: CGKeyCode = 9  // kVK_ANSI_V

    static func paste(_ text: String) {
        let board = NSPasteboard.general
        let saved = snapshot(board)

        board.clearContents()
        board.setString(text, forType: .string)
        // Ask clipboard managers not to record dictated text.
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = board.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down)
            event?.flags = .maskCommand  // explicit, so a still-held fn/shift doesn't leak in
            event?.post(tap: .cghidEventTap)
        }

        // Give the app time to read the clipboard (slow for some Electron and
        // remote-desktop apps), then restore it, unless something else has put
        // new content there meanwhile. The text is also kept for "Copy Last Dictation".
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard board.changeCount == ours else { return }
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
