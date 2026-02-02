import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var hotkeyManager = HotkeyManager.shared

    @AppStorage("headPoseEnabled") private var headPoseEnabled = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        TabView {
            GeneralSettingsView(headPoseEnabled: $headPoseEnabled, launchAtLogin: $launchAtLogin)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ChimeSettingsView()
                .tabItem {
                    Label("Chimes", systemImage: "bell")
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
        .frame(width: 500, height: 400)
        .environmentObject(appState)
    }
}

struct GeneralSettingsView: View {
    @Binding var headPoseEnabled: Bool
    @Binding var launchAtLogin: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .help("Start Awareness Anchor when you log in")
            }

            Section {
                Toggle("Enable head pose detection", isOn: $headPoseEnabled)
                    .help("Use camera to detect head movements as responses")

                if headPoseEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Head Gesture Guide")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack {
                            Image(systemName: "arrow.up")
                                .foregroundColor(.green)
                            Text("Tilt head up")
                            Spacer()
                            Text("Already Present")
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)

                        HStack {
                            Image(systemName: "arrow.left.and.right")
                                .foregroundColor(.orange)
                            Text("Turn head left/right")
                            Spacer()
                            Text("Returned")
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)

                    Text("Camera is only active during response windows, not continuously.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Head Pose Detection")
            }

            Section {
                Text("Keyboard shortcuts always work as a fallback:\n⌘⇧1 = Present  •  ⌘⇧2 = Returned")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Fallback Input")
            }
        }
        .padding()
    }
}

struct ChimeSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Average Interval")
                        Spacer()
                        Text(formatInterval(appState.averageIntervalSeconds))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    Slider(value: Binding(
                        get: { appState.averageIntervalSeconds },
                        set: { appState.updateInterval($0) }
                    ), in: 3...300, step: 1)

                    Text("Chimes occur at random intervals centered around this average.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Timing")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Response Window")
                        Spacer()
                        Text("\(Int(appState.responseWindowSeconds))s")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    Slider(value: Binding(
                        get: { appState.responseWindowSeconds },
                        set: { appState.updateResponseWindow($0) }
                    ), in: 3...30, step: 1)

                    Text("Time you have to respond after each chime.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Response Window")
            }

            Section {
                Text("Sound files are bundled with the app. Custom sounds coming soon.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Sounds")
            }
        }
        .padding()
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

struct HotkeySettingsView: View {
    @StateObject private var hotkeyManager = HotkeyManager.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Already Present")
                    Spacer()
                    Text(hotkeyManager.presentHotkey.displayName)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(6)
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Text("Returned to Awareness")
                    Spacer()
                    Text(hotkeyManager.returnedHotkey.displayName)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(6)
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("These shortcuts work globally, even when the app is in the background.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Text("Custom hotkey configuration coming in a future update.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
}
