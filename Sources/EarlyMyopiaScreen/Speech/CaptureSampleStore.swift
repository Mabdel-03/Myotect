import Foundation
import os

/// The recognizer's OWN store of 16 kHz mono samples, fed by WhisperKit's live-capture tap and
/// the only audio the recognizer ever reads.
///
/// It exists because WhisperKit's `AudioProcessor.audioSamples` is appended on the audio tap
/// thread with no locking and `purgeAudioSamples` shifts every index, so reading or trimming
/// that array from the main actor is a data race; and because `startRecordingLive` empties it,
/// which would reset every index bookkept across an engine rebuild (a route change, an
/// interruption, the periodic warm restart). Here every index is ABSOLUTE — `baseIndex` is the
/// absolute index of `samples[0]` and never decreases — so engine stops and starts are just
/// gaps in one continuous index space. Per-block RMS energies are computed incrementally as
/// blocks complete, on the tap thread, so the voice trace is always ready.
///
/// `baseIndex` is always a multiple of `ListeningBufferRules.energyBlockSamples`: `purge` drops
/// whole blocks only, so block `k` of the energy trace is exactly samples
/// `[baseIndex + k * blockSamples, …)` for the life of the store.
final class CaptureSampleStore: @unchecked Sendable {
    struct Snapshot {
        /// Absolute index of the first stored sample (block-aligned).
        let baseIndex: Int
        /// Absolute index one past the newest stored sample (includes the partial block).
        let totalCount: Int
        /// RMS per COMPLETE block from `baseIndex`.
        let blockEnergies: [Float]
    }

    private struct State {
        var baseIndex = 0
        var samples: [Float] = []
        var blockEnergies: [Float] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let blockSamples = ListeningBufferRules.energyBlockSamples

    /// Absolute index one past the newest sample.
    var totalCount: Int {
        state.withLock { $0.baseIndex + $0.samples.count }
    }

    /// Absolute index of `samples[0]`.
    var baseIndex: Int {
        state.withLock { $0.baseIndex }
    }

    /// Appends a chunk from the tap. Returns true iff at least one block completed — the cue for
    /// the recognizer to look at the buffer (about ten times a second, whatever the tap size).
    @discardableResult
    func append(_ chunk: [Float]) -> Bool {
        state.withLock { current in
            let before = current.blockEnergies.count
            current.samples.append(contentsOf: chunk)
            let completed = current.samples.count / blockSamples
            while current.blockEnergies.count < completed {
                let block = current.blockEnergies.count
                let start = block * blockSamples
                current.blockEnergies.append(
                    ListeningBufferRules.blockEnergy(current.samples[start..<(start + blockSamples)]))
            }
            return current.blockEnergies.count > before
        }
    }

    /// Drops whole blocks from the head until at most `seconds` of complete blocks (plus the
    /// partial tail) remain. Block alignment of `baseIndex` is preserved by construction.
    func purge(keepingLastSeconds seconds: Double) {
        let keepSamples = max(0, Int((seconds * Double(ListeningBufferRules.sampleRate)).rounded()))
        let keepBlocks = keepSamples / blockSamples
        state.withLock { current in
            let dropBlocks = max(0, current.blockEnergies.count - keepBlocks)
            guard dropBlocks > 0 else { return }
            let dropSamples = dropBlocks * blockSamples
            current.samples.removeFirst(dropSamples)
            current.blockEnergies.removeFirst(dropBlocks)
            current.baseIndex += dropSamples
        }
    }

    /// One locked copy of the bookkeeping and the (small) energy trace; samples are not copied.
    func snapshot() -> Snapshot {
        state.withLock {
            Snapshot(baseIndex: $0.baseIndex,
                     totalCount: $0.baseIndex + $0.samples.count,
                     blockEnergies: $0.blockEnergies)
        }
    }

    /// The samples in an ABSOLUTE range, clamped to what the store still holds.
    func copySamples(_ range: Range<Int>) -> [Float] {
        state.withLock { current in
            let lower = max(range.lowerBound, current.baseIndex) - current.baseIndex
            let upper = min(range.upperBound, current.baseIndex + current.samples.count) - current.baseIndex
            guard lower < upper else { return [] }
            return Array(current.samples[lower..<upper])
        }
    }
}
