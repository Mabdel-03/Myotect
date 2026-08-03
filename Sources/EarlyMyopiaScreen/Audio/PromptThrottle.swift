import Foundation

/// Repeat-throttle for guidance prompts: a prompt different from the last one speaks
/// immediately; the same prompt repeats only after `minInterval`. Lives with the caller (the
/// coordinator), matching the gold-standard placement. Pure and clock-injected for tests.
struct PromptThrottle: Equatable {
    var minInterval: TimeInterval = 5

    private var lastPrompt: SpokenPrompt?
    private var lastSpokenAt: Date = .distantPast

    init(minInterval: TimeInterval = 5) {
        self.minInterval = minInterval
    }

    /// True (and records the prompt) when it should be spoken now.
    mutating func shouldSpeak(_ prompt: SpokenPrompt, now: Date = Date()) -> Bool {
        guard prompt != lastPrompt || now.timeIntervalSince(lastSpokenAt) >= minInterval else {
            return false
        }
        lastPrompt = prompt
        lastSpokenAt = now
        return true
    }

    mutating func reset() {
        lastPrompt = nil
        lastSpokenAt = .distantPast
    }
}
