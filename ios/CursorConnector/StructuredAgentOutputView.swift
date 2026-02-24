import SwiftUI

// MARK: - Segment model

private enum OutputSegment: Sendable {
    case markdown(String)
    case code(language: String?, body: String)
}

// MARK: - Text normalization

/// Converts single newlines that look like paragraph boundaries into double newlines, so we get visible paragraph breaks when the source only uses "\n" between paragraphs.
private func normalizeParagraphBreaks(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count > 1 else { return text }
    let sentenceEnd: Set<Character> = [".", "!", "?"]
    var result: [String] = []
    for (idx, line) in lines.enumerated() {
        result.append(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let nextIdx = idx + 1
        guard nextIdx < lines.count else { continue }
        let nextLine = lines[nextIdx]
        let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
        guard !nextTrimmed.isEmpty else { continue }
        let lastChar = trimmed.last
        let firstNext = nextTrimmed.first
        if lastChar.map({ sentenceEnd.contains($0) }) == true,
           firstNext.map({ $0.isUppercase || $0.isNumber || $0 == "-" || $0 == "*" || $0 == "#" }) == true {
            result.append("")
        }
    }
    return result.joined(separator: "\n")
}

/// Restores spaces that are often lost when stream-json chunks are concatenated (e.g. "alert.The" → "alert. The", "output)TestFlight" → "output) TestFlight").
private func normalizeSpacesInStreamedText(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var result = ""
    let punctuation: Set<Character> = [".", "!", "?", ")", "]", ":", ";"]
    for (i, c) in text.enumerated() {
        let idx = text.index(text.startIndex, offsetBy: i)
        if i > 0 {
            let prevIdx = text.index(before: idx)
            let prev = text[prevIdx]
            // Space after sentence-ending (or list-ending) punctuation when followed by a letter
            if punctuation.contains(prev), c.isLetter, result.last != " " {
                result.append(" ")
            }
            // Space between lowercase and uppercase (e.g. "failureConnection" → "failure Connection")
            if prev.isLowercase, c.isUppercase, result.last != " " {
                result.append(" ")
            }
        }
        result.append(c)
    }
    return result
}

// MARK: - Parser

private func parseOutput(_ raw: String) -> [OutputSegment] {
    var segments: [OutputSegment] = []
    let fence = "```"
    var remaining = raw[...]
    var isCode = false
    var current = ""

    while !remaining.isEmpty {
        if let range = remaining.range(of: fence) {
            let before = String(remaining[..<range.lowerBound])
            remaining = remaining[range.upperBound...]

            if isCode {
                let codeContent = (current + before).trimmingCharacters(in: .whitespacesAndNewlines)
                let (lang, body): (String?, String) = {
                    let firstLineEnd = codeContent.rangeOfCharacter(from: .newlines)
                    if let end = firstLineEnd {
                        let first = String(codeContent[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let rest = String(codeContent[end.upperBound...])
                        return (first.isEmpty ? nil : first, rest)
                    }
                    return (nil, codeContent)
                }()
                segments.append(.code(language: lang, body: body))
                current = ""
            } else {
                if !(current + before).trimmingCharacters(in: .whitespaces).isEmpty {
                    segments.append(.markdown(current + before))
                }
                current = ""
            }
            isCode.toggle()
        } else {
            current += remaining
            remaining = ""
        }
    }

    let tail = current.trimmingCharacters(in: .whitespaces)
    if !tail.isEmpty {
        if isCode {
            let (lang, body): (String?, String) = {
                let firstLineEnd = tail.rangeOfCharacter(from: .newlines)
                if let end = firstLineEnd {
                    let first = String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let rest = String(tail[end.upperBound...])
                    return (first.isEmpty ? nil : first, rest)
                }
                return (nil, tail)
            }()
            segments.append(.code(language: lang, body: body))
        } else {
            segments.append(.markdown(tail))
        }
    }

    return segments
}

// MARK: - Structured view

struct StructuredAgentOutputView: View {
    let output: String
    var paragraphSpacing: CGFloat = 14
    var lineSpacing: CGFloat = 6

    private var segments: [OutputSegment] {
        parseOutput(normalizeSpacesInStreamedText(output))
    }

    var body: some View {
        if output.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: OutputSegment) -> some View {
        switch segment {
        case .markdown(let text):
            markdownBlock(text)
        case .code(let language, let body):
            codeBlock(language: language, body: body)
        }
    }

    private func markdownBlock(_ text: String) -> some View {
        // Only trim the outer block so we don't strip meaningful whitespace or newlines inside.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AnyView(EmptyView())
        }
        let withBreaks = normalizeParagraphBreaks(trimmed)
        let paragraphs = withBreaks.split(separator: "\n\n", omittingEmptySubsequences: true).map(String.init)
        return AnyView(
            VStack(alignment: .leading, spacing: paragraphSpacing) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, raw in
                    markdownParagraphWithNewlines(String(raw))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    /// Renders a paragraph so that single newlines are shown as line breaks (not collapsed by Markdown).
    private func markdownParagraphWithNewlines(_ raw: String) -> some View {
        let para = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if para.isEmpty {
            return AnyView(EmptyView())
        }
        let lines = para.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return AnyView(
            VStack(alignment: .leading, spacing: lineSpacing) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    markdownParagraph(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    /// Renders a single paragraph (markdown or plain) with consistent line spacing and no extra trimming of inner whitespace.
    @ViewBuilder
    private func markdownParagraph(_ raw: String) -> some View {
        let para = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if para.isEmpty {
            EmptyView()
        } else if let attr = try? AttributedString(markdown: para, options: .init(interpretedSyntax: .full)) {
            Text(attr)
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(para)
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBlock(language: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(body)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 280)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        StructuredAgentOutputView(output: """
        ## Summary
        I'll add a helper and use it in both places.

        **Steps:**
        1. Parse the output into code and markdown.
        2. Render code in a card.

        ```swift
        let x = 42
        print(x)
        ```

        Then we're done.
        """)
        .padding()
    }
}
