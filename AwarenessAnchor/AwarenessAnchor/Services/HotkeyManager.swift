import Foundation
import AppKit
import Carbon

// Key codes for common keys
enum KeyCode: UInt16 {
    case key1 = 18
    case key2 = 19
    case key3 = 20
    case key4 = 21
    case keyP = 35
    case keyS = 1
}

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt  // CGEventFlags raw value
    var displayName: String

    static let defaultPresent = HotkeyBinding(
        keyCode: KeyCode.key1.rawValue,
        modifiers: UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue),
        displayName: "⌘⇧1"
    )

    static let defaultReturned = HotkeyBinding(
        keyCode: KeyCode.key2.rawValue,
        modifiers: UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue),
        displayName: "⌘⇧2"
    )
}

class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published var presentHotkey: HotkeyBinding
    @Published var returnedHotkey: HotkeyBinding

    private init() {
        // Load saved hotkeys or use defaults
        if let data = UserDefaults.standard.data(forKey: "presentHotkey"),
           let hotkey = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            presentHotkey = hotkey
        } else {
            presentHotkey = .defaultPresent
        }

        if let data = UserDefaults.standard.data(forKey: "returnedHotkey"),
           let hotkey = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            returnedHotkey = hotkey
        } else {
            returnedHotkey = .defaultReturned
        }
    }

    func saveHotkeys() {
        if let data = try? JSONEncoder().encode(presentHotkey) {
            UserDefaults.standard.set(data, forKey: "presentHotkey")
        }
        if let data = try? JSONEncoder().encode(returnedHotkey) {
            UserDefaults.standard.set(data, forKey: "returnedHotkey")
        }
    }

    func matches(_ event: NSEvent, hotkey: HotkeyBinding) -> Bool {
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let requiredFlags = NSEvent.ModifierFlags(rawValue: UInt(hotkey.modifiers))

        return event.keyCode == hotkey.keyCode && eventFlags == requiredFlags
    }
}
