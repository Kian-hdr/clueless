import SwiftUI
import Foundation

struct MarkdownListItem: Equatable {
    var text: String
    var indentation: Int
    var ordinal: Int?
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([MarkdownListItem])
    case orderedList([MarkdownListItem])
    case code(language: String?, text: String)
    case quote(String)
}

/// A small block parser for answer text, not a complete CommonMark document
/// engine. It makes one linear pass and does not execute or load any content.
enum MarkdownAnswerParser {
    private struct Fence { let marker: Character; let count: Int; let language: String? }
    private struct Marker { let text: String; let columns: Int; let ordinal: Int? }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = [], index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            if let fence = openingFence(line) {
                index += 1
                var code: [String] = []
                while index < lines.count {
                    if closesFence(lines[index], fence) { index += 1; break }
                    code.append(lines[index]); index += 1
                }
                if !code.isEmpty { blocks.append(.code(language: fence.language, text: code.joined(separator: "\n"))) }
                continue
            }
            if let heading = heading(line) {
                if !heading.text.isEmpty { blocks.append(.heading(level: heading.level, text: heading.text)) }
                index += 1; continue
            }
            if quoteText(line) != nil {
                var quote: [String] = []
                while index < lines.count, let text = quoteText(lines[index]) { quote.append(text); index += 1 }
                let text = quote.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.quote(text)) }
                continue
            }
            if let first = listMarker(line) {
                let ordered = first.ordinal != nil
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    if let marker = listMarker(lines[index]), (marker.ordinal != nil) == ordered {
                        index += 1
                        if !marker.text.isEmpty {
                            items.append(.init(text: marker.text, indentation: min(6, marker.columns / 2), ordinal: marker.ordinal))
                        }
                    } else if let last = items.indices.last, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              indentation(lines[index]) > items[last].indentation * 2,
                              !startsBlock(lines[index]) {
                        items[last].text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else { break }
                }
                if !items.isEmpty { blocks.append(ordered ? .orderedList(items) : .unorderedList(items)) }
                continue
            }
            var paragraph = "", hardBreak = false
            while index < lines.count {
                let current = lines[index]
                if current.trimmingCharacters(in: .whitespaces).isEmpty || startsBlock(current) { break }
                let text = current.trimmingCharacters(in: .whitespaces)
                if !paragraph.isEmpty { paragraph += hardBreak ? "\n" : " " }
                hardBreak = current.hasSuffix("  ") || current.hasSuffix("\\")
                paragraph += current.hasSuffix("\\") ? String(text.dropLast()) : text
                index += 1
            }
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)) }
            else { index += 1 } // A pending streamed marker must never trap the parser.
        }
        return blocks
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }
    private static func unindented(_ line: String) -> Substring { line.drop(while: { $0 == " " || $0 == "\t" }) }
    private static func openingFence(_ line: String) -> Fence? {
        let text = unindented(line)
        guard let marker = text.first, marker == "`" || marker == "~" else { return nil }
        let count = text.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = text.dropFirst(count).trimmingCharacters(in: .whitespaces)
        return Fence(marker: marker, count: count, language: info.isEmpty ? nil : info)
    }
    private static func closesFence(_ line: String, _ fence: Fence) -> Bool {
        let text = unindented(line), count = unindented(line).prefix(while: { $0 == fence.marker }).count
        return count >= fence.count && text.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }
    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let text = unindented(line), count = text.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count) else { return nil }
        let remainder = text.dropFirst(count)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        let title = remainder.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        return (count, title)
    }
    private static func quoteText(_ line: String) -> String? {
        let text = unindented(line)
        guard text.first == ">" else { return nil }
        let remainder = text.dropFirst()
        return String(remainder.first == " " ? remainder.dropFirst() : remainder)
    }
    private static func listMarker(_ line: String) -> Marker? {
        let text = unindented(line)
        guard let first = text.first else { return nil }
        if ["-", "+", "*"].contains(first) {
            let remainder = text.dropFirst()
            guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
            return Marker(text: remainder.trimmingCharacters(in: .whitespaces), columns: indentation(line), ordinal: nil)
        }
        let digits = text.prefix(while: { $0 >= "0" && $0 <= "9" })
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = text.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        let remainder = rest.dropFirst()
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        return Marker(text: remainder.trimmingCharacters(in: .whitespaces), columns: indentation(line), ordinal: number)
    }
    private static func startsBlock(_ line: String) -> Bool {
        openingFence(line) != nil || heading(line) != nil || quoteText(line) != nil || listMarker(line) != nil
    }
}

enum MarkdownAnswerInline {
    private static let image = try! NSRegularExpression(pattern: #"!\[([^\]]*)\](?:\([^)]*\)|\[[^\]]*\])?"#)

    static func attributed(_ text: String, fontSize: Double = 16) -> AttributedString {
        // Images become alt text outside code spans. Native Text has no remote
        // image loader, and removing link actions avoids accidental navigation.
        let safeText = imageAltTextOutsideCode(text)
        var result = (try? AttributedString(markdown: safeText, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(safeText)
        for run in result.runs {
            if run.link != nil { result[run.range].link = nil }
            if run.inlinePresentationIntent?.contains(.code) == true { result[run.range].font = .system(size: fontSize, design: .monospaced) }
        }
        return result
    }

    private static func altText(_ text: Substring) -> String {
        let string = String(text)
        return image.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: "$1")
    }
    private static func imageAltTextOutsideCode(_ text: String) -> String {
        var result = "", cursor = text.startIndex, start = text.startIndex, delimiter: Int?
        while cursor < text.endIndex {
            guard text[cursor] == "`" else { cursor = text.index(after: cursor); continue }
            let fenceStart = cursor
            while cursor < text.endIndex, text[cursor] == "`" { cursor = text.index(after: cursor) }
            let count = text.distance(from: fenceStart, to: cursor)
            if delimiter == nil {
                result += altText(text[start..<fenceStart])
                start = fenceStart; delimiter = count
            } else if delimiter == count {
                result += text[start..<cursor]
                start = cursor; delimiter = nil
            }
        }
        result += delimiter == nil ? altText(text[start...]) : String(text[start...])
        return result
    }
}

/// Native block layout shared by the compact answer and selectable workspace.
/// Selection is left to the caller, so `.textSelection(.enabled)` can be applied
/// in the workspace without making the passive in-call widget editable.
struct MarkdownAnswerView: View {
    private let blocks: [MarkdownBlock]
    private let fontSize: Double
    init(_ markdown: String, fontSize: Double = 16) {
        blocks = MarkdownAnswerParser.parse(markdown)
        self.fontSize = fontSize.isFinite ? max(10, fontSize) : 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
        }
        .font(.system(size: fontSize))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text): inline(text).lineSpacing(2)
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: fontSize * (level == 1 ? 1.18 : level == 2 ? 1.1 : 1), weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        case .unorderedList(let items), .orderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let attributed = MarkdownAnswerInline.attributed(item.text, fontSize: fontSize)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.ordinal.map { "\($0)." } ?? "•")
                            .monospacedDigit()
                            .frame(minWidth: item.ordinal == nil ? 9 : 18, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(attributed).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indentation) * 12)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.ordinal.map { "Item \($0)" } ?? "Bullet"), \(String(attributed.characters))")
                }
            }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 5) {
                if let language { Text(language).font(.caption).foregroundStyle(.secondary) }
                ScrollView(.horizontal) {
                    Text(verbatim: text)
                        .font(.system(size: max(10, fontSize - 1), design: .monospaced))
                        .lineSpacing(2)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(9)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(language.map { "\($0) code" } ?? "Code"). \(text)")
        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2).accessibilityHidden(true)
                inline(text).foregroundStyle(.secondary).lineSpacing(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Quote. \(String(MarkdownAnswerInline.attributed(text).characters))")
        }
    }

    private func inline(_ text: String) -> some View {
        Text(MarkdownAnswerInline.attributed(text, fontSize: fontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
