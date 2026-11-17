import ApplicationServices
import XCTest
@testable import VoiceMacro

final class TextPastePolicyTests: XCTestCase {
    func testWebTextAreaDoesNotNeedDirectValueSetterForKeyboardPaste() {
        XCTAssertTrue(allows(role: kAXTextAreaRole, valueWritable: false))
        XCTAssertTrue(allows(role: kAXTextFieldRole, valueWritable: false))
    }

    func testMissingOptionalAccessibilityAttributesDoNotRejectTextField() {
        XCTAssertTrue(TextPastePolicy.allows(role: kAXTextFieldRole, subrole: nil, enabled: nil,
                                            editable: nil, readOnly: nil, protected: false, valueWritable: false))
    }

    func testSecureAndProtectedFieldsAreStillRejected() {
        XCTAssertFalse(allows(subrole: kAXSecureTextFieldSubrole))
        XCTAssertFalse(allows(protected: true))
    }

    func testDisabledAndExplicitlyReadOnlyFieldsAreStillRejected() {
        XCTAssertFalse(allows(enabled: false))
        XCTAssertFalse(allows(editable: false))
        XCTAssertFalse(allows(readOnly: true))
    }

    func testNonTextControlsAreNotPasteTargets() {
        for role in [kAXButtonRole, kAXStaticTextRole, "AXWebArea", kAXGroupRole] {
            XCTAssertFalse(allows(role: role), role)
        }
        XCTAssertTrue(allows(role: kAXGroupRole, editable: true))
    }

    func testComboBoxRequiresEvidenceOfTextEditing() {
        XCTAssertFalse(allows(role: kAXComboBoxRole, valueWritable: false))
        XCTAssertTrue(allows(role: kAXComboBoxRole, editable: true, valueWritable: false))
        XCTAssertTrue(allows(role: kAXComboBoxRole, valueWritable: true))
    }

    private func allows(role: String = kAXTextAreaRole, subrole: String? = nil, enabled: Bool = true,
                        editable: Bool? = nil, readOnly: Bool? = nil, protected: Bool = false,
                        valueWritable: Bool = true) -> Bool {
        TextPastePolicy.allows(role: role, subrole: subrole, enabled: enabled, editable: editable,
                               readOnly: readOnly, protected: protected, valueWritable: valueWritable)
    }
}
