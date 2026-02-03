import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bell.fill")
                    .foregroundColor(.orange)
                Text("Awareness Anchor")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Response Window Indicator
            if appState.isInResponseWindow {
                ResponseWindowView()
                    .padding()
                Divider()
            }

            // Play/Pause Control
            PlaybackControlView()
                .padding()

            Divider()

            // Today's Stats
            TodayStatsView()
                .padding()

            Divider()

            // Quick Actions
            HStack {
                SettingsButton()

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
            }
            .padding()
        }
        .frame(width: 320)
    }
}

struct ResponseWindowView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(Color.green.opacity(0.5), lineWidth: 2)
                            .scaleEffect(1.5)
                    )

                Text("Response Window Open")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text(String(format: "%.1fs", appState.responseWindowRemainingSeconds))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            // Progress bar
            ProgressView(value: appState.responseWindowRemainingSeconds, total: appState.responseWindowSeconds)
                .progressViewStyle(.linear)
                .tint(.green)

            // Response Buttons
            HStack(spacing: 12) {
                Button {
                    appState.recordResponse(.present)
                } label: {
                    HStack {
                        Image(systemName: "sun.max.fill")
                        Text("Present")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    appState.recordResponse(.returned)
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Returned")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Text("⌘⇧1 = Present  •  ⌘⇧2 = Returned")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.green.opacity(0.05))
        .cornerRadius(12)
    }
}

struct PlaybackControlView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            // Play/Pause Button
            Button {
                appState.togglePlayback()
            } label: {
                HStack {
                    Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                    Text(appState.isPlaying ? "Pause" : "Play")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(appState.isPlaying ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
                .foregroundColor(appState.isPlaying ? .red : .green)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            // Interval Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Average Interval")
                        .font(.subheadline)
                    Spacer()
                    Text(formatInterval(appState.averageIntervalSeconds))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Slider(value: Binding(
                    get: { appState.averageIntervalSeconds },
                    set: { appState.updateInterval(round($0)) }
                ), in: 3...300)
                .tint(.orange)
            }
        }
    }

    private func formatInterval(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            if secs == 0 {
                return "\(minutes)m"
            }
            return "\(minutes)m \(secs)s"
        }
        return "\(Int(seconds))s"
    }
}

struct TodayStatsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's Stats")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                StatBox(
                    icon: "sun.max.fill",
                    count: appState.todayStats.presentCount,
                    label: "Present",
                    color: .green
                )

                StatBox(
                    icon: "arrow.uturn.backward",
                    count: appState.todayStats.returnedCount,
                    label: "Returned",
                    color: .orange
                )

                StatBox(
                    icon: "moon.zzz.fill",
                    count: appState.todayStats.missedCount,
                    label: "Missed",
                    color: .gray
                )
            }

            if appState.todayStats.total > 0 {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Awareness")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(Int(appState.todayStats.awarenessRatio * 100))%")
                            .font(.headline)
                            .foregroundColor(.blue)
                    }

                    Spacer()

                    VStack(alignment: .trailing) {
                        Text("Quality")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(Int(appState.todayStats.qualityRatio * 100))%")
                            .font(.headline)
                            .foregroundColor(.purple)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

struct StatBox: View {
    let icon: String
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)

            Text("\(count)")
                .font(.title2)
                .fontWeight(.semibold)

            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsButtonModern()
        } else {
            SettingsButtonLegacy()
        }
    }
}

@available(macOS 14.0, *)
struct SettingsButtonModern: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings...") {
            AppDelegate.shared?.popover.performClose(nil)
            openSettings()
        }
        .buttonStyle(.plain)
        .foregroundColor(.blue)
    }
}

struct SettingsButtonLegacy: View {
    var body: some View {
        Button("Settings...") {
            AppDelegate.shared?.popover.performClose(nil)
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        .buttonStyle(.plain)
        .foregroundColor(.blue)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState.shared)
}
