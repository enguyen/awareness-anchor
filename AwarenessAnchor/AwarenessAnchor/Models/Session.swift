import Foundation

struct Session: Identifiable, Codable {
    let id: UUID
    let startTime: Date
    var endTime: Date?
    let avgIntervalSeconds: Double

    init(id: UUID = UUID(), startTime: Date = Date(), endTime: Date? = nil, avgIntervalSeconds: Double) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.avgIntervalSeconds = avgIntervalSeconds
    }

    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    var formattedDuration: String {
        guard let dur = duration else { return "In progress" }
        let minutes = Int(dur) / 60
        let seconds = Int(dur) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
