import XCTest
@testable import InterviewCore

final class MemoryBoundaryTests: XCTestCase {
    func testRejectsTraversalAndSensitiveNamespacesEvenWhenSelected() {
        XCTAssertFalse(MemoryBoundary.permits(path: "../Other/secret.md", selected: ["../Other/secret.md"]))
        XCTAssertFalse(MemoryBoundary.permits(path: "Wiki/Health/History.md", selected: ["Wiki/Health/History.md"]))
        XCTAssertFalse(MemoryBoundary.permits(path: "Wiki/Projects/../Health/History.md", selected: ["Wiki/Projects/../Health/History.md"]))
        XCTAssertTrue(MemoryBoundary.permits(path: "Wiki/Projects/Demo/Project_Brief.md", selected: ["Wiki/Projects/Demo/Project_Brief.md"]))
    }
    func testSelectedFilesOnlyAndConfidentialExcerptRejected() {
        XCTAssertFalse(MemoryBoundary.permits(path: "Wiki/Projects/Other.md", selected: ["Wiki/Projects/Demo.md"]))
        XCTAssertNil(MemoryBoundary.safeExcerpt("Strictly confidential company customer agreement"))
        XCTAssertNil(MemoryBoundary.safeExcerpt("API_KEY=example"))
        XCTAssertEqual(MemoryBoundary.safeExcerpt("Released a native game with measured CPU improvements."), "Released a native game with measured CPU improvements.")
    }
}
