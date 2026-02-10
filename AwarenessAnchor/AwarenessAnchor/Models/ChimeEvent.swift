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
    var responseType: ResponseType
    let responseTimeMs: Int?  // nil if missed
    let sessionId: UUID
    var originalResponseType: ResponseType?  // non-nil if corrected (stores pre-correction type)
    var correctedAt: Date?                   // when the correction was made

    var wasCorrected: Bool { originalResponseType != nil }

    init(id: UUID = UUID(), timestamp: Date = Date(), responseType: ResponseType, responseTimeMs: Int? = nil, sessionId: UUID, originalResponseType: ResponseType? = nil, correctedAt: Date? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.responseType = responseType
        self.responseTimeMs = responseTimeMs
        self.sessionId = sessionId
        self.originalResponseType = originalResponseType
        self.correctedAt = correctedAt
    }
}
