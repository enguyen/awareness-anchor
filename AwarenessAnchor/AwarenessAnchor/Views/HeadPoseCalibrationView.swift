import SwiftUI
import AVFoundation

struct HeadPoseCalibrationView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var detector: HeadPoseDetector

    @AppStorage("headPoseEnabled") private var headPoseEnabled = false
    @AppStorage("mouseTrackingEnabled") private var mouseTrackingEnabled = false

    @State private var deltaPitch: Float = 0
    @State private var deltaYaw: Float = 0
    @State private var signedYawDelta: Float = 0
    @State private var triggeredPose: HeadPose? = nil
    @State private var showTriggeredFeedback = false

    // Use coordinator's published state instead of detector
    private var isTestActive: Bool { appState.inputCoordinator.isCalibrationActive }

    // Threshold bindings
    @State private var pitchThreshold: Float = 0.16
    @State private var yawThreshold: Float = 0.28
    @State private var smoothingFactor: Float = 0.5
    @State private var dwellTime: Float = 0.2
    @State private var sensitivityMultiplier: Float = 1.3
    @State private var calibrationChimePlayer: AVAudioPlayer?
    @State private var recordingSavedMessage: String?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                // Left column: Response Preview + button
                VStack(spacing: 12) {
                    Text("Response Preview")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if headPoseEnabled {
                        ZStack(alignment: .top) {
                            HeadPoseSceneView(
                                pitchThreshold: detector.effectivePitchThreshold,
                                yawThreshold: detector.effectiveYawThreshold,
                                deltaPitch: deltaPitch,
                                signedYawDelta: signedYawDelta,
                                dwellProgress: appState.inputCoordinator.dwellProgress,
                                isTestActive: isTestActive,
                                faceDetected: detector.faceDetected,
                                isInCooldown: appState.inputCoordinator.isInCooldown,
                                topIntensity: appState.inputCoordinator.topIntensity,
                                leftIntensity: appState.inputCoordinator.leftIntensity,
                                rightIntensity: appState.inputCoordinator.rightIntensity,
                                activeSource: appState.inputCoordinator.activeSource.rawValue,
                                normalizedMouseX: appState.mouseEdgeDetector.normalizedXPosition,
                                normalizedMouseY: appState.mouseEdgeDetector.normalizedYPosition
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 280)
                            .cornerRadius(12)

                            if appState.inputCoordinator.isInCooldown {
                                InitializingBanner()
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            } else if showTriggeredFeedback, let pose = triggeredPose {
                                TriggeredBanner(pose: pose)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .saturation(isTestActive && !appState.inputCoordinator.isInCooldown && detector.faceDetected ? 1 : 0)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    } else {
                        ZStack(alignment: .top) {
                            MouseOnlyPreview(
                                isTestActive: isTestActive,
                                isInCooldown: appState.inputCoordinator.isInCooldown,
                                dwellProgress: appState.inputCoordinator.dwellProgress
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 280)
                            .cornerRadius(12)

                            if appState.inputCoordinator.isInCooldown {
                                InitializingBanner()
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            } else if showTriggeredFeedback, let pose = triggeredPose {
                                TriggeredBanner(pose: pose)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .saturation(isTestActive && !appState.inputCoordinator.isInCooldown ? 1 : 0)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    }

                    // Status text
                    Group {
                        if isTestActive {
                            if headPoseEnabled && !detector.faceDetected {
                                Text("No face detected")
                                    .foregroundColor(.red)
                            } else {
                                VStack(spacing: 2) {
                                    if headPoseEnabled {
                                        Text("Pitch: \(String(format: "%.2f", deltaPitch)) | Yaw: \(String(format: "%.2f", signedYawDelta))")
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                    if appState.inputCoordinator.dwellProgress > 0 {
                                        Text("Dwell: \(Int(appState.inputCoordinator.dwellProgress * 100))%")
                                            .font(.caption2)
                                            .foregroundColor(appState.inputCoordinator.dwellProgress > 0.5 ? .orange : .blue)
                                    } else {
                                        Text(statusHintText)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        } else {
                            Text(startHintText)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .font(.caption)

                    HStack(spacing: 8) {
                        Button(action: toggleTest) {
                            HStack {
                                Image(systemName: isTestActive ? "stop.circle.fill" : "play.circle.fill")
                                Text(isTestActive ? "Stop Preview" : "Preview Responses")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isTestActive ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
                            .foregroundColor(isTestActive ? .red : .green)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        if isTestActive {
                            Button(action: toggleRecording) {
                                HStack {
                                    Image(systemName: detector.isRecordingEnabled ? "stop.fill" : "record.circle")
                                    Text(detector.isRecordingEnabled ? "Stop (\(detector.recordingFrameCount))" : "Record")
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 12)
                                .background(detector.isRecordingEnabled ? Color.red.opacity(0.3) : Color.orange.opacity(0.2))
                                .foregroundColor(detector.isRecordingEnabled ? .red : .orange)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let msg = recordingSavedMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)

                // Right column: all settings sliders
                VStack(alignment: .leading, spacing: 20) {
                    // Stability Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Stability")
                            .font(.headline)

                        if headPoseEnabled {
                            ThresholdSlider(
                                icon: "waveform.path.ecg",
                                color: .blue,
                                label: "Smoothing",
                                value: $smoothingFactor,
                                range: 0.0...1.0,
                                hint: "Higher = smoother but laggier",
                                onChanged: { detector.smoothingFactor = $0 }
                            )

                            ThresholdSlider(
                                icon: "dial.medium",
                                color: .green,
                                label: "Sensitivity",
                                value: $sensitivityMultiplier,
                                range: 0.5...2.0,
                                hint: "Higher = triggers earlier",
                                onChanged: { detector.autoSensitivityMultiplier = $0 }
                            )
                        }

                        ThresholdSlider(
                            icon: "timer",
                            color: .purple,
                            label: "Dwell Time",
                            value: $dwellTime,
                            range: 0.0...0.5,
                            hint: "\(String(format: "%.2fs", dwellTime)) hold at edge",
                            onChanged: { detector.dwellTime = $0 }
                        )
                    }

                    // Head Pose Thresholds
                    if headPoseEnabled {
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Head Pose Thresholds")
                                .font(.headline)

                            if detector.isAutoThresholdActive {
                                Text("Thresholds only need to be adjusted when an external monitor is connected. They are set automatically when using the laptop screen only.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            ThresholdSlider(
                                icon: "arrow.left.arrow.right",
                                color: .orange,
                                label: "Turn head (Returned)",
                                value: $yawThreshold,
                                range: 0.05...0.50,
                                hint: "Higher = wider frustum = more turn needed",
                                onChanged: { detector.yawThreshold = $0 }
                            )
                            .opacity(detector.isAutoThresholdActive ? 0.4 : 1.0)
                            .disabled(detector.isAutoThresholdActive)

                            ThresholdSlider(
                                icon: "arrow.up",
                                color: .green,
                                label: "Tilt head up (Present)",
                                value: $pitchThreshold,
                                range: 0.05...0.50,
                                hint: "Higher = taller frustum = more tilt needed",
                                onChanged: { detector.pitchThreshold = $0 }
                            )
                            .opacity(detector.isAutoThresholdActive ? 0.4 : 1.0)
                            .disabled(detector.isAutoThresholdActive)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .onAppear {
            pitchThreshold = detector.pitchThreshold
            yawThreshold = detector.yawThreshold
            smoothingFactor = detector.smoothingFactor
            dwellTime = detector.dwellTime
            sensitivityMultiplier = detector.autoSensitivityMultiplier

            // Head pose calibration updates
            detector.onCalibrationUpdate = { _, _, dPitch, _, signedYaw in
                deltaPitch = dPitch
                signedYawDelta = signedYaw
            }

            // Head pose trigger callback
            detector.onCalibrationTriggered = { pose, edge in
                handleCalibrationTrigger(pose: pose, edge: edge)
            }

            // Mouse edge trigger callback (for calibration mode)
            appState.mouseEdgeDetector.onCalibrationTriggered = { pose, edge in
                handleCalibrationTrigger(pose: pose, edge: edge)
            }
        }
        .onDisappear {
            if isTestActive {
                appState.inputCoordinator.stopCalibration()
            }
            detector.onCalibrationUpdate = nil
            detector.onCalibrationTriggered = nil
            appState.mouseEdgeDetector.onCalibrationTriggered = nil
        }
        .onChange(of: appState.inputCoordinator.isInCooldown) { isCooling in
            // Play chime when cooldown ends (calibration resets)
            if !isCooling && isTestActive {
                playCalibrationChime()
            }
        }
    }

    private func handleCalibrationTrigger(pose: HeadPose, edge: GazeEdge) {
        withAnimation(.spring(response: 0.3)) {
            triggeredPose = pose
            showTriggeredFeedback = true
        }

        // Play system alert sound if enabled
        if UserDefaults.standard.bool(forKey: "playSystemSoundOnTrigger") {
            NSSound.beep()
        }

        // Trigger screen glow for calibration feedback (pass edge for correct direction)
        AppDelegate.shared?.showCalibrationGlow(for: edge)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showTriggeredFeedback = false
                triggeredPose = nil
            }
            // Don't reset baseline - keep it fixed for duration of test
            // User can click Stop/Start to reset baseline
        }
    }

    private func toggleRecording() {
        if detector.isRecordingEnabled {
            if let url = detector.stopRecording() {
                let name = url.lastPathComponent
                withAnimation {
                    recordingSavedMessage = "Saved \(detector.recordingFrameCount) frames: \(name)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    withAnimation {
                        recordingSavedMessage = nil
                    }
                }
            }
        } else {
            recordingSavedMessage = nil
            detector.startRecording()
        }
    }

    private func toggleTest() {
        if isTestActive {
            // Stop recording if active
            if detector.isRecordingEnabled {
                _ = detector.stopRecording()
            }
            appState.inputCoordinator.stopCalibration()
            deltaPitch = 0
            signedYawDelta = 0
        } else {
            // Reset UI state before starting
            deltaPitch = 0
            signedYawDelta = 0
            showTriggeredFeedback = false
            triggeredPose = nil

            playCalibrationChime()
            appState.inputCoordinator.startCalibration()
        }
    }

    private func playCalibrationChime() {
        if let url = Bundle.main.url(forResource: "bright-tibetan-bell-ding", withExtension: "mp3") {
            calibrationChimePlayer = try? AVAudioPlayer(contentsOf: url)
            calibrationChimePlayer?.play()
        }
    }

    // MARK: - Computed Properties

    private var statusHintText: String {
        if headPoseEnabled && mouseTrackingEnabled {
            return "Move mouse to edge or turn/tilt your head"
        } else if headPoseEnabled {
            return "Turn your head left or right, or tilt it upward"
        } else {
            return "Move mouse to screen edge"
        }
    }

    private var startHintText: String {
        if headPoseEnabled && mouseTrackingEnabled {
            return "Click 'Preview Responses' to test responding via mouse and head motions"
        } else if headPoseEnabled {
            return "Look at the center of your workspace, then click 'Preview Responses'"
        } else if mouseTrackingEnabled {
            return "Click 'Preview Responses' to test responding via mouse position"
        } else {
            return "Enable mouse or head tracking in Settings to preview responses"
        }
    }
}

// MARK: - Mouse Only Preview

struct MouseOnlyPreview: View {
    let isTestActive: Bool
    let isInCooldown: Bool
    let dwellProgress: Float

    var body: some View {
        ZStack {
            // Background
            Color(NSColor.windowBackgroundColor)

            VStack(spacing: 16) {
                if isTestActive {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)

                    Text("Move mouse to screen edges")
                        .font(.headline)

                    HStack(spacing: 24) {
                        EdgeIndicator(edge: "Top", color: .green, symbol: "arrow.up")
                        EdgeIndicator(edge: "Left", color: .orange, symbol: "arrow.left")
                        EdgeIndicator(edge: "Right", color: .orange, symbol: "arrow.right")
                    }
                    .padding(.top, 8)

                    if dwellProgress > 0 {
                        ProgressView(value: Double(dwellProgress))
                            .frame(width: 150)
                            .tint(dwellProgress > 0.5 ? .orange : .blue)
                    }
                } else {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("Mouse tracking ready")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct EdgeIndicator: View {
    let edge: String
    let color: Color
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundColor(color)
            Text(edge)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Triggered Banner

struct TriggeredBanner: View {
    let pose: HeadPose

    var body: some View {
        HStack {
            Image(systemName: pose == .tiltUp ? "sun.max.fill" : "arrow.uturn.backward.circle.fill")
            Text(pose == .tiltUp ? "Present!" : "Returned!")
                .fontWeight(.semibold)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(pose == .tiltUp ? Color.green : Color.orange)
        )
        .padding(.top, 8)
    }
}

// MARK: - Initializing Banner

struct InitializingBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "hourglass")
            Text("Initializing...")
                .fontWeight(.semibold)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray)
        )
        .padding(.top, 8)
    }
}

// MARK: - Threshold Slider

struct ThresholdSlider: View {
    let icon: String
    let color: Color
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Double>
    let hint: String
    let onChanged: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 20)
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Slider(value: Binding(
                get: { Double(value) },
                set: {
                    value = Float($0)
                    onChanged(Float($0))
                }
            ), in: range)
            .tint(color)
            Text(hint)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Legend Item

struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color.opacity(0.5))
                .frame(width: 12, height: 12)
            Text(text)
                .font(.caption)
        }
    }
}

#Preview {
    HeadPoseCalibrationView(detector: HeadPoseDetector())
        .environmentObject(AppState.shared)
        .frame(width: 720, height: 620)
}
