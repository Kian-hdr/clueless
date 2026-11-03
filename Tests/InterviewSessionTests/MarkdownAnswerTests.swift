import XCTest
import SwiftUI
@testable import InterviewAssistant

final class MarkdownAnswerTests: XCTestCase {
    func testLeadAndRealListItemsRemainSeparateBlocks() {
        let blocks = MarkdownAnswerParser.parse("I would test the boundaries first.\n\n- **Cancellation:** Stop old work.\n- **Cleanup:** Release resources.")
        XCTAssertEqual(blocks, [
            .paragraph("I would test the boundaries first."),
            .unorderedList([.init(text: "**Cancellation:** Stop old work.", indentation: 0, ordinal: nil), .init(text: "**Cleanup:** Release resources.", indentation: 0, ordinal: nil)])
        ])
    }

    func testHeadingsOrderedListsQuotesAndRepeatedParagraphs() {
        let blocks = MarkdownAnswerParser.parse("## Approach\n\n3. First step\n4) Second step\n\n> State assumptions.\n> Ask if needed.\n\nRepeat.\n\nRepeat.")
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "Approach"))
        XCTAssertEqual(blocks[1], .orderedList([.init(text: "First step", indentation: 0, ordinal: 3), .init(text: "Second step", indentation: 0, ordinal: 4)]))
        XCTAssertEqual(blocks[2], .quote("State assumptions.\nAsk if needed."))
        XCTAssertEqual(Array(blocks.suffix(2)), [.paragraph("Repeat."), .paragraph("Repeat.")])
    }

    func testFencedCodePreservesIndentationBlankLinesAndLiteralMarkdown() {
        let code = "def lookup(items):\n    # **literal**\n\n    return items[0]  "
        XCTAssertEqual(MarkdownAnswerParser.parse("Before.\n\n```python\n" + code + "\n```\n\nAfter."), [.paragraph("Before."), .code(language: "python", text: code), .paragraph("After.")])
        XCTAssertEqual(MarkdownAnswerParser.parse("~~~swift\n    let value = 1\n~~~"), [.code(language: "swift", text: "    let value = 1")])
    }

    func testIncompleteStreamMarkersDoNotCreateEmptyListOrLoseCode() {
        XCTAssertEqual(MarkdownAnswerParser.parse("A streamed lead.\n\n-"), [.paragraph("A streamed lead.")])
        XCTAssertEqual(MarkdownAnswerParser.parse("- First item\n- "), [.unorderedList([.init(text: "First item", indentation: 0, ordinal: nil)])])
        XCTAssertEqual(MarkdownAnswerParser.parse("## "), [])
        XCTAssertEqual(MarkdownAnswerParser.parse("```swift\n    let part"), [.code(language: "swift", text: "    let part")])
        XCTAssertTrue(String(MarkdownAnswerInline.attributed("**Partial bold").characters).contains("Partial bold"))
    }

    func testSoftLinesWrapButExplicitHardBreakAndListContinuationSurvive() {
        XCTAssertEqual(MarkdownAnswerParser.parse("One soft\nline.  \nA new line."), [.paragraph("One soft line.\nA new line.")])
        XCTAssertEqual(MarkdownAnswerParser.parse("- One item\n  continued here\n  - Nested item"), [.unorderedList([.init(text: "One item continued here", indentation: 0, ordinal: nil), .init(text: "Nested item", indentation: 1, ordinal: nil)])])
    }

    func testInlineFormattingUsesNativeRunsWithoutRemoteImageOrLinkActions() {
        let rendered = MarkdownAnswerInline.attributed("**Bold** and *emphasis* with `code` and [label](https://example.com). ![Diagram](https://example.com/image.png)")
        let plain = String(rendered.characters)
        XCTAssertTrue(plain.contains("Bold and emphasis with code and label."))
        XCTAssertTrue(plain.contains("Diagram"))
        XCTAssertFalse(rendered.runs.contains { $0.link != nil })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        let literalImageSyntax = MarkdownAnswerInline.attributed("`![literal](https://example.com/image.png)`")
        XCTAssertEqual(String(literalImageSyntax.characters), "![literal](https://example.com/image.png)")
    }

    @MainActor func testNativeViewBuildsAtCompactWidthWithoutWebContent() {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: MarkdownAnswerView("I would test behavior first.\n\n- **Boundary:** Cancel old work.\n- **Evidence:** Check the result.", fontSize: 16).frame(width: 388, alignment: .leading))
        view.frame = NSRect(x: 0, y: 0, width: 388, height: 190)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame.width, 388)
        XCTAssertFalse(String(reflecting: type(of: view)).contains("WebView"))
    }
}
