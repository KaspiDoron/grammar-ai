import Testing
@testable import GrammarAICore

@Suite("ResponseValidator - parsing")
struct ResponseValidatorParsingTests {

    @Test func parsesPlainJSON() throws {
        let result = try ResponseValidator.parse(rawResponse: #"{"corrected_text":"Hi.","changed":true,"language":"en"}"#)
        #expect(result == CorrectionResult(correctedText: "Hi.", changed: true, language: "en"))
    }

    @Test func toleratesMarkdownFence() throws {
        let raw = "```json\n{\"corrected_text\": \"Hi.\", \"changed\": true}\n```"
        #expect(try ResponseValidator.parse(rawResponse: raw).correctedText == "Hi.")
    }

    @Test func toleratesProseAroundTheObject() throws {
        let raw = "Here you go:\n{\"corrected_text\": \"Hi.\", \"changed\": true}\nHope that helps!"
        #expect(try ResponseValidator.parse(rawResponse: raw).correctedText == "Hi.")
    }

    @Test func missingChangedDefaultsToTrue() throws {
        #expect(try ResponseValidator.parse(rawResponse: #"{"corrected_text":"Hi."}"#).changed)
    }

    @Test func emptyLanguageBecomesNil() throws {
        #expect(try ResponseValidator.parse(rawResponse: #"{"corrected_text":"Hi.","language":""}"#).language == nil)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func blankReplyIsEmptyResponse(raw: String) {
        #expect(throws: CorrectionError.emptyResponse) { try ResponseValidator.parse(rawResponse: raw) }
    }

    @Test(arguments: [
        "I fixed your text: Hello there.",
        #"{"text":"wrong key"}"#,
        #"{"corrected_text": 42}"#,
        #"["corrected_text"]"#,
        "{not json}"
    ])
    func anythingElseIsInvalid(raw: String) {
        #expect(throws: CorrectionError.invalidResponse) { try ResponseValidator.parse(rawResponse: raw) }
    }

    @Test func keepsBracesInsideTheText() throws {
        let raw = #"{"corrected_text":"Use {name} as the placeholder.","changed":true}"#
        #expect(try ResponseValidator.parse(rawResponse: raw).correctedText == "Use {name} as the placeholder.")
    }
}

@Suite("ResponseValidator - validation")
struct ResponseValidatorValidationTests {

    private func validate(_ corrected: String, original: String) throws -> CorrectionResult {
        try ResponseValidator.validate(CorrectionResult(correctedText: corrected, changed: true), against: original)
    }

    @Test func acceptsAnOrdinaryCorrection() throws {
        let result = try validate("I don't think this is working properly.", original: "i dont think this is working properly")
        #expect(result.correctedText == "I don't think this is working properly.")
        #expect(result.changed)
    }

    @Test(arguments: ["", "   ", "\n"])
    func emptyCorrectionIsRejected(corrected: String) {
        #expect(throws: CorrectionError.emptyResponse) { try validate(corrected, original: "some text") }
    }

    @Test func anEssayIsRejected() {
        let essay = String(repeating: "This sentence explains the grammar rules in depth. ", count: 12)
        #expect(throws: CorrectionError.invalidResponse) { try validate(essay, original: "i has a apple") }
    }

    @Test func aTruncationIsRejected() {
        let original = String(repeating: "this are a long paragraph with many word in it. ", count: 10)
        #expect(throws: CorrectionError.invalidResponse) { try validate("This is", original: original) }
    }

    @Test func shortTextMayGrow() throws {
        #expect(try validate("you", original: "u").correctedText == "you")
    }

    @Test func preservesOuterWhitespaceOfTheSelection() throws {
        let result = try validate("Hello there.", original: "  helo there \n")
        #expect(result.correctedText == "  Hello there. \n")
    }

    @Test func identicalTextIsReportedUnchangedEvenIfTheModelSaysChanged() throws {
        #expect(try validate("All good.", original: "All good.").changed == false)
    }

    @Test func stripsQuotesTheModelAdded() throws {
        #expect(try validate("\"Hello there.\"", original: "helo there").correctedText == "Hello there.")
    }

    @Test func keepsQuotesTheUserWrote() throws {
        #expect(try validate("\"Hello there.\"", original: "\"helo there\"").correctedText == "\"Hello there.\"")
    }

    @Test func stripsLeakedDataTags() throws {
        let leaked = "<text_to_correct>\nHello there.\n</text_to_correct>"
        #expect(try validate(leaked, original: "helo there").correctedText == "Hello there.")
    }

    @Test func stripsACodeFenceTheModelAdded() throws {
        #expect(try validate("```\nHello there.\n```", original: "helo there").correctedText == "Hello there.")
    }

    @Test func keepsEmojiAndUnicodeIntact() throws {
        let corrected = "That's great 🎉🔥 - see you at the café, naïve me 👩‍👩‍👧‍👦"
        #expect(try validate(corrected, original: "thats great 🎉🔥 - see u at the café, naïve me 👩‍👩‍👧‍👦").correctedText == corrected)
    }

    @Test func acceptsHebrewAndMixedLanguage() throws {
        #expect(try validate("אני רוצה ללכת לחנות מחר.", original: "אני רוצה ללכת לחנות מחר").changed)
        let mixed = "אני צריך לעשות deploy ל-production היום."
        #expect(try validate(mixed, original: "אני צריך לעשות deploy ל production היום").correctedText == mixed)
    }
}
