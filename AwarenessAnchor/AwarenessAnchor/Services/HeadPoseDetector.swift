import Foundation
import Vision
import AVFoundation

enum HeadPose {
    case neutral
    case tiltUp      // Pitch > threshold -> "Already present"
    case turnLeftRight  // Yaw > threshold -> "Returned to awareness"
}

/// Screen edge for gaze direction indicator
enum GazeEdge {
    case none
    case top      // Looking up
    case left     // Turned left
    case right    // Turned right
}

class HeadPoseDetector: NSObject, ObservableObject {
    var onPoseDetected: ((HeadPose) -> Void)?

    // Callback for calibration mode - fires on every frame with raw values
    // Parameters: (rawPitch, rawYaw, deltaPitch, absYawDelta, signedYawDelta)
    var onCalibrationUpdate: ((Float, Float, Float, Float, Float) -> Void)?
    var onCalibrationTriggered: ((HeadPose) -> Void)?  // Fires when threshold hit in calibration

    // Debug: publish current values for UI display
    @Published var debugPitch: Float = 0
    @Published var debugYaw: Float = 0
    @Published var debugRawPitch: Float = 0
    @Published var debugRawYaw: Float = 0
    @Published var debugBaseline: String = "No baseline"
    @Published var faceDetected: Bool = false

    // Current gaze direction for screen edge glow
    @Published var currentGazeEdge: GazeEdge = .none
    @Published var gazeIntensity: Float = 0  // 0 to 1, how close to threshold

    // Calibration state - observable by UI
    @Published var isCalibrationActive: Bool = false

    // Callback for when a trigger happens (for wink animation)
    var onGazeTrigger: ((GazeEdge) -> Void)?

    // Track if face was ever detected during this response window
    private(set) var faceWasDetectedThisWindow: Bool = false

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let processingQueue = DispatchQueue(label: "com.awarenessanchor.headpose")

    private var isActive = false
    private var isWindowActive = false
    private var isCalibrationMode = false

    // Configurable thresholds - stored in UserDefaults
    var pitchThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "pitchThreshold").nonZeroOr(0.12)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "pitchThreshold") }
    }
    var yawThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "yawThreshold").nonZeroOr(0.20)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "yawThreshold") }
    }
    var yawNoiseThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "yawNoiseThreshold").nonZeroOr(0.10)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "yawNoiseThreshold") }
    }

    // Smoothing factor for IIR filter (0 = no smoothing, 1 = infinite smoothing)
    // Lower value = more responsive but jittery, higher = smoother but laggy
    var smoothingFactor: Float {
        get { Float(UserDefaults.standard.double(forKey: "smoothingFactor").nonZeroOr(0.3)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "smoothingFactor") }
    }

    // Dwell time: how long (seconds) gaze must stay outside threshold before triggering
    var dwellTime: Float {
        get { Float(UserDefaults.standard.double(forKey: "dwellTime").nonZeroOr(0.15)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "dwellTime") }
    }

    // Track baseline pose
    private var baselinePitch: Float?
    private var baselineYaw: Float?
    private var hasRespondedThisWindow = false

    // IIR smoothing state
    private var smoothedPitch: Float = 0
    private var smoothedYaw: Float = 0
    private var isFirstReading = true

    // Dwell time tracking
    private var dwellStartTime: Date?
    private var currentDwellPose: HeadPose = .neutral
    @Published var dwellProgress: Float = 0  // 0 to 1, for UI display

    // Prevent re-triggering until user returns to neutral
    private var requiresReturnToNeutral: Bool = false

    func startDetection() {
        guard captureSession == nil else { return }

        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .low  // Use low resolution for efficiency

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession?.canAddInput(input) == true else {
            appLog("[HP]Failed to access front camera", category: "HeadPose")
            return
        }

        captureSession?.addInput(input)

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput?.alwaysDiscardsLateVideoFrames = true

        if let output = videoOutput, captureSession?.canAddOutput(output) == true {
            captureSession?.addOutput(output)
        }

        isActive = true
        // Don't start capture session until response window opens
    }

    func stopDetection() {
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
        isActive = false
        isWindowActive = false
    }

    func activateForWindow() {
        guard isActive else {
            appLog("[HP]activateForWindow called but detector not active")
            return
        }

        appLog("[HP]Window activated, starting camera...")
        isWindowActive = true
        hasRespondedThisWindow = false
        faceWasDetectedThisWindow = false
        baselinePitch = nil
        baselineYaw = nil
        isFirstReading = true
        smoothedPitch = 0
        smoothedYaw = 0
        framesToSkip = 3  // Skip first few frames to let camera stabilize
        dwellStartTime = nil
        currentDwellPose = .neutral
        requiresReturnToNeutral = false

        DispatchQueue.main.async {
            self.debugBaseline = "Calibrating..."
            self.faceDetected = false
            self.dwellProgress = 0
        }

        // Start camera
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
            appLog("[HP]Camera started")
        }
    }

    func deactivateWindow() {
        isWindowActive = false

        // Stop camera to save resources
        captureSession?.stopRunning()

        // Reset gaze edge
        DispatchQueue.main.async {
            self.currentGazeEdge = .none
        }
    }

    // MARK: - Calibration Mode

    // Number of frames to skip before setting baseline (lets camera stabilize)
    private var framesToSkip: Int = 0

    func startCalibration() {
        // Set up capture session if needed
        if captureSession == nil && !isActive {
            startDetection()
        }

        appLog("[HP]Starting calibration mode...")
        isCalibrationMode = true
        isWindowActive = true
        hasRespondedThisWindow = false
        baselinePitch = nil
        baselineYaw = nil
        isFirstReading = true
        smoothedPitch = 0
        smoothedYaw = 0
        framesToSkip = 3  // Skip first few frames to let camera stabilize
        dwellStartTime = nil
        currentDwellPose = .neutral
        requiresReturnToNeutral = false

        DispatchQueue.main.async {
            self.isCalibrationActive = true
            self.debugBaseline = "Waiting for baseline..."
            self.faceDetected = false
            self.dwellProgress = 0
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
            appLog("[HP]Calibration camera started")
        }
    }

    func stopCalibration() {
        appLog("[HP]Stopping calibration mode...")
        isCalibrationMode = false
        isWindowActive = false
        captureSession?.stopRunning()

        DispatchQueue.main.async {
            self.isCalibrationActive = false
            self.currentGazeEdge = .none
            self.gazeIntensity = 0
            self.dwellProgress = 0
        }
    }

    func resetCalibrationBaseline() {
        baselinePitch = nil
        baselineYaw = nil
        hasRespondedThisWindow = false
        isFirstReading = true
        dwellStartTime = nil
        currentDwellPose = .neutral
        requiresReturnToNeutral = false
        DispatchQueue.main.async {
            self.debugBaseline = "Waiting for baseline..."
            self.debugPitch = 0
            self.debugYaw = 0
            self.dwellProgress = 0
        }
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        // In calibration mode, keep processing even after response
        guard isWindowActive, (isCalibrationMode || !hasRespondedThisWindow) else { return }

        // Use face rectangles request which provides pitch, yaw, roll
        let faceRequest = VNDetectFaceRectanglesRequest { [weak self] request, error in
            guard let self = self else { return }

            if let error = error {
                appLog("[HP]Vision error: \(error)")
                return
            }

            guard let results = request.results as? [VNFaceObservation],
                  let face = results.first else {
                DispatchQueue.main.async {
                    self.faceDetected = false
                    self.currentGazeEdge = .none
                }
                return
            }

            self.analyzeFacePose(face, in: pixelBuffer)
        }

        // Use revision 3 which supports pitch/yaw/roll
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([faceRequest])
    }

    private func analyzeFacePose(_ face: VNFaceObservation, in buffer: CVPixelBuffer) {
        // Mark that we detected a face at some point during this window
        faceWasDetectedThisWindow = true

        // VNFaceObservation provides pitch, yaw, roll as optional properties
        // Debug: print what we got
        appLog("[HP]Face found - pitch: \(String(describing: face.pitch)), yaw: \(String(describing: face.yaw)), roll: \(String(describing: face.roll))")

        guard let pitch = face.pitch?.floatValue,
              let yaw = face.yaw?.floatValue else {
            DispatchQueue.main.async {
                self.faceDetected = true  // Face IS detected, just no pose data
                self.debugBaseline = "Face found, no pose data"
            }
            appLog("[HP]No pitch/yaw data available (face detected but pose nil)")
            return
        }

        // Skip first few frames to let camera stabilize
        if framesToSkip > 0 {
            framesToSkip -= 1
            DispatchQueue.main.async {
                self.faceDetected = true
                self.debugBaseline = "Stabilizing camera..."
            }
            return
        }

        // Apply IIR smoothing filter
        // Formula: smoothed = alpha * new + (1 - alpha) * smoothed
        // where alpha = 1 - smoothingFactor
        let alpha = 1.0 - smoothingFactor
        if isFirstReading {
            smoothedPitch = pitch
            smoothedYaw = yaw
            isFirstReading = false
        } else {
            smoothedPitch = alpha * pitch + smoothingFactor * smoothedPitch
            smoothedYaw = alpha * yaw + smoothingFactor * smoothedYaw
        }

        // Establish baseline on first reading (after smoothing kicks in)
        if baselinePitch == nil {
            baselinePitch = smoothedPitch
            baselineYaw = smoothedYaw
            appLog("[HP]Baseline set: pitch=\(smoothedPitch), yaw=\(smoothedYaw)")
            DispatchQueue.main.async {
                self.debugBaseline = String(format: "Baseline: P=%.2f, Y=%.2f", self.smoothedPitch, self.smoothedYaw)
            }
            return
        }

        let pitchDelta = smoothedPitch - (baselinePitch ?? 0)
        let signedYawDelta = smoothedYaw - (baselineYaw ?? 0)
        let yawDelta = abs(signedYawDelta)

        // Update debug values and gaze edge on main thread
        DispatchQueue.main.async {
            self.faceDetected = true
            self.debugPitch = pitchDelta
            self.debugYaw = yawDelta
            self.debugRawPitch = pitch
            self.debugRawYaw = yaw

            // Update gaze edge and intensity for screen glow indicator
            // Intensity goes from 0 (center) to 1 (at threshold)
            let yawThresh = self.yawThreshold
            let pitchThresh = self.pitchThreshold

            // Calculate intensity as ratio of delta to threshold (clamped 0-1)
            let yawIntensity = min(abs(signedYawDelta) / yawThresh, 1.0)
            let pitchIntensity = min(abs(pitchDelta) / pitchThresh, 1.0)

            // Determine edge based on which direction has highest intensity
            // Swap left/right: positive yaw = looking left, negative = looking right (camera mirror)
            if signedYawDelta > 0.02 && yawIntensity > pitchIntensity {
                self.currentGazeEdge = .left  // Positive yaw = left
                self.gazeIntensity = yawIntensity
            } else if signedYawDelta < -0.02 && yawIntensity > pitchIntensity {
                self.currentGazeEdge = .right  // Negative yaw = right
                self.gazeIntensity = yawIntensity
            } else if pitchDelta < -0.02 {
                self.currentGazeEdge = .top
                self.gazeIntensity = pitchIntensity
            } else {
                self.currentGazeEdge = .none
                self.gazeIntensity = 0
            }
        }

        // Send calibration updates if in calibration mode
        if isCalibrationMode {
            DispatchQueue.main.async {
                self.onCalibrationUpdate?(pitch, yaw, pitchDelta, yawDelta, signedYawDelta)
            }
        }

        appLog("[HP]Delta: pitch=\(pitchDelta), yaw=\(yawDelta)")

        // Gesture priority: YAW takes precedence over PITCH
        //
        // Rationale: When using an external monitor above the webcam, turning
        // your head left/right while looking at the monitor creates apparent
        // pitch movement from the camera's perspective. A deliberate "turn"
        // gesture should always register as "returned", not "present".
        //
        // Only register "present" (tilt up) when there's minimal yaw movement,
        // indicating a pure vertical head tilt.

        // Get current thresholds
        let currentPitchThreshold = pitchThreshold
        let currentYawThreshold = yawThreshold
        let currentYawNoiseThreshold = yawNoiseThreshold
        let currentDwellTime = dwellTime

        // Determine which pose is detected (if any)
        var detectedPose: HeadPose = .neutral

        if yawDelta > currentYawThreshold {
            // Turning head left/right -> "Returned to awareness"
            detectedPose = .turnLeftRight
        } else if pitchDelta < -currentPitchThreshold && yawDelta < currentYawNoiseThreshold {
            // Pure tilt up with minimal turning -> "Already present"
            detectedPose = .tiltUp
        }

        // Dwell time tracking
        if detectedPose != .neutral {
            // Don't start new dwell if we're waiting for return to neutral
            if requiresReturnToNeutral {
                return
            }

            if detectedPose == currentDwellPose, let startTime = dwellStartTime {
                // Same pose, check if dwell time exceeded
                let elapsed = Float(Date().timeIntervalSince(startTime))
                let progress = min(elapsed / currentDwellTime, 1.0)

                DispatchQueue.main.async {
                    self.dwellProgress = progress
                }

                if elapsed >= currentDwellTime {
                    // Dwell time exceeded - trigger!
                    if detectedPose == .turnLeftRight {
                        appLog("[HP]TRIGGERED: Turn Left/Right (Returned) - yaw=\(yawDelta) > \(currentYawThreshold), dwell=\(elapsed)s")
                    } else {
                        appLog("[HP]TRIGGERED: Tilt Up (Present) - pitch=\(pitchDelta) < -\(currentPitchThreshold), dwell=\(elapsed)s")
                    }

                    // Determine triggered edge for wink animation
                    let triggeredEdge: GazeEdge
                    if detectedPose == .tiltUp {
                        triggeredEdge = .top
                    } else if signedYawDelta > 0 {
                        triggeredEdge = .left  // Positive yaw = left (camera mirror)
                    } else {
                        triggeredEdge = .right
                    }

                    // Require return to neutral before next trigger
                    requiresReturnToNeutral = true

                    if isCalibrationMode {
                        // Don't set hasRespondedThisWindow in calibration mode
                        // to allow repeated triggers for testing
                        DispatchQueue.main.async {
                            self.dwellProgress = 0
                            self.onGazeTrigger?(triggeredEdge)
                            self.onCalibrationTriggered?(detectedPose)
                        }
                    } else {
                        hasRespondedThisWindow = true
                        DispatchQueue.main.async {
                            self.dwellProgress = 0
                            self.onGazeTrigger?(triggeredEdge)
                            self.onPoseDetected?(detectedPose)
                        }
                    }

                    // Reset dwell tracking completely after trigger
                    dwellStartTime = nil
                    currentDwellPose = .neutral
                }
            } else {
                // New pose detected, start dwell timer
                dwellStartTime = Date()
                currentDwellPose = detectedPose
                DispatchQueue.main.async {
                    self.dwellProgress = 0
                }
            }
        } else {
            // Back to neutral, reset dwell tracking and allow new triggers
            if dwellStartTime != nil || currentDwellPose != .neutral || requiresReturnToNeutral {
                dwellStartTime = nil
                currentDwellPose = .neutral
                requiresReturnToNeutral = false  // Can trigger again after returning to neutral
                DispatchQueue.main.async {
                    self.dwellProgress = 0
                }
            }
        }
    }
}

extension HeadPoseDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processFrame(pixelBuffer)
    }
}

// MARK: - Helper Extensions

extension Double {
    func nonZeroOr(_ defaultValue: Double) -> Double {
        self == 0 ? defaultValue : self
    }
}
