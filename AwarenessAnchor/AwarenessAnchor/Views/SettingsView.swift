import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var hotkeyManager = HotkeyManager.shared

    @AppStorage("headPoseEnabled") private var headPoseEnabled = false
    @AppStorage("mouseTrackingEnabled") private var mouseTrackingEnabled = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        TabView {
            GeneralSettingsView(
                headPoseEnabled: $headPoseEnabled,
                mouseTrackingEnabled: $mouseTrackingEnabled,
                launchAtLogin: $launchAtLogin
            )
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ChimeSettingsView()
                .tabItem {
                    Label("Chimes", systemImage: "bell")
                }

            if headPoseEnabled || mouseTrackingEnabled {
                HeadPoseCalibrationView(detector: appState.headPoseDetector)
                    .tabItem {
                        Label("Calibrate", systemImage: "dial.low")
                    }
            }

            HotkeySettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            StatsView()
                .tabItem {
                    Label("Statistics", systemImage: "chart.bar")
                }
        }
        .frame(width: 480, height: 620)
        .environmentObject(appState)
        .onDisappear {
            // Stop calibration if settings window is closed
            appState.inputCoordinator.stopCalibration()
        }
    }
}

// MARK: - Shared Components

struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(title: title)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.leading, 8)
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Binding var headPoseEnabled: Bool
    @Binding var mouseTrackingEnabled: Bool
    @Binding var launchAtLogin: Bool
    @AppStorage("screenGlowEnabled") private var screenGlowEnabled = true
    @AppStorage("screenGlowOpacity") private var screenGlowOpacity = 0.5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Startup
                SettingsSection(title: "Startup") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                }

                Divider()

                // Responding to Chimes
                SettingsSection(title: "Responding to Chimes") {
                    // Mouse pointer tracking
                    Toggle("Mouse pointer tracking", isOn: $mouseTrackingEnabled)
                        .toggleStyle(.switch)

                    // Camera-based head tracking
                    Toggle("Camera-based head tracking", isOn: $headPoseEnabled)
                        .toggleStyle(.switch)

                    // Unified gesture explanation (shown when either is enabled)
                    if mouseTrackingEnabled || headPoseEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Move mouse or turn head to respond")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.title2)
                                VStack(alignment: .leading) {
                                    Text("Up / Top")
                                        .fontWeight(.medium)
                                    Text("Already Present")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }

                            HStack(spacing: 12) {
                                Image(systemName: "arrow.left.arrow.right.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(.title2)
                                VStack(alignment: .leading) {
                                    Text("Left / Right")
                                        .fontWeight(.medium)
                                    Text("Returned to Awareness")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)

                        Text("Camera and mouse position tracking activate only during response windows after a chime.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Visual Feedback
                SettingsSection(title: "Visual Feedback") {
                    Toggle("Show screen edge glow", isOn: $screenGlowEnabled)
                        .toggleStyle(.switch)

                    if screenGlowEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Glow opacity")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(screenGlowOpacity * 100))%")
                                    .fontWeight(.medium)
                                    .monospacedDigit()
                            }

                            Slider(value: $screenGlowOpacity, in: 0.1...1.0)
                                .tint(.orange)
                        }
                    }

                    Text("Displays a colored glow on screen edges when tracking input and registering responses.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Fallback
                SettingsSection(title: "Keyboard Fallback") {
                    Text("Shortcuts always work: ⌘⇧1 = Present • ⌘⇧2 = Returned")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Chime Settings

struct ChimeSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Interval
                SettingsSection(title: "Chime Interval") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Average time between chimes")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatInterval(appState.averageIntervalSeconds))
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }

                        Slider(value: Binding(
                            get: { appState.averageIntervalSeconds },
                            set: { appState.updateInterval(round($0)) }
                        ), in: 3...300)
                        .tint(.orange)

                        Text("Actual intervals vary randomly around this average.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Response Window
                SettingsSection(title: "Response Window") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Time to respond after chime")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(appState.responseWindowSeconds)) seconds")
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }

                        Slider(value: Binding(
                            get: { appState.responseWindowSeconds },
                            set: { appState.updateResponseWindow(round($0)) }
                        ), in: 3...30)
                        .tint(.orange)
                    }
                }

                Divider()

                // Sounds
                SettingsSection(title: "Sounds") {
                    Text("Five Tibetan singing bowl sounds are included. A random sound plays for each chime.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(24)
        }
    }

    private func formatInterval(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            if secs == 0 {
                return "\(minutes) min"
            }
            return "\(minutes) min \(secs) sec"
        }
        return "\(Int(seconds)) sec"
    }
}

// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
    @StateObject private var hotkeyManager = HotkeyManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: "Global Shortcuts") {
                    VStack(spacing: 12) {
                        HotkeyRow(
                            action: "Already Present",
                            icon: "sun.max.fill",
                            iconColor: .green,
                            shortcut: hotkeyManager.presentHotkey.displayName
                        )

                        HotkeyRow(
                            action: "Returned to Awareness",
                            icon: "arrow.uturn.backward",
                            iconColor: .orange,
                            shortcut: hotkeyManager.returnedHotkey.displayName
                        )
                    }

                    Text("These shortcuts work globally, even when other apps are focused.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }

                Divider()

                SettingsSection(title: "Customization") {
                    Text("Custom shortcut configuration coming in a future update.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(24)
        }
    }
}

struct HotkeyRow: View {
    let action: String
    let icon: String
    let iconColor: Color
    let shortcut: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 24)

            Text(action)

            Spacer()

            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
}
