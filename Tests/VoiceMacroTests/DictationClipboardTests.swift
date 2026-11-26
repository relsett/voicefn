import AppKit
import XCTest
@testable import VoiceMacro

@MainActor
final class DictationClipboardTests: XCTestCase {
    func testRestoresAllItemsAndRepresentationsAfterPaste() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = DictationClipboard(pasteboard: pasteboard)
        let richText = Data(#"{\rtf1\b Original}"#.utf8)
        let textItem = NSPasteboardItem()
        textItem.setString("Original", forType: .string)
        textItem.setData(richText, forType: .rtf)
        let fileItem = NSPasteboardItem()
        fileItem.setString("file:///tmp/example.txt", forType: .fileURL)
        XCTAssertTrue(pasteboard.writeObjects([textItem, fileItem]))

        let snapshot = try XCTUnwrap(clipboard.capture())
        XCTAssertTrue(clipboard.writeForPaste("Transcript", restoring: clipboard.snapshotForPaste(snapshot)))
        XCTAssertEqual(pasteboard.string(forType: .string), "Transcript")
        try await waitForRestore(on: pasteboard)

        let restored = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first?.string(forType: .string), "Original")
        XCTAssertEqual(restored.first?.data(forType: .rtf), richText)
        XCTAssertEqual(restored.last?.string(forType: .fileURL), "file:///tmp/example.txt")
    }

    func testRestoresEmptyClipboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = DictationClipboard(pasteboard: pasteboard)

        let snapshot = try XCTUnwrap(clipboard.capture())
        XCTAssertTrue(clipboard.writeForPaste("Transcript", restoring: clipboard.snapshotForPaste(snapshot)))
        try await waitForRestore(on: pasteboard)

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 0)
    }

    func testRestoresCopyMadeDuringRecording() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = DictationClipboard(pasteboard: pasteboard)
        clipboard.copy("Before recording")
        let snapshot = try XCTUnwrap(clipboard.capture())

        clipboard.copy("While recording")
        XCTAssertTrue(clipboard.writeForPaste("Transcript", restoring: clipboard.snapshotForPaste(snapshot)))
        try await waitForRestore(on: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "While recording")
    }

    func testKeepsCopyMadeAfterPaste() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = DictationClipboard(pasteboard: pasteboard)
        clipboard.copy("Original")
        let snapshot = try XCTUnwrap(clipboard.capture())

        XCTAssertTrue(clipboard.writeForPaste("Transcript", restoring: clipboard.snapshotForPaste(snapshot)))
        clipboard.copy("After paste")
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(pasteboard.string(forType: .string), "After paste")
    }

    func testConsecutiveDictationsRestoreOriginalClipboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = DictationClipboard(pasteboard: pasteboard)
        clipboard.copy("Original")
        let first = try XCTUnwrap(clipboard.capture())
        XCTAssertTrue(clipboard.writeForPaste("First transcript", restoring: clipboard.snapshotForPaste(first)))

        let second = try XCTUnwrap(clipboard.capture())
        XCTAssertTrue(clipboard.writeForPaste("Second transcript", restoring: clipboard.snapshotForPaste(second)))
        XCTAssertEqual(pasteboard.string(forType: .string), "Second transcript")
        try await waitForRestore(on: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "Original")
    }

    private func waitForRestore(on pasteboard: NSPasteboard) async throws {
        let changeCount = pasteboard.changeCount
        let deadline = ContinuousClock.now + .seconds(2)
        while pasteboard.changeCount == changeCount && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(pasteboard.changeCount, changeCount)
    }
}
