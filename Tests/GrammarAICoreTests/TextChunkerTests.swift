import Foundation
import Testing
@testable import GrammarAICore

@Suite("TextChunker")
struct TextChunkerTests {

    /// The one invariant that matters most: chunk texts + separators must
    /// rebuild the original exactly, whatever the input.
    private func assertRoundTrips(_ text: String, maxChunkChars: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let chunks = TextChunker.chunks(from: text, maxChunkChars: maxChunkChars)
        let rebuilt = TextChunker.reassemble(
            correctedTexts: chunks.map(\.text),
            separators: chunks.map(\.separator)
        )
        #expect(rebuilt == text, "round-trip must be exact", sourceLocation: sourceLocation)
    }

    @Test func shortTextIsOneChunk() {
        let chunks = TextChunker.chunks(from: "Just a sentence.", maxChunkChars: 1000)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "Just a sentence.")
        #expect(chunks[0].separator == "")
    }

    @Test func splitsOnParagraphsAndRoundTripsExactly() {
        let text = "First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here."
        let chunks = TextChunker.chunks(from: text, maxChunkChars: 25)
        #expect(chunks.count == 3)
        assertRoundTrips(text, maxChunkChars: 25)
    }

    @Test func preservesUnusualSeparators() {
        let text = "One.\n\n\n\nTwo.\n \nThree.\n\n  \n  Four."
        assertRoundTrips(text, maxChunkChars: 4)
        assertRoundTrips(text, maxChunkChars: 8)
    }

    @Test func splitsALongParagraphIntoSentences() {
        let text = "This is one. This is two! Is this three? Yes it is four. And a fifth one here."
        let chunks = TextChunker.chunks(from: text, maxChunkChars: 20)
        #expect(chunks.count > 1)
        for chunk in chunks where chunk.text.count > 20 {
            // Only an unsplittable single sentence may exceed the limit.
            #expect(!chunk.text.contains(". "))
        }
        assertRoundTrips(text, maxChunkChars: 20)
    }

    @Test func neverCutsAWordWhenSplittingAnOverlongSentence() {
        let text = "supercalifragilistic expialidocious antidisestablishmentarianism pneumonoultramicroscopicsilicovolcanoconiosis floccinaucinihilipilification"
        let chunks = TextChunker.chunks(from: text, maxChunkChars: 20)
        // Each chunk is a whole run of words; no word is split across chunks.
        let rejoined = chunks.map(\.text).joined(separator: " ")
        #expect(rejoined.split(separator: " ").count == text.split(separator: " ").count)
        assertRoundTrips(text, maxChunkChars: 20)
    }

    @Test func handlesEmojiAndHebrewWithoutBreakingRoundTrip() {
        let text = "שלום עולם, מה שלומך היום? 😀\n\nThis is English 🎉🔥 and more.\n\nעוד פסקה בעברית עם emoji 👩‍👩‍👧‍👦 כאן."
        assertRoundTrips(text, maxChunkChars: 15)
        assertRoundTrips(text, maxChunkChars: 40)
    }

    @Test func aBigDocumentSplitsIntoManyBoundedChunks() {
        let paragraph = "This are a paragraph that has a few sentences in it. Some of them have mistakes. We will fix all of them soon. "
        let text = Array(repeating: paragraph, count: 60).joined(separator: "\n\n")
        let chunks = TextChunker.chunks(from: text, maxChunkChars: 500)
        #expect(chunks.count >= 10)
        for chunk in chunks {
            #expect(chunk.text.count <= 500 || !chunk.text.contains(". "))
        }
        assertRoundTrips(text, maxChunkChars: 500)
    }

    @Test func needsChunkingRespectsTheThreshold() {
        #expect(!TextChunker.needsChunking("short", limit: 1000))
        #expect(TextChunker.needsChunking(String(repeating: "a", count: 1001), limit: 1000))
    }

    @Test(arguments: [7, 13, 50, 200, 999])
    func roundTripsForManyLimits(limit: Int) {
        let text = """
        Dear team, i wanted to share a quick update on the project.

        We has made good progress this week. The api is now working, and the
        tests are passing. There is still a few bugs to fix.

        Also - dont forget the meeting tommorow at 3pm.

        Thanks,
        me
        """
        assertRoundTrips(text, maxChunkChars: limit)
    }
}
