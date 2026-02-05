import SwiftUI
import AppKit
import Combine

@main
struct AwarenessAnchorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    let appState = AppState.shared
    private var eventMonitor: Any?
    private var iconResetTimer: Timer?
    private var feedbackWindow: NSWindow?

    // Multi-directional glow windows
    private var topGlowWindow: NSWindow?
    private var leftGlowWindow: NSWindow?
    private var rightGlowWindow: NSWindow?
    private var topGlowView: GradientGlowView?
    private var leftGlowView: GradientGlowView?
    private var rightGlowView: GradientGlowView?

    // Smoothed glow intensities (extra smoothing for subtle effect)
    private var smoothedTopIntensity: CGFloat = 0
    private var smoothedLeftIntensity: CGFloat = 0
    private var smoothedRightIntensity: CGFloat = 0

    private var gazeIntensityCancellable: AnyCancellable?
    private var topIntensityCancellable: AnyCancellable?
    private var leftIntensityCancellable: AnyCancellable?
    private var rightIntensityCancellable: AnyCancellable?
    private var calibrationActiveCancellable: AnyCancellable?
    private var currentGazeEdge: GazeEdge = .none
    private var isWinkAnimating: Bool = false
    private var activeWinkEdge: GazeEdge = .none  // Track which edge has active white glow
    private var isInCooldown: Bool = false  // Cooldown after return to neutral in calibration

    @AppStorage("screenGlowEnabled") private var screenGlowEnabled = true
    @AppStorage("screenGlowOpacity") private var screenGlowOpacity = 0.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Awareness Anchor")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(appState)
        )

        // Set up global hotkey monitoring
        setupHotkeyMonitor()

        // Set up response feedback callback
        setupResponseFeedback()

        // Set up sleep/wake observers
        setupSleepWakeObservers()

        // Hide dock icon (menu bar only app)
        NSApp.setActivationPolicy(.accessory)

        // Initialize services
        appState.initialize()

        // Set up gaze edge glow observer
        setupGazeEdgeObserver()
    }

    private func setupSleepWakeObservers() {
        // Observe system sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        // Observe system wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleSystemSleep(_ notification: Notification) {
        appState.handleSleep()
    }

    @objc private func handleSystemWake(_ notification: Notification) {
        appState.handleWake()
    }

    private func setupGazeEdgeObserver() {
        let coordinator = appState.inputCoordinator

        // Observe gaze edge changes (for legacy currentGazeEdge tracking)
        gazeIntensityCancellable = appState.headPoseDetector.$currentGazeEdge
            .receive(on: DispatchQueue.main)
            .sink { [weak self] edge in
                self?.currentGazeEdge = edge
            }

        // Observe unified intensities from InputCoordinator for multi-directional glow
        topIntensityCancellable = coordinator.$topIntensity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] intensity in
                self?.updateEdgeGlow(edge: .top, rawIntensity: CGFloat(intensity))
            }

        leftIntensityCancellable = coordinator.$leftIntensity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] intensity in
                self?.updateEdgeGlow(edge: .left, rawIntensity: CGFloat(intensity))
            }

        rightIntensityCancellable = coordinator.$rightIntensity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] intensity in
                self?.updateEdgeGlow(edge: .right, rawIntensity: CGFloat(intensity))
            }

        // Set up trigger callback for wink animation (via coordinator)
        coordinator.onGazeTrigger = { [weak self] edge in
            self?.performWinkAnimation(for: edge)
        }

        // Set up return-to-neutral callback for fading out white glow
        coordinator.onReturnToNeutral = { [weak self] in
            self?.handleReturnToNeutral()
        }

        // Hide all glows when calibration/tracking stops
        calibrationActiveCancellable = coordinator.$isCalibrationActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                if !isActive {
                    self?.hideAllGlowWindows()
                    self?.smoothedTopIntensity = 0
                    self?.smoothedLeftIntensity = 0
                    self?.smoothedRightIntensity = 0
                }
            }
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func setupHotkeyMonitor() {
        // Monitor for global keyboard shortcuts
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyEvent(event)
        }

        // Also monitor local events when app is focused
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyEvent(event)
            return event
        }
    }

    private func setupResponseFeedback() {
        // Subscribe to response events for visual feedback
        appState.onResponseRecorded = { [weak self] responseType in
            self?.showResponseFeedback(responseType)
        }
    }

    private func handleGlobalKeyEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Shift+1 -> Already Present
        if flags.contains([.command, .shift]) && event.keyCode == 18 { // keyCode 18 = "1"
            appState.recordResponse(.present)
        }
        // Cmd+Shift+2 -> Returned to Awareness
        else if flags.contains([.command, .shift]) && event.keyCode == 19 { // keyCode 19 = "2"
            appState.recordResponse(.returned)
        }
    }

    // MARK: - Visual Feedback

    func showResponseFeedback(_ type: ResponseType) {
        // Ensure main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showResponseFeedback(type)
            }
            return
        }

        // 1. Change menu bar icon temporarily
        showIconFeedback(for: type)

        // 2. Show screen edge glow (disabled for debugging)
        // showScreenGlow(for: type)
    }

    private func showIconFeedback(for type: ResponseType) {
        let iconName: String
        switch type {
        case .present:
            iconName = "sun.max.fill"
        case .returned:
            iconName = "arrow.uturn.backward.circle.fill"
        case .missed:
            return // No feedback for missed
        }

        // Change icon
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        }

        // Reset after 3 seconds
        iconResetTimer?.invalidate()
        iconResetTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            if let button = self?.statusItem.button {
                button.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Awareness Anchor")
            }
        }
    }

    private func updateEdgeGlow(edge: GazeEdge, rawIntensity: CGFloat) {
        // Don't update during wink animation or cooldown period
        if isWinkAnimating || isInCooldown { return }

        // Check if glow is enabled
        if !screenGlowEnabled {
            hideAllGlowWindows()
            return
        }

        // Get extra smoothing factor (smoothingFactor + 0.1, clamped to max 0.95)
        let baseSmoothingFactor = CGFloat(appState.headPoseDetector.smoothingFactor)
        let glowSmoothing = min(baseSmoothingFactor + 0.1, 0.95)

        // Get gaze position for bulge effect
        let coordinator = appState.inputCoordinator
        let yawPosition: CGFloat
        let pitchPosition: CGFloat

        if coordinator.activeSource == .mouse {
            // Mouse: use normalized position for bulge effect
            yawPosition = CGFloat(appState.mouseEdgeDetector.normalizedXPosition)
            pitchPosition = CGFloat(appState.mouseEdgeDetector.normalizedYPosition)
        } else {
            // Head pose: use normalized positions for bulge effect
            yawPosition = CGFloat(appState.headPoseDetector.normalizedYawPosition)
            pitchPosition = CGFloat(appState.headPoseDetector.normalizedPitchPosition)
        }

        // Apply extra smoothing and update the appropriate edge
        switch edge {
        case .top:
            smoothedTopIntensity = glowSmoothing * smoothedTopIntensity + (1 - glowSmoothing) * rawIntensity
            updateSingleEdgeGlow(
                edge: .top,
                intensity: smoothedTopIntensity,
                bulgePosition: yawPosition,  // Horizontal position for top edge
                window: &topGlowWindow,
                view: &topGlowView,
                color: .systemGreen,
                direction: .fromTop
            )
        case .left:
            smoothedLeftIntensity = glowSmoothing * smoothedLeftIntensity + (1 - glowSmoothing) * rawIntensity
            updateSingleEdgeGlow(
                edge: .left,
                intensity: smoothedLeftIntensity,
                bulgePosition: pitchPosition,  // Vertical position for left edge
                window: &leftGlowWindow,
                view: &leftGlowView,
                color: .systemOrange,
                direction: .fromLeft
            )
        case .right:
            smoothedRightIntensity = glowSmoothing * smoothedRightIntensity + (1 - glowSmoothing) * rawIntensity
            updateSingleEdgeGlow(
                edge: .right,
                intensity: smoothedRightIntensity,
                bulgePosition: pitchPosition,  // Vertical position for right edge
                window: &rightGlowWindow,
                view: &rightGlowView,
                color: .systemOrange,
                direction: .fromRight
            )
        case .none:
            break
        }
    }

    private func updateSingleEdgeGlow(
        edge: GazeEdge,
        intensity: CGFloat,
        bulgePosition: CGFloat,
        window: inout NSWindow?,
        view: inout GradientGlowView?,
        color: NSColor,
        direction: GradientGlowView.GradientDirection
    ) {
        // Hide if intensity too low
        if intensity < 0.01 {
            window?.orderOut(nil)
            return
        }

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let glowDepth: CGFloat = 300  // Larger to accommodate 2x bulge

        // Calculate window frame based on edge
        let windowFrame: NSRect
        switch edge {
        case .top:
            windowFrame = NSRect(
                x: screenFrame.minX,
                y: screenFrame.maxY - glowDepth,
                width: screenFrame.width,
                height: glowDepth
            )
        case .left:
            windowFrame = NSRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: glowDepth,
                height: screenFrame.height
            )
        case .right:
            windowFrame = NSRect(
                x: screenFrame.maxX - glowDepth,
                y: screenFrame.minY,
                width: glowDepth,
                height: screenFrame.height
            )
        case .none:
            return
        }

        // Create window and view if needed
        if window == nil {
            let newWindow = NSWindow(
                contentRect: windowFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            newWindow.isOpaque = false
            newWindow.backgroundColor = .clear
            newWindow.level = .screenSaver
            newWindow.ignoresMouseEvents = true
            newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]
            newWindow.hasShadow = false

            let glowView = GradientGlowView(frame: NSRect(origin: .zero, size: windowFrame.size))
            newWindow.contentView = glowView
            window = newWindow
            view = glowView
        }

        // Update window frame and view
        window?.setFrame(windowFrame, display: false)
        view?.frame = NSRect(origin: .zero, size: windowFrame.size)
        // Pass intensity as bulgeAmount so bulge grows as gaze approaches this edge
        view?.updateGlow(color: color, direction: direction, intensity: intensity, bulgePosition: bulgePosition, bulgeAmount: intensity, maxOpacity: screenGlowOpacity)
        window?.orderFront(nil)
    }

    private func hideAllGlowWindows() {
        topGlowWindow?.orderOut(nil)
        leftGlowWindow?.orderOut(nil)
        rightGlowWindow?.orderOut(nil)
    }

    private func performWinkAnimation(for edge: GazeEdge) {
        // Check if glow is enabled
        if !screenGlowEnabled { return }

        // Ignore triggers during cooldown period
        if isInCooldown { return }

        // Prevent double-triggering (can be called via both onGazeTrigger and onCalibrationTriggered)
        if isWinkAnimating { return }

        // Ensure window exists for this edge by calling updateEdgeGlow first
        // This creates the window if needed
        ensureGlowWindowExists(for: edge)

        // Get the appropriate window and view for this edge
        let glowWindow: NSWindow?
        let glowView: GradientGlowView?

        switch edge {
        case .top:
            glowWindow = topGlowWindow
            glowView = topGlowView
        case .left:
            glowWindow = leftGlowWindow
            glowView = leftGlowView
        case .right:
            glowWindow = rightGlowWindow
            glowView = rightGlowView
        case .none:
            return
        }

        guard let view = glowView, let window = glowWindow else { return }

        // Check if we're in calibration mode - different behavior for each
        let isCalibrationMode = appState.headPoseDetector.isCalibrationActive

        // Block gaze updates during wink and track active edge
        isWinkAnimating = true
        activeWinkEdge = edge
        window.orderFront(nil)

        // Phase 1: Fade out original color with sine curve (0.2s)
        let fadeOutAnimation = CAKeyframeAnimation(keyPath: "opacity")
        fadeOutAnimation.duration = 0.2

        // Generate sine-based fade out (1 -> 0 following quarter sine curve)
        var fadeOutValues: [CGFloat] = []
        let fadeOutSteps = 10
        for i in 0...fadeOutSteps {
            let t = CGFloat(i) / CGFloat(fadeOutSteps)  // 0 to 1
            let sineValue = cos(t * .pi / 2)  // cos(0) = 1, cos(π/2) = 0 - smooth deceleration
            fadeOutValues.append(sineValue)
        }
        fadeOutAnimation.values = fadeOutValues
        fadeOutAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        fadeOutAnimation.fillMode = .forwards
        fadeOutAnimation.isRemovedOnCompletion = false

        // Use CATransaction for completion of fade-out, then start white animation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self else { return }

            // Remove fade-out animation
            view.layer?.removeAnimation(forKey: "fadeOut")

            // Phase 2: Switch to white
            view.updateGlow(color: .white, direction: view.currentDirection, intensity: 1.0, maxOpacity: 1.0)

            if isCalibrationMode {
                // CALIBRATION MODE: Fade in white and STAY visible
                // Will fade out when user returns to neutral (handleReturnToNeutral)
                let fadeInAnimation = CAKeyframeAnimation(keyPath: "opacity")
                fadeInAnimation.duration = 0.3

                var fadeInValues: [CGFloat] = []
                let fadeInSteps = 15
                for i in 0...fadeInSteps {
                    let t = CGFloat(i) / CGFloat(fadeInSteps)
                    let sineValue = sin(t * .pi / 2)  // 0 -> 1
                    fadeInValues.append(sineValue)
                }
                fadeInAnimation.values = fadeInValues
                fadeInAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
                fadeInAnimation.fillMode = .forwards
                fadeInAnimation.isRemovedOnCompletion = false

                CATransaction.begin()
                CATransaction.setCompletionBlock {
                    view.layer?.removeAnimation(forKey: "fadeIn")
                    view.alphaValue = 1.0  // Keep white visible
                }
                view.layer?.add(fadeInAnimation, forKey: "fadeIn")
                CATransaction.commit()
            } else {
                // NORMAL MODE: Full pulse animation (fade in, then fade out)
                let pulseAnimation = CAKeyframeAnimation(keyPath: "opacity")
                pulseAnimation.duration = 0.6

                // Generate sine wave values (0 -> 1 -> 0)
                var pulseValues: [CGFloat] = []
                let pulseSteps = 30
                for i in 0...pulseSteps {
                    let t = CGFloat(i) / CGFloat(pulseSteps)
                    let sineValue = sin(t * .pi)  // 0 -> 1 -> 0
                    pulseValues.append(sineValue)
                }
                pulseAnimation.values = pulseValues
                pulseAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
                pulseAnimation.fillMode = .forwards
                pulseAnimation.isRemovedOnCompletion = false

                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    window.orderOut(nil)
                    view.layer?.removeAnimation(forKey: "pulse")
                    view.alphaValue = 1.0
                    // IMPORTANT: Reset the glow color to transparent to prevent white flash on next show
                    view.updateGlow(color: .clear, direction: view.currentDirection, intensity: 0, maxOpacity: 0)
                    self?.activeWinkEdge = .none
                    self?.isWinkAnimating = false
                }
                view.layer?.add(pulseAnimation, forKey: "pulse")
                CATransaction.commit()
            }
        }

        view.layer?.add(fadeOutAnimation, forKey: "fadeOut")
        CATransaction.commit()
    }

    /// Called when user returns to neutral position after a trigger
    private func handleReturnToNeutral() {
        guard activeWinkEdge != .none else { return }

        // Get the window and view for the active edge
        let glowWindow: NSWindow?
        let glowView: GradientGlowView?

        switch activeWinkEdge {
        case .top:
            glowWindow = topGlowWindow
            glowView = topGlowView
        case .left:
            glowWindow = leftGlowWindow
            glowView = leftGlowView
        case .right:
            glowWindow = rightGlowWindow
            glowView = rightGlowView
        case .none:
            return
        }

        guard let view = glowView, let window = glowWindow else {
            activeWinkEdge = .none
            isWinkAnimating = false
            return
        }

        // Check if we're in calibration mode for cooldown
        let isCalibrationMode = appState.inputCoordinator.isCalibrationActive

        // Fade out the white glow
        let fadeOutAnimation = CAKeyframeAnimation(keyPath: "opacity")
        fadeOutAnimation.duration = 0.3

        // Generate sine-based fade out (1 -> 0)
        var fadeOutValues: [CGFloat] = []
        let fadeOutSteps = 15
        for i in 0...fadeOutSteps {
            let t = CGFloat(i) / CGFloat(fadeOutSteps)
            let sineValue = cos(t * .pi / 2)  // 1 -> 0
            fadeOutValues.append(sineValue)
        }
        fadeOutAnimation.values = fadeOutValues
        fadeOutAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        fadeOutAnimation.fillMode = .forwards
        fadeOutAnimation.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self else { return }

            window.orderOut(nil)
            view.layer?.removeAnimation(forKey: "fadeOutWhite")
            view.alphaValue = 1.0

            // IMPORTANT: Reset the glow color to transparent to prevent white flash on next show
            view.updateGlow(color: .clear, direction: view.currentDirection, intensity: 0, maxOpacity: 0)

            // Reset state
            self.activeWinkEdge = .none

            // Hide all glow windows and reset smoothed intensities to prevent stale state
            self.hideAllGlowWindows()
            self.smoothedTopIntensity = 0
            self.smoothedLeftIntensity = 0
            self.smoothedRightIntensity = 0

            if isCalibrationMode {
                // In calibration mode, add 2 second cooldown before allowing new highlights
                // Set cooldown on AppDelegate (for glow updates) and both detectors (for triggers)
                self.isInCooldown = true
                self.appState.headPoseDetector.isInCooldown = true
                self.appState.mouseEdgeDetector.isInCooldown = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    self.isInCooldown = false
                    self.appState.headPoseDetector.isInCooldown = false
                    self.appState.mouseEdgeDetector.isInCooldown = false
                    self.isWinkAnimating = false
                    // Reset smoothed intensities again to ensure clean start
                    self.smoothedTopIntensity = 0
                    self.smoothedLeftIntensity = 0
                    self.smoothedRightIntensity = 0
                    // Don't reset baseline - keep original centerpoint for entire session
                    // User must return to within frustum to trigger again (handled by requiresReturnToNeutral)
                }
            } else {
                // In normal mode, no more highlights until next chime
                self.isWinkAnimating = false
            }
        }

        view.layer?.add(fadeOutAnimation, forKey: "fadeOutWhite")
        CATransaction.commit()
    }

    private func ensureGlowWindowExists(for edge: GazeEdge) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let glowDepth: CGFloat = 300  // Larger to accommodate 2x bulge

        let windowFrame: NSRect
        let color: NSColor
        let direction: GradientGlowView.GradientDirection

        switch edge {
        case .top:
            if topGlowWindow != nil { return }
            windowFrame = NSRect(x: screenFrame.minX, y: screenFrame.maxY - glowDepth,
                                 width: screenFrame.width, height: glowDepth)
            color = .systemGreen
            direction = .fromTop
            createGlowWindow(frame: windowFrame, color: color, direction: direction,
                           window: &topGlowWindow, view: &topGlowView)
        case .left:
            if leftGlowWindow != nil { return }
            windowFrame = NSRect(x: screenFrame.minX, y: screenFrame.minY,
                                 width: glowDepth, height: screenFrame.height)
            color = .systemOrange
            direction = .fromLeft
            createGlowWindow(frame: windowFrame, color: color, direction: direction,
                           window: &leftGlowWindow, view: &leftGlowView)
        case .right:
            if rightGlowWindow != nil { return }
            windowFrame = NSRect(x: screenFrame.maxX - glowDepth, y: screenFrame.minY,
                                 width: glowDepth, height: screenFrame.height)
            color = .systemOrange
            direction = .fromRight
            createGlowWindow(frame: windowFrame, color: color, direction: direction,
                           window: &rightGlowWindow, view: &rightGlowView)
        case .none:
            return
        }
    }

    private func createGlowWindow(
        frame: NSRect,
        color: NSColor,
        direction: GradientGlowView.GradientDirection,
        window: inout NSWindow?,
        view: inout GradientGlowView?
    ) {
        let newWindow = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.level = .screenSaver
        newWindow.ignoresMouseEvents = true
        newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]
        newWindow.hasShadow = false

        let glowView = GradientGlowView(frame: NSRect(origin: .zero, size: frame.size))
        glowView.updateGlow(color: color, direction: direction, intensity: 0)
        newWindow.contentView = glowView
        window = newWindow
        view = glowView
    }

    /// Public method for calibration view to show glow feedback
    func showCalibrationGlow(for edge: GazeEdge) {
        // Check if glow is enabled
        if !screenGlowEnabled { return }

        // Ignore .none edge
        guard edge != .none else { return }

        // Ensure window is set up for this edge first (bypass smoothing for instant feedback)
        updateEdgeGlow(edge: edge, rawIntensity: 1.0)

        // Then perform the wink animation
        performWinkAnimation(for: edge)
    }

    private func showScreenGlow(for type: ResponseType) {
        // Ensure we're on main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showScreenGlow(for: type)
            }
            return
        }

        // Close any existing feedback window
        feedbackWindow?.close()
        feedbackWindow = nil

        let color: NSColor
        switch type {
        case .present:
            color = NSColor.systemGreen
        case .returned:
            color = NSColor.systemOrange
        case .missed:
            return
        }

        // Get the main screen
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        // Create a borderless, transparent window
        let glowHeight: CGFloat = 6
        let windowFrame = NSRect(x: screenFrame.minX,
                                 y: screenFrame.maxY - glowHeight,
                                 width: screenFrame.width,
                                 height: glowHeight)

        let window = NSWindow(contentRect: windowFrame,
                             styleMask: .borderless,
                             backing: .buffered,
                             defer: false)
        window.isOpaque = false
        window.backgroundColor = color.withAlphaComponent(0.8)
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        window.orderFront(nil)
        feedbackWindow = window

        // Simple fade out after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.feedbackWindow?.close()
            self?.feedbackWindow = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }

        // Remove sleep/wake observers
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        appState.endSession()
    }
}

// MARK: - Gradient Glow View

class GradientGlowView: NSView {
    enum GradientDirection {
        case fromTop
        case fromLeft
        case fromRight
    }

    private var shapeLayer: CAShapeLayer?
    private var glowColor: NSColor = .systemGreen
    private(set) var currentDirection: GradientDirection = .fromTop
    private var intensity: CGFloat = 0
    private var bulgePosition: CGFloat = 0.5  // 0-1, position along the edge
    private var bulgeAmount: CGFloat = 0      // 0-1, how much the bulge extends
    private var maxOpacity: CGFloat = 0.5     // User-configurable max opacity

    // Blur radius for gradient effect
    private let blurRadius: CGFloat = 50

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
        setupLayers()
    }

    private func setupLayers() {
        let shape = CAShapeLayer()
        shape.frame = bounds
        layer?.addSublayer(shape)
        shapeLayer = shape
    }

    override func layout() {
        super.layout()
        shapeLayer?.frame = bounds
        updateGlow()
    }

    func updateGlow(color: NSColor, direction: GradientDirection, intensity: CGFloat, bulgePosition: CGFloat = 0.5, bulgeAmount: CGFloat = 0, maxOpacity: CGFloat = 0.5) {
        self.glowColor = color
        self.currentDirection = direction
        self.intensity = intensity
        self.bulgePosition = bulgePosition
        self.bulgeAmount = bulgeAmount
        self.maxOpacity = maxOpacity
        updateGlow()
    }

    private func updateGlow() {
        guard let shape = shapeLayer else { return }

        // Create the shape path - extends beyond screen edge so blur center is at edge
        let path = createBulgePath()
        shape.path = path.compatibleCGPath

        // Fill with solid color - use user-configurable max opacity
        let alpha = intensity * maxOpacity
        shape.fillColor = glowColor.withAlphaComponent(alpha).cgColor

        // Apply Gaussian blur for smooth gradient effect
        if let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            shape.filters = [blurFilter]
        }
    }

    private func createBulgePath() -> NSBezierPath {
        let path = NSBezierPath()
        let w = bounds.width
        let h = bounds.height

        // Base depth of the glow (from screen edge inward)
        let visibleDepth: CGFloat = 80

        // Bulge parameters
        // Bulge is centered at the SCREEN EDGE and extends inward
        // Radius scales dramatically with gaze proximity: 0 when not looking, 150 at full intensity
        let bulgeRadius: CGFloat = 150 * bulgeAmount

        switch currentDirection {
        case .fromTop:
            // Top edge glow
            let bulgeX = w * bulgePosition
            let screenEdgeY = h  // The actual screen edge
            let outerY = h + blurRadius  // Extend above screen for blur
            let innerY = h - visibleDepth  // Base inner edge

            path.move(to: NSPoint(x: 0, y: outerY))
            path.line(to: NSPoint(x: w, y: outerY))

            // Right side down to inner edge
            path.line(to: NSPoint(x: w, y: innerY))

            // Inner edge with bulge centered at SCREEN EDGE
            if bulgeRadius > 1 {
                let bulgeStartX = min(w, bulgeX + bulgeRadius)

                path.line(to: NSPoint(x: bulgeStartX, y: innerY))
                // Arc bulging DOWNWARD (into screen) - centered at screen edge
                path.appendArc(
                    withCenter: NSPoint(x: bulgeX, y: screenEdgeY),
                    radius: bulgeRadius,
                    startAngle: 0,
                    endAngle: 180,
                    clockwise: true  // Clockwise makes it bulge down
                )
                path.line(to: NSPoint(x: 0, y: innerY))
            } else {
                path.line(to: NSPoint(x: 0, y: innerY))
            }

            path.close()

        case .fromLeft:
            // Left edge glow
            let bulgeY = h * bulgePosition
            let screenEdgeX: CGFloat = 0  // The actual screen edge
            let outerX: CGFloat = -blurRadius  // Extend left of screen for blur
            let innerX = visibleDepth  // Base inner edge

            path.move(to: NSPoint(x: outerX, y: 0))
            path.line(to: NSPoint(x: outerX, y: h))

            // Top down to inner edge
            path.line(to: NSPoint(x: innerX, y: h))

            // Inner edge with bulge centered at SCREEN EDGE
            if bulgeRadius > 1 {
                let bulgeStartY = min(h, bulgeY + bulgeRadius)

                path.line(to: NSPoint(x: innerX, y: bulgeStartY))
                // Arc bulging RIGHTWARD (into screen) - centered at screen edge
                path.appendArc(
                    withCenter: NSPoint(x: screenEdgeX, y: bulgeY),
                    radius: bulgeRadius,
                    startAngle: 90,
                    endAngle: -90,
                    clockwise: true  // Clockwise makes it bulge right
                )
                path.line(to: NSPoint(x: innerX, y: 0))
            } else {
                path.line(to: NSPoint(x: innerX, y: 0))
            }

            path.close()

        case .fromRight:
            // Right edge glow
            let bulgeY = h * bulgePosition
            let screenEdgeX = w  // The actual screen edge
            let outerX = w + blurRadius  // Extend right of screen for blur
            let innerX = w - visibleDepth  // Base inner edge

            path.move(to: NSPoint(x: outerX, y: 0))
            path.line(to: NSPoint(x: outerX, y: h))

            // Top down to inner edge
            path.line(to: NSPoint(x: innerX, y: h))

            // Inner edge with bulge centered at SCREEN EDGE
            if bulgeRadius > 1 {
                let bulgeStartY = min(h, bulgeY + bulgeRadius)

                path.line(to: NSPoint(x: innerX, y: bulgeStartY))
                // Arc bulging LEFTWARD (into screen) - centered at screen edge
                path.appendArc(
                    withCenter: NSPoint(x: screenEdgeX, y: bulgeY),
                    radius: bulgeRadius,
                    startAngle: 90,
                    endAngle: -90,
                    clockwise: false  // Counter-clockwise makes it bulge left
                )
                path.line(to: NSPoint(x: innerX, y: 0))
            } else {
                path.line(to: NSPoint(x: innerX, y: 0))
            }

            path.close()
        }

        return path
    }
}

// MARK: - NSBezierPath Extension for CGPath

extension NSBezierPath {
    /// Returns a CGPath for this bezier path (compatibility for macOS < 14)
    var compatibleCGPath: CGPath {
        if #available(macOS 14.0, *) {
            return self.cgPath
        } else {
            let path = CGMutablePath()
            var points = [CGPoint](repeating: .zero, count: 3)

            for i in 0..<self.elementCount {
                let type = self.element(at: i, associatedPoints: &points)
                switch type {
                case .moveTo:
                    path.move(to: points[0])
                case .lineTo:
                    path.addLine(to: points[0])
                case .curveTo:
                    path.addCurve(to: points[2], control1: points[0], control2: points[1])
                case .closePath:
                    path.closeSubpath()
                case .cubicCurveTo:
                    path.addCurve(to: points[2], control1: points[0], control2: points[1])
                case .quadraticCurveTo:
                    path.addQuadCurve(to: points[1], control: points[0])
                @unknown default:
                    break
                }
            }
            return path
        }
    }
}

