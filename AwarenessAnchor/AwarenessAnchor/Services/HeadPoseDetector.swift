import Foundation
import Vision
import AVFoundation
import AppKit

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

/// Geometry helpers for computing head pose thresholds from known laptop screen dimensions.
struct DisplayGeometry {
    static let averageFaceWidthMeters: Float = 0.16

    /// True when the currently active screen is the built-in display (camera-to-screen geometry is known).
    /// Works even when external monitors are connected — only the active screen matters.
    static var isCurrentScreenBuiltIn: Bool {
        guard let mainScreen = NSScreen.main else { return false }
        let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// Physical screen size in meters for the built-in display.
    static var screenSizeMeters: (width: Float, height: Float)? {
        // Always use the built-in display dimensions (camera is fixed to it)
        let builtInID = builtInDisplayID ?? CGMainDisplayID()
        let sizeMM = CGDisplayScreenSize(builtInID)
        guard sizeMM.width > 0, sizeMM.height > 0 else { return nil }
        return (width: Float(sizeMM.width) / 1000.0, height: Float(sizeMM.height) / 1000.0)
    }

    /// Find the built-in display ID (if any).
    private static var builtInDisplayID: CGDirectDisplayID? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &displayCount)
        for i in 0..<Int(displayCount) {
            if CGDisplayIsBuiltin(displayIDs[i]) != 0 {
                return displayIDs[i]
            }
        }
        return nil
    }

    /// Estimate face distance from camera using bounding box width and horizontal FOV.
    static func estimateFaceDistance(boundingBoxWidth: Float, cameraHFOVDegrees: Float) -> Float {
        guard boundingBoxWidth > 0 else { return 0 }
        let halfAngle = (boundingBoxWidth * cameraHFOVDegrees * .pi / 180.0) / 2.0
        guard halfAngle > 0 else { return 0 }
        return averageFaceWidthMeters / (2.0 * tan(halfAngle))
    }

    /// Geometric pitch threshold: angle subtended by half the screen height at the given distance.
    static func computePitchThreshold(screenHeightMeters: Float, faceDistanceMeters: Float) -> Float {
        guard faceDistanceMeters > 0 else { return 0 }
        return atan(screenHeightMeters / 2.0 / faceDistanceMeters)
    }

    /// Geometric yaw threshold: angle subtended by half the screen width at the given distance.
    static func computeYawThreshold(screenWidthMeters: Float, faceDistanceMeters: Float) -> Float {
        guard faceDistanceMeters > 0 else { return 0 }
        return atan(screenWidthMeters / 2.0 / faceDistanceMeters)
    }
}

class HeadPoseDetector: NSObject, ObservableObject {
    var onPoseDetected: ((HeadPose) -> Void)?

    // Callback for calibration mode - fires on every frame with raw values
    // Parameters: (rawPitch, rawYaw, deltaPitch, absYawDelta, signedYawDelta)
    var onCalibrationUpdate: ((Float, Float, Float, Float, Float) -> Void)?
    var onCalibrationTriggered: ((HeadPose, GazeEdge) -> Void)?  // Fires when threshold hit in calibration (includes edge for direction)

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

    // Separate intensities for multi-directional glow (0 to 1 each)
    @Published var topIntensity: Float = 0
    @Published var leftIntensity: Float = 0
    @Published var rightIntensity: Float = 0

    // Normalized gaze position for bulge effect (0-1 range)
    // yawPosition: 0 = full left, 0.5 = center, 1 = full right
    // pitchPosition: 0 = full down, 0.5 = center, 1 = full up
    @Published var normalizedYawPosition: Float = 0.5
    @Published var normalizedPitchPosition: Float = 0.5

    // Calibration state - observable by UI
    @Published var isCalibrationActive: Bool = false

    // Callback for when a trigger happens (for wink animation)
    var onGazeTrigger: ((GazeEdge) -> Void)?

    // Callback for when user returns to neutral after a trigger
    var onReturnToNeutral: (() -> Void)?

    // Published state for UI to know when we're waiting for return
    @Published var isAwaitingReturnToNeutral: Bool = false

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
        get { Float(UserDefaults.standard.double(forKey: "pitchThreshold").nonZeroOr(0.16)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "pitchThreshold") }
    }
    var yawThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "yawThreshold").nonZeroOr(0.28)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "yawThreshold") }
    }
    var yawNoiseThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "yawNoiseThreshold").nonZeroOr(0.15)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "yawNoiseThreshold") }
    }

    // Smoothing factor for IIR filter (0 = no smoothing, 1 = infinite smoothing)
    // Lower value = more responsive but jittery, higher = smoother but laggy
    var smoothingFactor: Float {
        get { Float(UserDefaults.standard.double(forKey: "smoothingFactor").nonZeroOr(0.5)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "smoothingFactor") }
    }

    // Dwell time: how long (seconds) gaze must stay outside threshold before triggering
    var dwellTime: Float {
        get { Float(UserDefaults.standard.double(forKey: "dwellTime").nonZeroOr(0.2)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "dwellTime") }
    }

    // MARK: - Auto Thresholds (laptop geometry)

    @Published var isAutoThresholdActive: Bool = false
    @Published var autoComputedPitchThreshold: Float = 0
    @Published var autoComputedYawThreshold: Float = 0
    @Published var estimatedFaceDistanceMeters: Float = 0

    var autoSensitivityMultiplier: Float {
        get { Float(UserDefaults.standard.double(forKey: "autoSensitivityMultiplier").nonZeroOr(1.3)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "autoSensitivityMultiplier") }
    }

    private var cameraHFOVDegrees: Float = 64.0
    private var screenChangeObserver: NSObjectProtocol?

    var effectivePitchThreshold: Float {
        if isAutoThresholdActive, autoComputedPitchThreshold > 0 {
            return autoComputedPitchThreshold * autoSensitivityMultiplier
        }
        return pitchThreshold
    }

    var effectiveYawThreshold: Float {
        if isAutoThresholdActive, autoComputedYawThreshold > 0 {
            return autoComputedYawThreshold * autoSensitivityMultiplier
        }
        return yawThreshold
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

    // External cooldown flag - set by AppDelegate to prevent triggers during cooldown period
    @Published var isInCooldown: Bool = false

    // Face check mode: briefly start camera to detect face presence before chime
    private var isCheckingForFace = false
    private var faceCheckCompletion: ((Bool) -> Void)?
    private var faceCheckTimer: Timer?

    // Pre-chime pose capture: baseline from face detection before chime plays
    private var preChimePitch: Float?
    private var preChimeYaw: Float?

    // Orthogonal stillness tracking: frame-to-frame delta rates
    private var previousPitchDelta: Float?
    private var previousSignedYawDelta: Float?
    private let orthogonalSettleThreshold: Float = 0.02  // radians per frame

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

        // Camera HFOV: macOS doesn't expose videoFieldOfView, use 64° default
        // (MacBook FaceTime cameras are consistently ~64° HFOV)
        appLog("[HP] Camera HFOV: \(cameraHFOVDegrees)° (default)")

        // Set auto threshold mode based on display configuration
        isAutoThresholdActive = DisplayGeometry.isCurrentScreenBuiltIn
        appLog("[HP] Auto threshold mode: \(isAutoThresholdActive ? "ON (built-in screen)" : "OFF (external screen)")")

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput?.alwaysDiscardsLateVideoFrames = true

        if let output = videoOutput, captureSession?.canAddOutput(output) == true {
            captureSession?.addOutput(output)
        }

        // Listen for display configuration changes
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let wasAuto = self.isAutoThresholdActive
            self.isAutoThresholdActive = DisplayGeometry.isCurrentScreenBuiltIn
            if wasAuto != self.isAutoThresholdActive {
                appLog("[HP] Display changed — auto threshold: \(self.isAutoThresholdActive)")
                if !self.isAutoThresholdActive {
                    self.autoComputedPitchThreshold = 0
                    self.autoComputedYawThreshold = 0
                    self.estimatedFaceDistanceMeters = 0
                }
            }
        }

        isActive = true
        // Don't start capture session until response window opens
    }

    func stopDetection() {
        cancelFaceCheck()
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
        isActive = false
        isWindowActive = false
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
    }

    private func cancelFaceCheck() {
        if isCheckingForFace {
            isCheckingForFace = false
            faceCheckCompletion = nil
            faceCheckTimer?.invalidate()
            faceCheckTimer = nil
        }
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
        previousPitchDelta = nil
        previousSignedYawDelta = nil

        if isAutoThresholdActive {
            // Laptop mode: camera axis is always the baseline
            baselinePitch = 0
            baselineYaw = 0
        }

        // Use pre-chime pose for smoothing initialization (camera was already running for face check)
        if let pitch = preChimePitch, let yaw = preChimeYaw {
            smoothedPitch = pitch
            smoothedYaw = yaw
            isFirstReading = false
            framesToSkip = 0  // Camera already stabilized from face check

            if !isAutoThresholdActive {
                baselinePitch = pitch
                baselineYaw = yaw
                appLog("[HP]Using pre-chime baseline: pitch=\(pitch), yaw=\(yaw)")
            } else {
                appLog("[HP]Auto baseline: (0,0) — pre-chime smoothing init: pitch=\(pitch), yaw=\(yaw)")
            }
            preChimePitch = nil
            preChimeYaw = nil
        }

        DispatchQueue.main.async {
            self.debugBaseline = self.baselinePitch != nil
                ? String(format: "Baseline: P=%.2f, Y=%.2f", self.baselinePitch ?? 0, self.baselineYaw ?? 0)
                : "Calibrating..."
            self.faceDetected = self.baselinePitch != nil  // Already detected if we have pre-chime data
            self.dwellProgress = 0
            self.isAwaitingReturnToNeutral = false
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

        // Reset gaze edge and intensities
        DispatchQueue.main.async {
            self.currentGazeEdge = .none
            self.gazeIntensity = 0
            self.topIntensity = 0
            self.leftIntensity = 0
            self.rightIntensity = 0
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
        isFirstReading = true
        smoothedPitch = 0
        smoothedYaw = 0
        framesToSkip = 3  // Skip first few frames to let camera stabilize
        dwellStartTime = nil
        currentDwellPose = .neutral
        requiresReturnToNeutral = false
        previousPitchDelta = nil
        previousSignedYawDelta = nil

        if isAutoThresholdActive {
            // Laptop mode: camera axis is always the baseline
            baselinePitch = 0
            baselineYaw = 0
            appLog("[HP]Calibration auto baseline: (0,0)")
        } else {
            baselinePitch = nil
            baselineYaw = nil
        }

        DispatchQueue.main.async {
            self.isCalibrationActive = true
            self.debugBaseline = self.isAutoThresholdActive ? "Baseline: camera axis (auto)" : "Waiting for baseline..."
            self.faceDetected = false
            self.dwellProgress = 0
            self.isAwaitingReturnToNeutral = false
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
            self.topIntensity = 0
            self.leftIntensity = 0
            self.rightIntensity = 0
            self.dwellProgress = 0
            self.isAwaitingReturnToNeutral = false
            self.isInCooldown = false
        }
    }

    func resetCalibrationBaseline() {
        if isAutoThresholdActive {
            baselinePitch = 0
            baselineYaw = 0
        } else {
            baselinePitch = nil
            baselineYaw = nil
        }
        hasRespondedThisWindow = false
        isFirstReading = true
        dwellStartTime = nil
        currentDwellPose = .neutral
        requiresReturnToNeutral = false
        previousPitchDelta = nil
        previousSignedYawDelta = nil
        DispatchQueue.main.async {
            self.debugBaseline = "Waiting for baseline..."
            self.debugPitch = 0
            self.debugYaw = 0
            self.dwellProgress = 0
        }
    }

    // MARK: - Face Check (pre-chime gating)

    /// Briefly start camera to check if a face is present before playing a chime.
    /// Calls completion(true) as soon as a face is detected, or completion(false) on timeout.
    /// Camera stays running on success (response window will take over via activateForWindow).
    func checkForFace(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard isActive, captureSession != nil else {
            appLog("[HP] checkForFace: detector not active")
            completion(false)
            return
        }

        appLog("[HP] Starting face check (timeout: \(timeout)s)")
        isCheckingForFace = true
        faceCheckCompletion = completion

        // Start camera
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
            appLog("[HP] Face check camera started")
        }

        // Set timeout
        faceCheckTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self = self, self.isCheckingForFace else { return }
            appLog("[HP] Face check timed out after \(timeout)s")
            self.isCheckingForFace = false
            self.faceCheckCompletion = nil
            self.captureSession?.stopRunning()
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    /// Called when a face is found during face check mode
    private func faceCheckFound() {
        guard isCheckingForFace, let completion = faceCheckCompletion else { return }
        appLog("[HP] Face check succeeded - face detected")
        isCheckingForFace = false
        faceCheckCompletion = nil
        faceCheckTimer?.invalidate()
        faceCheckTimer = nil
        // Don't stop camera - response window will take over
        DispatchQueue.main.async {
            completion(true)
        }
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        // Allow processing during face check, active window, or calibration
        guard isCheckingForFace || (isWindowActive && (isCalibrationMode || !hasRespondedThisWindow)) else { return }

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

            // In face check mode, detect presence and capture pose for pre-chime baseline
            if self.isCheckingForFace {
                if let p = face.pitch?.floatValue, let y = face.yaw?.floatValue {
                    self.preChimePitch = p
                    self.preChimeYaw = y
                    appLog("[HP] Pre-chime pose captured: pitch=\(p), yaw=\(y)")
                }

                // Compute auto thresholds from face bounding box
                if DisplayGeometry.isCurrentScreenBuiltIn {
                    self.computeAutoThresholds(boundingBoxWidth: Float(face.boundingBox.width))
                }

                DispatchQueue.main.async {
                    self.faceDetected = true
                }
                self.faceCheckFound()
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
            if isAutoThresholdActive {
                // Laptop mode: camera axis is the baseline (geometry fully defines screen center)
                baselinePitch = 0
                baselineYaw = 0
                appLog("[HP]Auto baseline: (0,0) — raw smoothed: pitch=\(smoothedPitch), yaw=\(smoothedYaw)")
            } else {
                baselinePitch = smoothedPitch
                baselineYaw = smoothedYaw
                appLog("[HP]Baseline set: pitch=\(smoothedPitch), yaw=\(smoothedYaw)")
            }

            // Compute auto thresholds from current face bbox
            if DisplayGeometry.isCurrentScreenBuiltIn {
                computeAutoThresholds(boundingBoxWidth: Float(face.boundingBox.width))
            }

            DispatchQueue.main.async {
                self.debugBaseline = self.isAutoThresholdActive
                    ? "Baseline: camera axis (auto)"
                    : String(format: "Baseline: P=%.2f, Y=%.2f", self.baselinePitch ?? 0, self.baselineYaw ?? 0)
            }
            return
        }

        let pitchDelta = smoothedPitch - (baselinePitch ?? 0)
        let signedYawDelta = smoothedYaw - (baselineYaw ?? 0)
        let yawDelta = abs(signedYawDelta)

        // Orthogonal stillness: track frame-to-frame rate of change
        let pitchSpeed = abs(pitchDelta - (previousPitchDelta ?? pitchDelta))
        let yawSpeed = abs(signedYawDelta - (previousSignedYawDelta ?? signedYawDelta))
        previousPitchDelta = pitchDelta
        previousSignedYawDelta = signedYawDelta

        // Update debug values and gaze edge on main thread
        DispatchQueue.main.async {
            self.faceDetected = true
            self.debugPitch = pitchDelta
            self.debugYaw = yawDelta
            self.debugRawPitch = pitch
            self.debugRawYaw = yaw

            // Update gaze edge and intensity for screen glow indicator
            // Intensity goes from 0 (center) to 1 (at threshold)
            let yawThresh = self.effectiveYawThreshold
            let pitchThresh = self.effectivePitchThreshold

            // Calculate intensity as ratio of delta to threshold (clamped 0-1)
            let yawIntensity = min(abs(signedYawDelta) / yawThresh, 1.0)
            let pitchIntensity = min(abs(pitchDelta) / pitchThresh, 1.0)

            // Update separate intensities for multi-directional glow
            // Top: only when tilting up (negative pitch delta)
            self.topIntensity = pitchDelta < -0.02 ? pitchIntensity : 0

            // Left: positive yaw = looking left (camera mirror)
            self.leftIntensity = signedYawDelta > 0.02 ? yawIntensity : 0

            // Right: negative yaw = looking right (camera mirror)
            self.rightIntensity = signedYawDelta < -0.02 ? yawIntensity : 0

            // Update normalized gaze position for bulge effect
            // Yaw: positive yaw = looking left, map to screen X position
            let normalizedYaw = min(max(signedYawDelta / yawThresh, -1.0), 1.0)
            // When looking left (+yaw), bulge should be on left side (low X), so invert
            self.normalizedYawPosition = (1.0 - normalizedYaw) / 2.0  // Range: 0 (looking right) to 1 (looking left)

            // Pitch: negative pitch = looking up, map to screen Y position
            let normalizedPitch = min(max(pitchDelta / pitchThresh, -1.0), 1.0)
            // When looking up (-pitch), bulge should be at top (high Y), so invert the negative
            self.normalizedPitchPosition = (1.0 - normalizedPitch) / 2.0  // Range: 0 (looking down) to 1 (looking up)

            // Determine primary edge based on which direction has highest intensity (for legacy compatibility)
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

        appLog("[HP]Delta: pitch=\(pitchDelta), yaw=\(yawDelta), yawSpd=\(String(format: "%.4f", yawSpeed)), pitchSpd=\(String(format: "%.4f", pitchSpeed))")

        // Gesture priority: YAW takes precedence over PITCH
        //
        // When yaw exceeds its threshold, it wins (turnLeftRight). Otherwise,
        // pitch is evaluated independently. The orthogonal stillness check
        // prevents false triggers during active re-centering movement.

        // Get current thresholds (auto-computed or manual)
        let currentPitchThreshold = effectivePitchThreshold
        let currentYawThreshold = effectiveYawThreshold
        let currentDwellTime = dwellTime

        // Determine which pose is detected (if any)
        var detectedPose: HeadPose = .neutral

        if yawDelta > currentYawThreshold {
            // Turning head left/right -> "Returned to awareness"
            detectedPose = .turnLeftRight
        } else if pitchDelta < -currentPitchThreshold {
            // Tilt up -> "Already present" (orthogonal stillness gates the dwell)
            detectedPose = .tiltUp
        }

        // Dwell time tracking
        if detectedPose != .neutral {
            // Don't start new dwell if we're waiting for return to neutral or in cooldown
            if requiresReturnToNeutral || isInCooldown {
                appLog("[HP]Dwell BLOCKED: rtn=\(requiresReturnToNeutral) cool=\(isInCooldown) pose=\(detectedPose)")
                return
            }

            if detectedPose == currentDwellPose, let startTime = dwellStartTime {
                // Orthogonal stillness: pause dwell if user is still re-centering on the other axis
                let isSettled: Bool
                if detectedPose == .tiltUp {
                    isSettled = yawSpeed < orthogonalSettleThreshold
                } else {
                    isSettled = pitchSpeed < orthogonalSettleThreshold
                }
                if !isSettled {
                    dwellStartTime = Date()  // Push dwell forward — still re-centering
                    appLog("[HP]Dwell PUSHED: pose=\(detectedPose) yawSpd=\(String(format: "%.4f", yawSpeed)) pitchSpd=\(String(format: "%.4f", pitchSpeed))")
                }

                // Same pose, check if dwell time exceeded
                let elapsed = Float(Date().timeIntervalSince(dwellStartTime ?? startTime))
                appLog("[HP]Dwell: pose=\(detectedPose) elapsed=\(String(format: "%.3f", elapsed))s/\(currentDwellTime)s settled=\(isSettled)")
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
                    DispatchQueue.main.async {
                        self.isAwaitingReturnToNeutral = true
                    }

                    if isCalibrationMode {
                        // Don't set hasRespondedThisWindow in calibration mode
                        // to allow repeated triggers for testing
                        DispatchQueue.main.async {
                            self.dwellProgress = 0
                            self.onGazeTrigger?(triggeredEdge)
                            self.onCalibrationTriggered?(detectedPose, triggeredEdge)
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
                appLog("[HP]Dwell NEW: pose=\(detectedPose) (was \(currentDwellPose))")
                dwellStartTime = Date()
                currentDwellPose = detectedPose
                DispatchQueue.main.async {
                    self.dwellProgress = 0
                }
            }
        } else {
            // Back to neutral, reset dwell tracking and allow new triggers
            if dwellStartTime != nil || currentDwellPose != .neutral {
                dwellStartTime = nil
                currentDwellPose = .neutral
                DispatchQueue.main.async {
                    self.dwellProgress = 0
                }
            }

            // Fire callback when returning to neutral after a trigger
            if requiresReturnToNeutral {
                requiresReturnToNeutral = false
                DispatchQueue.main.async {
                    self.isAwaitingReturnToNeutral = false
                    self.onReturnToNeutral?()
                }
            }
        }
    }
    // MARK: - Auto Threshold Computation

    private func computeAutoThresholds(boundingBoxWidth bbW: Float) {
        let distance = DisplayGeometry.estimateFaceDistance(boundingBoxWidth: bbW, cameraHFOVDegrees: cameraHFOVDegrees)
        guard distance > 0, let screenSize = DisplayGeometry.screenSizeMeters else { return }

        let rawPitch = DisplayGeometry.computePitchThreshold(screenHeightMeters: screenSize.height, faceDistanceMeters: distance)
        let rawYaw = DisplayGeometry.computeYawThreshold(screenWidthMeters: screenSize.width, faceDistanceMeters: distance)

        appLog("[HP] Auto threshold: bbW=\(String(format: "%.3f", bbW)), dist=\(String(format: "%.2f", distance))m, pitch=\(String(format: "%.3f", rawPitch)), yaw=\(String(format: "%.3f", rawYaw))")

        DispatchQueue.main.async {
            self.estimatedFaceDistanceMeters = distance
            self.autoComputedPitchThreshold = rawPitch
            self.autoComputedYawThreshold = rawYaw
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
