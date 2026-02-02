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

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        appState.endSession()
    }
}
