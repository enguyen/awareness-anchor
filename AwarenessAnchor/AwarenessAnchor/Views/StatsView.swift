import SwiftUI
import Charts

struct StatsView: View {
    @State private var selectedPeriod: StatsPeriod = .week
    @State private var stats: StatsData = StatsData(presentCount: 0, returnedCount: 0, missedCount: 0, averageResponseTimeMs: 0, totalChimes: 0)

    private let dataStore = DataStore()

    var body: some View {
        VStack(spacing: 20) {
            // Period Picker
            Picker("Period", selection: $selectedPeriod) {
                Text("Today").tag(StatsPeriod.today)
                Text("Week").tag(StatsPeriod.week)
                Text("Month").tag(StatsPeriod.month)
                Text("All Time").tag(StatsPeriod.allTime)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

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
                    VStack(spacing: 24) {
                        // Summary Cards
                        HStack(spacing: 16) {
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
                                .frame(height: 200)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)

                        // Response Time
                        if stats.averageResponseTimeMs > 0 {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Average Response Time")
                                    .font(.headline)

                                HStack {
                                    Image(systemName: "timer")
                                        .foregroundColor(.orange)
                                    Text("\(stats.averageResponseTimeMs)ms")
                                        .font(.title2)
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(12)
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            loadStats()
        }
        .onChange(of: selectedPeriod) { _ in
            loadStats()
        }
    }

    private func loadStats() {
        dataStore.initialize()
        stats = dataStore.getStats(for: selectedPeriod)
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(color)

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(12)
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
            .cornerRadius(6)
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
}
