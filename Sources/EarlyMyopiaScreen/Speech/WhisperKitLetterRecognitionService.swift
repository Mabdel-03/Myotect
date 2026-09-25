import AVFoundation
import Combine
import Foundation
import WhisperKit

/// Live single-letter recognition via WhisperKit (on-device Whisper CoreML).
///
/// The listening design is ported from the sibling ETDRS app's `ETDRSWhisperLetterService` (the
/// version that is robust on device) behind Myotect's one-shot ``LetterRecognitionService``
/// contract: each `recognizeOneLetter` opens a *session* on the continuously running capture
/// engine and fires `onOutcome` **exactly once, on the main thread** — on the first clean Sloan
/// letter or spoken skip, or after the (soft) no-input window flushes.
///
/// What makes it robust, and why (see PROTOCOL §7 and the pure rules in ``ListeningBufferRules``):
/// - **Own audio store.** WhisperKit's `audioSamples` is appended on the tap thread with no lock
///   and reset by every engine start, so the service keeps its own ``CaptureSampleStore`` with
///   absolute, block-aligned indices and never reads WhisperKit's buffer or its voice heuristic.
/// - **Session start at the reveal.** The coordinator calls `recognizeOneLetter` in the same
///   main-actor turn that reveals the letter; the session's start index is minted synchronously,
///   before any `await`, so an answer given the instant the letter appears is heard from its
///   onset and nothing recorded before the reveal is ever transcribed.
/// - **Carried-over voice is never an answer.** A sound already under way in the session's first
///   block began before the child could see the letter (nobody reacts inside 100 ms); it is
///   skipped, so the tail of the previous answer can never be scored for the next letter.
/// - **Whole utterances only.** A live pass runs once the answer has ENDED (a quiet 0.3 s tail),
///   never on a first syllable Whisper would complete into a non-letter word; a pass that
///   produced no answer leaves the newest 0.3 s unconsumed so a straddling onset survives.
/// - **The trace decides silence.** `.unrecognized(.silence)` is delivered only when the window
///   held no speech-length sound AND no usable text; hallucination text over a real sound
///   retries as `.unintelligible`. The deadline flush decodes only the speech-length runs.
/// - **Soft deadline.** The window never fires while voice is in the tail or a decode is in
///   flight; it defers in short steps up to a cap, so a late answer scores for its own letter.
///
/// Single-fire discipline: a `didComplete` guard, a `finish` that runs on the main actor and
/// dispatches the handler via `DispatchQueue.main.async`, and a `cancel()` that delivers nothing
/// afterward. The `generation` counter neutralizes every task, pass and deadline of a superseded
/// trial; `armedSessionToken` is what a tap-driven pass reads (0 = nothing armed).
///
/// Audio-session strategy: WhisperKit's `startRecordingLive` applies `.playAndRecord +
/// .defaultToSpeaker`; the announcer speaks UNDER that session without a category flip
/// (`SpeechAnnouncer.setMicrophoneCaptureActive`). ARKit never touches the audio session.
///
/// All mutable state is touched only on the main actor; the tap thread touches only the store.
@MainActor
final class WhisperKitLetterRecognitionService: NSObject, ObservableObject, @MainActor LetterRecognitionService {

    /// Readiness of the WhisperKit model. Observed by `SetupPermissionsView` to gate "Begin".
    enum ModelState: Equatable {
        case preparing(ModelPrepPhase)
        case ready
        case failed(String)
    }

    /// Load/compile phases surfaced as determinate-ish progress during setup. The model is
    /// normally bundled; `.downloading` covers the first-run fallback when it is not (progress
    /// detail in ``downloadFraction``, so the operator never watches a frozen "locating model").
    enum ModelPrepPhase: Int, CaseIterable, Equatable {
        case locatingModel
        case downloading
        case initializing
        case prewarming
        case loading

        var label: String {
            switch self {
            case .locatingModel: return "locating model"
            case .downloading: return "downloading model"
            case .initializing: return "initializing"
            case .prewarming: return "prewarming"
            case .loading: return "loading"
            }
        }

        var fraction: Double {
            switch self {
            case .locatingModel: return 0.1
            case .downloading: return 0.25
            case .initializing: return 0.35
            case .prewarming: return 0.6
            case .loading: return 0.85
            }
        }
    }

    @Published private(set) var modelState: ModelState = .preparing(.locatingModel)
    /// 0...1 progress of the model download, meaningful only while
    /// `modelState == .preparing(.downloading)`.
    @Published private(set) var downloadFraction: Double = 0

    /// The service can run on real hardware regardless of model-load progress; readiness is reported
    /// separately via ``modelState``. Used only for service *selection*, not per-trial gating.
    nonisolated var isAvailable: Bool { true }

    // MARK: - Tuning

    /// Pinned model variant so the *bundled* folder name is known ahead of time.
    private let bundledModelVariant = "openai_whisper-base"
    private let bundledModelsFolderName = "WhisperModels"
    private let expectedLanguage = "en"
    /// A live pass needs at least this much unconsumed audio (gold constant).
    private let minimumRealtimeBufferSeconds: Float = 0.35
    /// A live pass hands Whisper at most the newest this-many seconds past the consumed pointer.
    private let realtimeTranscriptionWindowSeconds: Float = 2.4
    /// An engine that reports itself running yet delivers no audio for this long is restarted
    /// in place, once per trial (a Bluetooth headset's first buffer can be slow).
    private let engineStallSeconds: TimeInterval = 1.5
    /// Upper bound on waiting for an in-flight decode before the deadline flush runs.
    private let maximumInferenceDrainSeconds: TimeInterval = 1.5
    /// Padding (blocks) around the speech-length runs the deadline flush decodes.
    private let flushPadBlocks = 5

    // Config-backed (ScreenConfig, MARK: Speech).
    private let silenceThreshold: Float
    private let quietTailBlocks: Int
    private let maximumUtteranceBlocks: Int
    private let deadlineDeferralStep: TimeInterval
    private let deadlineDeferralCap: TimeInterval
    private let purgeKeepSeconds: TimeInterval
    private let captureBufferTrimSamples: Int

    private let block = ListeningBufferRules.energyBlockSamples
    private var minimumRealtimeSamples: Int { Int(minimumRealtimeBufferSeconds * Float(ListeningBufferRules.sampleRate)) }
    private var maxWindowSamples: Int { Int(realtimeTranscriptionWindowSeconds * Float(ListeningBufferRules.sampleRate)) }

    // MARK: - State (main actor only)

    private var whisperKit: WhisperKit?
    private var prepareTask: Task<WhisperKit, Error>?
    /// The service's own sample store; the ONLY audio ever read. Lives for the service's life.
    private let store = CaptureSampleStore()

    private var completion: ((RecognitionOutcome) -> Void)?
    private var didComplete = false
    /// Bumped on every `recognizeOneLetter`/`cancel` so anything from a superseded trial no-ops.
    private var generation = 0
    /// The generation tap-driven passes belong to; 0 while nothing is armed.
    private var armedSessionToken = 0
    /// Absolute, block-floored index where this trial's audio begins (minted at the reveal).
    private var sessionStartIndex = 0
    private var sessionStartedAt = Date()
    /// Set by the first block completed after the session start: the no-input window runs from
    /// here. Nil = the microphone has not delivered audio for this trial yet.
    private var windowArmedAt: Date?
    private var lastBlockAt: Date?
    /// Absolute consumed pointer; never decreases within a trial.
    private var consumedIndex = 0
    /// The strongest non-answer heard on a live pass this trial (ambiguous > unintelligible >
    /// filler). Substituted for a silent tail at the flush so an engaged child retries.
    private var engagedOutcome: RecognitionOutcome?
    /// One inference slot for the whole service; set only by `runPassIfNeeded` and cleared only
    /// by that pass's `defer` — engine restarts never touch it, so two decodes can never overlap.
    private var isRunningInference = false
    /// The in-flight decode, so `cancel()` can abort a stale one instead of blocking the next trial.
    private var inferenceTask: Task<String, Error>?
    /// Consecutive decode throws; three in a row is a structural capture failure, not a quiet child.
    private var consecutiveTranscribeErrors = 0
    private var engineRestartedThisTrial = false
    /// `store.totalCount` at the last successful engine start: audio is continuous across the
    /// session start only if this is not past it, and the block it fell in is masked out of the
    /// silence reference.
    private var engineStartIndex = 0
    private var engineStartedAt = Date()
    /// `store.totalCount` when WhisperKit's own buffer was last emptied (engine start or trim):
    /// the store receives the same chunks, so the difference is that buffer's size.
    private var captureBufferBaseIndex = 0
    private var deadlineTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    // MARK: Continuous capture state
    /// True between `beginCaptureSession` and `endCaptureSession` (one engine per listening
    /// block); trials then arm on the live engine instead of rebuilding it.
    private var captureSessionActive = false
    private var engineRunning = false
    private let captureEventsSubject = PassthroughSubject<CaptureEvent, Never>()
    private let diagnosticsSubject = PassthroughSubject<RecognitionDiagnostic, Never>()
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?

    init(config: ScreenConfig = ScreenConfig()) {
        silenceThreshold = config.voiceSilenceThreshold
        quietTailBlocks = max(1, Int((config.utteranceEndQuietSeconds * Double(ListeningBufferRules.sampleRate)).rounded())
            / ListeningBufferRules.energyBlockSamples)
        maximumUtteranceBlocks = max(1, Int((config.maximumUtteranceSeconds * Double(ListeningBufferRules.sampleRate)).rounded())
            / ListeningBufferRules.energyBlockSamples)
        deadlineDeferralStep = max(0.05, config.deadlineDeferralStepSeconds)
        deadlineDeferralCap = max(0, config.deadlineDeferralCapSeconds)
        purgeKeepSeconds = max(Double(ListeningBufferRules.referenceWindowBlocks) * 0.1, config.capturePurgeKeepSeconds)
        captureBufferTrimSamples = Int(config.captureBufferTrimAfterSeconds * Double(ListeningBufferRules.sampleRate))
        super.init()
        // Eagerly warm the model during the setup screen so the first trial has a loaded model.
        startModelPrep()
    }

    // MARK: - Model preparation

    /// Retry entry for the setup screen after a `.failed` load (e.g. transient memory pressure).
    func retryModelPreparation() {
        guard case .failed = modelState else { return }
        prepareTask = nil
        startModelPrep()
    }

    private func startModelPrep() {
        guard prepareTask == nil else { return }
        modelState = .preparing(.locatingModel)
        let task = Task<WhisperKit, Error> { try await self.prepareWhisperKit() }
        prepareTask = task
        Task {
            do {
                let kit = try await task.value
                self.whisperKit = kit
                self.modelState = .ready
            } catch {
                self.prepareTask = nil
                self.modelState = .failed(error.localizedDescription)
            }
        }
    }

    /// Ensures the model is loaded, awaiting the shared prep task if needed. Throws on load failure.
    private func ensureModelReady() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        if prepareTask == nil { startModelPrep() }
        guard let prepareTask else { throw WhisperKitLetterServiceError.whisperUnavailable }
        let kit = try await prepareTask.value
        whisperKit = kit
        return kit
    }

    private func prepareWhisperKit() async throws -> WhisperKit {
        // Prefer the bundled model folder; fall back to a download if it isn't present.
        if let bundledFolder = bundledModelFolderURL() {
            return try await initializeWhisperKit(model: nil, modelFolder: bundledFolder)
        }
        modelState = .preparing(.downloading)
        downloadFraction = 0
        let modelFolder = try await WhisperKit.download(variant: bundledModelVariant) { progress in
            Task { @MainActor [weak self] in
                self?.downloadFraction = progress.fractionCompleted
            }
        }
        return try await initializeWhisperKit(model: bundledModelVariant, modelFolder: modelFolder)
    }

    private func initializeWhisperKit(model: String?, modelFolder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: model,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: false,
            download: false
        )
        modelState = .preparing(.initializing)
        let kit = try await WhisperKit(config)
        modelState = .preparing(.prewarming)
        try await kit.prewarmModels()
        modelState = .preparing(.loading)
        try await kit.loadModels()
        return kit
    }

    /// Locates the bundled model directory under `Bundle.main/WhisperModels/`.
    /// Ported from `ETDRSWhisperLetterService.bundledModelFolderURL`.
    private nonisolated func bundledModelFolderURL() -> URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent(
            bundledModelsFolderName, isDirectory: true) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let exactCandidates = [
            root.appendingPathComponent(bundledModelVariant, isDirectory: true),
        ]
        for candidate in exactCandidates {
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }

        let childDirectories = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []

        if childDirectories.count == 1 { return childDirectories.first }

        let normalized = normalizedModelFolderToken(bundledModelVariant)
        return childDirectories.first { normalizedModelFolderToken($0.lastPathComponent).contains(normalized) }
    }

    private nonisolated func normalizedModelFolderToken(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    // MARK: - LetterRecognitionService

    /// Opens a session for the letter that is being revealed in THIS main-actor turn. Everything
    /// that pins the session to the reveal — the purge, the start index, the armed token — runs
    /// synchronously before any `await`, so a tap-driven pass can attribute audio to this trial
    /// from the very next block, whatever the permission/model/engine awaits below still have
    /// to do.
    func recognizeOneLetter(timeout: TimeInterval, onOutcome: @escaping (RecognitionOutcome) -> Void) {
        resetTrialState()
        completion = onOutcome
        didComplete = false
        let gen = generation

        store.purge(keepingLastSeconds: purgeKeepSeconds)
        sessionStartIndex = (store.totalCount / block) * block
        consumedIndex = sessionStartIndex
        sessionStartedAt = Date()
        windowArmedAt = nil
        lastBlockAt = nil
        engagedOutcome = nil
        consecutiveTranscribeErrors = 0
        engineRestartedThisTrial = false
        armedSessionToken = gen
        log("session #\(gen) start idx=\(sessionStartIndex) (engine running: \(engineRunning))")
        publish(.listening)

        deadlineTask = Task { [weak self] in
            await self?.runDeadline(generation: gen, timeout: timeout)
        }

        pollTask = Task { [weak self] in
            guard let self else { return }
            // Mic permission first: revocation after setup must surface as a structural failure
            // with a Settings path, never a silent unrecognized loop. Answers immediately once
            // determined; prompts only the very first time.
            guard await AudioProcessor.requestRecordPermission() else {
                self.finish(.serviceFailure(.microphonePermissionDenied), generation: gen)
                return
            }
            let kit: WhisperKit
            do {
                kit = try await self.ensureModelReady()
            } catch is CancellationError {
                return
            } catch {
                self.finish(.serviceFailure(.modelUnavailable(error.localizedDescription)), generation: gen)
                return
            }
            guard self.generation == gen, !self.didComplete else { return }
            do {
                try self.ensureEngineRunning(kit)
            } catch {
                self.finish(.serviceFailure(.audioCaptureFailed(error.localizedDescription)), generation: gen)
                return
            }
            // The poll loop is the backstop for a tap that stops delivering, and the home of
            // the stall watchdog; the tap itself drives passes as blocks complete.
            while !Task.isCancelled {
                await self.runLivePass(session: gen)
                self.restartEngineIfStalled(session: gen)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Ends the trial without delivering anything. Inside a capture session the engine stays
    /// warm for the next reveal (a distance pause is an inter-letter gap too); the store and
    /// WhisperKit's buffer are trimmed now rather than on a reveal.
    func cancel() {
        resetTrialState()
        if captureSessionActive, engineRunning, let kit = whisperKit {
            store.purge(keepingLastSeconds: purgeKeepSeconds)
            trimCaptureBufferIfOversized(kit)
        } else if !captureSessionActive {
            stopEngine()
        }
    }

    /// The trial-scoped part of `cancel()`: invalidates every task, pass and deadline of the
    /// current trial. Deliberately leaves `isRunningInference` alone — only the pass that set it
    /// clears it — but cancels the decode so it aborts in milliseconds.
    private func resetTrialState() {
        generation &+= 1
        armedSessionToken = 0
        deadlineTask?.cancel()
        deadlineTask = nil
        pollTask?.cancel()
        pollTask = nil
        inferenceTask?.cancel()
        completion = nil
        engagedOutcome = nil
        windowArmedAt = nil
    }

    // MARK: - Engine lifecycle

    /// `audioEngine` lives on the concrete `AudioProcessor`, not the `AudioProcessing` protocol.
    /// Our own flag is never trusted alone: an interruption or route change stops the engine
    /// without telling anyone.
    private func engineReportsRunning(_ kit: WhisperKit) -> Bool {
        (kit.audioProcessor as? AudioProcessor)?.audioEngine?.isRunning == true
    }

    /// Starts the engine unless it is live by both accounts. Synchronous on the main actor after
    /// every await, so two callers (a capture session opening, a trial arming) can never
    /// interleave two `startRecordingLive` calls.
    private func ensureEngineRunning(_ kit: WhisperKit) throws {
        guard !(engineRunning && engineReportsRunning(kit)) else { return }
        try startEngine(kit)
    }

    /// (Re)starts WhisperKit's live engine. Any engine still referenced — live, or dead after an
    /// interruption — is stopped first. The tap appends into OUR store (the closure captures the
    /// store strongly and the service weakly: WhisperKit keeps the callback past `stopRecording`)
    /// and hops to the main actor once per completed block. Never touches `isRunningInference`.
    private func startEngine(_ kit: WhisperKit) throws {
        engineRunning = false
        kit.audioProcessor.stopRecording()
        let store = self.store
        try kit.audioProcessor.startRecordingLive(inputDeviceID: nil) { [weak self] chunk in
            guard store.append(chunk) else { return }
            Task { @MainActor [weak self] in
                await self?.blockDidArrive()
            }
        }
        engineRunning = true
        engineStartIndex = store.totalCount
        engineStartedAt = Date()
        captureBufferBaseIndex = store.totalCount
        observeConfigurationChanges(of: kit)
        captureEventsSubject.send(.captureStarted)
    }

    private func stopEngine() {
        whisperKit?.audioProcessor.stopRecording()
        engineRunning = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    /// WhisperKit's own live buffer grows for the life of an engine and cannot be trimmed while
    /// its tap is appending. Once it holds `captureBufferTrimAfterSeconds` of audio the engine is
    /// PAUSED for a few milliseconds, the buffer emptied, and the engine resumed — no rebuild, so
    /// no deaf gap, no ramp-in artifact, and the store's audio stays continuous (the reference
    /// and the carried-over rule are unaffected). Falls back to a full restart if the resume
    /// fails. The store itself is never touched here.
    private func trimCaptureBufferIfOversized(_ kit: WhisperKit) {
        guard captureSessionActive, engineRunning,
              store.totalCount - captureBufferBaseIndex >= captureBufferTrimSamples else { return }
        kit.audioProcessor.pauseRecording()
        kit.audioProcessor.purgeAudioSamples(keepingLast: 0)
        do {
            try kit.audioProcessor.resumeRecordingLive(inputDeviceID: nil, callback: nil)
            captureBufferBaseIndex = store.totalCount
            log("capture buffer trimmed after \(captureBufferTrimSamples / ListeningBufferRules.sampleRate) s of audio")
        } catch {
            log("capture buffer trim could not resume the engine (\(error.localizedDescription)); rebuilding it")
            try? startEngine(kit)
        }
    }

    /// Between trials (a distance pause can last minutes) blocks keep arriving with nothing
    /// armed: keep both buffers bounded so memory stays flat however long the gap.
    private func houseKeepWhileIdle() {
        guard captureSessionActive, engineRunning, let kit = whisperKit else { return }
        let keepSamples = Int(purgeKeepSeconds * Double(ListeningBufferRules.sampleRate))
        if store.totalCount - store.baseIndex >= 2 * keepSamples {
            store.purge(keepingLastSeconds: purgeKeepSeconds)
        }
        trimCaptureBufferIfOversized(kit)
    }

    /// A session whose engine has delivered no audio since it (or the engine) started is on a
    /// dead engine — an interruption or route change stopped it, or a warm engine died in the
    /// gap. Restart it in place, once per trial: at once when the engine reports itself stopped,
    /// or after `engineStallSeconds` when it claims to run but nothing arrives. A restart that
    /// fails ends the trial structurally rather than letting it run out as "no input".
    private func restartEngineIfStalled(session: Int) {
        guard session == generation, session == armedSessionToken, !didComplete,
              !engineRestartedThisTrial, let kit = whisperKit else { return }
        let since = lastBlockAt ?? max(sessionStartedAt, engineStartedAt)
        guard !engineReportsRunning(kit) || Date().timeIntervalSince(since) >= engineStallSeconds else { return }
        engineRestartedThisTrial = true
        log("engine stalled (no audio for \(String(format: "%.1f", Date().timeIntervalSince(since))) s) — restarting in place")
        do {
            try startEngine(kit)
        } catch {
            finish(.serviceFailure(.audioCaptureFailed(error.localizedDescription)), generation: session)
        }
    }

    // MARK: - Passes

    /// One completed 100 ms block arrived (main actor). The token is read at execution, not at
    /// spawn, so a block belongs to whichever session is armed when it lands.
    private func blockDidArrive() async {
        let session = armedSessionToken
        guard session != 0 else {
            houseKeepWhileIdle()
            return
        }
        lastBlockAt = Date()
        if windowArmedAt == nil, store.totalCount > sessionStartIndex {
            windowArmedAt = Date()
            log("mic armed +\(String(format: "%.2f", Date().timeIntervalSince(sessionStartedAt))) s after reveal")
        }
        await runLivePass(session: session)
    }

    private func runLivePass(session: Int) async {
        guard case .outcome(let outcome) = await runPassIfNeeded(session: session, isFinal: false) else { return }
        switch outcome {
        case .letter, .skipped, .serviceFailure:
            finish(outcome, generation: session)
        case .ambiguous, .unrecognized:
            break
        }
    }

    private enum PassResult {
        case outcome(RecognitionOutcome)
        case bounced
        case silent
    }

    private struct SessionSnapshot {
        /// Block-aligned absolute end of the trace the pass saw; the consumed pointer moves
        /// relative to it so the retained tail is exactly whole quiet blocks.
        let endIndex: Int
        let buffer: [Float]
        /// Whether the unconsumed span held a speech-length sound (two consecutive voice blocks).
        let hadSpeechLengthSound: Bool
        let voicedBlocks: Int
    }

    private enum SnapshotDecision {
        case run(SessionSnapshot)
        case waiting
        case noSpeechLengthSound
    }

    /// The session's voice trace: per-block voice flags from the session start, computed against
    /// the quietest of the up to 20 blocks recorded before it (the warm engine has them).
    private func sessionTrace() -> (snapshot: CaptureSampleStore.Snapshot, endIndex: Int, sessionVoice: [Bool])? {
        let snapshot = store.snapshot()
        let baseBlock = snapshot.baseIndex / block
        let startBlock = sessionStartIndex / block
        let endBlock = baseBlock + snapshot.blockEnergies.count
        guard startBlock >= baseBlock, endBlock > startBlock else { return nil }
        let referenceBlocks = min(ListeningBufferRules.referenceWindowBlocks, startBlock - baseBlock)
        // The block an engine start landed in (and the next) can be mostly digital zero with a
        // sliver of room noise — far below the real floor — and would become the silence
        // reference for the next 2 s, making ordinary room noise read as voice (and, through the
        // carried-over rule, swallow a real answer). Masked to 0: neither reference nor voice.
        let energies = ListeningBufferRules.maskingEngineStart(
            energies: Array(snapshot.blockEnergies[(startBlock - referenceBlocks - baseBlock)...]),
            firstAbsoluteBlock: startBlock - referenceBlocks,
            engineStartBlock: engineStartIndex / block)
        let voiceAll = ListeningBufferRules.voiceBlocks(
            relativeEnergies: ListeningBufferRules.relativeEnergies(blockEnergies: energies),
            silenceThreshold: silenceThreshold)
        return (snapshot, endBlock * block, Array(voiceAll.dropFirst(referenceBlocks)))
    }

    private func snapshotSession(isFinal: Bool) -> SnapshotDecision {
        guard let (snapshot, endIndex, sessionVoice) = sessionTrace() else { return .waiting }

        // Carried-over voice: a sound already under way in the session's first block began
        // before the child could see the letter. Skipped up to the cap — but only while audio is
        // continuous across the session start; a fresh engine has no "before".
        if engineStartIndex <= sessionStartIndex {
            let carried = ListeningBufferRules.carriedOverBlocks(
                sessionVoice: sessionVoice, maximumBlocks: maximumUtteranceBlocks)
            let floor = sessionStartIndex + carried * block
            if carried > 0, floor > consumedIndex {
                if consumedIndex == sessionStartIndex {
                    log("carried-over voice: skipped \(carried) blocks so far (a sound already under way at the reveal; grows until it ends, cap \(maximumUtteranceBlocks))")
                }
                consumedIndex = floor
            }
        }

        let unconsumedFromBlock = (consumedIndex - sessionStartIndex) / block
        let unconsumedVoice = Array(sessionVoice[min(unconsumedFromBlock, sessionVoice.count)...])
        let hadSound = ListeningBufferRules.windowHadVoice(voice: unconsumedVoice)
        let voicedBlocks = unconsumedVoice.filter { $0 }.count

        if !isFinal {
            guard endIndex - consumedIndex >= minimumRealtimeSamples,
                  ListeningBufferRules.shouldRunLivePass(
                      voice: sessionVoice,
                      unconsumedFromBlock: unconsumedFromBlock,
                      quietTailBlocks: quietTailBlocks,
                      maximumUtteranceBlocks: maximumUtteranceBlocks)
            else { return .waiting }
            let from = ListeningBufferRules.windowStart(
                isFinal: false, consumed: consumedIndex, bufferCount: endIndex, maxWindowSamples: maxWindowSamples)
            return .run(SessionSnapshot(
                endIndex: endIndex,
                buffer: store.copySamples(from..<snapshot.totalCount),
                hadSpeechLengthSound: hadSound,
                voicedBlocks: voicedBlocks))
        }

        // The flush decodes only the speech-length runs (plus padding): 10 s of room floor with
        // one faint syllable is exactly what Whisper hallucinates text over, and with no
        // speech-length sound at all Whisper is not called.
        guard let span = ListeningBufferRules.flushSpan(
            voice: sessionVoice, unconsumedFromBlock: unconsumedFromBlock, padBlocks: flushPadBlocks)
        else { return .noSpeechLengthSound }
        let lower = sessionStartIndex + span.lowerBound * block
        let upper = sessionStartIndex + span.upperBound * block
        return .run(SessionSnapshot(
            endIndex: endIndex,
            buffer: store.copySamples(lower..<upper),
            hadSpeechLengthSound: true,
            voicedBlocks: voicedBlocks))
    }

    /// Transcribes the current window (live: the rolling window past the consumed pointer, once
    /// the utterance has ended; final: the speech-length runs) and classifies it. `session` is
    /// bound where the pass was spawned; a pass that outlives its trial must not touch the next
    /// trial's state — above all the consumed pointer — so every line after the `await` is
    /// guarded.
    private func runPassIfNeeded(session: Int, isFinal: Bool) async -> PassResult {
        guard session == generation, session == armedSessionToken, !didComplete,
              !isRunningInference, let kit = whisperKit else { return .bounced }
        let snapshot: SessionSnapshot
        switch snapshotSession(isFinal: isFinal) {
        case .waiting: return .bounced
        case .noSpeechLengthSound: return .silent
        case .run(let ready): snapshot = ready
        }

        isRunningInference = true
        defer {
            isRunningInference = false
            inferenceTask = nil
        }
        let seconds = Float(snapshot.buffer.count) / Float(ListeningBufferRules.sampleRate)
        let task = Task<String, Error> { [samples = snapshot.buffer] in
            try await self.transcribe(kit, samples: samples)
        }
        inferenceTask = task

        let transcript: String
        do {
            transcript = try await task.value
        } catch is CancellationError {
            return .bounced
        } catch {
            guard session == generation else { return .bounced }
            // Do NOT advance the consumed pointer: the audio stays for the next pass. Three
            // consecutive throws is a broken capture pipeline, not a quiet child; on the final
            // pass, audio that could not be decoded must RETRY, never score.
            consecutiveTranscribeErrors += 1
            if consecutiveTranscribeErrors >= 3 {
                return .outcome(.serviceFailure(.audioCaptureFailed(error.localizedDescription)))
            }
            return isFinal ? .outcome(.unrecognized(.unintelligible)) : .bounced
        }
        guard session == generation else {
            log("stale pass for session #\(session) dropped")
            return .bounced
        }
        consecutiveTranscribeErrors = 0

        let outcome = classify(transcript)
        let producedAnswer: Bool
        switch outcome {
        case .letter, .skipped: producedAnswer = true
        default: producedAnswer = false
        }
        // An answer, and the final flush, consume everything the pass saw; anything else keeps
        // the newest quiet tail so an utterance straddling the pass boundary keeps its onset —
        // and a hallucinated "Thank you." can never swallow the child's audio.
        consumedIndex = ListeningBufferRules.consumedSampleCount(
            current: consumedIndex,
            bufferCount: snapshot.endIndex,
            isFinal: isFinal,
            producedAnswer: producedAnswer,
            retainedSamples: quietTailBlocks * block)
        // Whisper's silence hallucinations over a real speech-length sound are engagement, not
        // silence: the child said something Whisper could not map.
        let traced = RecognitionFlushRules.upgradedForTrace(outcome, hadSpeechLengthSound: snapshot.hadSpeechLengthSound)
        log("\(isFinal ? "final flush" : "live pass") on \(String(format: "%.2f", seconds)) s (voiced blocks: \(snapshot.voicedBlocks)): \"\(transcript)\" → \(traced)")
        publish(.heard(raw: transcript, outcome: traced))

        if isFinal { return .outcome(traced) }
        if producedAnswer { return .outcome(outcome) }
        engagedOutcome = RecognitionFlushRules.strongerEngagement(engagedOutcome, traced)
        return .bounced
    }

    private func transcribe(_ kit: WhisperKit, samples: [Float]) async throws -> String {
        let decodeOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: expectedLanguage,
            temperature: 0,
            sampleLength: 8,
            topK: 1,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            promptTokens: nil,
            compressionRatioThreshold: nil,
            logProbThreshold: nil,
            firstTokenLogProbThreshold: nil,
            noSpeechThreshold: nil,
            concurrentWorkerCount: 1,
            chunkingStrategy: ChunkingStrategy.none
        )
        let result = try await kit.transcribe(audioArray: samples, decodeOptions: decodeOptions).first
        return result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Rejects Whisper filler/silence hallucinations (carrying the filter's kind), then defers to
    /// the shared Sloan mapper, whose own `.unrecognized` kind passes through untouched.
    private func classify(_ transcript: String) -> RecognitionOutcome {
        if let kind = WhisperTranscriptFilter.nonAnswerKind(transcript) { return .unrecognized(kind) }
        return LetterMappingTable.classify(transcript)
    }

    // MARK: - Soft deadline + flush

    private func alive(_ gen: Int) -> Bool {
        !Task.isCancelled && gen == generation && !didComplete
    }

    /// Whether the newest `quietTailBlocks` of the session read as voice — an utterance in progress.
    private func tailHasVoice() -> Bool {
        guard let trace = sessionTrace() else { return false }
        return ListeningBufferRules.tailHasVoice(voice: trace.sessionVoice, quietTailBlocks: quietTailBlocks)
    }

    /// Stage 1: the arming deadline — a microphone that never delivered audio (permission
    /// prompt, model still loading, engine start) ends the trial structurally, never as silence.
    /// Stage 2: the window, timed from the first audio. Stage 3: the SOFT part — while sound is
    /// still being collected or a decode is in flight, defer in short steps up to the cap, so a
    /// child who starts answering at 9.8 s is scored for this letter. Then flush.
    private func runDeadline(generation gen: Int, timeout: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
        guard alive(gen) else { return }
        guard let armedAt = windowArmedAt else {
            let failure: RecognitionServiceFailure = whisperKit == nil
                ? .modelUnavailable(WhisperKitLetterServiceError.whisperUnavailable.localizedDescription)
                : .audioCaptureFailed("The microphone delivered no audio.")
            finish(.serviceFailure(failure), generation: gen)
            return
        }
        let remaining = armedAt.addingTimeInterval(timeout).timeIntervalSinceNow
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }

        var deferred: TimeInterval = 0
        while alive(gen), ListeningBufferRules.shouldDeferDeadline(
            tailHasVoice: tailHasVoice(),
            inferenceInFlight: isRunningInference,
            deferredSeconds: deferred,
            stepSeconds: deadlineDeferralStep,
            capSeconds: deadlineDeferralCap) {
            try? await Task.sleep(nanoseconds: UInt64(deadlineDeferralStep * 1_000_000_000))
            // A live pass may have scored the late answer (finish → cancel) while we slept: the
            // cancelled sleep returns at once, and nothing may be logged or narrated for a trial
            // that has ended — the operator is reading its result.
            guard alive(gen) else { return }
            deferred += deadlineDeferralStep
            log("deadline deferred +\(String(format: "%.2f", deadlineDeferralStep)) s (total \(String(format: "%.2f", deferred)) s)")
            publish(.deferredDeadline(seconds: deferred))
        }
        guard alive(gen) else { return }
        if deferred + deadlineDeferralStep > deadlineDeferralCap + 1e-9, deferred > 0 {
            log("deadline deferral cap reached (\(String(format: "%.2f", deferred)) s)")
        }
        await flushAndFinish(generation: gen, deferredSeconds: deferred)
    }

    /// Drains an in-flight decode FIRST (it may be the child's late answer, which scores through
    /// `runLivePass` if it lands), then transcribes the speech-length runs not yet consumed. A
    /// window with no speech-length sound is silent without a decode; audio that could not be
    /// inspected retries; a silent tail after an engaged pass reports that pass.
    private func flushAndFinish(generation gen: Int, deferredSeconds: TimeInterval) async {
        var waited: TimeInterval = 0
        while isRunningInference, waited < maximumInferenceDrainSeconds {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        guard alive(gen) else { return }
        pollTask?.cancel()
        pollTask = nil

        let tail: RecognitionOutcome
        switch await runPassIfNeeded(session: gen, isFinal: true) {
        case .outcome(let outcome):
            tail = outcome
        case .silent:
            log("final flush skipped — no speech-length sound in the window")
            publish(.flushedSilent)
            tail = .unrecognized(.silence)
        case .bounced:
            tail = .unrecognized(.unintelligible)
        }
        guard alive(gen) else { return }
        let outcome = RecognitionFlushRules.resolveFinalOutcome(tail: tail, engagedDuringTrial: engagedOutcome)
        log("flush resolved: tail \(tail), engaged \(String(describing: engagedOutcome)) → \(outcome) (deferred \(String(format: "%.2f", deferredSeconds)) s)")
        finish(outcome, generation: gen)
    }

    /// The single point that delivers an outcome. Guards against double-fire and superseded
    /// trials, tears the trial down (engine kept warm inside a capture session), and dispatches
    /// the handler on the main thread (so the coordinator's `MainActor.assumeIsolated` holds).
    private func finish(_ outcome: RecognitionOutcome, generation: Int) {
        guard !didComplete, generation == self.generation else { return }
        didComplete = true
        let handler = completion
        log("trial #\(generation) ended: \(outcome) after \(String(format: "%.2f", Date().timeIntervalSince(sessionStartedAt))) s")
        cancel()
        DispatchQueue.main.async { handler?(outcome) }
    }

    // MARK: - Diagnostics + logging

    private func publish(_ kind: RecognitionDiagnostic.Kind) {
        diagnosticsSubject.send(RecognitionDiagnostic(kind: kind, at: Date()))
    }

    private nonisolated func log(_ message: String) {
        print("[Whisper] \(message)")
    }
}

// MARK: - ContinuousCaptureControlling + RecognitionDiagnosticsProviding

extension WhisperKitLetterRecognitionService: ContinuousCaptureControlling, RecognitionDiagnosticsProviding {
    var captureEvents: AnyPublisher<CaptureEvent, Never> {
        captureEventsSubject.eraseToAnyPublisher()
    }

    var diagnostics: AnyPublisher<RecognitionDiagnostic, Never> {
        diagnosticsSubject.eraseToAnyPublisher()
    }

    /// Starts one live engine for a whole listening block (warm-up / a scored condition) and
    /// registers audio interruption + route-change observers. Idempotent.
    func beginCaptureSession() {
        guard !captureSessionActive else { return }
        captureSessionActive = true
        registerAudioObservers()
        Task { [weak self] in
            guard let self else { return }
            guard await AudioProcessor.requestRecordPermission() else {
                self.captureEventsSubject.send(.failed(.microphonePermissionDenied))
                return
            }
            guard let kit = try? await self.ensureModelReady(), self.captureSessionActive else { return }
            do {
                try self.ensureEngineRunning(kit)
            } catch {
                self.captureEventsSubject.send(.failed(.audioCaptureFailed(error.localizedDescription)))
            }
        }
    }

    /// Hard stop: engine down, observers removed, store trimmed. Called at block boundaries, on
    /// background, on escalation, and at teardown. The retained tail is the next session's
    /// silence reference; indices stay continuous.
    func endCaptureSession() {
        captureSessionActive = false
        unregisterAudioObservers()
        stopEngine()
        store.purge(keepingLastSeconds: purgeKeepSeconds)
    }

    private func registerAudioObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleAudioInterruption(note) }
        }
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
    }

    private func unregisterAudioObservers() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        interruptionObserver = nil
        routeObserver = nil
    }

    /// AVAudioEngine stops itself on an input configuration change without telling WhisperKit.
    /// Bound to THIS engine instance, so the notification the old engine posts after a route
    /// rebuild cannot mark the healthy new engine dead. The watchdog or the next arm restarts.
    private func observeConfigurationChanges(of kit: WhisperKit) {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine = (kit.audioProcessor as? AudioProcessor)?.audioEngine else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engineRunning else { return }
                self.log("engine configuration changed; it will be restarted")
                self.engineRunning = false
            }
        }
    }

    /// A phone call / Siri / alarm mid-trial: stop the engine on `.began`; on `.ended` restart it
    /// when allowed and let the coordinator re-arm the current letter.
    private func handleAudioInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            stopEngine()
            captureEventsSubject.send(.interruptionBegan)
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                .contains(.shouldResume)
            if captureSessionActive, shouldResume, let kit = whisperKit {
                try? ensureEngineRunning(kit)
            }
            captureEventsSubject.send(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    /// Headphones/AirPods attached or detached: a fresh engine binds the new route. The store's
    /// absolute indices continue across the rebuild; the coordinator re-arms the letter.
    private func handleRouteChange(_ note: Notification) {
        guard captureSessionActive,
              let info = note.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            if let kit = whisperKit {
                try? startEngine(kit)
            }
            captureEventsSubject.send(.routeChanged)
        default:
            break
        }
    }
}

enum WhisperKitLetterServiceError: LocalizedError {
    case whisperUnavailable

    var errorDescription: String? {
        switch self {
        case .whisperUnavailable: return "The speech model is not ready yet."
        }
    }
}

/// The pure decisions behind the timeout flush, kept free of WhisperKit so they are unit-testable.
/// A `no input registered` row is visible in every export and its backstop is the only exit from
/// a same-level loop, so the service may only say "silence" when nothing usable was said in the
/// whole window — never "the tail after an earlier non-answer was quiet", never "Whisper wrote a
/// hallucination over a real sound", never "the audio could not be inspected".
enum RecognitionFlushRules {
    /// Rank of a non-answer as evidence that the child engaged (higher wins). Letters, skips,
    /// structural failures and silence markers are not engagement.
    private static func engagementRank(_ outcome: RecognitionOutcome) -> Int {
        switch outcome {
        case .ambiguous: return 3
        case .unrecognized(.unintelligible): return 2
        case .unrecognized(.filler): return 1
        case .letter, .skipped, .unrecognized(.silence), .serviceFailure: return 0
        }
    }

    /// The stronger of the engagement seen so far and a new non-final classification.
    static func strongerEngagement(_ current: RecognitionOutcome?,
                                   _ candidate: RecognitionOutcome) -> RecognitionOutcome? {
        let candidateRank = engagementRank(candidate)
        guard candidateRank > 0 else { return current }
        guard let current else { return candidate }
        return candidateRank > engagementRank(current) ? candidate : current
    }

    /// The outcome the flush delivers: the tail's own answer, except that a silent tail after an
    /// engaged pass earlier in the trial reports that pass — the child retries with a re-prompt
    /// rather than being logged as absent.
    static func resolveFinalOutcome(tail: RecognitionOutcome,
                                    engagedDuringTrial: RecognitionOutcome?) -> RecognitionOutcome {
        if case .unrecognized(.silence) = tail, let engaged = engagedDuringTrial {
            return engaged
        }
        return tail
    }

    /// The voice trace outranks Whisper's text on silence: a transcript the filter called a
    /// silence hallucination ("Thank you.", "you", "") over a speech-length sound means the child
    /// said something Whisper could not map — `.unintelligible`, which retries. Every other
    /// outcome passes through untouched.
    static func upgradedForTrace(_ outcome: RecognitionOutcome,
                                 hadSpeechLengthSound: Bool) -> RecognitionOutcome {
        if case .unrecognized(.silence) = outcome, hadSpeechLengthSound {
            return .unrecognized(.unintelligible)
        }
        return outcome
    }
}

/// Rejects transcripts that are filler or Whisper's classic silence hallucinations before they reach
/// ``LetterMappingTable``. A ported, trimmed subset of the sibling app's `fillerPhrases` +
/// `ignorableNonAnswerPhrases`, plus the "you"/"thank you"/"thanks for watching" family Whisper emits
/// on near-silent audio. Kept local to this service so ``LetterMappingTable`` stays pure and stable.
enum WhisperTranscriptFilter {
    /// Filler sounds — the child is engaged but hasn't answered yet.
    static let fillerExact: Set<String> = [
        "uh", "uhh", "uhhh", "um", "umm", "ummm", "er", "err", "erm", "ah", "ahh", "ahhh",
        "eh", "ehh", "hm", "hmm", "hmmm", "mm", "mmm", "mhm", "huh", "wait",
    ]

    /// Ignorable non-answers / silence markers, plus the "you"/"thank you"/"thanks for watching"
    /// family Whisper hallucinates on near-silent audio. All of these mean "heard nothing".
    /// The space-free "blankaudio"/"silentaudio" forms cover Whisper's bracketed markers via the
    /// compact-form check (gold parity).
    static let nonAnswerExact: Set<String> = [
        // Ignorable non-answers / silence markers
        "blank", "blank audio", "blankaudio", "empty", "no audio", "no speech", "no sound",
        "silence", "silent", "silent audio", "silentaudio", "pause", "noise", "music",
        "background noise", "background", "static",
        // Whisper silence hallucinations
        "you", "thank you", "thanks for watching", "thank you for watching", "bye", "the end",
    ]

    /// Classifies a whole transcript that must not reach the letter mapper: `.filler` for
    /// engaged-but-no-answer sounds, `.silence` for silence markers/hallucinations (and blank
    /// text). Returns nil when the transcript is a real answer candidate for the mapper.
    ///
    /// Normalization matches ``LetterMappingTable/normalize(_:)`` (non-letter runs become a
    /// space), and — as in the gold filter — the space-stripped compact form is checked against
    /// the sets too, so "[BLANK_AUDIO]" is caught however it collapses.
    static func nonAnswerKind(_ raw: String) -> NonAnswerKind? {
        let normalized = LetterMappingTable.normalize(raw)
        if normalized.isEmpty { return .silence }
        // The compact form is checked against the SILENCE markers only (gold rule). Never
        // against fillers: "Er, R" compacts to "err" and "Uh, H" to "uhh" — collapsing a
        // hesitation-plus-answer into a filler would discard a correct letter from exactly
        // the hesitant children this flow serves.
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        if fillerExact.contains(normalized) { return .filler }
        if nonAnswerExact.contains(normalized) || nonAnswerExact.contains(compact) {
            return .silence
        }
        // Token-wise: only reject when EVERY token is a known non-answer. Any filler token
        // means the child made a sound, so filler wins over silence markers in a mix.
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty,
              tokens.allSatisfy({ fillerExact.contains($0) || nonAnswerExact.contains($0) })
        else { return nil }
        return tokens.contains(where: { fillerExact.contains($0) }) ? .filler : .silence
    }

    /// Deprecated: use ``nonAnswerKind(_:)``, which also reports WHY the transcript was rejected.
    /// Kept as a thin shim so stragglers keep compiling until they migrate.
    static func isNonAnswer(_ raw: String) -> Bool {
        nonAnswerKind(raw) != nil
    }
}
