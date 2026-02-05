import Foundation
import Combine

class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Published Properties
    @Published var isPlaying = false
    @Published var averageIntervalSeconds: Double = 150
    @Published var responseWindowSeconds: Double = 10
    @Published var currentSession: Session?
    @Published var isInResponseWindow = false
    @Published var responseWindowRemainingSeconds: Double = 0
    @Published var lastChimeTime: Date?
    @Published var todayStats: DayStats = DayStats()
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
            guard let self = self, self.isInResponseWindow else { return }
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
        endResponseWindow(responded: false)
        endSession()
    }

    // MARK: - Sleep/Wake Handling

    func handleSleep() {
        guard isPlaying else { return }

        print("[AppState] System going to sleep - pausing session")

        // Pause chime timer (don't stop - session continues)
        chimeScheduler.pause()

        // Stop tracking and end response window if active
        if isInResponseWindow {
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
        updateTodayStats(with: type)
        endResponseWindow(responded: true)

        // Visual/audio feedback
        provideFeedback(for: type)
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

    // MARK: - Private Methods

    private func handleChime() {
        // Block if already in response window or chime audio still playing
        guard !isInResponseWindow, !audioPlayer.isChimePlaying else {
            appLog("[AppState] Chime blocked - response window active: \(isInResponseWindow), audio playing: \(audioPlayer.isChimePlaying)", category: "AppState")
            return
        }

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

            self.responseWindowRemainingSeconds -= 0.1

            if self.responseWindowRemainingSeconds <= 0 {
                self.endResponseWindow(responded: false)
            }
        }

        // Activate input tracking for this response window
        inputCoordinator.activateForWindow()
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
        // Notify listeners (AppDelegate handles visual feedback)
        onResponseRecorded?(type)
    }
}
