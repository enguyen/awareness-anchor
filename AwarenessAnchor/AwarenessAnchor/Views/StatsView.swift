import SwiftUI
import Charts

struct StatsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedPeriod: StatsPeriod = .week
    @State private var stats: StatsData = StatsData(presentCount: 0, returnedCount: 0, missedCount: 0, averageResponseTimeMs: 0, totalChimes: 0)

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
                        // Summary Cards
                        HStack(spacing: 12) {
                            SummaryCard(
                                title: "Awareness",
                                value: "\(Int(stats.awarenessRatio * 100))%",
                                subtitle: "\(stats.presentCount + stats.returnedCount)/\(stats.totalChimes) responded",
                                color: .blue
                            )

                            SummaryCard(
                                title: "Quality",
                                value: "\(Int(stats.qualityRatio * 100))%",
                                subtitle: "\(stats.presentCount) already present",
                                color: .purple
                            )
                        }

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
        appLog("[StatsView] Loaded stats: totalChimes=\(stats.totalChimes)", category: "StatsView")
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(color)

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.1))
        .cornerRadius(10)
    }
}

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
