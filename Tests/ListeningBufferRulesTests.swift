import XCTest
@testable import Myotect

/// The pure listening-buffer rules behind `WhisperKitLetterRecognitionService`: WHEN audio is
/// transcribed, what the voice trace says, and how the deadline and the consumed pointer move.
/// Ported from the sibling ETDRS app's rule tests (the design that is robust on device) plus
/// Myotect's carried-over-voice, flush-span and soft-deadline rules. Each test names the device
/// failure it prevents.
final class ListeningBufferRulesTests: XCTestCase {
    private let block = ListeningBufferRules.energyBlockSamples

    // MARK: - Energies

    /* Block energies are plain RMS per 1600 samples; the trailing partial block is dropped so the
       trace never contains a half-filled value that would read as quieter than it is, and block
       boundaries follow the slice (the service passes slices that start mid-buffer).
     */
    func testBlockEnergiesAreRMSPerFullBlock() {
        var samples = [Float](repeating: 0, count: block * 2 + 100)
        for index in block..<(block * 2) {
            samples[index] = index % 2 == 0 ? 0.5 : -0.5
        }
        let energies = ListeningBufferRules.blockEnergies(samples[...])
        XCTAssertEqual(energies.count, 2)
        XCTAssertEqual(energies[0], 0)
        XCTAssertEqual(energies[1], 0.5, accuracy: 0.0001)

        let offset = ListeningBufferRules.blockEnergies(samples[block...])
        XCTAssertEqual(offset.count, 1)
        XCTAssertEqual(offset[0], 0.5, accuracy: 0.0001)
        XCTAssertTrue(ListeningBufferRules.blockEnergies([Float](repeating: 0.1, count: block - 1)[...]).isEmpty)
        XCTAssertEqual(ListeningBufferRules.blockEnergy(samples[block..<(block * 2)]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ListeningBufferRules.blockEnergy([Float]()[...]), 0)
    }

    /* The energies are WhisperKit's normalization (dB relative to the quietest of the previous
       2 s) without its two start-up artifacts: the first block has no reference and reads as
       silence rather than voice, and a digital-zero or ramp-in buffer — which AVAudioEngine can
       deliver as it starts — is never used as the reference, so ordinary room noise does not read
       as voice for the whole window that follows.
     */
    func testRelativeEnergiesIgnoreDigitalZeroReferencesAndStartQuiet() {
        let room: Float = 0.003
        let speech: Float = 0.05

        let plain = ListeningBufferRules.relativeEnergies(blockEnergies: [room, room, speech, room])
        XCTAssertEqual(plain[0], 0, "No reference yet.")
        XCTAssertEqual(plain[1], 0, accuracy: 0.001, "Same level as the reference.")
        XCTAssertGreaterThan(plain[2], 0.10, "Speech well above the room floor.")
        XCTAssertEqual(plain[3], 0, accuracy: 0.001)

        let zeroStart = ListeningBufferRules.relativeEnergies(blockEnergies: [0, room, room, speech])
        XCTAssertEqual(zeroStart[1], 0, "A digital-zero block is not a reference.")
        XCTAssertEqual(zeroStart[2], 0, accuracy: 0.001, "Room noise stays quiet after a zero block.")
        XCTAssertGreaterThan(zeroStart[3], 0.10)

        let rampIn = ListeningBufferRules.relativeEnergies(blockEnergies: [1e-5, room, room, speech])
        XCTAssertEqual(rampIn[1], 0, "A near-silent ramp-in block (below -80 dBFS) is not a reference either.")
        XCTAssertEqual(rampIn[2], 0, accuracy: 0.001)
        XCTAssertGreaterThan(rampIn[3], 0.10)

        XCTAssertEqual(ListeningBufferRules.relativeEnergies(blockEnergies: [0, 0, 0]), [0, 0, 0])
        XCTAssertTrue(ListeningBufferRules.relativeEnergies(blockEnergies: []).isEmpty)

        let voice = ListeningBufferRules.voiceBlocks(relativeEnergies: plain, silenceThreshold: 0.10)
        XCTAssertEqual(voice, [false, false, true, false])
    }

    // MARK: - Live passes

    /* The old service handed Whisper the first syllable of an answer (its voice check fired the
       moment speech began), and Whisper completed a truncated "C" into a word like "seat". A pass
       now waits for the utterance to END (a quiet 0.3 s tail after voice in the unconsumed span),
       transcribes a sound that stays continuous past the cap anyway, and never runs on silence.
     */
    func testLivePassWaitsForTheUtteranceToEnd() {
        let quietTail = 3
        let cap = 20
        let silence = Array(repeating: false, count: 10)
        XCTAssertFalse(ListeningBufferRules.shouldRunLivePass(
            voice: silence, unconsumedFromBlock: 0, quietTailBlocks: quietTail, maximumUtteranceBlocks: cap))

        let speaking = silence + [true, true, true]
        XCTAssertFalse(
            ListeningBufferRules.shouldRunLivePass(
                voice: speaking, unconsumedFromBlock: 0, quietTailBlocks: quietTail, maximumUtteranceBlocks: cap),
            "Mid-utterance: the newest blocks are still voice.")

        let ended = speaking + [false, false, false]
        XCTAssertTrue(ListeningBufferRules.shouldRunLivePass(
            voice: ended, unconsumedFromBlock: 0, quietTailBlocks: quietTail, maximumUtteranceBlocks: cap))

        XCTAssertFalse(
            ListeningBufferRules.shouldRunLivePass(
                voice: ended, unconsumedFromBlock: ended.count - 2, quietTailBlocks: quietTail, maximumUtteranceBlocks: cap),
            "Voice that an earlier pass already consumed does not trigger another.")

        let continuous = silence + Array(repeating: true, count: cap)
        XCTAssertTrue(
            ListeningBufferRules.shouldRunLivePass(
                voice: continuous, unconsumedFromBlock: 0, quietTailBlocks: quietTail, maximumUtteranceBlocks: cap),
            "A sound that never pauses is transcribed once it reaches the cap.")
        XCTAssertFalse(ListeningBufferRules.shouldRunLivePass(
            voice: silence + Array(repeating: true, count: cap - 1),
            unconsumedFromBlock: 0, quietTailBlocks: quietTail, maximumUtteranceBlocks: cap))

        // A pass that produced no answer retains exactly the quiet tail (3 blocks). The retained
        // region holds no voice, so it cannot re-trigger a pass on the fragment before it —
        // retaining more would, which is why the retained tail equals the quiet tail.
        let fragment = silence + [true, true, true, true, false, false, false]
        XCTAssertFalse(ListeningBufferRules.shouldRunLivePass(
            voice: fragment, unconsumedFromBlock: fragment.count - 3, quietTailBlocks: quietTail, maximumUtteranceBlocks: cap))
        XCTAssertTrue(
            ListeningBufferRules.shouldRunLivePass(
                voice: fragment, unconsumedFromBlock: fragment.count - 5, quietTailBlocks: quietTail, maximumUtteranceBlocks: cap),
            "A retained span longer than the quiet tail re-triggers on the fragment.")
    }

    /* The consumed pointer decides what the next live pass and the deadline flush get to hear.
       A pass that produced an answer, and the final flush, consume everything they saw; ANY other
       pass — filler, a hallucinated "Thank you.", a bare "." — leaves the newest retained span
       unconsumed so an utterance straddling the pass boundary keeps its onset (the old service
       let a hallucination swallow the child's audio, which is how a child who spoke ended as
       "no input registered"); and the pointer never moves backwards.
     */
    func testConsumedPointerAdvancesForAnswersAndFinalButRetainsATailAfterANonAnswerPass() {
        XCTAssertEqual(
            ListeningBufferRules.consumedSampleCount(
                current: 1_000, bufferCount: 48_000, isFinal: false, producedAnswer: true, retainedSamples: 4_800),
            48_000)
        XCTAssertEqual(
            ListeningBufferRules.consumedSampleCount(
                current: 1_000, bufferCount: 48_000, isFinal: true, producedAnswer: false, retainedSamples: 4_800),
            48_000)
        XCTAssertEqual(
            ListeningBufferRules.consumedSampleCount(
                current: 1_000, bufferCount: 48_000, isFinal: false, producedAnswer: false, retainedSamples: 4_800),
            43_200,
            "A non-answer live pass (\"Thank you.\", \".\", \"um\") keeps the newest retained span.")
        XCTAssertEqual(
            ListeningBufferRules.consumedSampleCount(
                current: 46_000, bufferCount: 48_000, isFinal: false, producedAnswer: false, retainedSamples: 4_800),
            46_000,
            "The pointer never moves backwards.")
        XCTAssertEqual(
            ListeningBufferRules.consumedSampleCount(
                current: 50_000, bufferCount: 48_000, isFinal: true, producedAnswer: true, retainedSamples: 4_800),
            50_000,
            "A stale, smaller snapshot cannot re-open consumed audio.")
        XCTAssertEqual(
            ListeningBufferRules.consumedSampleCount(
                current: 0, bufferCount: 2_000, isFinal: false, producedAnswer: false, retainedSamples: 4_800),
            0,
            "A buffer shorter than the retained span stays wholly unconsumed.")
    }

    func testLiveWindowIsTheLastRollingWindowPastTheConsumedPointer() {
        XCTAssertEqual(ListeningBufferRules.windowStart(
            isFinal: false, consumed: 0, bufferCount: 100_000, maxWindowSamples: 38_400), 61_600)
        XCTAssertEqual(ListeningBufferRules.windowStart(
            isFinal: false, consumed: 80_000, bufferCount: 100_000, maxWindowSamples: 38_400), 80_000)
        XCTAssertEqual(ListeningBufferRules.windowStart(
            isFinal: false, consumed: 0, bufferCount: 10_000, maxWindowSamples: 38_400), 0)
    }

    func testFinalWindowStartsAtTheConsumedPointer() {
        XCTAssertEqual(ListeningBufferRules.windowStart(
            isFinal: true, consumed: 0, bufferCount: 100_000, maxWindowSamples: 38_400), 0)
        XCTAssertEqual(ListeningBufferRules.windowStart(
            isFinal: true, consumed: 20_000, bufferCount: 100_000, maxWindowSamples: 38_400), 20_000)
        // Never past the end of the buffer, never negative.
        XCTAssertEqual(ListeningBufferRules.windowStart(
            isFinal: true, consumed: 120_000, bufferCount: 100_000, maxWindowSamples: 38_400), 100_000)
        XCTAssertEqual(ListeningBufferRules.windowStart(
            isFinal: true, consumed: -5, bufferCount: 100_000, maxWindowSamples: 38_400), 0)
    }

    // MARK: - The trace as evidence

    /* The deadline decides whether text may be scored, and whether a window was silent, by asking
       whether it held a speech-length sound: two consecutive voice blocks. A spoken letter spans
       several; a single click or chair creak does not.
     */
    func testWindowHadVoiceNeedsTwoConsecutiveVoiceBlocks() {
        XCTAssertFalse(ListeningBufferRules.windowHadVoice(voice: []))
        XCTAssertFalse(ListeningBufferRules.windowHadVoice(voice: [true]))
        XCTAssertFalse(ListeningBufferRules.windowHadVoice(voice: [false, true, false, true, false]))
        XCTAssertTrue(ListeningBufferRules.windowHadVoice(voice: [false, true, true, false]))
    }

    /* The soft deadline asks only whether the NEWEST blocks are voice — an utterance still in
       progress — never whether the window ever held voice.
     */
    func testTailHasVoiceLooksOnlyAtTheQuietTail() {
        XCTAssertTrue(ListeningBufferRules.tailHasVoice(voice: [false, false, true], quietTailBlocks: 3))
        XCTAssertTrue(ListeningBufferRules.tailHasVoice(voice: [true, false, false, true, false], quietTailBlocks: 3))
        XCTAssertFalse(ListeningBufferRules.tailHasVoice(voice: [true, true, false, false, false], quietTailBlocks: 3))
        XCTAssertFalse(ListeningBufferRules.tailHasVoice(voice: [], quietTailBlocks: 3))
        XCTAssertTrue(ListeningBufferRules.tailHasVoice(voice: [false, true], quietTailBlocks: 0),
                      "A zero tail still looks at the newest block.")
    }

    /* Runs are maximal stretches of at least two consecutive voice blocks; an isolated single
       voice block is a click, not speech, and never forms or extends a run.
     */
    func testSpeechRunsIgnoreIsolatedVoiceBlocks() {
        let voice = [true, false, true, true, false, false, true, true, true, false, true]
        XCTAssertEqual(ListeningBufferRules.speechRuns(voice: voice, from: 0), [2..<4, 6..<9])
        XCTAssertEqual(ListeningBufferRules.speechRuns(voice: voice, from: 3), [6..<9],
                       "A run cut to a single block by the consumed pointer is no longer a run.")
        XCTAssertEqual(ListeningBufferRules.speechRuns(voice: voice, from: 7), [7..<9],
                       "A run cut to two blocks is still a run from the pointer onward.")
        XCTAssertEqual(ListeningBufferRules.speechRuns(voice: [true, true], from: 0), [0..<2],
                       "A run touching the end of the trace still counts.")
        XCTAssertTrue(ListeningBufferRules.speechRuns(voice: voice, from: 20).isEmpty)
        XCTAssertTrue(ListeningBufferRules.speechRuns(voice: [], from: 0).isEmpty)
    }

    /* The final flush hands Whisper only the speech-length runs (plus padding), never the whole
       window: 10 s of room floor with one faint syllable is exactly what Whisper-base hallucinates
       text over, and with no speech-length run at all Whisper is not called. An isolated click
       before the answer must not widen the span back to it.
     */
    func testFlushSpanCoversOnlySpeechLengthRunsWithPaddingAndIsNilWithoutOne() {
        var voice = Array(repeating: false, count: 100)
        for index in 40..<45 { voice[index] = true }
        XCTAssertEqual(ListeningBufferRules.flushSpan(voice: voice, unconsumedFromBlock: 0, padBlocks: 3), 37..<48)

        voice[2] = true
        XCTAssertEqual(ListeningBufferRules.flushSpan(voice: voice, unconsumedFromBlock: 0, padBlocks: 3), 37..<48,
                       "An isolated click at 0.2 s does not widen the span.")

        XCTAssertNil(ListeningBufferRules.flushSpan(voice: voice, unconsumedFromBlock: 46, padBlocks: 3),
                     "Voice only before the consumed pointer is not re-heard.")
        XCTAssertEqual(ListeningBufferRules.flushSpan(voice: voice, unconsumedFromBlock: 42, padBlocks: 3), 42..<48,
                       "Padding never reaches back into consumed audio.")

        var single = Array(repeating: false, count: 30)
        single[10] = true
        XCTAssertNil(ListeningBufferRules.flushSpan(voice: single, unconsumedFromBlock: 0, padBlocks: 3))
        XCTAssertNil(ListeningBufferRules.flushSpan(voice: [], unconsumedFromBlock: 0, padBlocks: 3))

        var tail = Array(repeating: false, count: 10)
        tail[8] = true
        tail[9] = true
        XCTAssertEqual(ListeningBufferRules.flushSpan(voice: tail, unconsumedFromBlock: 0, padBlocks: 5), 3..<10,
                       "A run touching the end is clamped to the trace.")
    }

    // MARK: - Myotect additions

    /* The session starts in the same run-loop turn as the letter reveal, so voice in the
       session's first block began before the child could see the letter: the tail of the
       previous answer, or a self-correction during the blank — the reported "bleed". It is
       skipped up to the cap; a session that starts in silence skips nothing.
     */
    func testCarriedOverVoiceIsSkippedOnlyWhenTheSessionStartsInsideARun() {
        XCTAssertEqual(ListeningBufferRules.carriedOverBlocks(
            sessionVoice: [true, true, false, true], maximumBlocks: 20), 2)
        XCTAssertEqual(ListeningBufferRules.carriedOverBlocks(
            sessionVoice: [false, true, true], maximumBlocks: 20), 0, "Started in silence: nothing is skipped.")
        XCTAssertEqual(ListeningBufferRules.carriedOverBlocks(sessionVoice: [], maximumBlocks: 20), 0)
        XCTAssertEqual(ListeningBufferRules.carriedOverBlocks(
            sessionVoice: Array(repeating: true, count: 30), maximumBlocks: 20), 20,
            "A sound continuous for the whole cap is room noise; stop skipping so the trial is not starved.")
        XCTAssertEqual(ListeningBufferRules.carriedOverBlocks(
            sessionVoice: [true, true], maximumBlocks: 0), 0)
        XCTAssertEqual(ListeningBufferRules.carriedOverBlocks(
            sessionVoice: Array(repeating: true, count: 20), maximumBlocks: 20), 20,
            "Exactly at the cap the whole prefix is skipped.")
    }

    /* The rule is recomputed on every pass while the trace grows; it must only ever grow (the
       consumed pointer it drives never moves backwards) and freeze once a quiet block ends the run.
     */
    func testCarriedOverBlocksGrowMonotonicallyAsTheRunGrows() {
        var trace: [Bool] = []
        var previous = 0
        for isVoice in [true, true, true, false, true, true] {
            trace.append(isVoice)
            let carried = ListeningBufferRules.carriedOverBlocks(sessionVoice: trace, maximumBlocks: 20)
            XCTAssertGreaterThanOrEqual(carried, previous)
            previous = carried
        }
        XCTAssertEqual(previous, 3, "Frozen at the first quiet block; the later run is the child's answer.")
    }

    /* The deadline defers only while sound is still being collected (voice in the tail) or a
       transcription is in flight, and only within the cap — a television keeps the tail voiced
       forever, so the cap is what guarantees the window ends.
     */
    func testDeadlineDefersOnlyForVoiceOrInferenceWithinTheCap() {
        XCTAssertFalse(ListeningBufferRules.shouldDeferDeadline(
            tailHasVoice: false, inferenceInFlight: false, deferredSeconds: 0, stepSeconds: 0.25, capSeconds: 3))
        XCTAssertTrue(ListeningBufferRules.shouldDeferDeadline(
            tailHasVoice: true, inferenceInFlight: false, deferredSeconds: 0, stepSeconds: 0.25, capSeconds: 3))
        XCTAssertTrue(ListeningBufferRules.shouldDeferDeadline(
            tailHasVoice: false, inferenceInFlight: true, deferredSeconds: 0, stepSeconds: 0.25, capSeconds: 3))
        XCTAssertTrue(ListeningBufferRules.shouldDeferDeadline(
            tailHasVoice: true, inferenceInFlight: true, deferredSeconds: 2.75, stepSeconds: 0.25, capSeconds: 3),
            "The boundary is inclusive.")
        XCTAssertFalse(ListeningBufferRules.shouldDeferDeadline(
            tailHasVoice: true, inferenceInFlight: true, deferredSeconds: 3.0, stepSeconds: 0.25, capSeconds: 3))
        XCTAssertFalse(ListeningBufferRules.shouldDeferDeadline(
            tailHasVoice: true, inferenceInFlight: false, deferredSeconds: 0, stepSeconds: 0.25, capSeconds: 0),
            "A zero cap makes the deadline hard.")
    }

    /* After a cap-path pass (voice continuous for the whole cap) the retained 0.3 s tail IS voice,
       so the first quiet blocks that follow re-run a pass over the tail of the same utterance —
       deliberate: a long answer is heard to its end. After a quiet-tail pass nothing re-triggers.
     */
    func testCapPathRetainedTailReTriggersOnceTheSoundEnds() {
        let continuous = Array(repeating: true, count: 20)
        XCTAssertTrue(ListeningBufferRules.shouldRunLivePass(
            voice: continuous, unconsumedFromBlock: 0, quietTailBlocks: 3, maximumUtteranceBlocks: 20))
        // The cap pass consumed all but the newest 3 (voice) blocks; three quiet blocks arrive.
        let ended = continuous + [false, false, false]
        XCTAssertTrue(ListeningBufferRules.shouldRunLivePass(
            voice: ended, unconsumedFromBlock: 17, quietTailBlocks: 3, maximumUtteranceBlocks: 20),
            "The retained voice tail re-triggers once the sound ends.")
        XCTAssertFalse(ListeningBufferRules.shouldRunLivePass(
            voice: ended, unconsumedFromBlock: 20, quietTailBlocks: 3, maximumUtteranceBlocks: 20),
            "With the whole utterance consumed, quiet blocks alone never trigger.")
    }

    /* Two speech-length runs in the unconsumed span are decoded as one span that bridges the gap
       between them (Whisper hears the pause too), padded on both sides.
     */
    func testFlushSpanBridgesTwoRuns() {
        var voice = Array(repeating: false, count: 60)
        for index in 10..<12 { voice[index] = true }
        for index in 40..<45 { voice[index] = true }
        XCTAssertEqual(ListeningBufferRules.flushSpan(voice: voice, unconsumedFromBlock: 0, padBlocks: 3), 7..<48)
        XCTAssertEqual(ListeningBufferRules.flushSpan(voice: voice, unconsumedFromBlock: 20, padBlocks: 3), 37..<48,
                       "A run already consumed is left out.")
    }

    /* The block an engine start lands in can be mostly digital zero with a sliver of room noise:
       far below the real floor, it passes the -80 dBFS guard, becomes the reference for the next
       2 s, and makes ordinary room noise read as voice — which the carried-over rule would then
       skip along with a real answer. Masking that block (and the next) to 0 removes it as a
       reference without making it voice.
     */
    func testEngineStartBlocksAreMaskedOutOfTheReference() {
        let room: Float = 0.003
        let rampIn: Float = 0.0005          // -66 dBFS: above the guard, far below the floor
        let speech: Float = 0.05
        let energies = [room, room, room, room, room, rampIn, room, speech]

        let unmasked = ListeningBufferRules.voiceBlocks(
            relativeEnergies: ListeningBufferRules.relativeEnergies(blockEnergies: energies), silenceThreshold: 0.10)
        XCTAssertTrue(unmasked[6], "Without the mask, room noise after the ramp-in block reads as voice.")

        let masked = ListeningBufferRules.maskingEngineStart(
            energies: energies, firstAbsoluteBlock: 100, engineStartBlock: 105)
        XCTAssertEqual(masked[5], 0)
        XCTAssertEqual(masked[6], 0)
        XCTAssertEqual(Array(masked[0..<5]), Array(energies[0..<5]))
        XCTAssertEqual(masked[7], speech)
        let voice = ListeningBufferRules.voiceBlocks(
            relativeEnergies: ListeningBufferRules.relativeEnergies(blockEnergies: masked), silenceThreshold: 0.10)
        XCTAssertFalse(voice[5])
        XCTAssertFalse(voice[6], "A masked block is never voice.")
        XCTAssertTrue(voice[7], "Speech still stands out against the room floor.")

        XCTAssertEqual(ListeningBufferRules.maskingEngineStart(energies: energies, firstAbsoluteBlock: 100, engineStartBlock: 90), energies,
                       "An engine start before the slice changes nothing.")
        XCTAssertEqual(ListeningBufferRules.maskingEngineStart(energies: energies, firstAbsoluteBlock: 100, engineStartBlock: 108), energies,
                       "An engine start after the slice changes nothing.")
        XCTAssertEqual(ListeningBufferRules.maskingEngineStart(energies: energies, firstAbsoluteBlock: 100, engineStartBlock: 99)[0], 0,
                       "A start one block before the slice still masks the slice's first block.")
    }
}
