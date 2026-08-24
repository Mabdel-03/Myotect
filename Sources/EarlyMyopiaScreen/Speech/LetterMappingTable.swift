import Foundation

/// The outcome of trying to map a spoken transcript to a Sloan letter.
enum RecognitionOutcome: Equatable {
    /// A single, unambiguous Sloan letter.
    case letter(String)
    /// The transcript matched more than one distinct Sloan letter. Repeat the trial.
    case ambiguous
    /// Nothing usable was recognized. The payload says *why*, so the operator can tell
    /// "heard mumbling" from "heard nothing". Repeat the trial.
    case unrecognized(NonAnswerKind)
    /// The recognition service itself is broken (permissions, model, capture). Structural —
    /// repeating the letter cannot fix it, so never retry-loop this outcome; surface it and
    /// escalate to the clinician keypad instead.
    case serviceFailure(RecognitionServiceFailure)
}

/// Why a trial produced no usable answer. Ports the gold app's `isFiller` /
/// `isIgnorableNonAnswer` distinction so downstream handling can distinguish an engaged child
/// from a dead microphone.
enum NonAnswerKind: Equatable {
    /// No/near-no audio, or a silence-hallucination transcript ("thank you").
    case silence
    /// "um", "uh" — the child is engaged but hasn't answered yet.
    case filler
    /// Real speech that mapped to no Sloan letter.
    case unintelligible
}

/// A structural failure of the recognition service, as opposed to a trial that simply heard
/// nothing usable. These never resolve by repeating the same letter.
enum RecognitionServiceFailure: Equatable {
    case microphonePermissionDenied
    case modelUnavailable(String)
    case audioCaptureFailed(String)
}

/// Deterministic mapping from speech-recognition transcripts to Sloan letters.
///
/// Ported and trimmed from the sibling app's layered phonetic matcher
/// (`ETDRSViewController.phoneticMatch`), restricted to the Sloan set (`C D H K N O R S V Z`).
/// Kept as a compile-checked Swift table rather than bundled JSON so it stays in lockstep with
/// ``SloanLetter`` and is trivially unit testable.
enum LetterMappingTable {
    static let sloanSet: Set<String> = Set(SloanLetter.all)

    /// Phonetic spellings to Sloan letters. Only Sloan-set letters appear as values.
    /// Multiple spellings per letter are intentional (covers common ASR variants).
    static let phonetics: [String: String] = [
        // C
        "see": "C", "sea": "C", "cee": "C", "si": "C", "c": "C", "sie": "C", "ce": "C",
        // D
        "dee": "D", "di": "D", "d": "D", "de": "D", "dea": "D",
        // H
        "aitch": "H", "atch": "H", "aych": "H", "h": "H", "haitch": "H", "eitch": "H",
        "ache": "H", "hatch": "H", "each": "H",
        // K
        "kay": "K", "key": "K", "k": "K", "kei": "K", "cay": "K", "kai": "K", "que": "K",
        // N
        "en": "N", "enn": "N", "n": "N", "ne": "N", "ene": "N",
        // O
        "oh": "O", "o": "O", "owe": "O", "ohh": "O",
        // R
        "are": "R", "ar": "R", "arr": "R", "r": "R", "aar": "R", "aire": "R",
        // S ("yes" is deliberately NOT mapped: a conversational "yes" must never score as S,
        // and the gold table leaves it unmapped too)
        "ess": "S", "es": "S", "s": "S",
        // V
        "vee": "V", "vi": "V", "v": "V", "ve": "V", "vea": "V", "via": "V",
        // Z
        "zee": "Z", "zed": "Z", "zi": "Z", "z": "Z", "zea": "Z", "ze": "Z",
    ]

    /// Whisper whole-word hallucination corrections (gold misidentificationMap, restricted to
    /// Sloan-10 targets). Checked AFTER `phonetics`, so a genuine phonetic spelling always wins.
    static let misidentifications: [String: String] = [
        // K
        "okay": "K",
        // N
        "an": "N", "and": "N", "in": "N", "nand": "N",
        // R
        "our": "R", "or": "R",
        // V
        "vie": "V",
    ]

    /// Normalizes a raw transcript: lowercased, with every non-letter run replaced by a single
    /// space (gold `cleanedTranscriptToken`: `[^A-Z]+` → " "). Replacing with a space rather than
    /// deleting keeps punctuation-joined words apart — "C-D" must become the two tokens "c d"
    /// (an answer plus a correction), never the unmappable "cd"; "[BLANK_AUDIO]" must become
    /// "blank audio" (a known silence marker), never "blankaudio".
    static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "[^a-z]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Maps a single normalized token to a Sloan letter, or nil if none.
    static func letter(forTranscript raw: String) -> String? {
        let text = normalize(raw)
        guard !text.isEmpty else { return nil }

        // Exact phonetic match.
        if let letter = phonetics[text] { return letter }

        // Whisper hallucination correction ("okay" -> K). After phonetics so a genuine
        // phonetic spelling always wins.
        if let letter = misidentifications[text] { return letter }

        // Single alphabetic character that is itself a Sloan letter (e.g. "k").
        if text.count == 1, let ch = text.first, ch.isLetter {
            let upper = text.uppercased()
            if sloanSet.contains(upper) { return upper }
        }

        // Repeated single letter ("rrr" -> "R").
        let uniqueLetters = Set(text.filter { $0.isLetter })
        if uniqueLetters.count == 1, let only = uniqueLetters.first {
            let upper = String(only).uppercased()
            if sloanSet.contains(upper) { return upper }
        }

        return nil
    }

    /// Classifies a transcript that may contain one or more words. If distinct Sloan letters are
    /// detected, returns `.ambiguous`; a single letter returns `.letter`; otherwise `.unrecognized`
    /// (`.silence` for blank text, `.unintelligible` for speech that mapped to no letter).
    static func classify(_ raw: String) -> RecognitionOutcome {
        let text = normalize(raw)
        guard !text.isEmpty else { return .unrecognized(.silence) }

        // Whole-transcript match first (handles single-token answers cleanly).
        if let single = letter(forTranscript: text) {
            return .letter(single)
        }

        // Otherwise scan tokens and collect distinct Sloan letters.
        let tokens = text.split(whereSeparator: { $0 == " " }).map(String.init)
        var found = Set<String>()
        for token in tokens {
            if let letter = letter(forTranscript: token) {
                found.insert(letter)
            }
        }

        switch found.count {
        case 0: return .unrecognized(.unintelligible)
        case 1: return .letter(found.first!)
        default: return .ambiguous
        }
    }
}
