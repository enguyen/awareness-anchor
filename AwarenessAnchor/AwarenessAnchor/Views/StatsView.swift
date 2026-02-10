import SwiftUI
import Charts

struct StatsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedPeriod: StatsPeriod = .week
    @State private var stats: StatsData = StatsData(presentCount: 0, returnedCount: 0, missedCount: 0, averageResponseTimeMs: 0, totalChimes: 0)
    @State private var timeStats: TimeEstimateStats = TimeEstimateStats(
        pointEstimate: 0,
        confidenceInterval: (0, 1),
        effectiveSampleSize: 0,
        rawSampleSize: 0,
        autocorrelation: 0,
        totalPracticeTime: 0
    )
    @State private var optimizationStats: OptimizationResult?

    var body: some View {
        VStack(spacing: 0) {
            // Period Picker
            Picker("Period", selection: $selectedPeriod) {
                Text("Today").tag(StatsPeriod.today)
                Text("Week").tag(StatsPeriod.week)
                Text("Month").tag(StatsPeriod.month)
                Text("All Time").tag(StatsPeriod.allTime)
            }
            .pickerStyle(.segmented)
            .padding(20)

            if stats.totalChimes == 0 {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No data yet")
                        .font(.headline)
                    Text("Start a session to see your awareness stats")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        // Time in Awareness Card (main visualization)
                        TimeInAwarenessCard(timeStats: timeStats)

                        // Response Distribution
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Response Distribution")
                                .font(.headline)

                            ResponseDistributionChart(stats: stats)
                                .frame(height: 160)
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)

                        // Response Time
                        if stats.averageResponseTimeMs > 0 {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Average Response Time")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text("\(stats.averageResponseTimeMs)")
                                            .font(.title)
                                            .fontWeight(.semibold)
                                        Text("ms")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "timer")
                                    .font(.title)
                                    .foregroundColor(.orange)
                            }
                            .padding(16)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(10)
                        }

                        // Practice Time
                        if timeStats.totalPracticeTime > 0 {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Total Practice Time")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Text(formatPracticeTime(timeStats.totalPracticeTime))
                                        .font(.title2)
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                                Image(systemName: "clock")
                                    .font(.title)
                                    .foregroundColor(.blue)
                            }
                            .padding(16)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(10)
                        }

                        // --- Phase 2: Optimization Cards ---

                        if let opt = optimizationStats {
                            ChimeEffectivenessCard(stats: opt)

                            if opt.hasEnoughPairsForSurvival {
                                AwarenessDurationCard(stats: opt)
                            }

                            if opt.hasEnoughDataForOptimization {
                                OptimalFrequencyCard(stats: opt, appState: appState)
                            }

                            if opt.hasEnoughDataForTrend {
                                EpisodeDurationTrendCard(stats: opt)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            loadStats()
        }
        .onChange(of: selectedPeriod) { _ in
            loadStats()
        }
        .onChange(of: appState.statsNeedRefresh) { _ in
            loadStats()
        }
    }

    private func loadStats() {
        appLog("[StatsView] loadStats called for period: \(selectedPeriod)", category: "StatsView")
        stats = appState.dataStore.getStats(for: selectedPeriod)
        timeStats = appState.dataStore.getTimeEstimateStats(for: selectedPeriod)
        optimizationStats = appState.dataStore.getOptimizationStats(
            for: selectedPeriod,
            currentIntervalSeconds: appState.averageIntervalSeconds,
            responseWindowSeconds: appState.responseWindowSeconds
        )
        appLog("[StatsView] Loaded stats: totalChimes=\(stats.totalChimes)", category: "StatsView")
    }

    private func formatPracticeTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Time in Awareness Card

struct TimeInAwarenessCard: View {
    let timeStats: TimeEstimateStats
    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with info button
            HStack {
                Text("Time in Awareness")
                    .font(.headline)
                Spacer()
                Button(action: { showingInfo.toggle() }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingInfo) {
                    TimeInAwarenessInfoView()
                }
            }

            if timeStats.rawSampleSize < 3 {
                // Not enough data
                VStack(spacing: 8) {
                    Text("Need more data")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("At least 3 chime responses are needed for statistical estimates")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                // Box plot visualization
                ConfidenceIntervalView(timeStats: timeStats)
                    .frame(height: 60)

                // Summary text
                HStack(spacing: 4) {
                    Text("\(Int(timeStats.pointEstimate * 100))%")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.green)

                    let ciLow = Int(timeStats.confidenceInterval.low * 100)
                    let ciHigh = Int(timeStats.confidenceInterval.high * 100)
                    Text("(\(ciLow)% - \(ciHigh)%)")
                        .font(.callout)
                        .foregroundColor(.secondary)

                    Spacer()
                }

                // Technical details
                HStack(spacing: 16) {
                    StatDetail(
                        label: "Samples",
                        value: "\(Int(timeStats.effectiveSampleSize)) eff",
                        detail: "(\(timeStats.rawSampleSize) raw)"
                    )

                    StatDetail(
                        label: "Autocorr",
                        value: String(format: "%.2f", timeStats.autocorrelation),
                        detail: autocorrelationInterpretation
                    )
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    private var autocorrelationInterpretation: String {
        let rho = timeStats.autocorrelation
        if rho > 0.5 {
            return "(sticky states)"
        } else if rho > 0.2 {
            return "(moderate)"
        } else if rho < -0.2 {
            return "(alternating)"
        } else {
            return "(near random)"
        }
    }
}

struct StatDetail: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Text(value)
                    .fontWeight(.medium)
                Text(detail)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Confidence Interval Visualization

struct ConfidenceIntervalView: View {
    let timeStats: TimeEstimateStats

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 8)
                    .offset(y: height / 2 - 4)

                // Scale markers
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { value in
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Color(NSColor.separatorColor))
                            .frame(width: 1, height: 12)
                        Text("\(Int(value * 100))%")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .offset(x: width * value - 0.5, y: height / 2 + 6)
                }

                // Confidence interval box
                let ciLow = timeStats.confidenceInterval.low
                let ciHigh = timeStats.confidenceInterval.high
                let boxX = width * ciLow
                let boxWidth = width * (ciHigh - ciLow)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.green.opacity(0.3))
                    .frame(width: max(4, boxWidth), height: 24)
                    .offset(x: boxX, y: height / 2 - 12)

                // Point estimate marker
                let pointX = width * timeStats.pointEstimate
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
                    .offset(x: pointX - 6, y: height / 2 - 6)
            }
        }
    }
}

// MARK: - Info Popover

struct TimeInAwarenessInfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Understanding Time in Awareness")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                InfoItem(
                    title: "What this measures",
                    text: "An estimate of what percentage of your practice time you spend in an aware, present state vs. distracted."
                )

                InfoItem(
                    title: "Already Present",
                    text: "You were aware when the chime played. Indicates you were in the Present state."
                )

                InfoItem(
                    title: "Returning",
                    text: "The chime brought you back to awareness. Indicates you were in the Absent (distracted) state."
                )

                InfoItem(
                    title: "Missed",
                    text: "You remained unaware even after the chime. Also indicates Absent state."
                )

                Divider()

                InfoItem(
                    title: "Confidence Interval",
                    text: "The green box shows the range where your true awareness percentage likely falls (95% confidence)."
                )

                InfoItem(
                    title: "Effective Samples",
                    text: "Your observations are correlated (if present now, likely present soon). Effective samples accounts for this, giving a more accurate confidence interval."
                )

                InfoItem(
                    title: "Autocorrelation",
                    text: "Measures how 'sticky' your states are. Higher values mean longer periods of sustained focus or distraction. Values near 0 mean more random switching."
                )
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

struct InfoItem: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Response Distribution Chart

struct ResponseDistributionChart: View {
    let stats: StatsData

    var chartData: [ChartDataPoint] {
        [
            ChartDataPoint(type: "Present", count: stats.presentCount, color: .green),
            ChartDataPoint(type: "Returned", count: stats.returnedCount, color: .orange),
            ChartDataPoint(type: "Missed", count: stats.missedCount, color: .gray)
        ]
    }

    var body: some View {
        Chart(chartData) { point in
            BarMark(
                x: .value("Type", point.type),
                y: .value("Count", point.count)
            )
            .foregroundStyle(point.color)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }
}

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let type: String
    let count: Int
    let color: Color
}

// MARK: - Chime Effectiveness Card

struct ChimeEffectivenessCard: View {
    let stats: OptimizationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chime Effectiveness")
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(stats.chimeEffectiveness * 100))%")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
                Text("of absent chimes brought you back")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Text("Value per chime: ~\(Int(stats.valuePerChimeSeconds))s of awareness gained")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

// MARK: - Awareness Duration Card

struct AwarenessDurationCard: View {
    let stats: OptimizationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Awareness Episode Duration")
                .font(.headline)

            // Side-by-side duration stats
            HStack(spacing: 20) {
                DurationStat(
                    label: "Natural",
                    duration: stats.naturalDuration,
                    color: .green
                )

                DurationStat(
                    label: "After Chime",
                    duration: stats.inducedDuration,
                    color: .orange
                )
            }

            // Survival curve chart
            if stats.inducedDuration.survivalCurve.count > 1 {
                SurvivalCurveChart(
                    naturalCurve: stats.naturalDuration.survivalCurve,
                    inducedCurve: stats.inducedDuration.survivalCurve
                )
                .frame(height: 120)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct DurationStat: View {
    let label: String
    let duration: AwarenessDuration
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            if let median = duration.medianDuration {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("~\(Int(median))s")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(color)
                    Text("median")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if duration.totalObservations > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(">\(Int(duration.meanDuration))s")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(color)
                    Text("mean")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("\(duration.totalObservations) observations")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SurvivalCurveChart: View {
    let naturalCurve: [SurvivalPoint]
    let inducedCurve: [SurvivalPoint]

    var body: some View {
        Chart {
            // Natural awareness (green)
            if naturalCurve.count > 1 {
                ForEach(naturalCurve) { point in
                    LineMark(
                        x: .value("Time (s)", point.time),
                        y: .value("Survival", point.survivalProbability),
                        series: .value("Type", "Natural")
                    )
                    .foregroundStyle(.green)
                    .interpolationMethod(.stepEnd)
                }
            }

            // Induced awareness (orange)
            ForEach(inducedCurve) { point in
                LineMark(
                    x: .value("Time (s)", point.time),
                    y: .value("Survival", point.survivalProbability),
                    series: .value("Type", "After Chime")
                )
                .foregroundStyle(.orange)
                .interpolationMethod(.stepEnd)
            }

            // 50% line
            RuleMark(y: .value("Median", 0.5))
                .foregroundStyle(.secondary.opacity(0.3))
                .lineStyle(StrokeStyle(dash: [4, 4]))
        }
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("P(still aware)")
        .chartYScale(domain: 0...1)
    }
}

// MARK: - Optimal Frequency Card

struct OptimalFrequencyCard: View {
    let stats: OptimizationResult
    @ObservedObject var appState: AppState
    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Optimal Chime Frequency")
                    .font(.headline)
                Spacer()
                Button(action: { showingInfo.toggle() }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingInfo) {
                    OptimalFrequencyInfoView()
                }
            }

            // Current vs recommended
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatSeconds(stats.currentIntervalSeconds))
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("\(Int(stats.expectedAwarenessAtCurrent * 100))% awareness")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommended")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text(formatSeconds(stats.recommendedIntervalSeconds))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                    Text("\(Int(stats.expectedAwarenessAtRecommended * 100))% awareness")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }

            // Value per chime
            if stats.valuePerChimeSeconds > 0 {
                Text("Each chime adds ~\(Int(stats.valuePerChimeSeconds))s of awareness")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Apply button if recommendation differs significantly
            let diff = abs(stats.recommendedIntervalSeconds - stats.currentIntervalSeconds) / stats.currentIntervalSeconds
            if diff > 0.1 {
                Button {
                    appState.updateInterval(stats.recommendedIntervalSeconds)
                } label: {
                    Text("Apply Recommended Interval")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    private func formatSeconds(_ seconds: Double) -> String {
        if seconds >= 60 {
            let min = Int(seconds) / 60
            let sec = Int(seconds) % 60
            return sec == 0 ? "\(min)m" : "\(min)m \(sec)s"
        }
        return "\(Int(seconds))s"
    }
}

struct OptimalFrequencyInfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How This Works")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                InfoItem(
                    title: "Episode Duration",
                    text: "We measure how long your awareness episodes last using survival analysis (Kaplan-Meier). This is the key metric."
                )

                InfoItem(
                    title: "Interval Tracking",
                    text: "The recommended interval is set to ~75% of your median episode duration. This keeps most awareness chains alive between chimes."
                )

                InfoItem(
                    title: "The Training Loop",
                    text: "As your awareness episodes get longer through practice, the recommended interval will increase. You'll see awareness stay high while chimes become less frequent — that's progress."
                )

                InfoItem(
                    title: "Equilibrium",
                    text: "Shorter intervals mean more chimes and higher awareness, but more intrusiveness. The recommendation balances both."
                )
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Episode Duration Trend Card

struct EpisodeDurationTrendCard: View {
    let stats: OptimizationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Awareness Progress")
                .font(.headline)

            if !stats.durationTrend.isEmpty {
                // Duration trend chart
                Chart {
                    ForEach(stats.durationTrend) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Duration (s)", point.medianDuration)
                        )
                        .foregroundStyle(.blue)

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Duration (s)", point.medianDuration)
                        )
                        .foregroundStyle(.blue)
                        .symbolSize(20)
                    }
                }
                .chartYAxisLabel("episode duration (s)")
                .frame(height: 120)

                Text("Longer episodes = deeper awareness. When this rises, your interval can increase.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Natural rate trend (secondary)
            if !stats.naturalRateTrend.isEmpty {
                Divider()

                Text("Natural Awareness Rate by Session")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Chart {
                    ForEach(stats.naturalRateTrend) { point in
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Rate", point.naturalRate)
                        )
                        .foregroundStyle(.green.opacity(0.7))
                        .symbolSize(CGFloat(max(10, min(40, point.sampleSize))))
                    }
                }
                .chartYScale(domain: 0...1)
                .chartYAxisLabel("present %")
                .frame(height: 80)

                Text("% of chimes where you were already aware (dot size = session length)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

#Preview {
    StatsView()
        .environmentObject(AppState.shared)
}
