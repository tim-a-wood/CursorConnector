import SwiftUI

// MARK: - Segment model

private enum OutputSegment: Sendable {
    case markdown(String)
    case code(language: String?, body: String)
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

    private var segments: [OutputSegment] {
        parseOutput(output)
    }

    var body: some View {
        if output.isEmpty {
            emptyView
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyView: some View {
        Text("No output yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let paragraphs = text.split(separator: "\n\n", omittingEmptySubsequences: true)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, raw in
                let block = String(raw)
                Group {
                    if let attr = try? AttributedString(markdown: block, options: .init(interpretedSyntax: .full)) {
                        Text(attr)
                    } else {
                        Text(block)
                    }
                }
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeBlock(language: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
