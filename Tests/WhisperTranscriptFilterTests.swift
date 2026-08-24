import XCTest
@testable import Myotect

/// Verifies the Whisper-specific pre-filter that sits in front of ``LetterMappingTable`` in
/// ``WhisperKitLetterRecognitionService``. It must reject filler and Whisper's silence
/// hallucinations — reporting WHICH kind, so the operator can tell "heard mumbling" from
/// "heard nothing" — while leaving real letter answers to fall through to the mapper.
final class WhisperTranscriptFilterTests: XCTestCase {
    func testFillerKind() {
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("um"), .filler)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("uh"), .filler)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("hmm"), .filler)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("wait"), .filler)
        // Case/punctuation-insensitive, and all-filler token runs stay filler.
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("UM."), .filler)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("uh um"), .filler)
    }

    func testSilenceKindForHallucinations() {
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("you"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("Thank you"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("Thanks for watching!"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("  You?  "), .silence)
    }

    func testSilenceKindForSilenceMarkers() {
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("blank"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("blank audio"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("[silence]"), .silence)
    }

    func testSilenceKindForBracketedWhisperMarkers() {
        // Whisper's classic bracketed markers: underscores/brackets normalize to spaced tokens,
        // and the compact forms are covered too (gold-standard behavior). Missing these
        // misreported true silence as "heard mumbling" to the operator.
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("[BLANK_AUDIO]"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("BLANK_AUDIO"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("(blank audio)"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("[SILENT_AUDIO]"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("blankaudio"), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("silentaudio"), .silence)
    }

    func testSilenceKindForEmptyAndWhitespace() {
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind(""), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("   "), .silence)
        XCTAssertEqual(WhisperTranscriptFilter.nonAnswerKind("."), .silence)
    }

    func testRealAnswerCandidatesReturnNil() {
        // Real answers — phonetic spellings AND misidentification keys — must NOT be filtered:
        // classification is the mapper's job.
        for phrase in ["see", "C", "aitch", "zed", "oh", "okay", "and", "or", "our", "in", "vie"] {
            XCTAssertNil(WhisperTranscriptFilter.nonAnswerKind(phrase),
                         "\"\(phrase)\" must reach the letter mapper")
        }
    }

    func testHesitationPrefixedAnswersReachTheMapper() {
        // A hesitant child's "filler + letter" must never be swallowed as filler: the compact
        // form of "er r" is "err" and of "uh h" is "uhh" — checking the compact form against
        // the FILLER set (unlike gold) would discard these correct answers. The filter must
        // pass them through, and the mapper must then resolve the letter.
        for (phrase, letter) in [("Er, R", "R"), ("Uh, H", "H"), ("Ah... H", "H"), ("Eh, H", "H")] {
            XCTAssertNil(WhisperTranscriptFilter.nonAnswerKind(phrase),
                         "\"\(phrase)\" must reach the letter mapper")
            XCTAssertEqual(LetterMappingTable.classify(phrase), .letter(letter),
                           "\"\(phrase)\" must resolve to \(letter)")
        }
    }

    func testDeprecatedIsNonAnswerShimAgrees() {
        // The boolean shim stays until every caller migrates to nonAnswerKind.
        XCTAssertTrue(WhisperTranscriptFilter.isNonAnswer("um"))
        XCTAssertTrue(WhisperTranscriptFilter.isNonAnswer("thank you"))
        XCTAssertFalse(WhisperTranscriptFilter.isNonAnswer("see"))
    }

    func testRejectedPhrasesNeverCollideWithLetterTables() {
        // Guardrail: no rejected phrase may resolve to a Sloan letter through ANY layer
        // (phonetics, misidentifications, or the single/repeated-letter fallbacks), or we'd
        // drop real answers — and no letter table may resurrect a rejected phrase. This
        // permanently protects the "YOU" -> U fix: "you" stays a silence hallucination.
        let rejected = WhisperTranscriptFilter.fillerExact.union(WhisperTranscriptFilter.nonAnswerExact)
        for phrase in rejected {
            XCTAssertNil(LetterMappingTable.letter(forTranscript: phrase),
                         "Rejected phrase \"\(phrase)\" also maps to a Sloan letter")
            XCTAssertNil(LetterMappingTable.phonetics[phrase],
                         "Rejected phrase \"\(phrase)\" is a phonetics key")
            XCTAssertNil(LetterMappingTable.misidentifications[phrase],
                         "Rejected phrase \"\(phrase)\" is a misidentifications key")
        }
        // A misidentification key may only shadow a phonetics key with the SAME letter value,
        // because phonetics wins the lookup.
        for (key, letter) in LetterMappingTable.misidentifications {
            if let phonetic = LetterMappingTable.phonetics[key] {
                XCTAssertEqual(phonetic, letter,
                               "\"\(key)\" maps to \(phonetic) via phonetics but \(letter) via misidentifications")
            }
        }
    }
}
