import Foundation

/// Finds the sentence the caret sits in, for as-you-type correction. Working
/// a sentence at a time keeps each correction small and fast, and means the
/// suggestion is about the thing the user just finished writing.
public enum SentenceExtractor {

    public struct Sentence: Equatable, Sendable {
        public let text: String
        /// Character offsets into the whole value: `text == value[start..<end]`.
        public let start: Int
        public let end: Int
        public init(text: String, start: Int, end: Int) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    private static let terminators: Set<Character> = [".", "!", "?", "\n", "。", "！", "？"]

    /// The sentence containing (or just before) `caret`. Returns nil when there
    /// is nothing worth correcting yet - too short, or the caret is in the
    /// middle of a word the user is still typing.
    ///
    /// `requireTerminator` (the default) only returns a sentence once it ends
    /// in `.`, `!`, `?` or a newline, so the user is not interrupted mid-word.
    public static func sentence(in value: String, caret: Int, requireTerminator: Bool = true, minLength: Int = 8) -> Sentence? {
        let characters = Array(value)
        guard !characters.isEmpty else { return nil }
        let caret = max(0, min(caret, characters.count))

        // Look at the character just before the caret: if the user is
        // mid-word (a letter/number right before AND after the caret), wait.
        if requireTerminator {
            let before = caret > 0 ? characters[caret - 1] : " "
            // The sentence must have just been ended by a terminator right
            // before the caret (optionally followed by spaces the caret is on).
            var probe = caret - 1
            while probe >= 0, characters[probe] == " " { probe -= 1 }
            let endsSentence = probe >= 0 && terminators.contains(characters[probe])
            let atEnd = caret == characters.count
            if !endsSentence, !(atEnd && terminators.contains(before)) {
                return nil
            }
        }

        // Sentence end: the terminator at/just before the caret (inclusive).
        var end = caret
        if requireTerminator {
            var probe = caret - 1
            while probe >= 0, characters[probe] == " " { probe -= 1 }
            end = probe + 1 // include the terminator
        }
        // Sentence start: just after the previous terminator.
        var start = min(end, characters.count) - 1
        while start > 0 {
            let ch = characters[start - 1]
            if terminators.contains(ch) { break }
            start -= 1
        }
        // Skip leading spaces so the sentence text is clean, but keep the
        // offsets aligned to the value.
        while start < end, characters[start] == " " { start += 1 }

        guard start < end else { return nil }
        let text = String(characters[start..<end])
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minLength else { return nil }
        // A single word with no spaces is not a sentence worth touching.
        guard text.contains(" ") else { return nil }
        return Sentence(text: text, start: start, end: end)
    }

    /// Replaces `sentence`'s range in `value` with `replacement`, returning the
    /// new value and where the caret should sit (just after the replacement).
    public static func apply(_ replacement: String, to sentence: Sentence, in value: String) -> (value: String, caret: Int) {
        let characters = Array(value)
        let start = max(0, min(sentence.start, characters.count))
        let end = max(start, min(sentence.end, characters.count))
        let newValue = String(characters[0..<start]) + replacement + String(characters[end...])
        return (newValue, start + replacement.count)
    }
}
