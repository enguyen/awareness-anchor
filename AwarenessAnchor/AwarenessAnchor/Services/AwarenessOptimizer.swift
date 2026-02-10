import Foundation

// MARK: - Data Structures

struct ChimePair {
    let first: ChimeEvent
    let second: ChimeEvent
    let interval: TimeInterval
}

struct SurvivalPoint: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let survivalProbability: Double
    let atRisk: Int
    let events: Int
}

struct AwarenessDuration {
    let medianDuration: TimeInterval?   // nil if >50% censored
    let meanDuration: TimeInterval      // restricted mean (area under KM curve)
    let survivalCurve: [SurvivalPoint]
    let totalObservations: Int
    let uncensoredCount: Int            // awareness ended before next chime
    let censoredCount: Int              // awareness still held at next chime
}

struct OptimizationResult {
    let chimeEffectiveness: Double
    let naturalDuration: AwarenessDuration
    let inducedDuration: AwarenessDuration
    let valuePerChimeSeconds: Double
    let naturalAwarenessRate: Double
    let currentIntervalSeconds: Double
    let recommendedIntervalSeconds: Double
    let expectedAwarenessAtRecommended: Double
    let expectedAwarenessAtCurrent: Double
    let naturalRateTrend: [TrendPoint]
    let durationTrend: [DurationTrendPoint]
    let hasEnoughPairsForSurvival: Bool
    let hasEnoughDataForOptimization: Bool
    let hasEnoughDataForTrend: Bool
}

struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let naturalRate: Double
    let sampleSize: Int
}

struct DurationTrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let medianDuration: TimeInterval
    let sampleSize: Int
}

// MARK: - Optimizer

struct AwarenessOptimizer {

    /// Main entry point: analyze events and sessions, return optimization results
    static func analyze(
        events: [ChimeEvent],
        sessions: [Session],
        currentIntervalSeconds: Double,
        responseWindowSeconds: Double
    ) -> OptimizationResult {

        let sorted = events.sorted { $0.timestamp < $1.timestamp }

        // Basic counts
        let presentCount = sorted.filter { $0.responseType == .present }.count
        let returnedCount = sorted.filter { $0.responseType == .returned }.count
        let missedCount = sorted.filter { $0.responseType == .missed }.count
        let total = presentCount + returnedCount + missedCount

        let naturalAwarenessRate = total > 0 ? Double(presentCount) / Double(total) : 0
        let absentChimes = returnedCount + missedCount
        let chimeEffectiveness = absentChimes > 0 ? Double(returnedCount) / Double(absentChimes) : 0

        // Extract pairs
        let pairs = extractPairs(events: sorted, responseWindowSeconds: responseWindowSeconds)

        // Separate into natural and induced observations
        let naturalObs = survivalObservations(from: pairs, startType: .present)
        let inducedObs = survivalObservations(from: pairs, startType: .returned)

        // Kaplan-Meier survival estimation
        let naturalDuration = kaplanMeier(observations: naturalObs, maxTime: 300)
        let inducedDuration = kaplanMeier(observations: inducedObs, maxTime: 300)

        // Enough data checks
        let hasEnoughPairsForSurvival = inducedObs.count >= 5
        let hasEnoughDataForOptimization = total >= 10 && returnedCount >= 1
        let sessionsWithEnoughEvents = sessions.filter { session in
            sorted.filter { $0.sessionId == session.id }.count >= 3
        }
        let hasEnoughDataForTrend = sessionsWithEnoughEvents.count >= 3

        // Optimization: find recommended interval
        let (recommendedInterval, expectedAtRecommended, expectedAtCurrent) = optimizeInterval(
            naturalDuration: naturalDuration,
            inducedDuration: inducedDuration,
            naturalRate: naturalAwarenessRate,
            pReturn: chimeEffectiveness,
            currentInterval: currentIntervalSeconds
        )

        let valuePerChime = chimeEffectiveness * inducedDuration.meanDuration

        // Trends
        let naturalRateTrend = computeNaturalRateTrend(events: sorted, sessions: sessions)
        let durationTrend = computeDurationTrend(events: sorted, responseWindowSeconds: responseWindowSeconds)

        return OptimizationResult(
            chimeEffectiveness: chimeEffectiveness,
            naturalDuration: naturalDuration,
            inducedDuration: inducedDuration,
            valuePerChimeSeconds: valuePerChime,
            naturalAwarenessRate: naturalAwarenessRate,
            currentIntervalSeconds: currentIntervalSeconds,
            recommendedIntervalSeconds: recommendedInterval,
            expectedAwarenessAtRecommended: expectedAtRecommended,
            expectedAwarenessAtCurrent: expectedAtCurrent,
            naturalRateTrend: naturalRateTrend,
            durationTrend: durationTrend,
            hasEnoughPairsForSurvival: hasEnoughPairsForSurvival,
            hasEnoughDataForOptimization: hasEnoughDataForOptimization,
            hasEnoughDataForTrend: hasEnoughDataForTrend
        )
    }

    // MARK: - Pair Extraction

    /// Extract consecutive chime pairs within the same session, filtering artifacts
    static func extractPairs(events: [ChimeEvent], responseWindowSeconds: Double) -> [ChimePair] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }

        // Group by session
        var sessionEvents: [UUID: [ChimeEvent]] = [:]
        for event in sorted {
            sessionEvents[event.sessionId, default: []].append(event)
        }

        var pairs: [ChimePair] = []
        for (_, sessionEvts) in sessionEvents {
            let ordered = sessionEvts.sorted { $0.timestamp < $1.timestamp }
            for i in 0..<(ordered.count - 1) {
                let interval = ordered[i + 1].timestamp.timeIntervalSince(ordered[i].timestamp)

                // Filter: skip overlapping chime artifacts and session gaps
                guard interval > responseWindowSeconds, interval < 3600 else { continue }

                pairs.append(ChimePair(
                    first: ordered[i],
                    second: ordered[i + 1],
                    interval: interval
                ))
            }
        }

        return pairs
    }

    // MARK: - Survival Observations

    struct SurvivalObservation {
        let time: TimeInterval
        let isCensored: Bool    // true = awareness survived to next chime
    }

    /// Convert pairs into survival observations for a given starting response type
    /// For Present->X: Present->Present = censored, Present->Returned/Missed = event
    /// For Returned->X: Returned->Present = censored, Returned->Returned/Missed = event
    static func survivalObservations(from pairs: [ChimePair], startType: ResponseType) -> [SurvivalObservation] {
        pairs.compactMap { pair in
            guard pair.first.responseType == startType else { return nil }
            let isCensored = pair.second.responseType == .present
            return SurvivalObservation(time: pair.interval, isCensored: isCensored)
        }
    }

    // MARK: - Kaplan-Meier

    /// Standard Kaplan-Meier survival estimation
    static func kaplanMeier(observations: [SurvivalObservation], maxTime: TimeInterval) -> AwarenessDuration {
        guard !observations.isEmpty else {
            return AwarenessDuration(
                medianDuration: nil,
                meanDuration: 0,
                survivalCurve: [SurvivalPoint(time: 0, survivalProbability: 1.0, atRisk: 0, events: 0)],
                totalObservations: 0,
                uncensoredCount: 0,
                censoredCount: 0
            )
        }

        let sorted = observations.sorted { $0.time < $1.time }
        let totalObs = sorted.count
        let uncensored = sorted.filter { !$0.isCensored }.count
        let censored = sorted.filter { $0.isCensored }.count

        // Build KM curve
        var curve: [SurvivalPoint] = [SurvivalPoint(time: 0, survivalProbability: 1.0, atRisk: totalObs, events: 0)]
        var survival = 1.0
        var atRisk = totalObs

        var i = 0
        while i < sorted.count {
            let t = sorted[i].time
            var events = 0
            var censoredHere = 0

            // Count events and censored at this time
            while i < sorted.count && sorted[i].time == t {
                if sorted[i].isCensored {
                    censoredHere += 1
                } else {
                    events += 1
                }
                i += 1
            }

            if events > 0 && atRisk > 0 {
                survival *= (1.0 - Double(events) / Double(atRisk))
                curve.append(SurvivalPoint(
                    time: t,
                    survivalProbability: max(0, survival),
                    atRisk: atRisk,
                    events: events
                ))
            }

            atRisk -= (events + censoredHere)
        }

        // Restricted mean survival time (area under KM curve, up to maxTime)
        var rmst = 0.0
        for j in 0..<curve.count {
            let tStart = curve[j].time
            let tEnd = (j + 1 < curve.count) ? min(curve[j + 1].time, maxTime) : maxTime
            if tStart >= maxTime { break }
            rmst += curve[j].survivalProbability * (tEnd - tStart)
        }

        // Median: smallest t where S(t) <= 0.5
        var median: TimeInterval? = nil
        for point in curve {
            if point.survivalProbability <= 0.5 {
                median = point.time
                break
            }
        }

        return AwarenessDuration(
            medianDuration: median,
            meanDuration: rmst,
            survivalCurve: curve,
            totalObservations: totalObs,
            uncensoredCount: uncensored,
            censoredCount: censored
        )
    }

    // MARK: - Equilibrium Optimization

    /// Find the interval that maximizes awareness minus intrusiveness
    static func optimizeInterval(
        naturalDuration: AwarenessDuration,
        inducedDuration: AwarenessDuration,
        naturalRate: Double,
        pReturn: Double,
        currentInterval: Double
    ) -> (recommended: Double, expectedAtRecommended: Double, expectedAtCurrent: Double) {

        let lambda = 0.005  // intrusiveness cost per chime per hour

        // Build lookup for survival functions at 1-second resolution
        let naturalS = survivalLookup(from: naturalDuration.survivalCurve, maxT: 300)
        let inducedS = survivalLookup(from: inducedDuration.survivalCurve, maxT: 300)

        var bestT = currentInterval
        var bestU = -Double.infinity
        var bestAwareness = 0.0

        var awarenessAtCurrent = 0.0

        for tInt in stride(from: 30, through: 300, by: 15) {
            let T = Double(tInt)
            let awareness = equilibriumAwareness(
                T: T,
                naturalS: naturalS,
                inducedS: inducedS,
                naturalRate: naturalRate,
                pReturn: pReturn
            )

            let chimesPerHour = 3600.0 / T
            let U = awareness - lambda * chimesPerHour

            if U > bestU {
                bestU = U
                bestT = T
                bestAwareness = awareness
            }

            // Also compute awareness at current interval (nearest 15s step)
            if abs(T - currentInterval) < 8 {
                awarenessAtCurrent = awareness
            }
        }

        // Also compute exact current interval if not on grid
        if awarenessAtCurrent == 0 {
            awarenessAtCurrent = equilibriumAwareness(
                T: currentInterval,
                naturalS: naturalS,
                inducedS: inducedS,
                naturalRate: naturalRate,
                pReturn: pReturn
            )
        }

        return (bestT, bestAwareness, awarenessAtCurrent)
    }

    /// Build a lookup table of S(t) at 1-second intervals from a KM survival curve
    private static func survivalLookup(from curve: [SurvivalPoint], maxT: Int) -> [Double] {
        var lookup = Array(repeating: 0.0, count: maxT + 1)
        var curveIdx = 0
        var currentS = 1.0

        for t in 0...maxT {
            while curveIdx < curve.count && curve[curveIdx].time <= Double(t) {
                currentS = curve[curveIdx].survivalProbability
                curveIdx += 1
            }
            lookup[t] = currentS
        }

        return lookup
    }

    /// Compute steady-state awareness proportion at interval T
    private static func equilibriumAwareness(
        T: Double,
        naturalS: [Double],
        inducedS: [Double],
        naturalRate: Double,
        pReturn: Double
    ) -> Double {
        let tInt = min(Int(T), naturalS.count - 1)

        // RMST: restricted mean survival time truncated at T
        var rmstNatural = 0.0
        var rmstInduced = 0.0
        for t in 0..<tInt {
            rmstNatural += naturalS[t]
            rmstInduced += inducedS[t]
        }

        // Find steady-state P(aware at chime boundary) iteratively
        var pi = naturalRate
        for _ in 0..<100 {
            let piNext = pi * naturalS[tInt] + (1 - pi) * pReturn * inducedS[tInt]
            if abs(piNext - pi) < 0.0001 { break }
            pi = piNext
        }

        // Final awareness fraction with converged pi
        return (pi * rmstNatural + (1 - pi) * pReturn * rmstInduced) / T
    }

    // MARK: - Trends

    /// Natural awareness rate per session
    static func computeNaturalRateTrend(events: [ChimeEvent], sessions: [Session]) -> [TrendPoint] {
        var trend: [TrendPoint] = []

        for session in sessions.sorted(by: { $0.startTime < $1.startTime }) {
            let sessionEvents = events.filter { $0.sessionId == session.id }
            guard sessionEvents.count >= 3 else { continue }

            let presentCount = sessionEvents.filter { $0.responseType == .present }.count
            let rate = Double(presentCount) / Double(sessionEvents.count)

            trend.append(TrendPoint(
                date: session.startTime,
                naturalRate: rate,
                sampleSize: sessionEvents.count
            ))
        }

        return trend
    }

    /// Episode duration trend: KM median over rolling windows of events
    static func computeDurationTrend(events: [ChimeEvent], responseWindowSeconds: Double) -> [DurationTrendPoint] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 50 else { return [] }

        let windowSize = 50
        let stepSize = 25
        var trend: [DurationTrendPoint] = []

        var startIdx = 0
        while startIdx + windowSize <= sorted.count {
            let window = Array(sorted[startIdx..<(startIdx + windowSize)])
            let pairs = extractPairs(events: window, responseWindowSeconds: responseWindowSeconds)
            let inducedObs = survivalObservations(from: pairs, startType: .returned)

            if inducedObs.count >= 5 {
                let km = kaplanMeier(observations: inducedObs, maxTime: 300)
                // Use RMST as fallback if median is nil (>50% censored)
                let duration = km.medianDuration ?? km.meanDuration

                let midDate = window[windowSize / 2].timestamp
                trend.append(DurationTrendPoint(
                    date: midDate,
                    medianDuration: duration,
                    sampleSize: inducedObs.count
                ))
            }

            startIdx += stepSize
        }

        return trend
    }
}
