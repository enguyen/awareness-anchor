import Foundation
import Combine
import AppKit

class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Published Properties
    @Published var isPlaying = false
    @Published var averageIntervalSeconds: Double = 150
    @Published var responseWindowSeconds: Double = 10
    @Published var currentSession: Session?
    @Published var isInResponseWindow = false
    @Published var responseWindowRemainingSeconds: Double = 0
    @Published var isInCorrectionWindow = false
    @Published var correctionWindowRemainingSeconds: Double = 0
    @Published var lastChimeTime: Date?
    @Published var todayStats: DayStats = DayStats()
    @Published var lastRecordedEvent: ChimeEvent?
    @Published var statsNeedRefresh: UUID = UUID()  // Changes to trigger stats refresh

    // MARK: - Services
    private let chimeScheduler: ChimeScheduler
    private let audioPlayer: AudioPlayer
    let dataStore: DataStore  // Public for StatsView access
    let inputCoordinator: InputCoordinator  // Unified input handler

    /// Direct access to head pose detector (for calibration UI and backward compatibility)
    var headPoseDetector: HeadPoseDetector {
        inputCoordinator.headPoseDetector
    }

    /// Direct access to mouse edge detector (for calibration UI)
    var mouseEdgeDetector: MouseEdgeDetector {
        inputCoordinator.mouseEdgeDetector
    }

    // MARK: - Callbacks
    var onResponseRecorded: ((ResponseType) -> Void)?

    // MARK: - Private State
    private var cancellables = Set<AnyCancellable>()
    private var responseWindowTimer: Timer?
    private var correctionWindowTimer: Timer?
    private let correctionWindowDuration: Double = 3.0
    private var pendingChimeId: UUID?

    struct DayStats {
        var presentCount: Int = 0
        var returnedCount: Int = 0
        var missedCount: Int = 0

        var total: Int { presentCount + returnedCount + missedCount }

        var awarenessRatio: Double {
            guard total > 0 else { return 0 }
            return Double(presentCount + returnedCount) / Double(total)
        }

        var qualityRatio: Double {
            let responded = presentCount + returnedCount
            guard responded > 0 else { return 0 }
            return Double(presentCount) / Double(responded)
        }
    }

    private init() {
        self.chimeScheduler = ChimeScheduler()
        self.audioPlayer = AudioPlayer()
        self.dataStore = DataStore()
        self.inputCoordinator = InputCoordinator()

        setupBindings()
    }

    func initialize() {
        dataStore.initialize()
        loadTodayStats()
        loadSettings()
    }

    private func setupBindings() {
        // When chime scheduler fires
        chimeScheduler.onChime = { [weak self] in
            self?.handleChime()
        }

        // Unified input detection (head pose and/or mouse edge)
        inputCoordinator.onPoseDetected = { [weak self] pose in
            guard let self = self else { return }

            // Correction window: the opposite gesture swaps the just-recorded response.
            // (HeadPoseDetector/MouseEdgeDetector already filter same-pose triggers, but
            // we also gate here in case any callback slips through.)
            if self.isInCorrectionWindow {
                switch pose {
                case .tiltUp:
                    self.swapLastResponse(to: .present)
                case .turnLeftRight:
                    self.swapLastResponse(to: .returned)
                case .neutral:
                    break
                }
                return
            }

            guard self.isInResponseWindow else { return }
            switch pose {
            case .tiltUp:
                self.recordResponse(.present)
            case .turnLeftRight:
                self.recordResponse(.returned)
            case .neutral:
                break
            }
        }
    }

    // MARK: - Public Methods

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        appLog("[AppState] play() called", category: "AppState")
        isPlaying = true
        currentSession = Session(avgIntervalSeconds: averageIntervalSeconds)

        // Save session immediately so chime events can reference it (foreign key constraint)
        if let session = currentSession {
            appLog("[AppState] Saving new session: \(session.id.uuidString)", category: "AppState")
            dataStore.saveSession(session)
        }

        chimeScheduler.start(averageIntervalSeconds: averageIntervalSeconds)

        // Start input detection (coordinator handles which inputs are enabled)
        inputCoordinator.startDetection()
    }

    func pause() {
        isPlaying = false
        chimeScheduler.stop()
        inputCoordinator.stopDetection()
        if isInCorrectionWindow {
            endCorrectionWindow()
        } else {
            endResponseWindow(responded: false)
        }
        endSession()
    }

    // MARK: - Sleep/Wake Handling

    func handleSleep() {
        guard isPlaying else { return }

        print("[AppState] System going to sleep - pausing session")

        // Pause chime timer (don't stop - session continues)
        chimeScheduler.pause()

        // Stop tracking and end response/correction window if active
        if isInCorrectionWindow {
            endCorrectionWindow()
        } else if isInResponseWindow {
            endResponseWindow(responded: false)
        }
        inputCoordinator.deactivateWindow()
    }

    func handleWake() {
        guard isPlaying else { return }

        print("[AppState] System woke up - resuming session")

        // Resume chime timer
        chimeScheduler.resume()

        // Re-enable input detection
        inputCoordinator.startDetection()
    }

    func endSession() {
        guard var session = currentSession else { return }
        session.endTime = Date()
        dataStore.saveSession(session)
        currentSession = nil
    }

    func recordResponse(_ type: ResponseType) {
        appLog("[AppState] recordResponse called: \(type)", category: "AppState")

        guard isInResponseWindow, let sessionId = currentSession?.id, let chimeTime = lastChimeTime else {
            appLog("[AppState] recordResponse guard failed - isInResponseWindow=\(isInResponseWindow), sessionId=\(currentSession?.id.uuidString ?? "nil"), chimeTime=\(lastChimeTime?.description ?? "nil")", category: "AppState")
            return
        }

        let responseTimeMs = Int(Date().timeIntervalSince(chimeTime) * 1000)
        let event = ChimeEvent(
            responseType: type,
            responseTimeMs: responseTimeMs,
            sessionId: sessionId
        )

        appLog("[AppState] Calling dataStore.saveChimeEvent", category: "AppState")
        dataStore.saveChimeEvent(event)
        lastRecordedEvent = event
        updateTodayStats(with: type)

        // Stop the response window countdown — a response has been recorded.
        // Detector stays live; correction window opens to allow a hands-free swap.
        responseWindowTimer?.invalidate()
        responseWindowTimer = nil
        isInResponseWindow = false
        responseWindowRemainingSeconds = 0

        // Visual/audio feedback
        provideFeedback(for: type)

        enterCorrectionWindow(after: type)
    }

    func updateInterval(_ seconds: Double) {
        averageIntervalSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "averageIntervalSeconds")

        if isPlaying {
            chimeScheduler.updateInterval(averageIntervalSeconds: seconds)
        }
    }

    func updateResponseWindow(_ seconds: Double) {
        responseWindowSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "responseWindowSeconds")
    }

    func correctLastResponse(_ newType: ResponseType) {
        guard var event = lastRecordedEvent, event.responseType != newType else { return }

        let oldType = event.responseType
        dataStore.updateChimeEventType(eventId: event.id, newType: newType)

        // Update in-memory event
        if event.originalResponseType == nil {
            event.originalResponseType = oldType
        }
        event.responseType = newType
        event.correctedAt = Date()
        lastRecordedEvent = event

        // Adjust todayStats if the event is from today
        let calendar = Calendar.current
        if calendar.isDateInToday(event.timestamp) {
            adjustTodayStats(removing: oldType, adding: newType)
        }

        statsNeedRefresh = UUID()
    }

    private func adjustTodayStats(removing oldType: ResponseType, adding newType: ResponseType) {
        switch oldType {
        case .present: todayStats.presentCount = max(0, todayStats.presentCount - 1)
        case .returned: todayStats.returnedCount = max(0, todayStats.returnedCount - 1)
        case .missed: todayStats.missedCount = max(0, todayStats.missedCount - 1)
        }
        switch newType {
        case .present: todayStats.presentCount += 1
        case .returned: todayStats.returnedCount += 1
        case .missed: todayStats.missedCount += 1
        }
    }

    // MARK: - Private Methods

    /// How long to wait for face detection before skipping a chime (seconds)
    private let faceDetectionTimeout: TimeInterval = 3.0

    private func handleChime() {
        // Block if already in response/correction window or chime audio still playing
        guard !isInResponseWindow, !isInCorrectionWindow, !audioPlayer.isChimePlaying else {
            appLog("[AppState] Chime blocked - response window active: \(isInResponseWindow), correction window active: \(isInCorrectionWindow), audio playing: \(audioPlayer.isChimePlaying)", category: "AppState")
            return
        }

        let headPoseEnabled = UserDefaults.standard.bool(forKey: "headPoseEnabled")

        if headPoseEnabled {
            // Wait for face detection before playing chime
            appLog("[AppState] Chime pending - waiting for face detection", category: "AppState")
            headPoseDetector.checkForFace(timeout: faceDetectionTimeout) { [weak self] faceDetected in
                guard let self = self else { return }
                if faceDetected {
                    appLog("[AppState] Face detected - proceeding with chime", category: "AppState")
                    self.proceedWithChime()
                } else {
                    appLog("[AppState] No face detected - skipping chime", category: "AppState")
                }
            }
        } else {
            proceedWithChime()
        }
    }

    private func proceedWithChime() {
        lastChimeTime = Date()
        pendingChimeId = UUID()
        audioPlayer.playRandomChime()
        startResponseWindow()
    }

    private func startResponseWindow() {
        isInResponseWindow = true
        responseWindowRemainingSeconds = responseWindowSeconds

        // Start countdown timer
        responseWindowTimer?.invalidate()
        responseWindowTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            // Pause countdown while user is mid-gesture (any edge glow showing).
            // Window stays open until they finish — even if the timer would have hit 0.
            if self.isRegisteringFeedback {
                return
            }

            self.responseWindowRemainingSeconds -= 0.1

            if self.responseWindowRemainingSeconds <= 0 {
                self.endResponseWindow(responded: false)
            }
        }

        // Activate input tracking for this response window
        inputCoordinator.activateForWindow()
    }

    // True when any edge intensity is high enough that the user appears to be
    // actively attempting a gesture. Matches the practical visibility floor of
    // the screen-edge glow.
    private var isRegisteringFeedback: Bool {
        let threshold: Float = 0.05
        return inputCoordinator.topIntensity > threshold ||
               inputCoordinator.leftIntensity > threshold ||
               inputCoordinator.rightIntensity > threshold
    }

    // MARK: - Correction Window

    /// After a response is recorded, keep the detector live for a few seconds.
    /// Only the opposite gesture is accepted, and its trigger swaps the recorded response.
    private func enterCorrectionWindow(after recorded: ResponseType) {
        let opposite: HeadPose
        switch recorded {
        case .present:
            opposite = .turnLeftRight
        case .returned:
            opposite = .tiltUp
        case .missed:
            // Missed responses don't pass through here, but keep the function total.
            return
        }

        isInCorrectionWindow = true
        correctionWindowRemainingSeconds = correctionWindowDuration
        inputCoordinator.beginCorrectionMode(allowedPose: opposite)

        correctionWindowTimer?.invalidate()
        correctionWindowTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            // Pause countdown while the user is mid-gesture, same as the main response window.
            if self.isRegisteringFeedback {
                return
            }

            self.correctionWindowRemainingSeconds -= 0.1
            if self.correctionWindowRemainingSeconds <= 0 {
                self.endCorrectionWindow()
            }
        }
    }

    private func endCorrectionWindow() {
        correctionWindowTimer?.invalidate()
        correctionWindowTimer = nil
        isInCorrectionWindow = false
        correctionWindowRemainingSeconds = 0
        inputCoordinator.endCorrectionMode()
        // Final teardown: stop detector/camera as if the response window had just closed.
        endResponseWindow(responded: true)
    }

    private func swapLastResponse(to newType: ResponseType) {
        appLog("[AppState] Correction swap to \(newType)", category: "AppState")
        correctLastResponse(newType)
        provideFeedback(for: newType)
        endCorrectionWindow()
    }

    private func endResponseWindow(responded: Bool) {
        responseWindowTimer?.invalidate()
        responseWindowTimer = nil
        isInResponseWindow = false
        responseWindowRemainingSeconds = 0

        // Check if user was present (face detected) before deactivating
        // Note: With mouse tracking, user is always considered present
        let headPoseEnabled = UserDefaults.standard.bool(forKey: "headPoseEnabled")
        let mouseEnabled = UserDefaults.standard.bool(forKey: "mouseTrackingEnabled")
        let userWasPresent = mouseEnabled || !headPoseEnabled || inputCoordinator.faceWasDetectedThisWindow

        inputCoordinator.deactivateWindow()

        // If no response, record as missed - but only if user was actually present
        // (if head pose is enabled and no face detected, user was away from device)
        if !responded, let sessionId = currentSession?.id {
            if userWasPresent {
                let event = ChimeEvent(
                    responseType: .missed,
                    responseTimeMs: nil,
                    sessionId: sessionId
                )
                dataStore.saveChimeEvent(event)
                lastRecordedEvent = event
                updateTodayStats(with: .missed)
            } else {
                print("[AppState] No face detected during window - skipping missed event (user away)")
            }
        }

        pendingChimeId = nil
    }

    private func updateTodayStats(with type: ResponseType) {
        switch type {
        case .present:
            todayStats.presentCount += 1
        case .returned:
            todayStats.returnedCount += 1
        case .missed:
            todayStats.missedCount += 1
        }
        // Trigger stats refresh for any listening views
        appLog("[AppState] Triggering statsNeedRefresh", category: "AppState")
        statsNeedRefresh = UUID()
    }

    private func loadTodayStats() {
        let events = dataStore.getEventsForToday()
        todayStats = DayStats(
            presentCount: events.filter { $0.responseType == .present }.count,
            returnedCount: events.filter { $0.responseType == .returned }.count,
            missedCount: events.filter { $0.responseType == .missed }.count
        )
        lastRecordedEvent = dataStore.getLastEvent()
    }

    private func loadSettings() {
        if UserDefaults.standard.object(forKey: "averageIntervalSeconds") != nil {
            averageIntervalSeconds = UserDefaults.standard.double(forKey: "averageIntervalSeconds")
        }
        if UserDefaults.standard.object(forKey: "responseWindowSeconds") != nil {
            responseWindowSeconds = UserDefaults.standard.double(forKey: "responseWindowSeconds")
        }
    }

    private func provideFeedback(for type: ResponseType) {
        // Play system alert sound if enabled
        if UserDefaults.standard.bool(forKey: "playSystemSoundOnTrigger") {
            NSSound.beep()
        }

        // Notify listeners (AppDelegate handles visual feedback)
        onResponseRecorded?(type)
    }
}
