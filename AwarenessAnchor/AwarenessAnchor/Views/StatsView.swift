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

#Preview {
    StatsView()
        .environmentObject(AppState.shared)
}
