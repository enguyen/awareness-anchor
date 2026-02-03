import Foundation

class ChimeScheduler {
    var onChime: (() -> Void)?

    private var timer: Timer?
    private var averageIntervalSeconds: Double = 150
    private var isRunning = false
    private var isPaused = false

    // Sleep/wake tracking
    private var scheduledFireTime: Date?
    private var remainingTimeOnPause: Double?

    func start(averageIntervalSeconds: Double) {
        self.averageIntervalSeconds = averageIntervalSeconds
        isRunning = true
        isPaused = false
        remainingTimeOnPause = nil
        scheduleNextChime()
    }

    func stop() {
        isRunning = false
        isPaused = false
        timer?.invalidate()
        timer = nil
        scheduledFireTime = nil
        remainingTimeOnPause = nil
    }

    func updateInterval(averageIntervalSeconds: Double) {
        self.averageIntervalSeconds = averageIntervalSeconds
        // Reschedule with new interval
        if isRunning && !isPaused {
            scheduleNextChime()
        }
    }

    // MARK: - Pause/Resume for Sleep/Wake

    func pause() {
        guard isRunning, !isPaused else { return }

        isPaused = true

        // Calculate remaining time until next chime
        if let fireTime = scheduledFireTime {
            remainingTimeOnPause = max(0, fireTime.timeIntervalSinceNow)
        }

        timer?.invalidate()
        timer = nil

        print("[ChimeScheduler] Paused. Remaining time: \(remainingTimeOnPause ?? 0) seconds")
    }

    func resume() {
        guard isRunning, isPaused else { return }

        isPaused = false

        // Resume with remaining time, or schedule new chime if no remaining time
        if let remaining = remainingTimeOnPause, remaining > 0 {
            print("[ChimeScheduler] Resuming with \(remaining) seconds remaining")
            scheduleChime(interval: remaining)
        } else {
            print("[ChimeScheduler] Resuming with new random interval")
            scheduleNextChime()
        }

        remainingTimeOnPause = nil
    }

    private func scheduleNextChime() {
        timer?.invalidate()

        guard isRunning, !isPaused else { return }

        // Random factor between 0.5 and 1.5 (centered on average)
        let randomFactor = 0.5 + Double.random(in: 0...1)
        let actualInterval = max(1.0, averageIntervalSeconds * randomFactor)

        scheduleChime(interval: actualInterval)
    }

    private func scheduleChime(interval: Double) {
        timer?.invalidate()

        guard isRunning, !isPaused else { return }

        scheduledFireTime = Date().addingTimeInterval(interval)

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self, self.isRunning, !self.isPaused else { return }
            self.onChime?()
            self.scheduleNextChime()
        }

        // Ensure timer fires even when menu is open
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
