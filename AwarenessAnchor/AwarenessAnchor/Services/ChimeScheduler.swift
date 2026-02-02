import Foundation

class ChimeScheduler {
    var onChime: (() -> Void)?

    private var timer: Timer?
    private var averageIntervalSeconds: Double = 150
    private var isRunning = false

    func start(averageIntervalSeconds: Double) {
        self.averageIntervalSeconds = averageIntervalSeconds
        isRunning = true
        scheduleNextChime()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func updateInterval(averageIntervalSeconds: Double) {
        self.averageIntervalSeconds = averageIntervalSeconds
        // Reschedule with new interval
        if isRunning {
            scheduleNextChime()
        }
    }

    private func scheduleNextChime() {
        timer?.invalidate()

        guard isRunning else { return }

        // Random factor between 0.5 and 1.5 (centered on average)
        let randomFactor = 0.5 + Double.random(in: 0...1)
        let actualInterval = max(1.0, averageIntervalSeconds * randomFactor)

        timer = Timer.scheduledTimer(withTimeInterval: actualInterval, repeats: false) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.onChime?()
            self.scheduleNextChime()
        }

        // Ensure timer fires even when menu is open
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
