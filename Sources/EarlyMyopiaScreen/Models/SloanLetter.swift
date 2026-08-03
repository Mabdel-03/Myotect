import Foundation

/// The Sloan optotype letter set used for the screening.
///
/// These are the standard 10 Sloan letters. The set is intentionally kept in one place so the
/// optotype generator, the speech mapping table, and the warm-up all draw from the same source.
/// The set is configurable via ``ScreenConfig`` if the speech-recognition work later identifies a
/// subset with less ASR overlap.
enum SloanLetter {
    /// Standard 10 Sloan letters.
    static let all: [String] = ["C", "D", "H", "K", "N", "O", "R", "S", "V", "Z"]

    /// Large warm-up letters are drawn from the same set.
    static func random(excluding previous: String? = nil) -> String {
        var candidates = all
        if let previous, candidates.count > 1 {
            candidates.removeAll { $0 == previous }
        }
        return candidates.randomElement() ?? all[0]
    }
}
