import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to make its own copy of the string
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

class DataStore {
    private var db: OpaquePointer?
    private let dbPath: String

    init() {
        // Store database in Application Support directory
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("AwarenessAnchor", isDirectory: true)

        // Create directory if needed
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)

        dbPath = appDir.appendingPathComponent("awareness.db").path
    }

    func initialize() {
        appLog("[DataStore] Initializing database at: \(dbPath)", category: "DataStore")

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            appLog("[DataStore] ERROR: Failed to open database", category: "DataStore")
            return
        }

        appLog("[DataStore] Database opened successfully", category: "DataStore")
        createTables()
    }

    private func createTables() {
        let createSessionsTable = """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                start_time REAL NOT NULL,
                end_time REAL,
                avg_interval_seconds REAL NOT NULL
            );
        """

        let createEventsTable = """
            CREATE TABLE IF NOT EXISTS chime_events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                response_type TEXT NOT NULL,
                response_time_ms INTEGER,
                session_id TEXT NOT NULL,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            );
        """

        let createEventsIndex = """
            CREATE INDEX IF NOT EXISTS idx_events_timestamp ON chime_events(timestamp);
        """

        executeSQL(createSessionsTable)
        executeSQL(createEventsTable)
        executeSQL(createEventsIndex)
    }

    private func executeSQL(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("SQL Error: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    // MARK: - Session Operations

    func saveSession(_ session: Session) {
        appLog("[DataStore] saveSession called: \(session.id.uuidString)", category: "DataStore")

        // Ensure database is initialized
        if db == nil {
            appLog("[DataStore] db was nil in saveSession, initializing...", category: "DataStore")
            initialize()
        }

        let sql = """
            INSERT OR REPLACE INTO sessions (id, start_time, end_time, avg_interval_seconds)
            VALUES (?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            appLog("[DataStore] ERROR: Failed to prepare saveSession statement", category: "DataStore")
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, session.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, session.startTime.timeIntervalSince1970)
        if let endTime = session.endTime {
            sqlite3_bind_double(statement, 3, endTime.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_double(statement, 4, session.avgIntervalSeconds)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            appLog("[DataStore] SUCCESS: Saved session: \(session.id.uuidString)", category: "DataStore")
        } else {
            appLog("[DataStore] ERROR: Failed to save session, result=\(result)", category: "DataStore")
        }
    }

    func getSessions(limit: Int = 100) -> [Session] {
        let sql = "SELECT id, start_time, end_time, avg_interval_seconds FROM sessions ORDER BY start_time DESC LIMIT ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var sessions: [Session] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let idString = String(cString: sqlite3_column_text(statement, 0))
            let startTime = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let endTime: Date? = sqlite3_column_type(statement, 2) != SQLITE_NULL
                ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                : nil
            let avgInterval = sqlite3_column_double(statement, 3)

            if let id = UUID(uuidString: idString) {
                sessions.append(Session(
                    id: id,
                    startTime: startTime,
                    endTime: endTime,
                    avgIntervalSeconds: avgInterval
                ))
            }
        }

        return sessions
    }

    // MARK: - Chime Event Operations

    func saveChimeEvent(_ event: ChimeEvent) {
        appLog("[DataStore] saveChimeEvent called: \(event.responseType.rawValue), sessionId=\(event.sessionId.uuidString)", category: "DataStore")

        // Ensure database is initialized
        if db == nil {
            appLog("[DataStore] db was nil, initializing...", category: "DataStore")
            initialize()
        }

        let sql = """
            INSERT INTO chime_events (id, timestamp, response_type, response_time_ms, session_id)
            VALUES (?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            appLog("[DataStore] ERROR: Failed to prepare statement for saveChimeEvent", category: "DataStore")
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, event.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, event.responseType.rawValue, -1, SQLITE_TRANSIENT)
        if let responseTime = event.responseTimeMs {
            sqlite3_bind_int(statement, 4, Int32(responseTime))
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_text(statement, 5, event.sessionId.uuidString, -1, SQLITE_TRANSIENT)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            appLog("[DataStore] SUCCESS: Saved chime event: \(event.responseType.rawValue)", category: "DataStore")
        } else {
            appLog("[DataStore] ERROR: Failed to save chime event, result=\(result)", category: "DataStore")
        }
    }

    func getEventsForToday() -> [ChimeEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        return getEvents(from: startOfDay, to: endOfDay)
    }

    func getEvents(from startDate: Date, to endDate: Date) -> [ChimeEvent] {
        let sql = """
            SELECT id, timestamp, response_type, response_time_ms, session_id
            FROM chime_events
            WHERE timestamp >= ? AND timestamp < ?
            ORDER BY timestamp DESC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, startDate.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, endDate.timeIntervalSince1970)

        var events: [ChimeEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let idString = String(cString: sqlite3_column_text(statement, 0))
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let responseTypeString = String(cString: sqlite3_column_text(statement, 2))
            let responseTimeMs: Int? = sqlite3_column_type(statement, 3) != SQLITE_NULL
                ? Int(sqlite3_column_int(statement, 3))
                : nil
            let sessionIdString = String(cString: sqlite3_column_text(statement, 4))

            if let id = UUID(uuidString: idString),
               let responseType = ResponseType(rawValue: responseTypeString),
               let sessionId = UUID(uuidString: sessionIdString) {
                events.append(ChimeEvent(
                    id: id,
                    timestamp: timestamp,
                    responseType: responseType,
                    responseTimeMs: responseTimeMs,
                    sessionId: sessionId
                ))
            }
        }

        return events
    }

    func getEventsForSession(_ sessionId: UUID) -> [ChimeEvent] {
        let sql = """
            SELECT id, timestamp, response_type, response_time_ms, session_id
            FROM chime_events
            WHERE session_id = ?
            ORDER BY timestamp ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, sessionId.uuidString, -1, SQLITE_TRANSIENT)

        var events: [ChimeEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let idString = String(cString: sqlite3_column_text(statement, 0))
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let responseTypeString = String(cString: sqlite3_column_text(statement, 2))
            let responseTimeMs: Int? = sqlite3_column_type(statement, 3) != SQLITE_NULL
                ? Int(sqlite3_column_int(statement, 3))
                : nil
            let sessionIdStr = String(cString: sqlite3_column_text(statement, 4))

            if let id = UUID(uuidString: idString),
               let responseType = ResponseType(rawValue: responseTypeString),
               let sessId = UUID(uuidString: sessionIdStr) {
                events.append(ChimeEvent(
                    id: id,
                    timestamp: timestamp,
                    responseType: responseType,
                    responseTimeMs: responseTimeMs,
                    sessionId: sessId
                ))
            }
        }

        return events
    }

    // MARK: - Analytics

    func getStats(for period: StatsPeriod) -> StatsData {
        appLog("[DataStore] getStats called for period: \(period)", category: "DataStore")

        // Ensure database is initialized
        if db == nil {
            appLog("[DataStore] db was nil in getStats, initializing...", category: "DataStore")
            initialize()
        }

        let (startDate, endDate) = period.dateRange
        appLog("[DataStore] Date range: \(startDate) to \(endDate)", category: "DataStore")

        let events = getEvents(from: startDate, to: endDate)

        let presentCount = events.filter { $0.responseType == .present }.count
        let returnedCount = events.filter { $0.responseType == .returned }.count
        let missedCount = events.filter { $0.responseType == .missed }.count

        let responseTimes = events.compactMap { $0.responseTimeMs }
        let avgResponseTime = responseTimes.isEmpty ? 0 : responseTimes.reduce(0, +) / responseTimes.count

        appLog("[DataStore] getStats result: \(events.count) events (present=\(presentCount), returned=\(returnedCount), missed=\(missedCount))", category: "DataStore")

        return StatsData(
            presentCount: presentCount,
            returnedCount: returnedCount,
            missedCount: missedCount,
            averageResponseTimeMs: avgResponseTime,
            totalChimes: events.count
        )
    }

    deinit {
        sqlite3_close(db)
    }
}

enum StatsPeriod {
    case today
    case week
    case month
    case allTime

    var dateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!

        switch self {
        case .today:
            return (calendar.startOfDay(for: now), endOfDay)
        case .week:
            let startOfWeek = calendar.date(byAdding: .day, value: -7, to: now)!
            return (startOfWeek, endOfDay)
        case .month:
            let startOfMonth = calendar.date(byAdding: .month, value: -1, to: now)!
            return (startOfMonth, endOfDay)
        case .allTime:
            return (Date.distantPast, endOfDay)
        }
    }
}

struct StatsData {
    let presentCount: Int
    let returnedCount: Int
    let missedCount: Int
    let averageResponseTimeMs: Int
    let totalChimes: Int

    var awarenessRatio: Double {
        guard totalChimes > 0 else { return 0 }
        return Double(presentCount + returnedCount) / Double(totalChimes)
    }

    var qualityRatio: Double {
        let responded = presentCount + returnedCount
        guard responded > 0 else { return 0 }
        return Double(presentCount) / Double(responded)
    }
}
