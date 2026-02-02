import SwiftUI

struct HeadPoseCalibrationView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var detector: HeadPoseDetector

    @State private var isTestActive = false
    @State private var deltaPitch: Float = 0
    @State private var deltaYaw: Float = 0
    @State private var signedYawDelta: Float = 0
    @State private var triggeredPose: HeadPose? = nil
    @State private var showTriggeredFeedback = false

    // Threshold bindings
    @State private var pitchThreshold: Float = 0.12
    @State private var yawThreshold: Float = 0.20
    @State private var smoothingFactor: Float = 0.3
    @State private var dwellTime: Float = 0.15

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 3D Head Pose Preview
                VStack(spacing: 8) {
                    Text("Head Pose Preview")
                        .font(.headline)

                    ZStack(alignment: .top) {
                        // Main 3D SceneKit visualization
                        HeadPoseSceneView(
                            pitchThreshold: pitchThreshold,
                            yawThreshold: yawThreshold,
                            deltaPitch: deltaPitch,
                            signedYawDelta: signedYawDelta,
                            dwellProgress: detector.dwellProgress,
                            isTestActive: isTestActive,
                            faceDetected: detector.faceDetected
                        )
                        .frame(width: 280, height: 280)
                        .cornerRadius(12)

                        // Triggered feedback banner at top
                        if showTriggeredFeedback, let pose = triggeredPose {
                            TriggeredBanner(pose: pose)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .frame(width: 280, height: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )

                    // Status text
                    Group {
                        if isTestActive {
                            if !detector.faceDetected {
                                Text("No face detected")
                                    .foregroundColor(.red)
                            } else {
                                VStack(spacing: 2) {
                                    Text("Pitch: \(String(format: "%.2f", deltaPitch)) | Yaw: \(String(format: "%.2f", signedYawDelta))")
                                        .font(.system(.caption, design: .monospaced))
                                    if detector.dwellProgress > 0 {
                                        Text("Dwell: \(Int(detector.dwellProgress * 100))%")
                                            .font(.caption2)
                                            .foregroundColor(detector.dwellProgress > 0.5 ? .orange : .blue)
                                    } else {
                                        Text("Turn your head left or right, or tilt it upward")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        } else {
                            Text("Click 'Start Test' to fix the threshold frustum")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                }

                // Test Button
                Button(action: toggleTest) {
                    HStack {
                        Image(systemName: isTestActive ? "stop.circle.fill" : "play.circle.fill")
                        Text(isTestActive ? "Stop Test" : "Start Test")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isTestActive ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
                    .foregroundColor(isTestActive ? .red : .green)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Divider()

                // Threshold Sliders
                VStack(alignment: .leading, spacing: 16) {
                    Text("Thresholds")
                        .font(.headline)

                    ThresholdSlider(
                        icon: "arrow.left.arrow.right",
                        color: .orange,
                        label: "Turn head (Returned to Awareness)",
                        value: $yawThreshold,
                        range: 0.05...0.50,
                        hint: "Higher = wider frustum = more turn needed",
                        onChanged: { detector.yawThreshold = $0 }
                    )

                    ThresholdSlider(
                        icon: "arrow.up",
                        color: .green,
                        label: "Tilt head up (Already Present)",
                        value: $pitchThreshold,
                        range: 0.05...0.50,
                        hint: "Higher = taller frustum = more tilt needed",
                        onChanged: { detector.pitchThreshold = $0 }
                    )
                }

                Divider()

                // Smoothing & Dwell Settings
                VStack(alignment: .leading, spacing: 16) {
                    Text("Stability")
                        .font(.headline)

                    ThresholdSlider(
                        icon: "waveform.path.ecg",
                        color: .blue,
                        label: "Smoothing",
                        value: $smoothingFactor,
                        range: 0.0...0.7,
                        hint: "Higher = smoother but laggier tracking",
                        onChanged: { detector.smoothingFactor = $0 }
                    )

                    ThresholdSlider(
                        icon: "timer",
                        color: .purple,
                        label: "Dwell Time",
                        value: $dwellTime,
                        range: 0.0...2.0,
                        hint: "\(String(format: "%.1fs", dwellTime)) - how long to hold outside threshold",
                        onChanged: { detector.dwellTime = $0 }
                    )
                }

                Divider()

                // Legend
                HStack(spacing: 16) {
                    LegendItem(color: .green, text: "Tilt Up = Already Present")
                    LegendItem(color: .orange, text: "Turn = Returned to Awareness")
                }
            }
            .padding(24)
        }
        .onAppear {
            pitchThreshold = detector.pitchThreshold
            yawThreshold = detector.yawThreshold
            smoothingFactor = detector.smoothingFactor
            dwellTime = detector.dwellTime

            detector.onCalibrationUpdate = { _, _, dPitch, _, signedYaw in
                deltaPitch = dPitch
                signedYawDelta = signedYaw
            }

            detector.onCalibrationTriggered = { pose in
                withAnimation(.spring(response: 0.3)) {
                    triggeredPose = pose
                    showTriggeredFeedback = true
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation {
                        showTriggeredFeedback = false
                        triggeredPose = nil
                    }
                    // Don't reset baseline - keep it fixed for duration of test
                    // User can click Stop/Start to reset baseline
                }
            }
        }
        .onDisappear {
            if isTestActive {
                detector.stopCalibration()
            }
            detector.onCalibrationUpdate = nil
            detector.onCalibrationTriggered = nil
        }
    }

    private func toggleTest() {
        if isTestActive {
            detector.stopCalibration()
            isTestActive = false
            deltaPitch = 0
            signedYawDelta = 0
        } else {
            // Reset UI state before starting
            deltaPitch = 0
            signedYawDelta = 0
            detector.startCalibration()
            isTestActive = true
            showTriggeredFeedback = false
            triggeredPose = nil
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
        .frame(width: 420, height: 750)
}
