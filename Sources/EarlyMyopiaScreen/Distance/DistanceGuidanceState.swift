import Foundation

/// Distance guidance shown to the subject as a capsule pill during lock and trial phases.
///
/// Pure UI state: the coordinator owns every transition (including auto-dismissing `.ok` after
/// `guidanceOKDismissSeconds`); the pill view just renders whichever case is published.
enum DistanceGuidanceState: Equatable {
    /// No pill — in band with nothing to say.
    case hidden
    /// Red warning pill with a specific message (tracking lost, session interrupted, backgrounded).
    case warning(message: String)
    /// Green confirmation pill, shown briefly after a distance pause resolves.
    case ok
    /// "TOO FAR / Move closer to continue" pill.
    case moveCloser
    /// "TOO CLOSE / Move farther away" pill.
    case moveFarther
    /// "Hold still" pill while the dwell re-lock is confirming stability.
    case holdSteady
}
