import Foundation
import AppKit
import Combine

/// Detects mouse pointer proximity to screen edges, providing the same interface as HeadPoseDetector
/// for unified input handling via InputCoordinator.
class MouseEdgeDetector: ObservableObject {
    // MARK: - Published Properties (matching HeadPoseDetector interface)

    /// Intensity values for each edge (0-1), based on mouse proximity
    @Published var topIntensity: Float = 0
    @Published var leftIntensity: Float = 0
    @Published var rightIntensity: Float = 0

    /// Progress toward dwell trigger (0-1)
    @Published var dwellProgress: Float = 0

    /// Whether we're waiting for mouse to return to center after a trigger
    @Published var isAwaitingReturnToNeutral: Bool = false

    /// External cooldown flag - set by InputCoordinator
    @Published var isInCooldown: Bool = false

    /// Whether mouse is currently in an active zone
    @Published var isActive: Bool = false

    /// Normalized mouse position for bulge effect (0-1 range)
    /// xPosition: 0 = full left, 0.5 = center, 1 = full right
    /// yPosition: 0 = full down, 0.5 = center, 1 = full up
    @Published var normalizedXPosition: Float = 0.5
    @Published var normalizedYPosition: Float = 0.5

    // MARK: - Callbacks (matching HeadPoseDetector interface)

    /// Called when dwell threshold exceeded at an edge
    var onGazeTrigger: ((GazeEdge) -> Void)?

    /// Called when mouse returns to neutral zone after a trigger
    var onReturnToNeutral: (() -> Void)?

    /// Called when a pose/edge is detected (for AppState compatibility)
    var onPoseDetected: ((HeadPose) -> Void)?

    /// Called when trigger happens in calibration mode (for UI feedback)
    var onCalibrationTriggered: ((HeadPose, GazeEdge) -> Void)?

    // MARK: - Configuration (fixed, not user-configurable)

    /// Size of the zone where glow intensity gradually appears (pixels from edge)
    let glowZonePixels: CGFloat = 150

    /// Size of the trigger zone at screen edge where dwell counting starts
    let triggerZonePixels: CGFloat = 10

    /// Minimum distance from edge to be considered "neutral" (for return-to-neutral detection)
    let neutralZonePixels: CGFloat = 200

    // MARK: - Private State

    private var eventMonitor: Any?
    private var isWindowActive = false
    private var isCalibrationMode = false

    // Dwell time tracking (uses HeadPoseDetector's dwellTime setting)
    private var dwellStartTime: Date?
    private var currentDwellEdge: GazeEdge = .none
    private var requiresReturnToNeutral: Bool = false

    // Track current mouse position for speed calculations
    private(set) var lastMousePosition: CGPoint?
    private(set) var lastUpdateTime: Date?

    // MARK: - Dwell Time (reads from HeadPoseDetector's UserDefaults)

    var dwellTime: Float {
        Float(UserDefaults.standard.double(forKey: "dwellTime").nonZeroOr(0.2))
    }

    // MARK: - Lifecycle

    func startDetection() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.processMouseEvent(event)
        }

        // Also monitor local events when app is focused
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.processMouseEvent(event)
            return event
        }

        isActive = true
    }

    func stopDetection() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isActive = false
        isWindowActive = false
        resetState()
    }

    func activateForWindow() {
        guard eventMonitor != nil else {
            appLog("[Mouse] activateForWindow called but detector not active")
            return
        }

        appLog("[Mouse] Window activated, starting mouse tracking...")
        isWindowActive = true
        dwellStartTime = nil
        currentDwellEdge = .none
        requiresReturnToNeutral = false

        DispatchQueue.main.async {
            self.dwellProgress = 0
            self.isAwaitingReturnToNeutral = false
        }
    }

    func deactivateWindow() {
        isWindowActive = false
        resetState()
    }

    // MARK: - Calibration Mode

    func startCalibration() {
        if eventMonitor == nil {
            startDetection()
        }

        appLog("[Mouse] Starting calibration mode...")
        isCalibrationMode = true
        isWindowActive = true
        dwellStartTime = nil
        currentDwellEdge = .none
        requiresReturnToNeutral = false

        DispatchQueue.main.async {
            self.dwellProgress = 0
            self.isAwaitingReturnToNeutral = false
        }
    }

    func stopCalibration() {
        appLog("[Mouse] Stopping calibration mode...")
        isCalibrationMode = false
        isWindowActive = false
        resetState()
    }

    // MARK: - Private Methods

    private func resetState() {
        DispatchQueue.main.async {
            self.topIntensity = 0
            self.leftIntensity = 0
            self.rightIntensity = 0
            self.dwellProgress = 0
            self.isAwaitingReturnToNeutral = false
            self.isInCooldown = false
        }
        dwellStartTime = nil
        currentDwellEdge = .none
        requiresReturnToNeutral = false
    }

    private func processMouseEvent(_ event: NSEvent) {
        guard isWindowActive else { return }

        let mouseLocation = NSEvent.mouseLocation

        // Update tracking for speed calculation
        lastMousePosition = mouseLocation
        lastUpdateTime = Date()

        // Get the screen where mouse is located
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) else { return }
        let screenFrame = screen.frame

        // Calculate screen center
        let centerX = screenFrame.midX
        let centerY = screenFrame.midY

        // Calculate distances from center (like head pose does from neutral)
        let deltaX = mouseLocation.x - centerX  // Positive = right, Negative = left
        let deltaY = mouseLocation.y - centerY  // Positive = up, Negative = down

        // Calculate max possible distance to each edge from center
        let maxDistanceToTop = screenFrame.maxY - centerY
        let maxDistanceToLeft = centerX - screenFrame.minX
        let maxDistanceToRight = screenFrame.maxX - centerX

        // Calculate intensities as fraction of distance to edge (matching head pose behavior)
        // Intensity starts at 0 at center and reaches 1 at edge
        // Only show intensity in the direction of movement (like head pose)
        let deadZone: CGFloat = 20  // Small dead zone at center (like head pose's 0.02 threshold)

        var rawTopIntensity: CGFloat = 0
        var rawLeftIntensity: CGFloat = 0
        var rawRightIntensity: CGFloat = 0

        // Top: only when mouse is above center
        if deltaY > deadZone {
            rawTopIntensity = min(deltaY / maxDistanceToTop, 1.0)
        }

        // Left: only when mouse is left of center
        if deltaX < -deadZone {
            rawLeftIntensity = min(abs(deltaX) / maxDistanceToLeft, 1.0)
        }

        // Right: only when mouse is right of center
        if deltaX > deadZone {
            rawRightIntensity = min(deltaX / maxDistanceToRight, 1.0)
        }

        // Calculate distances from each edge for trigger zone detection
        let distanceFromTop = screenFrame.maxY - mouseLocation.y
        let distanceFromLeft = mouseLocation.x - screenFrame.minX
        let distanceFromRight = screenFrame.maxX - mouseLocation.x
        let distanceFromBottom = mouseLocation.y - screenFrame.minY

        // Determine which edge we're closest to (if any is in trigger zone)
        var detectedEdge: GazeEdge = .none

        if distanceFromTop <= triggerZonePixels {
            detectedEdge = .top
        } else if distanceFromLeft <= triggerZonePixels {
            detectedEdge = .left
        } else if distanceFromRight <= triggerZonePixels {
            detectedEdge = .right
        }

        // Check if we're in neutral zone (near center, for return-to-neutral detection)
        let distanceFromCenter = sqrt(deltaX * deltaX + deltaY * deltaY)
        let neutralRadius = min(screenFrame.width, screenFrame.height) * 0.2  // 20% of smaller dimension
        let isInNeutralZone = distanceFromCenter < neutralRadius

        // Calculate normalized position for bulge effect (0-1 range)
        let normalizedX = Float((mouseLocation.x - screenFrame.minX) / screenFrame.width)
        let normalizedY = Float((mouseLocation.y - screenFrame.minY) / screenFrame.height)

        // Update published intensities and positions on main thread
        DispatchQueue.main.async {
            self.topIntensity = Float(rawTopIntensity)
            self.leftIntensity = Float(rawLeftIntensity)
            self.rightIntensity = Float(rawRightIntensity)
            self.normalizedXPosition = normalizedX
            self.normalizedYPosition = normalizedY
        }

        // Handle dwell tracking
        processDwellLogic(detectedEdge: detectedEdge, isInNeutralZone: isInNeutralZone)
    }

    private func processDwellLogic(detectedEdge: GazeEdge, isInNeutralZone: Bool) {
        let currentDwellTime = dwellTime

        if detectedEdge != .none {
            // Don't start new dwell if waiting for return or in cooldown
            if requiresReturnToNeutral || isInCooldown {
                return
            }

            if detectedEdge == currentDwellEdge, let startTime = dwellStartTime {
                // Same edge, check dwell progress
                let elapsed = Float(Date().timeIntervalSince(startTime))
                let progress = min(elapsed / currentDwellTime, 1.0)

                DispatchQueue.main.async {
                    self.dwellProgress = progress
                }

                if elapsed >= currentDwellTime {
                    // Dwell complete - trigger!
                    appLog("[Mouse] TRIGGERED: \(detectedEdge), dwell=\(elapsed)s")

                    requiresReturnToNeutral = true

                    // Map edge to HeadPose for compatibility
                    let pose: HeadPose = detectedEdge == .top ? .tiltUp : .turnLeftRight

                    DispatchQueue.main.async {
                        self.isAwaitingReturnToNeutral = true
                        self.dwellProgress = 0
                        self.onGazeTrigger?(detectedEdge)

                        if self.isCalibrationMode {
                            // In calibration mode, use dedicated callback for UI feedback (include edge for direction)
                            self.onCalibrationTriggered?(pose, detectedEdge)
                        } else {
                            // In normal mode, use pose detected callback
                            self.onPoseDetected?(pose)
                        }
                    }

                    // Reset dwell tracking
                    dwellStartTime = nil
                    currentDwellEdge = .none
                }
            } else {
                // New edge detected, start dwell timer
                dwellStartTime = Date()
                currentDwellEdge = detectedEdge
                DispatchQueue.main.async {
                    self.dwellProgress = 0
                }
            }
        } else {
            // Not at an edge, reset dwell tracking
            if dwellStartTime != nil || currentDwellEdge != .none {
                dwellStartTime = nil
                currentDwellEdge = .none
                DispatchQueue.main.async {
                    self.dwellProgress = 0
                }
            }

            // Check for return to neutral after a trigger
            if requiresReturnToNeutral && isInNeutralZone {
                requiresReturnToNeutral = false
                DispatchQueue.main.async {
                    self.isAwaitingReturnToNeutral = false
                    self.onReturnToNeutral?()
                }
            }
        }
    }
}
