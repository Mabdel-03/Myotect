import XCTest
@testable import Myotect

final class LetterMappingTableTests: XCTestCase {
    func testCommonPhonetics() {
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "see"), "C")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "oh"), "O")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "ess"), "S")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "are"), "R")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "aitch"), "H")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "vee"), "V")
    }

    func testCaseAndPunctuationInsensitive() {
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "  See.  "), "C")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "ZED"), "Z")
    }

    func testSingleLetterDirectMatch() {
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "k"), "K")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "n"), "N")
    }

    func testNonSloanReturnsNil() {
        // P and F are not in the Sloan set used here.
        XCTAssertNil(LetterMappingTable.letter(forTranscript: "pee"))
        XCTAssertNil(LetterMappingTable.letter(forTranscript: "eff"))
        XCTAssertNil(LetterMappingTable.letter(forTranscript: "banana"))
    }

    func testConversationalYesIsNotALetter() {
        // "yes" must never score as S (gold leaves it unmapped): a child agreeing with the
        // operator is not an answer.
        XCTAssertNil(LetterMappingTable.letter(forTranscript: "yes"))
        XCTAssertEqual(LetterMappingTable.classify("yes"), .unrecognized(.unintelligible))
    }

    func testNormalizationSpacesOutPunctuation() {
        // Non-letter runs become a single space (gold `[^A-Z]+ → " "`), so punctuation-joined
        // words stay separate tokens instead of fusing into unmappable blobs.
        XCTAssertEqual(LetterMappingTable.normalize("C-D"), "c d")
        XCTAssertEqual(LetterMappingTable.normalize("[BLANK_AUDIO]"), "blank audio")
        XCTAssertEqual(LetterMappingTable.normalize("  See.  "), "see")
    }

    func testPunctuationJoinedLettersClassifyAsAmbiguous() {
        // "C-D" is an answer plus a correction: two distinct letters → ambiguous → the trial
        // repeats. (Fusing to "cd" used to burn a retry as unintelligible.)
        XCTAssertEqual(LetterMappingTable.classify("C-D"), .ambiguous)
    }

    func testClassifySingleLetter() {
        XCTAssertEqual(LetterMappingTable.classify("see"), .letter("C"))
    }

    func testClassifyAmbiguousWhenMultipleDistinctLetters() {
        // "see oh" -> C and O -> ambiguous.
        XCTAssertEqual(LetterMappingTable.classify("see oh"), .ambiguous)
        // Misidentification corrections participate too: "see or" -> C and R -> ambiguous.
        XCTAssertEqual(LetterMappingTable.classify("see or"), .ambiguous)
    }

    func testClassifyUnrecognizedKinds() {
        // Blank text is silence; real-but-unmappable speech is unintelligible.
        XCTAssertEqual(LetterMappingTable.classify(""), .unrecognized(.silence))
        XCTAssertEqual(LetterMappingTable.classify("   "), .unrecognized(.silence))
        XCTAssertEqual(LetterMappingTable.classify("banana"), .unrecognized(.unintelligible))
        XCTAssertEqual(LetterMappingTable.classify("hello world"), .unrecognized(.unintelligible))
    }

    func testMisidentificationCorrections() {
        // Whisper whole-word hallucinations remapped to their Sloan targets (gold layer).
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "okay"), "K")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "an"), "N")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "and"), "N")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "in"), "N")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "nand"), "N")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "our"), "R")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "or"), "R")
        XCTAssertEqual(LetterMappingTable.letter(forTranscript: "vie"), "V")
        XCTAssertEqual(LetterMappingTable.classify("okay"), .letter("K"))
    }

    func testMisidentificationValuesAreSloanLetters() {
        for value in LetterMappingTable.misidentifications.values {
            XCTAssertTrue(LetterMappingTable.sloanSet.contains(value), "\(value) not in Sloan set")
        }
    }

    func testPhoneticsAndMisidentificationsAreDisjoint() {
        // `letter(forTranscript:)` checks phonetics BEFORE misidentifications, so a genuine
        // phonetic spelling always wins. No key currently exists in both tables, so that
        // precedence cannot be exercised end to end; this disjointness assertion keeps it that
        // way (a shared key would silently start relying on lookup order).
        let shared = Set(LetterMappingTable.phonetics.keys)
            .intersection(LetterMappingTable.misidentifications.keys)
        XCTAssertTrue(shared.isEmpty, "Keys in both phonetics and misidentifications: \(shared)")
    }

    func testAllValuesAreSloanLetters() {
        for value in LetterMappingTable.phonetics.values {
            XCTAssertTrue(LetterMappingTable.sloanSet.contains(value), "\(value) not in Sloan set")
        }
    }

    // MARK: - Spoken skip

    func testClassifySkipAndWhisperVariants() {
        for phrase in ["skip", "Skip.", "SKIP!", "  skip  ", "skipped", "skips", "skipping", "skype"] {
            XCTAssertEqual(LetterMappingTable.classify(phrase), .skipped, "\"\(phrase)\"")
        }
        for phrase in LetterMappingTable.skipPhrases {
            XCTAssertEqual(LetterMappingTable.classify(phrase), .skipped, "\"\(phrase)\"")
        }
    }

    func testClassifySkipWithFillerOrTailIsSkip() {
        // A hesitation before, or a tail after, must not hide the skip — and a hallucinated
        // "thank you" tail is not a letter either.
        for phrase in ["um skip", "Uh, skip.", "skip it", "skip this one", "please skip",
                       "skip thank you"] {
            XCTAssertEqual(LetterMappingTable.classify(phrase), .skipped, "\"\(phrase)\"")
        }
    }

    func testClassifySkipMixedWithLetterIsAmbiguous() {
        // A skip beside a letter is a mixed utterance: retry rather than guess. "okay skip" is
        // the known cost — "okay" is a K correction — pinned here so nobody "fixes" it blind.
        for phrase in ["c skip", "skip see", "okay skip", "S, skip"] {
            XCTAssertEqual(LetterMappingTable.classify(phrase), .ambiguous, "\"\(phrase)\"")
        }
    }

    func testTierTwoSkipVariantsAreNotSkips() {
        // "ski" / "kip" / "skit" / "skid" / "skiff" are deliberately excluded: Whisper can fuse
        // an "S… K" self-correction into such a word, and a false skip is a scored miss whereas
        // a missed skip is only a retry. "S K" itself must stay ambiguous (a correction).
        for phrase in ["ski", "kip", "skit", "skid", "skiff"] {
            XCTAssertEqual(LetterMappingTable.classify(phrase), .unrecognized(.unintelligible),
                           "\"\(phrase)\"")
        }
        XCTAssertEqual(LetterMappingTable.classify("S K"), .ambiguous)
    }

    func testSkipPhrasesNeverCollideWithLetterTables() {
        // Guardrail (mirror of the filter's): no skip phrase may resolve to a Sloan letter
        // through ANY layer, or a real answer would be scored as a skipped miss.
        for phrase in LetterMappingTable.skipPhrases {
            XCTAssertEqual(phrase, LetterMappingTable.normalize(phrase),
                           "\"\(phrase)\" must be stored pre-normalized")
            XCTAssertNil(LetterMappingTable.letter(forTranscript: phrase),
                         "Skip phrase \"\(phrase)\" also maps to a Sloan letter")
            XCTAssertNil(LetterMappingTable.phonetics[phrase],
                         "Skip phrase \"\(phrase)\" is a phonetics key")
            XCTAssertNil(LetterMappingTable.misidentifications[phrase],
                         "Skip phrase \"\(phrase)\" is a misidentifications key")
            XCTAssertFalse(LetterMappingTable.sloanSet.contains(phrase.uppercased()))
        }
    }
}
