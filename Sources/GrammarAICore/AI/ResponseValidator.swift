import Foundation

/// Turns raw provider output into a `CorrectionResult`, or throws. Nothing
/// reaches the user's document without passing through here.
public enum ResponseValidator {

    /// Parses a model reply that should be a JSON object. Tolerates the two
    /// deviations models actually produce - a markdown code fence around the
    /// JSON, and stray prose before/after it - and rejects everything else.
    public static func parse(rawResponse: String) throws -> CorrectionResult {
        let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CorrectionError.emptyResponse }

        let candidates = [trimmed, stripCodeFence(trimmed), outermostJSONObject(in: trimmed)]
        for candidate in candidates {
            guard let candidate, let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return try result(fromJSONObject: object)
        }
        throw CorrectionError.invalidResponse
    }

    /// Builds a result from an already-decoded object (native structured output).
    public static func result(fromJSONObject object: [String: Any]) throws -> CorrectionResult {
        guard let corrected = object["corrected_text"] as? String else {
            throw CorrectionError.invalidResponse
        }
        let changed = object["changed"] as? Bool
        let language = (object["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CorrectionResult(correctedText: corrected, changed: changed ?? true, language: language)
    }

    /// Final gate before replacement. Returns text that is safe to paste:
    /// non-empty, plausibly a correction of `original` (not an essay, not a
    /// refusal, not a truncation, not unrelated text) and with the
    /// original's outer whitespace.
    ///
    /// `mode` matters because Professional and Custom legitimately rewrite:
    /// there a distant reply is flagged `needsReview` instead of rejected,
    /// and the pipeline then asks the user before replacing anything.
    public static func validate(
        _ result: CorrectionResult,
        against original: String,
        mode: CorrectionMode = .natural
    ) throws -> CorrectionResult {
        let originalCore = original.trimmingCharacters(in: .whitespacesAndNewlines)
        var corrected = result.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else { throw CorrectionError.emptyResponse }

        corrected = stripLeakedTags(corrected)
        corrected = stripAddedWrapping(corrected, original: originalCore)
        guard !corrected.isEmpty else { throw CorrectionError.emptyResponse }

        // A correction stays close to the original's size. Short texts can
        // legitimately grow ("u" -> "you"); long ones cannot triple, and a
        // long text that comes back much shorter has lost content.
        let originalLength = originalCore.count
        let correctedLength = corrected.count
        let rewrites = mode == .professional || mode == .custom
        let upperBound = originalLength * 2 + 40
        let lowerBound: Int
        switch originalLength {
        case ..<20: lowerBound = 1
        case ..<200: lowerBound = originalLength / 3
        default: lowerBound = originalLength * 6 / 10
        }
        guard correctedLength <= upperBound else { throw CorrectionError.invalidResponse }
        var needsReview = false
        if correctedLength < lowerBound {
            // "Make it concise" can legitimately shrink a text, so a rewrite
            // mode asks the user instead of refusing - within reason.
            guard rewrites, correctedLength >= max(1, originalLength / 5) else {
                throw CorrectionError.invalidResponse
            }
            needsReview = true
        }

        // A correction resembles what it corrects. This is the backstop
        // against prompt injection: if text inside the selection talked the
        // model into answering with something else, that answer resembles
        // nothing the user wrote, and it is never pasted silently.
        //
        // Thresholds are calibrated on measured scores (docs/RESEARCH.md):
        // real corrections, even with every word misspelled, score 0.63 and
        // up; answers, refusals and injected text score 0.56 and down. The
        // band in between is not guessed at - the user is asked.
        switch Self.resemblance(of: corrected, to: originalCore, rewrites: rewrites) {
        case .close: break
        case .uncertain: needsReview = true
        case .unrelated: throw CorrectionError.invalidResponse
        }

        // Selections often carry a trailing space or newline; keep exactly
        // what the user had so the surrounding text does not shift.
        let leading = String(original.prefix(while: { $0.isWhitespace }))
        let trailing = String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let final = leading + corrected + trailing

        return CorrectionResult(
            correctedText: final,
            changed: final != original,
            language: result.language,
            needsReview: needsReview
        )
    }

    enum Resemblance: Equatable { case close, uncertain, unrelated }

    static func resemblance(of corrected: String, to original: String, rewrites: Bool) -> Resemblance {
        // Too short for character pairs to mean anything ("teh" and "the"
        // share none): compare the letters themselves, and do not guess.
        if normalized(original).count < 12 {
            return dice(characterCounts(original), characterCounts(corrected)) >= 0.5 ? .close : .unrelated
        }
        let score = similarity(original, corrected)
        if score >= 0.6 { return .close }
        return score >= (rewrites ? 0.1 : 0.35) ? .uncertain : .unrelated
    }

    /// Sorensen-Dice similarity over character pairs, 0...1. Character pairs
    /// (not words) so that a typo-ridden original still matches its fix:
    /// "helo wrold" and "Hello world" share most of their pairs but not a
    /// single whole word. Case, punctuation and spacing are ignored, and it
    /// works the same for every script.
    static func similarity(_ first: String, _ second: String) -> Double {
        dice(characterPairs(first), characterPairs(second))
    }

    private static func dice(_ a: [String: Int], _ b: [String: Int]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var shared = 0
        for (key, count) in a {
            shared += min(count, b[key] ?? 0)
        }
        return Double(2 * shared) / Double(a.values.reduce(0, +) + b.values.reduce(0, +))
    }

    private static func normalized(_ text: String) -> [Character] {
        var result: [Character] = []
        var lastWasSpace = true
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        if result.last == " " { result.removeLast() }
        return result
    }

    private static func characterCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for character in normalized(text) where character != " " {
            counts[String(character), default: 0] += 1
        }
        return counts
    }

    private static func characterPairs(_ text: String) -> [String: Int] {
        let characters = normalized(text)
        guard characters.count >= 2 else { return [:] }
        var pairs: [String: Int] = [:]
        for index in 0..<(characters.count - 1) {
            pairs[String(characters[index...index + 1]), default: 0] += 1
        }
        return pairs
    }

    // MARK: - Helpers

    static func stripCodeFence(_ text: String) -> String? {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 else { return nil }
        var body = String(text.dropFirst(3).dropLast(3))
        // Drop an info string such as "json" on the opening fence line.
        if let newline = body.firstIndex(of: "\n") {
            let firstLine = body[..<newline].trimmingCharacters(in: .whitespaces)
            if firstLine.allSatisfy({ $0.isLetter }) {
                body = String(body[body.index(after: newline)...])
            }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func outermostJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end])
    }

    /// The model occasionally echoes our data tags back, with or without
    /// the per-request suffix.
    static func stripLeakedTags(_ text: String) -> String {
        text.replacingOccurrences(
            of: "</?\\Q\(CorrectionPrompt.tagName)\\E(-[0-9a-f]+)?>",
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes quotes or a code fence the model added around the whole text,
    /// but only when the original did not have them.
    static func stripAddedWrapping(_ text: String, original: String) -> String {
        var result = text
        if !original.hasPrefix("```"), let unfenced = stripCodeFence(result) {
            result = unfenced
        }
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        for (open, close) in quotePairs {
            guard result.count >= 2, result.first == open, result.last == close else { continue }
            let originalWrapped = original.first == open && original.last == close
            let inner = result.dropFirst().dropLast()
            if !originalWrapped, !inner.contains(open), !inner.contains(close) {
                result = String(inner)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
