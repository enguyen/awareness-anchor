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
    private var gazeGlowWindow: NSWindow?
    private var gazeGlowView: GradientGlowView?
    private var gazeEdgeCancellable: AnyCancellable?
    private var gazeIntensityCancellable: AnyCancellable?
    private var currentGazeEdge: GazeEdge = .none
    private var isWinkAnimating: Bool = false

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

        // Hide dock icon (menu bar only app)
        NSApp.setActivationPolicy(.accessory)

        // Initialize services
        appState.initialize()

        // Set up gaze edge glow observer
        setupGazeEdgeObserver()
    }

    private func setupGazeEdgeObserver() {
        let detector = appState.headPoseDetector

        // Observe gaze edge changes
        gazeEdgeCancellable = detector.$currentGazeEdge
            .receive(on: DispatchQueue.main)
            .sink { [weak self] edge in
                self?.currentGazeEdge = edge
                self?.updateGazeGlow(edge: edge, intensity: detector.gazeIntensity)
            }

        // Observe gaze intensity changes
        gazeIntensityCancellable = detector.$gazeIntensity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] intensity in
                guard let self = self else { return }
                self.updateGazeGlow(edge: self.currentGazeEdge, intensity: intensity)
            }

        // Set up trigger callback for wink animation
        detector.onGazeTrigger = { [weak self] edge in
            self?.performWinkAnimation(for: edge)
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

    private func updateGazeGlow(edge: GazeEdge, intensity: Float) {
        // Don't update during wink animation
        if isWinkAnimating { return }

        // Hide glow if no edge or zero intensity
        if edge == .none || intensity < 0.01 {
            gazeGlowWindow?.orderOut(nil)
            return
        }

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let glowDepth: CGFloat = 100  // Gradient extends 100px from edge

        // Calculate window frame and gradient direction based on edge
        let windowFrame: NSRect
        let color: NSColor
        let gradientDirection: GradientGlowView.GradientDirection

        switch edge {
        case .top:
            windowFrame = NSRect(
                x: screenFrame.minX,
                y: screenFrame.maxY - glowDepth,
                width: screenFrame.width,
                height: glowDepth
            )
            color = NSColor.systemGreen
            gradientDirection = .fromTop
        case .left:
            windowFrame = NSRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: glowDepth,
                height: screenFrame.height
            )
            color = NSColor.systemOrange
            gradientDirection = .fromLeft
        case .right:
            windowFrame = NSRect(
                x: screenFrame.maxX - glowDepth,
                y: screenFrame.minY,
                width: glowDepth,
                height: screenFrame.height
            )
            color = NSColor.systemOrange
            gradientDirection = .fromRight
        case .none:
            return
        }

        // Create window and view if needed
        if gazeGlowWindow == nil {
            let window = NSWindow(
                contentRect: windowFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.hasShadow = false

            let glowView = GradientGlowView(frame: NSRect(origin: .zero, size: windowFrame.size))
            window.contentView = glowView
            gazeGlowWindow = window
            gazeGlowView = glowView
        }

        // Update window frame and view
        gazeGlowWindow?.setFrame(windowFrame, display: false)
        gazeGlowView?.frame = NSRect(origin: .zero, size: windowFrame.size)
        gazeGlowView?.updateGlow(color: color, direction: gradientDirection, intensity: CGFloat(intensity))
        gazeGlowWindow?.orderFront(nil)
    }

    private func performWinkAnimation(for edge: GazeEdge) {
        guard let glowView = gazeGlowView else { return }

        // Block gaze updates during wink
        isWinkAnimating = true

        // Set to white for the wink
        glowView.updateGlow(color: .white, direction: glowView.currentDirection, intensity: 1.0)

        // Single wink: fade in quickly, then fade out
        glowView.alphaValue = 0
        gazeGlowWindow?.orderFront(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            glowView.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                self?.gazeGlowView?.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                self?.gazeGlowWindow?.orderOut(nil)
                self?.gazeGlowView?.alphaValue = 1.0  // Reset for next use
                self?.isWinkAnimating = false  // Allow gaze updates again
            })
        })
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

    private var gradientLayer: CAGradientLayer?
    private var glowColor: NSColor = .systemGreen
    private(set) var currentDirection: GradientDirection = .fromTop
    private var intensity: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupGradientLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupGradientLayer()
    }

    private func setupGradientLayer() {
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        layer?.addSublayer(gradient)
        gradientLayer = gradient
    }

    override func layout() {
        super.layout()
        gradientLayer?.frame = bounds
        updateGradient()
    }

    func updateGlow(color: NSColor, direction: GradientDirection, intensity: CGFloat) {
        self.glowColor = color
        self.currentDirection = direction
        self.intensity = intensity
        updateGradient()
    }

    private func updateGradient() {
        guard let gradient = gradientLayer else { return }

        // Apply intensity to alpha (0 at center of frustum, 1 at threshold)
        let alpha = intensity * 0.8  // Max 80% opacity at full intensity
        let opaqueColor = glowColor.withAlphaComponent(alpha).cgColor
        let transparentColor = glowColor.withAlphaComponent(0).cgColor

        gradient.colors = [opaqueColor, transparentColor]

        // Set gradient direction based on edge
        switch currentDirection {
        case .fromTop:
            gradient.startPoint = CGPoint(x: 0.5, y: 1.0)  // Top
            gradient.endPoint = CGPoint(x: 0.5, y: 0.0)    // Bottom (into screen)
        case .fromLeft:
            gradient.startPoint = CGPoint(x: 0.0, y: 0.5)  // Left edge
            gradient.endPoint = CGPoint(x: 1.0, y: 0.5)    // Right (into screen)
        case .fromRight:
            gradient.startPoint = CGPoint(x: 1.0, y: 0.5)  // Right edge
            gradient.endPoint = CGPoint(x: 0.0, y: 0.5)    // Left (into screen)
        }
    }
}

