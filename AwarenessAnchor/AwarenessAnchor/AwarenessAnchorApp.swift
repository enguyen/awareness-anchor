import SwiftUI
import AppKit

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
        // 1. Change menu bar icon temporarily
        showIconFeedback(for: type)

        // 2. Show screen edge glow
        showScreenGlow(for: type)
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

