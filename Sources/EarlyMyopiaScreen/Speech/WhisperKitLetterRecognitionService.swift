import AVFoundation
import Combine
import Foundation
import WhisperKit

/// Live single-letter recognition via WhisperKit (on-device Whisper CoreML).
///
/// Ported from the sibling ETDRS app's `ETDRSWhisperLetterService`, but adapted from that app's
/// *continuous / streaming* model to Myotect's *one-shot-per-letter* ``LetterRecognitionService``
/// contract: each `recognizeOneLetter` starts a fresh live capture, transcribes rolling audio
/// windows, and fires `onOutcome` **exactly once, on the main thread**, on the first confidently
/// classified Sloan letter (or on timeout after a final flush).
///
/// Single-fire discipline: a `didComplete` guard, a `finish` that runs on the main thread and
/// dispatches the handler via `DispatchQueue.main.async`, and a `cancel()` that delivers nothing
/// afterward. An internal `generation` counter neutralizes a callback from a superseded trial
/// after a rapid restart.
///
/// Audio-session strategy: WhisperKit's own `setupAudioSessionForDevice` applies
/// `.playAndRecord + .defaultToSpeaker` on every `startRecordingLive` — that IS the capture-side
/// session config, and any app-side category set beforehand is overridden. The TTS announcer
/// flips to `.playback` only around utterances. ARKit's camera never touches the audio session,
/// so the continuously running face-tracking session is unaffected.
///
/// Classification reuses ``LetterMappingTable/classify(_:)`` (the single Sloan-set source of truth),
/// preceded by a thin Whisper-specific ``WhisperTranscriptFilter`` that rejects filler and Whisper's
/// classic silence hallucinations before they reach the mapper.
///
/// All mutable state (`completion`, `didComplete`, `generation`, `timeoutWork`, `captureTask`) is
/// touched only on the main thread: the coordinator calls `recognizeOneLetter`/`cancel` from
/// `@MainActor`, and the async capture work hops back to the main actor before calling `finish`.
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

    // MARK: - Tuning (ported from ETDRSWhisperLetterService)

    /// Pinned model variant so the *bundled* folder name is known ahead of time.
    private let bundledModelVariant = "openai_whisper-base"
    private let bundledModelsFolderName = "WhisperModels"
    private let expectedLanguage = "en"
    private let minimumRealtimeBufferSeconds: Float = 0.35
    private let realtimeTranscriptionWindowSeconds: Float = 2.4
    private let silenceThreshold: Float = 0.10
    private let minimumFinalBufferSeconds: Float = 0.15

    // MARK: - State

    private var whisperKit: WhisperKit?
    private var prepareTask: Task<WhisperKit, Error>?

    private var completion: ((RecognitionOutcome) -> Void)?
    private var didComplete = false
    /// Bumped on every `recognizeOneLetter`/`cancel` so a `finish` from a superseded trial no-ops.
    private var generation = 0
    private var timeoutWork: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?

    /// Tracks how much of the WhisperKit ring buffer has already been transcribed this trial.
    private var lastObservedSampleCount = 0
    private var isRunningInference = false
    /// Consecutive transcription throws; three in a row is a structural capture failure, not a
    /// quiet child.
    private var consecutiveTranscribeErrors = 0

    // MARK: Continuous capture state
    /// True between `beginCaptureSession` and `endCaptureSession` (one engine per listening
    /// block); trials then re-arm on the live engine instead of rebuilding it.
    private var captureSessionActive = false
    private var engineRunning = false
    private let captureEventsSubject = PassthroughSubject<CaptureEvent, Never>()
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    override init() {
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

    func recognizeOneLetter(timeout: TimeInterval, onOutcome: @escaping (RecognitionOutcome) -> Void) {
        cancel()                            // reset any prior in-flight recognition
        completion = onOutcome
        didComplete = false
        generation &+= 1
        let myGeneration = generation

        captureTask = Task { [weak self] in
            guard let self else { return }
            // Mic permission first: revocation after setup must surface as a structural failure
            // with a Settings path, never a silent unrecognized loop. Answers immediately once
            // determined; prompts only the very first time.
            guard await AudioProcessor.requestRecordPermission() else {
                self.finish(.serviceFailure(.microphonePermissionDenied), generation: myGeneration)
                return
            }
            let kit: WhisperKit
            do {
                kit = try await self.ensureModelReady()
            } catch is CancellationError {
                return
            } catch {
                self.finish(.serviceFailure(.modelUnavailable(error.localizedDescription)),
                            generation: myGeneration)
                return
            }
            if Task.isCancelled { return }
            do {
                if self.captureSessionActive, self.engineRunning {
                    self.armOnLiveEngine(kit)
                } else {
                    try self.startRecording(kit)
                }
            } catch {
                self.finish(.serviceFailure(.audioCaptureFailed(error.localizedDescription)),
                            generation: myGeneration)
                return
            }
            await self.runCaptureLoop(kit, generation: myGeneration)
        }

        scheduleTimeout(timeout, generation: myGeneration)
    }

    func cancel() {
        generation &+= 1
        timeoutWork?.cancel()
        timeoutWork = nil
        captureTask?.cancel()
        captureTask = nil
        // In a capture session the engine survives cancellation (disarm only); one-shot mode
        // tears it down as before — and must clear the flag, or a later beginCaptureSession
        // would see engineRunning=true and silently skip starting the engine.
        if !captureSessionActive {
            whisperKit?.audioProcessor.stopRecording()
            engineRunning = false
        }
        completion = nil
        lastObservedSampleCount = 0
        isRunningInference = false
    }

    // MARK: - Audio capture

    private func startRecording(_ kit: WhisperKit) throws {
        lastObservedSampleCount = 0
        isRunningInference = false
        consecutiveTranscribeErrors = 0
        // WhisperKit's startRecordingLive applies its own audio-session config (.playAndRecord);
        // see the class doc. We drive transcription from the poll loop, so the per-buffer
        // callback is a no-op.
        try kit.audioProcessor.startRecordingLive(inputDeviceID: nil) { _ in }
        engineRunning = true
        captureEventsSubject.send(.captureStarted)
    }

    /// Per-trial re-arm on a live engine: trim history to at most one transcription window and
    /// mark it consumed, so this trial listens "from now" without an engine rebuild (and its
    /// startup latency + audio-session churn against the live ARKit camera).
    private func armOnLiveEngine(_ kit: WhisperKit) {
        let keep = Int(realtimeTranscriptionWindowSeconds * Float(WhisperKit.sampleRate))
        kit.audioProcessor.purgeAudioSamples(keepingLast: keep)
        lastObservedSampleCount = kit.audioProcessor.audioSamples.count
        isRunningInference = false
        consecutiveTranscribeErrors = 0
    }

    /// Polls the rolling window until a letter is classified, a structural failure surfaces, the
    /// trial is cancelled, or the timeout flush takes over. Runs off the main actor (WhisperKit
    /// `await`s); `finish` hops back to main.
    private func runCaptureLoop(_ kit: WhisperKit, generation: Int) async {
        while !Task.isCancelled {
            if let outcome = await processWindow(kit, isFinal: false) {
                switch outcome {
                case .letter, .serviceFailure:
                    finish(outcome, generation: generation)
                    return
                case .ambiguous, .unrecognized:
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Transcribes the current rolling window (or, when `isFinal`, the pending tail) and classifies it.
    /// Returns `.letter` only when a single clean Sloan letter is found; otherwise nil (keep listening),
    /// except when `isFinal` where `.ambiguous`/`.unrecognized` are returned as the final answer.
    private func processWindow(_ kit: WhisperKit, isFinal: Bool) async -> RecognitionOutcome? {
        guard !isRunningInference else { return nil }

        let fullBuffer = Array(kit.audioProcessor.audioSamples)
        guard !fullBuffer.isEmpty else { return isFinal ? .unrecognized(.silence) : nil }

        let maxWindowSamples = Int(realtimeTranscriptionWindowSeconds * Float(WhisperKit.sampleRate))
        let consumed = min(lastObservedSampleCount, fullBuffer.count)
        let startIndex = max(consumed, fullBuffer.count - maxWindowSamples)
        let window = Array(fullBuffer[startIndex...])

        let newSampleCount = fullBuffer.count - lastObservedSampleCount
        let newBufferSeconds = Float(max(newSampleCount, 0)) / Float(WhisperKit.sampleRate)

        if isFinal {
            guard newBufferSeconds >= minimumFinalBufferSeconds else { return .unrecognized(.silence) }
        } else {
            guard newBufferSeconds >= minimumRealtimeBufferSeconds else { return nil }
            let voiceDetected = AudioProcessor.isVoiceDetected(
                in: kit.audioProcessor.relativeEnergy,
                nextBufferInSeconds: newBufferSeconds,
                silenceThreshold: silenceThreshold)
            guard voiceDetected else { return nil }
        }

        isRunningInference = true
        defer { isRunningInference = false }

        let transcript: String
        do {
            transcript = try await transcribe(kit, samples: window)
            consecutiveTranscribeErrors = 0
        } catch {
            // Do NOT advance the consumed pointer: the audio stays for the next pass. Three
            // consecutive throws is a broken capture pipeline, not a quiet child.
            consecutiveTranscribeErrors += 1
            if consecutiveTranscribeErrors >= 3 {
                return .serviceFailure(.audioCaptureFailed(error.localizedDescription))
            }
            return isFinal ? .unrecognized(.silence) : nil
        }
        // A trial superseded mid-inference must not mutate the pointer state the NEXT trial
        // will arm with.
        if Task.isCancelled, !isFinal { return nil }
        // Advance the consumed pointer only when this pass actually produced text (or is the
        // final flush). An empty transcription keeps the audio, so an utterance straddling a
        // poll boundary never loses its onset (gold-standard rule).
        if isFinal || !transcript.isEmpty {
            lastObservedSampleCount = fullBuffer.count
        }

        let outcome = classify(transcript)
        if isFinal { return outcome }
        // While listening, only a clean single letter ends the trial; ambiguity keeps listening.
        if case .letter = outcome { return outcome }
        return nil
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

    // MARK: - Timeout + completion

    private func scheduleTimeout(_ timeout: TimeInterval, generation: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, !self.didComplete else { return }
            Task { [weak self] in await self?.flushAndFinish(generation: generation) }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// On timeout, stop the poll loop and do one final transcription of pending audio.
    private func flushAndFinish(generation: Int) async {
        guard self.generation == generation, !didComplete else { return }
        captureTask?.cancel()
        captureTask = nil

        // The poll loop may be suspended inside an inference right now; the final pass would
        // bounce off the isRunningInference guard and misreport a real answer as silence. Wait
        // (bounded) for it to drain before flushing.
        var waited: TimeInterval = 0
        while isRunningInference, waited < 2.0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        guard self.generation == generation, !didComplete else { return }

        var outcome: RecognitionOutcome = .unrecognized(.silence)
        if let kit = whisperKit {
            outcome = await processWindow(kit, isFinal: true) ?? .unrecognized(.silence)
        }
        finish(outcome, generation: generation)
    }

    /// The single point that delivers an outcome. Guards against double-fire and superseded trials,
    /// tears down capture, and dispatches the handler on the main thread (so the coordinator's
    /// `MainActor.assumeIsolated` in its recognition callback is satisfied).
    private func finish(_ outcome: RecognitionOutcome, generation: Int) {
        guard !didComplete, generation == self.generation else { return }
        didComplete = true
        let handler = completion
        cancel()
        DispatchQueue.main.async { handler?(outcome) }
    }
}

// MARK: - ContinuousCaptureControlling

extension WhisperKitLetterRecognitionService: ContinuousCaptureControlling {
    var captureEvents: AnyPublisher<CaptureEvent, Never> {
        captureEventsSubject.eraseToAnyPublisher()
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
            guard let kit = try? await self.ensureModelReady(),
                  self.captureSessionActive, !self.engineRunning else { return }
            do {
                try self.startRecording(kit)
            } catch {
                self.captureEventsSubject.send(.failed(.audioCaptureFailed(error.localizedDescription)))
            }
        }
    }

    /// Hard stop: engine down, observers removed. Called at block boundaries, on background,
    /// on escalation, and at teardown.
    func endCaptureSession() {
        captureSessionActive = false
        unregisterAudioObservers()
        whisperKit?.audioProcessor.stopRecording()
        engineRunning = false
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

    /// A phone call / Siri / alarm mid-trial: stop the engine on `.began`; on `.ended` restart it
    /// when allowed and let the coordinator re-arm the current letter.
    private func handleAudioInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            whisperKit?.audioProcessor.stopRecording()
            engineRunning = false
            captureEventsSubject.send(.interruptionBegan)
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                .contains(.shouldResume)
            if captureSessionActive, shouldResume, let kit = whisperKit {
                try? startRecording(kit)
            }
            captureEventsSubject.send(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    /// Headphones/AirPods attached or detached: a fresh engine binds the new route.
    private func handleRouteChange(_ note: Notification) {
        guard captureSessionActive,
              let info = note.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            whisperKit?.audioProcessor.stopRecording()
            engineRunning = false
            if let kit = whisperKit {
                try? startRecording(kit)
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
