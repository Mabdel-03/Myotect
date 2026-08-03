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
}
