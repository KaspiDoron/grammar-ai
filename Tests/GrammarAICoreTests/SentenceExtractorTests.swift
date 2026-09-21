import Foundation
import Testing
@testable import GrammarAICore

@Suite("SentenceExtractor")
struct SentenceExtractorTests {

    @Test func returnsNilMidWord() {
        // Caret in the middle of "workin" - still typing.
        #expect(SentenceExtractor.sentence(in: "i am workin", caret: 11) == nil)
    }

    @Test func returnsTheSentenceOnceItIsTerminated() {
        let value = "i dont think this is right."
        let s = SentenceExtractor.sentence(in: value, caret: value.count)
        #expect(s?.text == "i dont think this is right.")
        #expect(s?.start == 0)
        #expect(s?.end == value.count)
    }

    @Test func picksTheSentenceJustFinishedNotTheWholeField() {
        let value = "First one is fine. i has a typo here."
        let s = SentenceExtractor.sentence(in: value, caret: value.count)
        #expect(s?.text == "i has a typo here.")
    }

    @Test func worksWhenCaretIsAfterTheTerminatorAndASpace() {
        let value = "this needs a fix. "
        let s = SentenceExtractor.sentence(in: value, caret: value.count)
        #expect(s?.text == "this needs a fix.")
    }

    @Test func ignoresTooShortOrSingleWord() {
        #expect(SentenceExtractor.sentence(in: "ok.", caret: 3) == nil)
        #expect(SentenceExtractor.sentence(in: "hello.", caret: 6) == nil) // one word
    }

    @Test func handlesNewlineAsATerminator() {
        let value = "please fix this line\n"
        let s = SentenceExtractor.sentence(in: value, caret: value.count)
        #expect(s?.text.contains("please fix this line") == true)
    }

    @Test func appliesACorrectionAtTheRightRange() {
        let value = "First one is fine. i has a typo here."
        let s = SentenceExtractor.sentence(in: value, caret: value.count)!
        let (newValue, caret) = SentenceExtractor.apply("I have a typo here.", to: s, in: value)
        #expect(newValue == "First one is fine. I have a typo here.")
        #expect(caret == newValue.count)
    }

    @Test func applyPreservesTextAfterTheSentence() {
        let value = "fix this sentance. keep this part."
        // caret right after the first sentence's period + space
        let s = SentenceExtractor.sentence(in: value, caret: 18)!
        #expect(s.text == "fix this sentance.")
        let (newValue, _) = SentenceExtractor.apply("Fix this sentence.", to: s, in: value)
        #expect(newValue == "Fix this sentence. keep this part.")
    }

    @Test func handlesHebrewSentences() {
        let value = "אני רוצה ללכת לחנות."
        let s = SentenceExtractor.sentence(in: value, caret: value.count)
        #expect(s?.text == "אני רוצה ללכת לחנות.")
    }
}
