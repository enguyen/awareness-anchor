import Foundation

enum ResponseType: String, Codable, CaseIterable {
    case present = "present"       // Was already in open awareness
    case returned = "returned"     // Had to come back from distraction
    case missed = "missed"         // No response within window

    var displayName: String {
        switch self {
        case .present: return "Already Present"
        case .returned: return "Returned"
        case .missed: return "Missed"
        }
    }

    var emoji: String {
        switch self {
        case .present: return "🧘"
        case .returned: return "🔔"
        case .missed: return "💤"
        }
    }
}

struct ChimeEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let responseType: ResponseType
    let responseTimeMs: Int?  // nil if missed
    let sessionId: UUID

    init(id: UUID = UUID(), timestamp: Date = Date(), responseType: ResponseType, responseTimeMs: Int? = nil, sessionId: UUID) {
        self.id = id
        self.timestamp = timestamp
        self.responseType = responseType
        self.responseTimeMs = responseTimeMs
        self.sessionId = sessionId
    }
}
