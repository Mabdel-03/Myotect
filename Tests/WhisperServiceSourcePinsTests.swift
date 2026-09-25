import XCTest
@testable import Myotect

/// Source pins for the one file the simulator cannot exercise. The three references below are the
/// exact regressions that reintroduce the on-device bugs the listening rework fixed: reading
/// WhisperKit's unlocked `audioSamples` (data race, indices reset by every engine start),
/// trimming it while its tap is live (shifts every index), and gating on WhisperKit's
/// per-tap-buffer voice heuristic (fires on the first syllable, mis-sized buffers). The engine
/// state may still be read through the concrete `AudioProcessor` cast.
final class WhisperServiceSourcePinsTests: XCTestCase {
    func testServiceNeverReadsWhisperKitsBufferOrItsVoiceHeuristic() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/EarlyMyopiaScreen/Speech/WhisperKitLetterRecognitionService.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("AudioProcessor.isVoiceDetected"))
        XCTAssertFalse(source.contains("audioProcessor.audioSamples"))
        // The one permitted trim of WhisperKit's buffer happens with the engine PAUSED (its tap
        // is silent), never while it is live.
        XCTAssertEqual(source.components(separatedBy: "purgeAudioSamples(").count - 1, 1)
        let pause = source.range(of: "kit.audioProcessor.pauseRecording()")
        let purge = source.range(of: "kit.audioProcessor.purgeAudioSamples(")
        XCTAssertNotNil(pause)
        XCTAssertNotNil(purge)
        if let pause, let purge {
            XCTAssertLessThan(pause.lowerBound, purge.lowerBound, "pause first, then trim")
        }
        XCTAssertFalse(source.contains(".relativeEnergy"))
        XCTAssertTrue(source.contains("as? AudioProcessor)?.audioEngine"),
                      "The engine's own isRunning is the only WhisperKit capture state consulted.")
        XCTAssertTrue(source.contains("CaptureSampleStore"))
    }
}
