import Foundation
import Combine
import AppKit

/// Coordinates between HeadPoseDetector and MouseEdgeDetector, providing unified
/// intensity values for screen edge glow based on motion-based precedence.
class InputCoordinator: ObservableObject {
    // MARK: - Input Sources

    let headPoseDetector: HeadPoseDetector
    let mouseEdgeDetector: MouseEdgeDetector

    // MARK: - Published Properties (unified output)

    /// Unified intensity values - these are what AppDelegate subscribes to
    @Published var topIntensity: Float = 0
    @Published var leftIntensity: Float = 0
    @Published var rightIntensity: Float = 0

    /// Which input source is currently active
    @Published var activeSource: InputSource = .none

    /// Combined dwell progress (from active source)
    @Published var dwellProgress: Float = 0

    /// Combined awaiting return to neutral state
    @Published var isAwaitingReturnToNeutral: Bool = false

    /// Combined cooldown state
    @Published var isInCooldown: Bool = false

    /// Pass through face detected from head pose
    @Published var faceDetected: Bool = false

    /// Pass through calibration active state
    @Published var isCalibrationActive: Bool = false

    // MARK: - Callbacks (unified)

    var onGazeTrigger: ((GazeEdge) -> Void)?
    var onReturnToNeutral: (() -> Void)?
    var onPoseDetected: ((HeadPose) -> Void)?

    // MARK: - Input Source Enum

    enum InputSource: String {
        case none
        case headPose
        case mouse
    }

    // MARK: - Motion Tracking for Precedence

    /// Smoothed speed values (normalized: 0-1 scale for both)
    private var smoothedHeadSpeed: Float = 0
    private var smoothedMouseSpeed: Float = 0

    /// Previous positions for speed calculation
    private var lastHeadPitch: Float?
    private var lastHeadYaw: Float?
    private var lastMouseX: CGFloat?
    private var lastMouseY: CGFloat?
    private var lastSpeedUpdateTime: Date?

    /// Smoothing factor for speed (0 = responsive, 1 = very smooth)
    private let speedSmoothing: Float = 0.8

    /// Speed update timer
    private var speedUpdateTimer: Timer?

    /// Source switch debouncing: a candidate must stay dominant for this long before we switch
    private let sourceSwitchDelay: TimeInterval = 0.5
    private var pendingSource: InputSource?
    private var pendingSwitchStartTime: Date?

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Settings

    private var headPoseEnabled: Bool {
        UserDefaults.standard.bool(forKey: "headPoseEnabled")
    }

    private var mouseTrackingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "mouseTrackingEnabled")
    }

    // MARK: - Initialization

    init(headPoseDetector: HeadPoseDetector, mouseEdgeDetector: MouseEdgeDetector) {
        self.headPoseDetector = headPoseDetector
        self.mouseEdgeDetector = mouseEdgeDetector

        setupBindings()
    }

    convenience init() {
        self.init(headPoseDetector: HeadPoseDetector(), mouseEdgeDetector: MouseEdgeDetector())
    }

    private func setupBindings() {
        // Forward head pose intensity changes
        headPoseDetector.$topIntensity
            .combineLatest(headPoseDetector.$leftIntensity, headPoseDetector.$rightIntensity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] top, left, right in
                self?.updateHeadPoseInput(top: top, left: left, right: right)
            }
            .store(in: &cancellables)

        // Forward mouse intensity changes
        mouseEdgeDetector.$topIntensity
            .combineLatest(mouseEdgeDetector.$leftIntensity, mouseEdgeDetector.$rightIntensity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] top, left, right in
                self?.updateMouseInput(top: top, left: left, right: right)
            }
            .store(in: &cancellables)

        // Forward dwell progress
        headPoseDetector.$dwellProgress
            .combineLatest(mouseEdgeDetector.$dwellProgress)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] headDwell, mouseDwell in
                guard let self = self else { return }
                switch self.activeSource {
                case .headPose:
                    self.dwellProgress = headDwell
                case .mouse:
                    self.dwellProgress = mouseDwell
                case .none:
                    self.dwellProgress = max(headDwell, mouseDwell)
                }
            }
            .store(in: &cancellables)

        // Forward awaiting return to neutral
        headPoseDetector.$isAwaitingReturnToNeutral
            .combineLatest(mouseEdgeDetector.$isAwaitingReturnToNeutral)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] head, mouse in
                self?.isAwaitingReturnToNeutral = head || mouse
            }
            .store(in: &cancellables)

        // Forward cooldown state
        headPoseDetector.$isInCooldown
            .combineLatest(mouseEdgeDetector.$isInCooldown)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] head, mouse in
                self?.isInCooldown = head || mouse
            }
            .store(in: &cancellables)

        // Forward face detected
        headPoseDetector.$faceDetected
            .receive(on: DispatchQueue.main)
            .assign(to: &$faceDetected)

        // Note: isCalibrationActive is managed directly by startCalibration/stopCalibration
        // rather than forwarding from detectors, to ensure it works for both mouse and head pose

        // Set up trigger callbacks
        headPoseDetector.onGazeTrigger = { [weak self] edge in
            guard let self = self else { return }
            if self.activeSource != .mouse {  // Only fire if head pose is active
                self.onGazeTrigger?(edge)
            }
        }

        mouseEdgeDetector.onGazeTrigger = { [weak self] edge in
            guard let self = self else { return }
            if self.activeSource != .headPose {  // Only fire if mouse is active
                self.onGazeTrigger?(edge)
            }
        }

        headPoseDetector.onReturnToNeutral = { [weak self] in
            self?.onReturnToNeutral?()
        }

        mouseEdgeDetector.onReturnToNeutral = { [weak self] in
            guard let self = self else { return }
            self.onReturnToNeutral?()
            // If the response window already ended and we were holding glow
            // for the post-trigger state, clean up now
            if !self.mouseEdgeDetector.isWindowActive {
                self.activeSource = .none
            }
        }

        headPoseDetector.onPoseDetected = { [weak self] pose in
            guard let self = self else { return }
            if self.activeSource != .mouse {
                self.onPoseDetected?(pose)
            }
        }

        mouseEdgeDetector.onPoseDetected = { [weak self] pose in
            guard let self = self else { return }
            if self.activeSource != .headPose {
                self.onPoseDetected?(pose)
            }
        }
    }

    // MARK: - Lifecycle

    func startDetection() {
        if headPoseEnabled {
            headPoseDetector.startDetection()
        }
        if mouseTrackingEnabled {
            mouseEdgeDetector.startDetection()
        }

        // Start speed update timer
        startSpeedTracking()
    }

    func stopDetection() {
        headPoseDetector.stopDetection()
        mouseEdgeDetector.stopDetection()
        stopSpeedTracking()
        activeSource = .none
    }

    func activateForWindow() {
        appLog("[Coord] Activating for window - head:\(headPoseEnabled) mouse:\(mouseTrackingEnabled)")

        if headPoseEnabled {
            headPoseDetector.activateForWindow()
        }
        if mouseTrackingEnabled {
            mouseEdgeDetector.activateForWindow()
        }

        // Reset speed tracking and pending source switch
        smoothedHeadSpeed = 0
        smoothedMouseSpeed = 0
        lastHeadPitch = nil
        lastHeadYaw = nil
        lastMouseX = nil
        lastMouseY = nil
        lastSpeedUpdateTime = nil
        pendingSource = nil
        pendingSwitchStartTime = nil
    }

    func deactivateWindow() {
        headPoseDetector.deactivateWindow()
        mouseEdgeDetector.deactivateWindow()

        // Don't reset activeSource or intensities if mouse is awaiting return to neutral
        // (glow should persist until mouse moves away from edge)
        if !mouseEdgeDetector.isAwaitingReturnToNeutral {
            activeSource = .none
            DispatchQueue.main.async {
                self.topIntensity = 0
                self.leftIntensity = 0
                self.rightIntensity = 0
            }
        }
    }

    // MARK: - Calibration Mode

    func startCalibration() {
        appLog("[Coord] Starting calibration - head:\(headPoseEnabled) mouse:\(mouseTrackingEnabled)")

        // Set calibration active immediately
        DispatchQueue.main.async {
            self.isCalibrationActive = true
        }

        if headPoseEnabled {
            headPoseDetector.startCalibration()
        }
        if mouseTrackingEnabled {
            mouseEdgeDetector.startCalibration()
        }

        startSpeedTracking()
    }

    func stopCalibration() {
        appLog("[Coord] Stopping calibration")

        headPoseDetector.stopCalibration()
        mouseEdgeDetector.stopCalibration()
        stopSpeedTracking()
        activeSource = .none

        // Clear calibration active state
        DispatchQueue.main.async {
            self.isCalibrationActive = false
            self.topIntensity = 0
            self.leftIntensity = 0
            self.rightIntensity = 0
            self.dwellProgress = 0
        }
    }

    // MARK: - Speed Tracking

    private func startSpeedTracking() {
        speedUpdateTimer?.invalidate()
        speedUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.updateSpeeds()
        }
    }

    private func stopSpeedTracking() {
        speedUpdateTimer?.invalidate()
        speedUpdateTimer = nil
    }

    private func updateSpeeds() {
        let now = Date()
        guard let lastTime = lastSpeedUpdateTime else {
            lastSpeedUpdateTime = now
            return
        }

        let deltaTime = Float(now.timeIntervalSince(lastTime))
        guard deltaTime > 0 else { return }

        // Calculate head pose speed (% of frustum per second)
        var headSpeed: Float = 0
        let currentPitch = headPoseDetector.debugPitch
        let currentYaw = headPoseDetector.debugYaw

        if let lastPitch = lastHeadPitch, let lastYaw = lastHeadYaw {
            let pitchDelta = abs(currentPitch - lastPitch)
            let yawDelta = abs(currentYaw - lastYaw)
            // Normalize by threshold to get % of frustum
            let pitchThreshold = headPoseDetector.pitchThreshold
            let yawThreshold = headPoseDetector.yawThreshold
            let normalizedPitchSpeed = (pitchDelta / pitchThreshold) / deltaTime
            let normalizedYawSpeed = (yawDelta / yawThreshold) / deltaTime
            headSpeed = max(normalizedPitchSpeed, normalizedYawSpeed)
        }
        lastHeadPitch = currentPitch
        lastHeadYaw = currentYaw

        // Calculate mouse speed (% of screen per second)
        var mouseSpeed: Float = 0
        if let mousePos = mouseEdgeDetector.lastMousePosition,
           let screen = NSScreen.main {
            if let lastX = lastMouseX, let lastY = lastMouseY {
                let dx = abs(mousePos.x - lastX)
                let dy = abs(mousePos.y - lastY)
                // Normalize by screen size
                let normalizedXSpeed = Float(dx / screen.frame.width) / deltaTime
                let normalizedYSpeed = Float(dy / screen.frame.height) / deltaTime
                mouseSpeed = max(normalizedXSpeed, normalizedYSpeed)
            }
            lastMouseX = mousePos.x
            lastMouseY = mousePos.y
        }

        // Apply smoothing
        smoothedHeadSpeed = speedSmoothing * smoothedHeadSpeed + (1 - speedSmoothing) * headSpeed
        smoothedMouseSpeed = speedSmoothing * smoothedMouseSpeed + (1 - speedSmoothing) * mouseSpeed

        lastSpeedUpdateTime = now

        // Determine active source based on which has higher speed
        let previousSource = activeSource
        if headPoseEnabled && mouseTrackingEnabled {
            // Lock to mouse immediately while actively dwelling or awaiting return after trigger
            let mouseLocked = mouseEdgeDetector.dwellProgress > 0 || mouseEdgeDetector.isAwaitingReturnToNeutral
            if mouseLocked {
                activeSource = .mouse
                pendingSource = nil
                pendingSwitchStartTime = nil
            } else {
                // Determine which source the speed comparison suggests
                var suggestedSource: InputSource? = nil
                if smoothedHeadSpeed > smoothedMouseSpeed * 1.2 {
                    suggestedSource = .headPose
                } else if smoothedMouseSpeed > smoothedHeadSpeed * 1.2 {
                    suggestedSource = .mouse
                }
                // If speeds are similar, no suggestion (keep current)

                if let suggested = suggestedSource, suggested != activeSource {
                    // Different source wants to take over — start or continue the hold timer
                    if pendingSource == suggested, let startTime = pendingSwitchStartTime {
                        // Same candidate still dominant — check if hold period elapsed
                        if now.timeIntervalSince(startTime) >= sourceSwitchDelay {
                            activeSource = suggested
                            pendingSource = nil
                            pendingSwitchStartTime = nil
                        }
                    } else {
                        // New candidate — start the hold timer
                        pendingSource = suggested
                        pendingSwitchStartTime = now
                    }
                } else {
                    // Current source is still dominant (or speeds similar) — cancel any pending switch
                    pendingSource = nil
                    pendingSwitchStartTime = nil
                }
            }
        } else if headPoseEnabled {
            activeSource = .headPose
        } else if mouseTrackingEnabled {
            activeSource = .mouse
        } else {
            activeSource = .none
        }

        if activeSource != previousSource {
            appLog("[Coord] Source changed: \(previousSource.rawValue) -> \(activeSource.rawValue)")
        }
    }

    // MARK: - Input Updates

    private func updateHeadPoseInput(top: Float, left: Float, right: Float) {
        // Only use head pose if it's the active source (or only source)
        guard headPoseEnabled else { return }
        guard activeSource == .headPose || !mouseTrackingEnabled else { return }

        self.topIntensity = top
        self.leftIntensity = left
        self.rightIntensity = right
    }

    private func updateMouseInput(top: Float, left: Float, right: Float) {
        guard mouseTrackingEnabled else { return }
        // Forward mouse intensities if mouse is active source, only source,
        // or in post-trigger state (glow persists until return to neutral)
        guard activeSource == .mouse || !headPoseEnabled || mouseEdgeDetector.isAwaitingReturnToNeutral else { return }

        self.topIntensity = top
        self.leftIntensity = left
        self.rightIntensity = right
    }

    // MARK: - Passthrough Properties

    /// Whether face was detected during current window (for head pose)
    var faceWasDetectedThisWindow: Bool {
        headPoseDetector.faceWasDetectedThisWindow
    }

    /// Current gaze edge from head pose (for legacy compatibility)
    var currentGazeEdge: GazeEdge {
        headPoseDetector.currentGazeEdge
    }
}
