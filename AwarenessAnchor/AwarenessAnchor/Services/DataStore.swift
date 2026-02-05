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

// MARK: - Time-in-State Estimation

struct TimeEstimateStats {
    let pointEstimate: Double              // π̂ = present / (present + returned + missed)
    let confidenceInterval: (low: Double, high: Double)  // 95% CI
    let effectiveSampleSize: Double        // n_eff
    let rawSampleSize: Int                 // n
    let autocorrelation: Double            // ρ (estimated from data)
    let totalPracticeTime: TimeInterval    // Sum of session durations

    /// Returns true if we have enough samples for meaningful statistics
    var hasEnoughData: Bool {
        rawSampleSize >= 3
    }

    /// Returns the CI width as a percentage (for display)
    var ciWidth: Double {
        (confidenceInterval.high - confidenceInterval.low) * 100
    }
}

extension DataStore {

    // MARK: - Time Estimate Statistics

    func getTimeEstimateStats(for period: StatsPeriod) -> TimeEstimateStats {
        let (startDate, endDate) = period.dateRange
        let events = getEvents(from: startDate, to: endDate)

        // Sort events by timestamp (chronological order for autocorrelation)
        let sortedEvents = events.sorted { $0.timestamp < $1.timestamp }

        let presentCount = sortedEvents.filter { $0.responseType == .present }.count
        let returnedCount = sortedEvents.filter { $0.responseType == .returned }.count
        let missedCount = sortedEvents.filter { $0.responseType == .missed }.count
        let n = presentCount + returnedCount + missedCount

        // Point estimate: proportion of time in Present state
        // "Present" response means user was aware; "Returned"/"Missed" mean they were absent
        let pointEstimate: Double = n > 0 ? Double(presentCount) / Double(n) : 0

        // Estimate autocorrelation from the sequence of observations
        let rho = estimateAutocorrelation(events: sortedEvents)

        // Effective sample size accounting for autocorrelation
        // n_eff = n × (1 - ρ) / (1 + ρ)
        let effectiveN: Double
        if rho >= 1.0 {
            effectiveN = 1.0  // Prevent division by zero / negative
        } else if rho <= -1.0 {
            effectiveN = Double(n)  // Negative autocorrelation doesn't reduce effective n
        } else {
            effectiveN = max(1.0, Double(n) * (1 - rho) / (1 + rho))
        }

        // Wilson score confidence interval with effective sample size
        let ci = wilsonConfidenceInterval(successes: presentCount, trials: n, effectiveN: effectiveN)

        // Total practice time
        let practiceTime = getTotalPracticeTime(for: period)

        return TimeEstimateStats(
            pointEstimate: pointEstimate,
            confidenceInterval: ci,
            effectiveSampleSize: effectiveN,
            rawSampleSize: n,
            autocorrelation: rho,
            totalPracticeTime: practiceTime
        )
    }

    /// Estimate lag-1 autocorrelation from a sequence of chime events
    /// Binary encoding: Present=1, Absent (Returned OR Missed)=0
    func estimateAutocorrelation(events: [ChimeEvent]) -> Double {
        guard events.count >= 3 else { return 0.0 }

        // Binary encode: Present=1, Absent=0
        let binary: [Double] = events.map { $0.responseType == .present ? 1.0 : 0.0 }
        let n = binary.count

        // Mean
        let mean = binary.reduce(0, +) / Double(n)

        // Variance (sample variance)
        let variance = binary.map { pow($0 - mean, 2) }.reduce(0, +) / Double(n - 1)

        // If variance is zero (all same response), autocorrelation is undefined
        guard variance > 0 else { return 0.0 }

        // Lag-1 autocovariance
        var autocovariance = 0.0
        for i in 0..<(n - 1) {
            autocovariance += (binary[i] - mean) * (binary[i + 1] - mean)
        }
        autocovariance /= Double(n - 1)

        // Autocorrelation
        let rho = autocovariance / variance

        // Clamp to valid range [-1, 1]
        return max(-1.0, min(1.0, rho))
    }

    /// Wilson score confidence interval for a proportion
    /// Uses effectiveN to account for autocorrelation
    func wilsonConfidenceInterval(successes: Int, trials: Int, effectiveN: Double) -> (low: Double, high: Double) {
        guard trials > 0, effectiveN > 0 else { return (0, 1) }

        let p = Double(successes) / Double(trials)
        let z = 1.96  // 95% confidence level
        let z2 = z * z

        // Wilson score interval formula, using effectiveN for variance
        let denominator = 1 + z2 / effectiveN
        let center = (p + z2 / (2 * effectiveN)) / denominator
        let spread = z * sqrt(p * (1 - p) / effectiveN + z2 / (4 * effectiveN * effectiveN)) / denominator

        let low = max(0, center - spread)
        let high = min(1, center + spread)

        return (low, high)
    }

    /// Get total practice time (sum of completed session durations) for a period
    func getTotalPracticeTime(for period: StatsPeriod) -> TimeInterval {
        let (startDate, endDate) = period.dateRange

        let sql = """
            SELECT start_time, end_time
            FROM sessions
            WHERE start_time >= ? AND start_time < ? AND end_time IS NOT NULL;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, startDate.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, endDate.timeIntervalSince1970)

        var totalTime: TimeInterval = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let startTime = sqlite3_column_double(statement, 0)
            let endTime = sqlite3_column_double(statement, 1)
            totalTime += (endTime - startTime)
        }

        return totalTime
    }
}
