import AppKit

/// Structured dictation as HTML, so apps that paste rich text show a real
/// list (1. 2. 3.) or paragraphs. The plain string is on the same pasteboard
/// item: plain-text fields, terminals and code editors read that one and
/// never look at the HTML.
enum RichText {
    private static let numbered = try! NSRegularExpression(pattern: "^(\\d{1,3})\\. (.*)$")

    /// HTML for `text`, or nil when it has no list or paragraph to show.
    static func html(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }
        var body = "", paragraph: [String] = [], list: [String] = [], start = 1, structured = false
        func flushParagraph() {
            if !paragraph.isEmpty { body += "<p>" + paragraph.map(escape).joined(separator: "<br>") + "</p>"; paragraph = [] }
        }
        func flushList() {
            if !list.isEmpty {
                body += (start == 1 ? "<ol>" : "<ol start=\"\(start)\">") + list.map { "<li>\(escape($0))</li>" }.joined() + "</ol>"
                list = []; structured = true
            }
        }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = numbered.firstMatch(in: line, range: range),
               let number = Range(match.range(at: 1), in: line), let item = Range(match.range(at: 2), in: line) {
                flushParagraph()
                if list.isEmpty { start = Int(line[number]) ?? 1 }
                list.append(String(line[item]))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushList(); flushParagraph(); structured = structured || !body.isEmpty
            } else {
                flushList(); paragraph.append(line)
            }
        }
        flushList(); flushParagraph()
        guard structured else { return nil }
        return "<meta charset=\"utf-8\">" + body
    }

    /// The list items and paragraph lines a rich editor shows, without the
    /// numbers it renders itself; insertion checks look for these in order.
    static func visibleLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            let shown = numbered.firstMatch(in: line, range: range).flatMap { Range($0.range(at: 2), in: line) }.map { String(line[$0]) } ?? line
            let trimmed = shown.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
