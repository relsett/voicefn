import AppKit

@MainActor
final class DictationClipboard {
    struct Snapshot {
        fileprivate let changeCount: Int
        fileprivate let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
    }

    private let pasteboard: NSPasteboard
    private var pendingRestore: (changeCount: Int, snapshot: Snapshot)?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func capture() -> Snapshot? {
        let changeCount = pasteboard.changeCount
        // A new recording can begin while the previous Cmd-V is still being processed.
        if let pendingRestore, pendingRestore.changeCount == changeCount {
            return Snapshot(changeCount: changeCount, items: pendingRestore.snapshot.items)
        }
        guard let sourceItems = pasteboard.pasteboardItems else { return nil }
        var items: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
        for item in sourceItems {
            var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations.append((type, data))
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        return Snapshot(changeCount: changeCount, items: items)
    }

    func snapshotForPaste(_ original: Snapshot?) -> Snapshot? {
        if let original, original.changeCount == pasteboard.changeCount { return original }
        // Keep anything the user copied since the recording started.
        return capture()
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func writeForPaste(_ text: String, restoring snapshot: Snapshot?) -> Bool {
        let changeCount = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        if let snapshot {
            pendingRestore = (changeCount, snapshot)
            // Posted Cmd-V events are asynchronous. Allow time for the target to read the text.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [self] in
                restore(after: changeCount)
            }
        }
        return true
    }

    private func restore(after changeCount: Int) {
        guard let pendingRestore, pendingRestore.changeCount == changeCount else { return }
        self.pendingRestore = nil
        guard pasteboard.changeCount == changeCount else { return }

        let items = pendingRestore.snapshot.items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
