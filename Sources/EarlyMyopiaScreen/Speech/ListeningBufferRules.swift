import Foundation

/// Pure bookkeeping for the live listening buffer, kept off the WhisperKit service so every
/// decision about WHEN audio is transcribed and WHAT the trace says is unit-testable without a
/// microphone. Ported from the sibling ETDRS app's `ETDRSListeningBufferRules` (the design that
/// is robust on device), plus Myotect's additions: the carried-over-voice rule, the flush span,
/// and the soft-deadline predicate.
///
/// Everything works on a per-100 ms "block" trace of the 16 kHz sample stream. Block `i` of a
/// trace covers samples `[i * energyBlockSamples, (i + 1) * energyBlockSamples)` of the slice the
/// trace was computed from.
enum ListeningBufferRules {
    /// WhisperKit's capture rate; every index in this file is a 16 kHz sample index.
    static let sampleRate = 16_000
    /// 100 ms of 16 kHz audio — the granularity of the voice-activity trace.
    static let energyBlockSamples = 1600
    /// How many previous blocks (2 s) the silence reference is taken from.
    static let referenceWindowBlocks = 20
    /// A "speech-length sound" is this many CONSECUTIVE voice blocks: a spoken letter spans
    /// several; a click or a chair creak does not. This is the definition of a sound, not a
    /// tuning knob, so it is a constant rather than a `ScreenConfig` key.
    static let speechLengthBlocks = 2

    // MARK: - Energies

    /// RMS energy (0…1) of one slice — the incremental store calls this once per completed block.
    static func blockEnergy(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        samples.withUnsafeBufferPointer { pointer in
            for value in pointer {
                sum += value * value
            }
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Per-block RMS energy (0…1); the trailing partial block is dropped. Block boundaries follow
    /// the slice, not the parent array.
    static func blockEnergies(_ samples: ArraySlice<Float>) -> [Float] {
        let blockCount = samples.count / energyBlockSamples
        guard blockCount > 0 else { return [] }
        var energies: [Float] = []
        energies.reserveCapacity(blockCount)
        let base = samples.startIndex
        for block in 0..<blockCount {
            let start = base + block * energyBlockSamples
            energies.append(blockEnergy(samples[start..<(start + energyBlockSamples)]))
        }
        return energies
    }

    /// WhisperKit's normalization — each block in dB relative to the quietest of the previous
    /// `referenceWindow` blocks, rescaled so the reference is 0 and full scale is 1 — with two
    /// guards: a block with no valid reference (the first block, or nothing but near-silence
    /// behind it) is 0, and blocks below `minimumReference` (-80 dBFS; real room floors sit well
    /// above it) are never used as the reference, because a zero or ramp-in buffer at engine
    /// start-up would otherwise make room noise read as voice for a whole window.
    static func relativeEnergies(
        blockEnergies: [Float],
        referenceWindow: Int = referenceWindowBlocks,
        minimumReference: Float = 1e-4
    ) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(blockEnergies.count)
        for (index, energy) in blockEnergies.enumerated() {
            let windowStart = max(0, index - referenceWindow)
            let reference = blockEnergies[windowStart..<index].filter { $0 >= minimumReference }.min()
            guard let reference, energy > 0 else {
                result.append(0)
                continue
            }
            let dbReference = 20 * log10(reference)
            guard dbReference < 0 else {
                result.append(0)
                continue
            }
            let dbEnergy = 20 * log10(energy)
            let normalized = (dbEnergy - dbReference) / (0 - dbReference)
            result.append(max(0, min(normalized, 1)))
        }
        return result
    }

    static func voiceBlocks(relativeEnergies: [Float], silenceThreshold: Float) -> [Bool] {
        relativeEnergies.map { $0 > silenceThreshold }
    }

    /// Zeroes the energy of the block an engine (re)start landed in and the `blocks − 1` after
    /// it. AVAudioEngine's first buffers can be digital zero or a ramp-in; a block that is mostly
    /// zeros with a sliver of room noise reads far below the real floor, would become the silence
    /// reference for the next 2 s, and would make ordinary room noise read as voice. A zero block
    /// is neither a reference (below `minimumReference`) nor voice (`energy > 0`). `energies[0]`
    /// is absolute block `firstAbsoluteBlock`; a start outside the slice changes nothing.
    static func maskingEngineStart(energies: [Float], firstAbsoluteBlock: Int,
                                   engineStartBlock: Int, blocks: Int = 2) -> [Float] {
        let lower = engineStartBlock - firstAbsoluteBlock
        let upper = lower + max(0, blocks)
        guard upper > 0, lower < energies.count else { return energies }
        var masked = energies
        for index in max(0, lower)..<min(energies.count, upper) {
            masked[index] = 0
        }
        return masked
    }

    // MARK: - Live passes

    /// Whether a live pass should transcribe now: voice somewhere in the unconsumed span, and
    /// either the utterance has ended (the newest `quietTailBlocks` are quiet) or voice has been
    /// continuous for `maximumUtteranceBlocks` — a long answer, or a noisy room, is transcribed
    /// anyway rather than waiting forever for a quiet tail. Transcribing on the first syllable
    /// hands Whisper a truncated clip, which it completes into a non-letter word.
    static func shouldRunLivePass(
        voice: [Bool],
        unconsumedFromBlock: Int,
        quietTailBlocks: Int,
        maximumUtteranceBlocks: Int
    ) -> Bool {
        let from = max(0, min(unconsumedFromBlock, voice.count))
        guard let firstVoice = voice[from...].firstIndex(of: true) else { return false }
        let stillSpeaking = voice.suffix(max(1, quietTailBlocks)).contains(true)
        if !stillSpeaking { return true }
        return voice.count - firstVoice >= max(1, maximumUtteranceBlocks)
    }

    /// Where the consumed pointer moves after a pass. A pass that produced an answer, and the
    /// final flush, consume everything they saw. Any other live pass consumes all but the newest
    /// `retainedSamples`, so an utterance straddling the pass boundary keeps its onset (and a
    /// hallucinated "Thank you." can never swallow the child's audio). Never moves backwards.
    static func consumedSampleCount(
        current: Int,
        bufferCount: Int,
        isFinal: Bool,
        producedAnswer: Bool,
        retainedSamples: Int
    ) -> Int {
        if isFinal || producedAnswer {
            return max(current, bufferCount)
        }
        return max(current, bufferCount - max(0, retainedSamples))
    }

    /// Where a live transcription window starts: the last rolling window past the consumed
    /// pointer. The final flush hands Whisper the `flushSpan` instead.
    static func windowStart(isFinal: Bool, consumed: Int, bufferCount: Int,
                            maxWindowSamples: Int) -> Int {
        let consumed = max(0, min(consumed, bufferCount))
        return isFinal ? consumed : max(consumed, bufferCount - maxWindowSamples)
    }

    // MARK: - The trace as evidence

    /// Whether a trace holds a speech-length sound (`speechLengthBlocks` consecutive voice blocks).
    static func windowHadVoice(voice: [Bool]) -> Bool {
        !speechRuns(voice: voice, from: 0).isEmpty
    }

    /// Whether the newest `quietTailBlocks` of a trace read as voice — an utterance in progress.
    static func tailHasVoice(voice: [Bool], quietTailBlocks: Int) -> Bool {
        voice.suffix(max(1, quietTailBlocks)).contains(true)
    }

    /// Maximal runs of at least `speechLengthBlocks` consecutive voice blocks at or after `from`,
    /// as block ranges of `voice`. Isolated single voice blocks (clicks) are not runs.
    static func speechRuns(voice: [Bool], from: Int) -> [Range<Int>] {
        let start = max(0, min(from, voice.count))
        var runs: [Range<Int>] = []
        var runStart: Int?
        for index in start..<voice.count {
            if voice[index] {
                if runStart == nil { runStart = index }
            } else if let began = runStart {
                if index - began >= speechLengthBlocks { runs.append(began..<index) }
                runStart = nil
            }
        }
        if let began = runStart, voice.count - began >= speechLengthBlocks {
            runs.append(began..<voice.count)
        }
        return runs
    }

    /// The block span the final flush hands Whisper: from `padBlocks` before the first
    /// speech-length run in the unconsumed span to `padBlocks` after the last, clamped to the
    /// trace. Nil when the unconsumed span holds no speech-length sound — then Whisper is not
    /// called at all (5–10 s of room noise is exactly what it hallucinates text over). Isolated
    /// single voice blocks never widen the span.
    static func flushSpan(voice: [Bool], unconsumedFromBlock: Int, padBlocks: Int) -> Range<Int>? {
        let from = max(0, min(unconsumedFromBlock, voice.count))
        let runs = speechRuns(voice: voice, from: from)
        guard let first = runs.first, let last = runs.last else { return nil }
        let lower = max(from, first.lowerBound - max(0, padBlocks))
        let upper = min(voice.count, last.upperBound + max(0, padBlocks))
        guard lower < upper else { return nil }
        return lower..<upper
    }

    // MARK: - Myotect additions

    /// How many session blocks belong to a sound that was ALREADY under way when the session
    /// started (the tail of the previous letter's answer, a self-correction during the blank).
    /// The session start is minted in the same run-loop turn as the letter reveal and floored to
    /// the block boundary, so voice in the session's first block began before the child could
    /// have seen the letter — a human cannot react inside 100 ms — and is never an answer.
    ///
    /// Returns the length of the leading all-voice prefix, capped at `maximumBlocks` (a sound
    /// continuous for the whole cap is room noise, not the tail of an answer — stop skipping so
    /// a noisy room cannot starve the trial). Zero when the session started in silence. Stateless
    /// and monotone as the trace grows, so it can be recomputed on every pass. The mirror image
    /// of the ETDRS app's pre-roll, which reaches BACK to keep an onset because that app arms
    /// after the letter is drawn. Callers apply it only while audio is continuous across the
    /// session start (a fresh engine has no "before").
    static func carriedOverBlocks(sessionVoice: [Bool], maximumBlocks: Int) -> Int {
        guard sessionVoice.first == true else { return 0 }
        let prefix = sessionVoice.prefix(while: { $0 }).count
        return min(max(0, maximumBlocks), prefix)
    }

    /// Whether the (soft) no-input deadline should be pushed back by one more `stepSeconds`:
    /// while the newest audio is voice or a transcription is in flight, and the total deferral
    /// stays within `capSeconds` — a television keeps the tail "voiced" forever, so the cap is
    /// what guarantees the window still ends.
    static func shouldDeferDeadline(
        tailHasVoice: Bool,
        inferenceInFlight: Bool,
        deferredSeconds: TimeInterval,
        stepSeconds: TimeInterval,
        capSeconds: TimeInterval
    ) -> Bool {
        guard tailHasVoice || inferenceInFlight else { return false }
        return deferredSeconds + stepSeconds <= capSeconds + 1e-9
    }
}
