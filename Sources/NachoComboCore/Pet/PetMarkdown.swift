import Foundation

/// A run of Nacho's answer with its inline style (`**굵게**`, `*기울임*`, `` `코드` ``, `[글](링크)`).
public struct PetMarkdownSpan: Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var link: URL?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: URL? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.code = code; self.link = link
    }
}

/// Inline markdown for Nacho's chat bubbles. Line breaks and spaces are kept as written; block syntax (lists, headings)
/// is left as typed. A half-written marker (an answer still streaming: `**굵` ) stays plain until it closes.
public enum PetMarkdown {
    public static func spans(_ source: String) -> [PetMarkdownSpan] {
        guard source.contains("*") || source.contains("`") || source.contains("_") || source.contains("](") || source.contains("~") else {
            return [PetMarkdownSpan(source)]
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: source, options: options) else { return [PetMarkdownSpan(source)] }
        var out: [PetMarkdownSpan] = []
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            if text.isEmpty { continue }
            let intent = run.inlinePresentationIntent ?? []
            let span = PetMarkdownSpan(text, bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized),
                                       code: intent.contains(.code), link: run.link)
            if var last = out.last, last.bold == span.bold, last.italic == span.italic, last.code == span.code, last.link == span.link {
                last.text += span.text
                out[out.count - 1] = last
            } else {
                out.append(span)
            }
        }
        return out.isEmpty ? [PetMarkdownSpan(source)] : out
    }
}
