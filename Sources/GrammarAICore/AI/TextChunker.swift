import Foundation

/// Splits a large text into pieces small enough for one model call, and puts
/// the corrected pieces back together exactly.
///
/// A model has a limited context and gets slower and less reliable on very
/// long input, so a big selection is corrected piece by piece. The split
/// prefers natural boundaries - paragraphs first, then sentences, then, only
/// if a single sentence is still too long, whitespace - so each piece is
/// self-contained and the model has the context it needs. The exact
/// separators between pieces are preserved, so reassembly restores the
/// original layout character for character.
public enum TextChunker {

    public struct Chunk: Equatable, Sendable {
        /// The text to correct.
        public let text: String
        /// The exact separator that followed it in the original (often "\n\n").
        /// Kept verbatim and never sent to the model.
        public let separator: String

        public init(text: String, separator: String) {
            self.text = text
            self.separator = separator
        }
    }

    /// True when `text` is worth splitting. Below this it is one call.
    public static func needsChunking(_ text: String, limit: Int) -> Bool {
        text.count > limit
    }

    /// Splits `text` so every chunk's `text` is at most `maxChunkChars`
    /// (except an single unsplittable token, which is kept whole rather than
    /// cut mid-word). Concatenating each chunk's `text + separator` in order
    /// reproduces the original exactly.
    public static func chunks(from text: String, maxChunkChars: Int) -> [Chunk] {
        guard text.count > maxChunkChars else {
            return [Chunk(text: text, separator: "")]
        }
        // Split into paragraphs, keeping each paragraph's trailing blank-line
        // separator so it can be restored.
        let paragraphs = splitKeepingSeparators(text, pattern: "\n[ \t]*\n[ \t\n]*")
        var chunks: [Chunk] = []
        for piece in paragraphs {
            if piece.body.count <= maxChunkChars {
                chunks.append(Chunk(text: piece.body, separator: piece.separator))
            } else {
                // Paragraph too big: break it into sentences and pack them
                // back up to the limit (splitting a still-too-long sentence
                // on whitespace as a last resort).
                let sentences = splitKeepingSeparators(piece.body, pattern: "(?<=[.!?。！？])\\s+")
                var packed = pack(sentences, maxChunkChars: maxChunkChars, allowSubsplit: true)
                // The paragraph's own separator belongs after its last piece.
                if !packed.isEmpty {
                    packed[packed.count - 1] = Chunk(text: packed[packed.count - 1].text, separator: piece.separator)
                }
                chunks.append(contentsOf: packed)
            }
        }
        return chunks.isEmpty ? [Chunk(text: text, separator: "")] : chunks
    }

    /// Reassembles corrected chunk texts with the original separators. The
    /// corrected array must line up with the chunks it came from.
    public static func reassemble(correctedTexts: [String], separators: [String]) -> String {
        var result = ""
        for (index, text) in correctedTexts.enumerated() {
            result += text
            if index < separators.count { result += separators[index] }
        }
        return result
    }

    // MARK: - Splitting

    private struct Piece { let body: String; let separator: String }

    /// Splits on `pattern`, returning each body with the exact matched
    /// separator that followed it. The final piece has an empty separator.
    private static func splitKeepingSeparators(_ text: String, pattern: String) -> [Piece] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [Piece(body: text, separator: "")]
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [Piece(body: text, separator: "")] }

        var pieces: [Piece] = []
        var cursor = 0
        for match in matches {
            let body = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let separator = ns.substring(with: match.range)
            // Skip an empty body from a leading separator; fold its separator
            // onto the previous piece if any.
            if body.isEmpty, var last = pieces.popLast() {
                last = Piece(body: last.body, separator: last.separator + separator)
                pieces.append(last)
            } else {
                pieces.append(Piece(body: body, separator: separator))
            }
            cursor = match.range.location + match.range.length
        }
        let tail = ns.substring(from: cursor)
        if !tail.isEmpty { pieces.append(Piece(body: tail, separator: "")) }
        return pieces
    }

    /// Packs pieces (sentences, or words) into chunks no larger than the
    /// limit, keeping the exact separators between them so the result rebuilds
    /// the input character for character. A piece longer than the limit is,
    /// when `allowSubsplit` is set, split once more on whitespace into words;
    /// a single unbreakable word is kept whole (over the limit rather than
    /// cut). The chunk that a piece's own separator belongs to is the one
    /// ending in that piece.
    private static func pack(_ pieces: [Piece], maxChunkChars: Int, allowSubsplit: Bool) -> [Chunk] {
        var chunks: [Chunk] = []
        var currentText = ""
        var pendingSeparator = ""
        var started = false

        func flush() {
            guard started else { return }
            chunks.append(Chunk(text: currentText, separator: pendingSeparator))
            currentText = ""
            pendingSeparator = ""
            started = false
        }

        for piece in pieces {
            if piece.body.count > maxChunkChars, allowSubsplit {
                flush()
                let words = splitKeepingSeparators(piece.body, pattern: "\\s+")
                var sub = pack(words, maxChunkChars: maxChunkChars, allowSubsplit: false)
                if !sub.isEmpty {
                    // This piece's trailing separator follows its last word.
                    sub[sub.count - 1] = Chunk(text: sub[sub.count - 1].text, separator: piece.separator)
                }
                chunks.append(contentsOf: sub)
                continue
            }
            let addedLength = started ? pendingSeparator.count + piece.body.count : piece.body.count
            if started, currentText.count + addedLength > maxChunkChars {
                flush()
            }
            if started {
                currentText += pendingSeparator + piece.body
            } else {
                currentText = piece.body
                started = true
            }
            pendingSeparator = piece.separator
        }
        flush()
        return chunks
    }
}
