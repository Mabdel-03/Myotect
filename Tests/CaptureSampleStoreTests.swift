import XCTest
@testable import Myotect

/// The recognizer's own sample store: absolute, block-aligned indices that survive trimming, so
/// every index the listening rules bookkeep stays valid across purges and engine rebuilds.
final class CaptureSampleStoreTests: XCTestCase {
    private let block = ListeningBufferRules.energyBlockSamples

    /* The tap delivers chunks of arbitrary size; a pass is worth spawning only when a whole
       100 ms block completed, and the partial remainder must be carried into the next block.
     */
    func testAppendReportsCompletedBlocksOnlyAndCarriesTheRemainder() {
        let store = CaptureSampleStore()
        XCTAssertFalse(store.append([Float](repeating: 0.1, count: 1000)))
        XCTAssertEqual(store.snapshot().blockEnergies.count, 0)
        XCTAssertEqual(store.totalCount, 1000)

        XCTAssertTrue(store.append([Float](repeating: 0.1, count: 700)))
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.blockEnergies.count, 1)
        XCTAssertEqual(snapshot.blockEnergies[0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.totalCount, 1700, "The 100-sample remainder is still counted.")

        XCTAssertTrue(store.append([Float](repeating: 0.5, count: block * 2)))
        XCTAssertEqual(store.snapshot().blockEnergies.count, 3)
        // Block 1 = the carried 100 samples at 0.1 plus 1500 samples at 0.5.
        XCTAssertEqual(store.snapshot().blockEnergies[1],
                       ((100 * 0.01 + 1500 * 0.25) / 1600).squareRoot(), accuracy: 0.0001)
        XCTAssertFalse(store.append([]))
    }

    /* Absolute indices are the whole point: after a purge the same absolute range returns the
       same floats, the energy trace shifts by exactly the dropped blocks, and the total count is
       unchanged — so a session start minted before the purge still addresses the same audio.
     */
    func testAbsoluteIndicesSurviveAPurge() {
        let store = CaptureSampleStore()
        var samples = [Float](repeating: 0.01, count: block * 50)      // 5 s
        samples[60_000] = 0.9                                          // a marker at absolute 60 000
        store.append(samples)
        let before = store.snapshot()
        XCTAssertEqual(before.baseIndex, 0)
        XCTAssertEqual(before.totalCount, block * 50)
        XCTAssertEqual(before.blockEnergies.count, 50)
        let markerBefore = store.copySamples(59_000..<61_000)

        store.purge(keepingLastSeconds: 3)
        let after = store.snapshot()
        XCTAssertEqual(after.baseIndex, 32_000, "5 s minus 3 s kept = 20 blocks dropped.")
        XCTAssertEqual(after.totalCount, before.totalCount)
        XCTAssertEqual(after.blockEnergies.count, 30)
        XCTAssertEqual(after.blockEnergies, Array(before.blockEnergies[20...]))
        XCTAssertEqual(store.copySamples(59_000..<61_000), markerBefore)
        XCTAssertEqual(store.copySamples(59_000..<61_000)[1_000], 0.9)
    }

    /* Purging drops whole blocks only, keeps at least the requested tail, and leaves the base
       index block-aligned — the invariant every block ↔ sample conversion relies on.
     */
    func testPurgeIsBlockAlignedAndNeverDropsBelowKeep() {
        let store = CaptureSampleStore()
        store.append([Float](repeating: 0.02, count: block * 7 + 900))  // 7 full blocks + partial
        store.purge(keepingLastSeconds: 0.25)                            // keep 2 full blocks
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.baseIndex % block, 0)
        XCTAssertEqual(snapshot.baseIndex, block * 5)
        XCTAssertEqual(snapshot.blockEnergies.count, 2)
        XCTAssertEqual(snapshot.totalCount, block * 7 + 900, "The partial tail is never dropped.")

        store.purge(keepingLastSeconds: 10)
        XCTAssertEqual(store.baseIndex, block * 5, "Nothing to drop when the store is shorter than the keep.")
        store.purge(keepingLastSeconds: 0)
        XCTAssertEqual(store.baseIndex, block * 7, "A zero keep drops every complete block but keeps the partial tail.")
        XCTAssertEqual(store.totalCount, block * 7 + 900)

        store.append([Float](repeating: 0.02, count: 700))
        XCTAssertEqual(store.snapshot().blockEnergies.count, 1, "Blocks keep completing on the aligned grid after a purge.")
    }

    /* Copies are addressed absolutely and clamped: a range that reaches below the base or past
       the end returns only what the store still holds, and a fully purged range is empty.
     */
    func testCopySamplesClampsOutOfRangeRequests() {
        let store = CaptureSampleStore()
        store.append((0..<(block * 3)).map { Float($0) })
        store.purge(keepingLastSeconds: 0.1)   // base = 3200
        XCTAssertEqual(store.baseIndex, block * 2)

        XCTAssertEqual(store.copySamples(3_000..<3_202), [3200, 3201])
        XCTAssertEqual(store.copySamples((block * 3 - 2)..<(block * 3 + 50)), [4798, 4799])
        XCTAssertTrue(store.copySamples(0..<1_000).isEmpty)
        XCTAssertTrue(store.copySamples(10_000..<20_000).isEmpty)
        XCTAssertTrue(store.copySamples(4_000..<4_000).isEmpty)
    }
}
