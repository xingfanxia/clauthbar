import Foundation
import XCTest

@testable import CCSBarKit

/// Profile-rename flow: the pure client-side name validation
/// (`renameValidationError`, which mirrors the daemon's `validate_profile_name`)
/// and the commit guard (an invalid name surfaces a loud error and never fires the
/// socket). The socket round-trip itself is covered by the daemon's socket tests.
final class RenameTests: XCTestCase {
    // MARK: - Name validation (pure)

    func testEmptyNameRejected() {
        XCTAssertNotNil(StatusModel.renameValidationError("   ", old: "xfx", existing: ["xfx"]))
    }

    func testBadCharsetRejected() {
        XCTAssertNotNil(StatusModel.renameValidationError("has space", old: "xfx", existing: ["xfx"]))
        XCTAssertNotNil(StatusModel.renameValidationError("slash/name", old: "xfx", existing: ["xfx"]))
    }

    func testLeadingDotRejected() {
        XCTAssertNotNil(StatusModel.renameValidationError(".hidden", old: "xfx", existing: ["xfx"]))
    }

    func testCollisionRejectedCaseInsensitively() {
        // A DIFFERENT existing profile with the same name (any case) collides.
        let err = StatusModel.renameValidationError("CL-AX", old: "xfx", existing: ["xfx", "cl-ax"])
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.contains("already exists"))
    }

    func testValidNamePasses() {
        XCTAssertNil(StatusModel.renameValidationError("xfx2", old: "xfx", existing: ["xfx", "cl-ax"]))
        // Legit charset: letters, digits, - _ .
        XCTAssertNil(StatusModel.renameValidationError("work_2.old-1", old: "xfx", existing: ["xfx"]))
    }

    func testCaseOnlySelfRenameAllowed() {
        // Renaming a profile to a case variant of ITSELF is not a collision.
        XCTAssertNil(StatusModel.renameValidationError("XFX", old: "xfx", existing: ["xfx", "cl-ax"]))
    }

    // MARK: - Begin / cancel toggle the banner state

    @MainActor
    func testBeginAndCancelRenameToggleState() {
        let model = StatusModel(preview: nil, liveness: .down)
        XCTAssertNil(model.renaming)
        model.beginRename("xfx")
        XCTAssertEqual(model.renaming, "xfx")
        model.cancelRename()
        XCTAssertNil(model.renaming)
    }

    // MARK: - Commit guard (invalid name never reaches the socket)

    @MainActor
    func testCommitWithInvalidNameSurfacesErrorAndClosesEditor() {
        let model = StatusModel(preview: nil, liveness: .down)
        model.beginRename("xfx")
        // An empty name is invalid regardless of the profile set → the guard fires
        // before any socket work: the editor closes and the error is loud.
        model.commitRename("xfx", to: "  ")
        XCTAssertNil(model.renaming, "the editor closes on a rejected rename")
        XCTAssertNotNil(model.lastCommandError, "an invalid name surfaces a loud error")
    }
}
