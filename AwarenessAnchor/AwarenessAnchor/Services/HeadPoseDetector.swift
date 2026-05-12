import Foundation
import Vision
import AVFoundation
import AppKit

enum HeadPose: Equatable {
    case neutral
    case tiltUp      // Pitch > threshold -> "Already present"
    case turnLeftRight  // Yaw > threshold -> "Returned to awareness"
}

/// Screen edge for gaze direction indicator
enum GazeEdge: Equatable {
    case none
    case top      // Looking up
    case left     // Turned left
    case right    // Turned right
}

// MARK: - HeadPoseEngine (pure, testable trigger logic)

/// A single frame of recorded face-tracking data for replay in tests.
struct PoseFrame {
    let pitch: Float
    let yaw: Float
    let boundingBoxWidth: Float
    let timestamp: TimeInterval
}

/// How thresholds are resolved per frame.
enum ThresholdMode: Equatable {
    /// Fixed thresholds (external monitor / manual configuration).
    case manual(pitch: Float, yaw: Float)
    /// Geometric thresholds computed from bounding box width + screen geometry each frame.
    case auto(screenWidthMeters: Float, screenHeightMeters: Float,
              cameraHFOVDegrees: Float, sensitivityMultiplier: Float)
}

/// Configuration for HeadPoseEngine — all values needed to reproduce trigger behavior.
struct EngineConfig: Equatable {
    var thresholdMode: ThresholdMode = .manual(pitch: 0.16, yaw: 0.28)
    var smoothingFactor: Float = 0.5
    var dwellTime: Float = 0.2
    var framesToSkip: Int = 5
    var orthogonalSettleThreshold: Float = 0.02
}

/// Events emitted by HeadPoseEngine — no side effects, just data.
enum EngineEvent: Equatable {
    case triggered(pose: HeadPose, edge: GazeEdge)
    case returnedToNeutral
    case baselineSet(pitch: Float, yaw: Float)
    case dwellProgress(Float)
    case dwellBlocked
    case gazeUpdate(pitchDelta: Float, signedYawDelta: Float,
                    topIntensity: Float, leftIntensity: Float, rightIntensity: Float,
                    normalizedYaw: Float, normalizedPitch: Float,
                    gazeEdge: GazeEdge, gazeIntensity: Float)
    case autoThresholdsComputed(pitch: Float, yaw: Float, distance: Float)
    case skippingFrame
}

/// Pure, side-effect-free engine that processes face pose frames and emits events.
/// Tests feed it PoseFrame sequences and assert on returned events.
struct HeadPoseEngine {
    var config: EngineConfig

    // Mutable state
    private(set) var baselinePitch: Float?
    private(set) var baselineYaw: Float?
    private var smoothedPitch: Float = 0
    private var smoothedYaw: Float = 0
    private var isFirstReading = true
    private var framesToSkip: Int = 0
    private var dwellStartTimestamp: TimeInterval?
    private var currentDwellPose: HeadPose = .neutral
    private(set) var requiresReturnToNeutral: Bool = false
    var isInCooldown: Bool = false
    // Applied uniformly to both pitch and yaw thresholds. Set to >1.0 during a
    // correction window to require a larger head movement for the swap gesture.
    var correctionThresholdMultiplier: Float = 1.0
    private var previousPitchDelta: Float?
    private var previousSignedYawDelta: Float?

    // Auto threshold state (readable by detector for UI)
    private(set) var autoComputedPitchThreshold: Float = 0
    private(set) var autoComputedYawThreshold: Float = 0
    private(set) var estimatedFaceDistanceMeters: Float = 0

    init(config: EngineConfig) {
        self.config = config
        self.framesToSkip = config.framesToSkip
    }

    /// Feed a single frame. Returns zero or more events.
    mutating func feed(pitch: Float, yaw: Float,
                       boundingBoxWidth: Float,
                       at timestamp: TimeInterval) -> [EngineEvent] {
        var events: [EngineEvent] = []

        // Skip initial frames for camera stabilization
        if framesToSkip > 0 {
            framesToSkip -= 1
            events.append(.skippingFrame)
            return events
        }

        // IIR smoothing
        let alpha = 1.0 - config.smoothingFactor
        if isFirstReading {
            smoothedPitch = pitch
            smoothedYaw = yaw
            isFirstReading = false
        } else {
            smoothedPitch = alpha * pitch + config.smoothingFactor * smoothedPitch
            smoothedYaw = alpha * yaw + config.smoothingFactor * smoothedYaw
        }

        // Establish baseline on first stable reading
        if baselinePitch == nil {
            baselinePitch = smoothedPitch
            baselineYaw = smoothedYaw
            events.append(.baselineSet(pitch: smoothedPitch, yaw: smoothedYaw))

            // Compute auto thresholds at baseline if in auto mode
            if case .auto = config.thresholdMode {
                events.append(contentsOf: computeAutoThresholds(boundingBoxWidth: boundingBoxWidth))
            }
            return events
        }

        let pitchDelta = smoothedPitch - (baselinePitch ?? 0)
        let signedYawDelta = smoothedYaw - (baselineYaw ?? 0)
        let yawDelta = abs(signedYawDelta)

        // Orthogonal stillness tracking
        let pitchSpeed = abs(pitchDelta - (previousPitchDelta ?? pitchDelta))
        let yawSpeed = abs(signedYawDelta - (previousSignedYawDelta ?? signedYawDelta))
        previousPitchDelta = pitchDelta
        previousSignedYawDelta = signedYawDelta

        // Resolve effective thresholds
        let (currentPitchThreshold, currentYawThreshold) = effectiveThresholds(boundingBoxWidth: boundingBoxWidth)

        // Emit gaze update for UI
        let yawIntensity = currentYawThreshold > 0 ? min(abs(signedYawDelta) / currentYawThreshold, 1.0) : 0
        let pitchIntensity = currentPitchThreshold > 0 ? min(abs(pitchDelta) / currentPitchThreshold, 1.0) : 0

        let topI: Float = pitchDelta < -0.02 ? pitchIntensity : 0
        let leftI: Float = signedYawDelta > 0.02 ? yawIntensity : 0
        let rightI: Float = signedYawDelta < -0.02 ? yawIntensity : 0

        let normalizedYaw = currentYawThreshold > 0
            ? (1.0 - min(max(signedYawDelta / currentYawThreshold, -1.0), 1.0)) / 2.0
            : 0.5
        let normalizedPitch = currentPitchThreshold > 0
            ? (1.0 - min(max(pitchDelta / currentPitchThreshold, -1.0), 1.0)) / 2.0
            : 0.5

        let gazeEdge: GazeEdge
        let gazeInt: Float
        if signedYawDelta > 0.02 && yawIntensity > pitchIntensity {
            gazeEdge = .left
            gazeInt = yawIntensity
        } else if signedYawDelta < -0.02 && yawIntensity > pitchIntensity {
            gazeEdge = .right
            gazeInt = yawIntensity
        } else if pitchDelta < -0.02 {
            gazeEdge = .top
            gazeInt = pitchIntensity
        } else {
            gazeEdge = .none
            gazeInt = 0
        }

        events.append(.gazeUpdate(
            pitchDelta: pitchDelta, signedYawDelta: signedYawDelta,
            topIntensity: topI, leftIntensity: leftI, rightIntensity: rightI,
            normalizedYaw: normalizedYaw, normalizedPitch: normalizedPitch,
            gazeEdge: gazeEdge, gazeIntensity: gazeInt
        ))

        // Pose detection
        var detectedPose: HeadPose = .neutral
        if yawDelta > currentYawThreshold {
            detectedPose = .turnLeftRight
        } else if pitchDelta < -currentPitchThreshold {
            detectedPose = .tiltUp
        }

        // Dwell tracking
        if detectedPose != .neutral {
            if requiresReturnToNeutral || isInCooldown {
                events.append(.dwellBlocked)
                return events
            }

            if detectedPose == currentDwellPose, let startTime = dwellStartTimestamp {
                // Orthogonal stillness check
                let isSettled: Bool
                if detectedPose == .tiltUp {
                    isSettled = yawSpeed < config.orthogonalSettleThreshold
                } else {
                    isSettled = pitchSpeed < config.orthogonalSettleThreshold
                }
                if !isSettled {
                    dwellStartTimestamp = timestamp
                }

                let elapsed = Float(timestamp - (dwellStartTimestamp ?? startTime))
                let progress = min(elapsed / config.dwellTime, 1.0)
                events.append(.dwellProgress(progress))

                if elapsed >= config.dwellTime {
                    // Trigger!
                    let triggeredEdge: GazeEdge
                    if detectedPose == .tiltUp {
                        triggeredEdge = .top
                    } else if signedYawDelta > 0 {
                        triggeredEdge = .left
                    } else {
                        triggeredEdge = .right
                    }

                    requiresReturnToNeutral = true
                    events.append(.triggered(pose: detectedPose, edge: triggeredEdge))

                    // Reset dwell
                    dwellStartTimestamp = nil
                    currentDwellPose = .neutral
                }
            } else {
                // New pose, start dwell
                dwellStartTimestamp = timestamp
                currentDwellPose = detectedPose
                events.append(.dwellProgress(0))
            }
        } else {
            // Neutral — reset dwell
            if dwellStartTimestamp != nil || currentDwellPose != .neutral {
                dwellStartTimestamp = nil
                currentDwellPose = .neutral
                events.append(.dwellProgress(0))
            }

            if requiresReturnToNeutral {
                requiresReturnToNeutral = false
                events.append(.returnedToNeutral)
            }
        }

        return events
    }

    /// Reset all mutable state (for new window/calibration session).
    mutating func reset() {
        baselinePitch = nil
        baselineYaw = nil
        smoothedPitch = 0
        smoothedYaw = 0
        isFirstReading = true
        framesToSkip = config.framesToSkip
        dwellStartTimestamp = nil
        currentDwellPose = .neutral
        requiresReturnToNeutral = false
        isInCooldown = false
        previousPitchDelta = nil
        previousSignedYawDelta = nil
        autoComputedPitchThreshold = 0
        autoComputedYawThreshold = 0
        estimatedFaceDistanceMeters = 0
    }

    // MARK: - Threshold resolution

    func effectiveThresholds(boundingBoxWidth: Float) -> (pitch: Float, yaw: Float) {
        let base: (pitch: Float, yaw: Float)
        switch config.thresholdMode {
        case .manual(let pitch, let yaw):
            base = (pitch, yaw)
        case .auto(let screenW, let screenH, let hfov, let mult):
            let distance = DisplayGeometry.estimateFaceDistance(boundingBoxWidth: boundingBoxWidth, cameraHFOVDegrees: hfov)
            guard distance > 0 else { return (0, 0) }
            let rawPitch = DisplayGeometry.computePitchThreshold(screenHeightMeters: screenH, faceDistanceMeters: distance)
            let rawYaw = DisplayGeometry.computeYawThreshold(screenWidthMeters: screenW, faceDistanceMeters: distance)
            base = (rawPitch * mult, rawYaw * mult)
        }
        return (base.pitch * correctionThresholdMultiplier, base.yaw * correctionThresholdMultiplier)
    }

    private mutating func computeAutoThresholds(boundingBoxWidth bbW: Float) -> [EngineEvent] {
        guard case .auto(let screenW, let screenH, let hfov, _) = config.thresholdMode else { return [] }
        let distance = DisplayGeometry.estimateFaceDistance(boundingBoxWidth: bbW, cameraHFOVDegrees: hfov)
        guard distance > 0 else { return [] }

        let rawPitch = DisplayGeometry.computePitchThreshold(screenHeightMeters: screenH, faceDistanceMeters: distance)
        let rawYaw = DisplayGeometry.computeYawThreshold(screenWidthMeters: screenW, faceDistanceMeters: distance)

        autoComputedPitchThreshold = rawPitch
        autoComputedYawThreshold = rawYaw
        estimatedFaceDistanceMeters = distance

        return [.autoThresholdsComputed(pitch: rawPitch, yaw: rawYaw, distance: distance)]
    }
}

/// Geometry helpers for computing head pose thresholds from known laptop screen dimensions.
struct DisplayGeometry {
    static let averageFaceWidthMeters: Float = 0.16

    /// True when the only connected display is the built-in laptop screen (no external monitors).
    /// Auto thresholds only apply in this case since camera-to-screen geometry is fully known.
    static var isLaptopOnly: Bool {
        guard let builtIn = builtInDisplayID else { return false }
        // Check that the built-in display exists AND is the only screen
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &displayCount)
        return displayCount == 1 && displayIDs[0] == builtIn
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

    // MARK: - Pure engine (delegated trigger logic)
    private var engine: HeadPoseEngine = HeadPoseEngine(config: EngineConfig())
    private var sessionStartTime: Date = Date()

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

    private var hasRespondedThisWindow = false

    // Correction mode: after a response is recorded, the detector keeps running
    // for a few seconds with one gesture allowed (the opposite of the recorded one)
    // so the user can swap their answer hands-free.
    // - Same-pose triggers are dropped before the callback fires.
    // - Intensities for the disallowed direction are masked to 0, so the screen-edge
    //   glow never invites the user to perform the same gesture again.
    private(set) var correctionAllowedPose: HeadPose? = nil

    @Published var dwellProgress: Float = 0  // 0 to 1, for UI display

    // External cooldown flag - set by AppDelegate to prevent triggers during cooldown period
    @Published var isInCooldown: Bool = false {
        didSet { engine.isInCooldown = isInCooldown }
    }

    // Face check mode: briefly start camera to detect face presence before chime
    private var isCheckingForFace = false
    private var faceCheckCompletion: ((Bool) -> Void)?
    private var faceCheckTimer: Timer?

    // Pre-chime pose capture: baseline from face detection before chime plays
    private var preChimePitch: Float?
    private var preChimeYaw: Float?

    // MARK: - Recording (for test case capture)
    @Published var isRecordingEnabled = false
    @Published var recordingFrameCount: Int = 0
    private var recordingBuffer: [(pitch: Float, yaw: Float, bbw: Float, t: TimeInterval)] = []
    private var recordingStartTime: Date?

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
        isAutoThresholdActive = DisplayGeometry.isLaptopOnly
        appLog("[HP] Auto threshold mode: \(isAutoThresholdActive ? "ON (laptop only)" : "OFF (external monitor connected)")")

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
            self.isAutoThresholdActive = DisplayGeometry.isLaptopOnly
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

    /// Sync engine config from current UserDefaults / auto-threshold state.
    private func syncEngineConfig() {
        let mode: ThresholdMode
        if isAutoThresholdActive, let screenSize = DisplayGeometry.screenSizeMeters {
            mode = .auto(screenWidthMeters: screenSize.width,
                         screenHeightMeters: screenSize.height,
                         cameraHFOVDegrees: cameraHFOVDegrees,
                         sensitivityMultiplier: autoSensitivityMultiplier)
        } else {
            mode = .manual(pitch: pitchThreshold, yaw: yawThreshold)
        }
        engine.config.thresholdMode = mode
        engine.config.smoothingFactor = smoothingFactor
        engine.config.dwellTime = dwellTime
        engine.isInCooldown = isInCooldown
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
        sessionStartTime = Date()

        syncEngineConfig()
        engine.reset()

        // Discard pre-chime pose — single-frame snapshots are unreliable and poison
        // the smoother if they differ from the stabilized tracking position.
        // Let the first real frame after skip initialize the smoother cleanly.
        if preChimePitch != nil || preChimeYaw != nil {
            appLog("[HP]Discarding pre-chime data (pitch=\(preChimePitch ?? 0), yaw=\(preChimeYaw ?? 0)) — will init from stabilized frames")
            preChimePitch = nil
            preChimeYaw = nil
        }

        DispatchQueue.main.async {
            self.debugBaseline = "Calibrating..."
            self.faceDetected = false
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

    // MARK: - Correction Mode

    /// Re-open detection for a swap. Clears the "already responded" gate so the engine
    /// can fire a second trigger, but only the allowed pose will be reported through.
    func beginCorrectionMode(allowedPose: HeadPose) {
        let multiplier = HeadPoseDetector.configuredCorrectionMultiplier()
        appLog("[HP] beginCorrectionMode allowed=\(allowedPose) multiplier=\(multiplier)")
        correctionAllowedPose = allowedPose
        engine.correctionThresholdMultiplier = multiplier
        hasRespondedThisWindow = false
        DispatchQueue.main.async {
            self.isAwaitingReturnToNeutral = false
            // Zero the disallowed direction immediately so the glow doesn't linger.
            switch allowedPose {
            case .tiltUp:
                self.leftIntensity = 0
                self.rightIntensity = 0
            case .turnLeftRight:
                self.topIntensity = 0
            case .neutral:
                break
            }
        }
    }

    func endCorrectionMode() {
        appLog("[HP] endCorrectionMode")
        correctionAllowedPose = nil
        engine.correctionThresholdMultiplier = 1.0
        hasRespondedThisWindow = true
    }

    /// Read the user-configured correction threshold multiplier. Defaults to 1.25
    /// when the setting has never been written.
    static func configuredCorrectionMultiplier() -> Float {
        let stored = UserDefaults.standard.object(forKey: "correctionThresholdMultiplier") as? Double
        return Float(stored ?? 1.25)
    }

    // MARK: - Calibration Mode

    func startCalibration() {
        // Set up capture session if needed
        if captureSession == nil && !isActive {
            startDetection()
        }

        appLog("[HP]Starting calibration mode...")
        isCalibrationMode = true
        isWindowActive = true
        hasRespondedThisWindow = false
        sessionStartTime = Date()

        syncEngineConfig()
        engine.reset()

        DispatchQueue.main.async {
            self.isCalibrationActive = true
            self.debugBaseline = "Waiting for baseline..."
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
        hasRespondedThisWindow = false
        sessionStartTime = Date()
        syncEngineConfig()
        engine.reset()
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

                // Compute auto thresholds from face bounding box (pre-chime)
                if DisplayGeometry.isLaptopOnly {
                    let bbW = Float(face.boundingBox.width)
                    let dist = DisplayGeometry.estimateFaceDistance(boundingBoxWidth: bbW, cameraHFOVDegrees: self.cameraHFOVDegrees)
                    if dist > 0, let screenSize = DisplayGeometry.screenSizeMeters {
                        let rawPitch = DisplayGeometry.computePitchThreshold(screenHeightMeters: screenSize.height, faceDistanceMeters: dist)
                        let rawYaw = DisplayGeometry.computeYawThreshold(screenWidthMeters: screenSize.width, faceDistanceMeters: dist)
                        DispatchQueue.main.async {
                            self.estimatedFaceDistanceMeters = dist
                            self.autoComputedPitchThreshold = rawPitch
                            self.autoComputedYawThreshold = rawYaw
                        }
                    }
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

        appLog("[HP]Face found - pitch: \(String(describing: face.pitch)), yaw: \(String(describing: face.yaw)), roll: \(String(describing: face.roll))")

        guard let pitch = face.pitch?.floatValue,
              let yaw = face.yaw?.floatValue else {
            DispatchQueue.main.async {
                self.faceDetected = true
                self.debugBaseline = "Face found, no pose data"
            }
            appLog("[HP]No pitch/yaw data available (face detected but pose nil)")
            return
        }

        let bbw = Float(face.boundingBox.width)
        let timestamp = Date().timeIntervalSince(sessionStartTime)

        // Record frame if recording is active
        if isRecordingEnabled {
            let t = Date().timeIntervalSince(recordingStartTime ?? Date())
            recordingBuffer.append((pitch: pitch, yaw: yaw, bbw: bbw, t: t))
            DispatchQueue.main.async {
                self.recordingFrameCount = self.recordingBuffer.count
            }
        }

        // Delegate to pure engine
        let events = engine.feed(pitch: pitch, yaw: yaw, boundingBoxWidth: bbw, at: timestamp)

        // Dispatch engine events to published properties and callbacks
        for event in events {
            switch event {
            case .skippingFrame:
                DispatchQueue.main.async {
                    self.faceDetected = true
                    self.debugBaseline = "Stabilizing camera..."
                }

            case .baselineSet(let bPitch, let bYaw):
                appLog("[HP]Baseline set: pitch=\(bPitch), yaw=\(bYaw) (auto=\(self.isAutoThresholdActive))")
                DispatchQueue.main.async {
                    self.faceDetected = true
                    self.debugBaseline = String(format: "Baseline: P=%.2f, Y=%.2f", bPitch, bYaw)
                }

            case .autoThresholdsComputed(let rawPitch, let rawYaw, let distance):
                appLog("[HP] Auto threshold: dist=\(String(format: "%.2f", distance))m, pitch=\(String(format: "%.3f", rawPitch)), yaw=\(String(format: "%.3f", rawYaw))")
                DispatchQueue.main.async {
                    self.estimatedFaceDistanceMeters = distance
                    self.autoComputedPitchThreshold = rawPitch
                    self.autoComputedYawThreshold = rawYaw
                }

            case .gazeUpdate(let pitchDelta, let signedYawDelta, let topI, let leftI, let rightI,
                             let normYaw, let normPitch, let edge, let intensity):
                let yawDelta = abs(signedYawDelta)

                // Mask intensities for the disallowed direction while in correction mode.
                var publishedTopI = topI
                var publishedLeftI = leftI
                var publishedRightI = rightI
                if let allowed = self.correctionAllowedPose {
                    switch allowed {
                    case .tiltUp:
                        publishedLeftI = 0
                        publishedRightI = 0
                    case .turnLeftRight:
                        publishedTopI = 0
                    case .neutral:
                        break
                    }
                }

                DispatchQueue.main.async {
                    self.faceDetected = true
                    self.debugPitch = pitchDelta
                    self.debugYaw = yawDelta
                    self.debugRawPitch = pitch
                    self.debugRawYaw = yaw
                    self.topIntensity = publishedTopI
                    self.leftIntensity = publishedLeftI
                    self.rightIntensity = publishedRightI
                    self.normalizedYawPosition = normYaw
                    self.normalizedPitchPosition = normPitch
                    self.currentGazeEdge = edge
                    self.gazeIntensity = intensity
                }

                // Calibration callback
                if self.isCalibrationMode {
                    DispatchQueue.main.async {
                        self.onCalibrationUpdate?(pitch, yaw, pitchDelta, yawDelta, signedYawDelta)
                    }
                }

            case .dwellProgress(let progress):
                DispatchQueue.main.async {
                    self.dwellProgress = progress
                }

            case .dwellBlocked:
                appLog("[HP]Dwell BLOCKED: rtn=\(self.engine.requiresReturnToNeutral) cool=\(self.isInCooldown)")

            case .triggered(let pose, let triggeredEdge):
                // In correction mode only the opposite gesture is allowed through.
                if let allowed = self.correctionAllowedPose, pose != allowed {
                    appLog("[HP] correction-mode drop: \(pose) (only \(allowed) allowed)")
                    break
                }

                if pose == .turnLeftRight {
                    appLog("[HP]TRIGGERED: Turn Left/Right (Returned)")
                } else {
                    appLog("[HP]TRIGGERED: Tilt Up (Present)")
                }

                DispatchQueue.main.async {
                    self.isAwaitingReturnToNeutral = true
                }

                if self.isCalibrationMode {
                    DispatchQueue.main.async {
                        self.dwellProgress = 0
                        self.onGazeTrigger?(triggeredEdge)
                        self.onCalibrationTriggered?(pose, triggeredEdge)
                    }
                } else {
                    self.hasRespondedThisWindow = true
                    DispatchQueue.main.async {
                        self.dwellProgress = 0
                        self.onGazeTrigger?(triggeredEdge)
                        self.onPoseDetected?(pose)
                    }
                }

            case .returnedToNeutral:
                DispatchQueue.main.async {
                    self.isAwaitingReturnToNeutral = false
                    self.onReturnToNeutral?()
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        recordingBuffer = []
        recordingStartTime = Date()
        DispatchQueue.main.async {
            self.recordingFrameCount = 0
            self.isRecordingEnabled = true
        }
        appLog("[HP] Recording started")
    }

    func stopRecording() -> URL? {
        DispatchQueue.main.async {
            self.isRecordingEnabled = false
        }
        appLog("[HP] Recording stopped (\(recordingBuffer.count) frames)")

        guard !recordingBuffer.isEmpty else { return nil }

        // Build JSON with metadata
        let metadata: [String: Any]
        if isAutoThresholdActive, let screenSize = DisplayGeometry.screenSizeMeters {
            metadata = [
                "displayMode": "laptop",
                "screenWidthMeters": screenSize.width,
                "screenHeightMeters": screenSize.height,
                "cameraHFOVDegrees": cameraHFOVDegrees,
                "sensitivityMultiplier": autoSensitivityMultiplier
            ]
        } else {
            metadata = [
                "displayMode": "external",
                "manualPitchThreshold": pitchThreshold,
                "manualYawThreshold": yawThreshold
            ]
        }

        let frames = recordingBuffer.map { frame -> [String: Any] in
            [
                "pitch": Double(String(format: "%.4f", frame.pitch))!,
                "yaw": Double(String(format: "%.4f", frame.yaw))!,
                "bbw": Double(String(format: "%.4f", frame.bbw))!,
                "t": Double(String(format: "%.3f", frame.t))!
            ]
        }

        let recording: [String: Any] = [
            "metadata": metadata,
            "frames": frames
        ]

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "headpose_recording_\(formatter.string(from: Date())).json"
        let desktopURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent(filename)

        do {
            let data = try JSONSerialization.data(withJSONObject: recording, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: desktopURL)
            appLog("[HP] Recording saved to \(desktopURL.path)")
            recordingBuffer = []
            return desktopURL
        } catch {
            appLog("[HP] Failed to save recording: \(error)")
            recordingBuffer = []
            return nil
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
