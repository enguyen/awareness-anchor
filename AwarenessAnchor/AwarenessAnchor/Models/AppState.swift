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

    // MARK: - Services
    private let chimeScheduler: ChimeScheduler
    private let audioPlayer: AudioPlayer
    private let dataStore: DataStore
    let headPoseDetector: HeadPoseDetector  // Public for debug UI access

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
        self.headPoseDetector = HeadPoseDetector()

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

        // Head pose detection
        headPoseDetector.onPoseDetected = { [weak self] pose in
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
        isPlaying = true
        currentSession = Session(avgIntervalSeconds: averageIntervalSeconds)
        chimeScheduler.start(averageIntervalSeconds: averageIntervalSeconds)

        if UserDefaults.standard.bool(forKey: "headPoseEnabled") {
            headPoseDetector.startDetection()
        }
    }

    func pause() {
        isPlaying = false
        chimeScheduler.stop()
        headPoseDetector.stopDetection()
        endResponseWindow(responded: false)
        endSession()
    }

    func endSession() {
        guard var session = currentSession else { return }
        session.endTime = Date()
        dataStore.saveSession(session)
        currentSession = nil
    }

    func recordResponse(_ type: ResponseType) {
        guard isInResponseWindow, let sessionId = currentSession?.id, let chimeTime = lastChimeTime else {
            return
        }

        let responseTimeMs = Int(Date().timeIntervalSince(chimeTime) * 1000)
        let event = ChimeEvent(
            responseType: type,
            responseTimeMs: responseTimeMs,
            sessionId: sessionId
        )

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

        // Activate camera for head pose if enabled
        if UserDefaults.standard.bool(forKey: "headPoseEnabled") {
            headPoseDetector.activateForWindow()
        }
    }

    private func endResponseWindow(responded: Bool) {
        responseWindowTimer?.invalidate()
        responseWindowTimer = nil
        isInResponseWindow = false
        responseWindowRemainingSeconds = 0

        headPoseDetector.deactivateWindow()

        // If no response, record as missed
        if !responded, let sessionId = currentSession?.id {
            let event = ChimeEvent(
                responseType: .missed,
                responseTimeMs: nil,
                sessionId: sessionId
            )
            dataStore.saveChimeEvent(event)
            updateTodayStats(with: .missed)
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
        // Could add haptic feedback or subtle audio confirmation
        // For now, the UI update provides visual feedback
    }
}
