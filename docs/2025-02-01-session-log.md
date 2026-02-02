# Development Session Log - February 1, 2025

## Project: Awareness Anchor macOS App

Port of the Awareness Anchor web app to a native macOS menu bar application.

---

## Debug Loops Encountered

### 1. Build Failure: Missing `import AppKit`

**Symptom:** Build errors for `NSEvent` and `NSSound` being undefined.

**Cause:** SwiftUI projects don't automatically include AppKit. The code used `NSEvent` for global hotkey monitoring and `NSSound` references without the necessary import.

**Fix:** Added `import AppKit` to files using AppKit classes:
- `AwarenessAnchorApp.swift`
- `MenuBarView.swift`

---

### 2. `onChange(of:initial:)` Only Available in macOS 14.0+

**Symptom:** Build error stating `onChange(of:initial:)` is only available in macOS 14.0 or newer.

**Cause:** The newer SwiftUI API with the `initial:` parameter was used, but the app targets macOS 13.0+.

**Fix:** Replaced with older syntax that works on macOS 13.0:
```swift
// Before (macOS 14.0+ only)
.onChange(of: value, initial: true) { oldValue, newValue in
    // ...
}

// After (macOS 13.0+)
.onChange(of: value) { _ in
    // ...
}
```

---

### 3. `SettingsLink` Only Available in macOS 14.0+

**Symptom:** Build error stating `SettingsLink` is only available in macOS 14.0 or newer.

**Cause:** `SettingsLink` is a new SwiftUI component introduced in macOS 14.0.

**Fix:** Created version-specific views with `#available` check:
```swift
struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsButtonModern()
        } else {
            SettingsButtonLegacy()
        }
    }
}

struct SettingsButtonLegacy: View {
    var body: some View {
        Button("Settings...") {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
```

---

### 4. Settings Panel Not Opening

**Symptom:** Clicking "Settings..." did nothing, with console warning "Please use SettingsLink".

**Cause:** The `showSettingsWindow:` selector is deprecated and logs a warning instead of opening settings on macOS 14+.

**Fix:** For macOS 14+, use the proper environment action:
```swift
@available(macOS 14.0, *)
struct SettingsButtonModern: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings...") {
            AppDelegate.shared?.popover.performClose(nil)
            openSettings()
        }
    }
}
```

For macOS 13, the legacy selector `showPreferencesWindow:` still works.

---

### 5. Layout Recursion Warning from GeometryReader

**Symptom:** Console warning about layout recursion or infinite layout loop when displaying the response window countdown.

**Cause:** Using `GeometryReader` inside a popover to create a custom progress bar. GeometryReader can cause layout instability in certain contexts.

**Fix:** Replaced custom GeometryReader-based progress bar with native SwiftUI `ProgressView`:
```swift
// Before
GeometryReader { geometry in
    Rectangle()
        .fill(Color.green)
        .frame(width: geometry.size.width * (remaining / total))
}

// After
ProgressView(value: appState.responseWindowRemainingSeconds, total: appState.responseWindowSeconds)
    .progressViewStyle(.linear)
    .tint(.green)
```

---

### 6. Head Pose Detection Not Working

**Symptom:** Camera activated during response window but no head pose gestures were being detected. Debug UI showed "Face found, no pose data".

**Cause:** `VNDetectFaceLandmarksRequest` does not provide pitch/yaw/roll data. It only provides facial landmarks (eyes, nose, mouth positions).

**Fix:** Switched to `VNDetectFaceRectanglesRequest` with revision 3, which explicitly supports pitch, yaw, and roll:
```swift
let faceRequest = VNDetectFaceRectanglesRequest { request, error in
    guard let face = results.first else { return }
    // face.pitch, face.yaw, face.roll are now available
}
faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
```

---

### 7. Head Pose "Look Up" Not Triggering Present Response

**Symptom:** Looking up did not trigger the "Already Present" response. Looking down seemed to trigger it instead.

**Cause:** Vision framework's coordinate system has pitch values that go MORE NEGATIVE when looking up, not more positive.

**Original (incorrect) logic:**
```swift
if pitchDelta > pitchThreshold {  // Looking up?
    onPoseDetected?(.tiltUp)
}
```

**Fix:** Inverted the comparison:
```swift
// Note: Looking UP makes pitch more NEGATIVE in Vision's coordinate system
if pitchDelta < -pitchThreshold {
    onPoseDetected?(.tiltUp)
}
```

---

### 8. Slider Visual Artifact (Dotted Tick Marks)

**Symptom:** The interval slider displayed unsightly dotted tick marks across the track.

**Cause:** Using the `step:` parameter on the Slider caused SwiftUI to render tick marks at each step interval:
```swift
Slider(value: $value, in: 3...300, step: 1)  // Shows 297 tick marks!
```

**Fix:** Removed the `step:` parameter and applied rounding in the setter:
```swift
Slider(value: Binding(
    get: { appState.averageIntervalSeconds },
    set: { appState.updateInterval(round($0)) }
), in: 3...300)
```

---

## Key Learnings

1. **macOS Version Compatibility**: When targeting older macOS versions, always check API availability. SwiftUI APIs evolve significantly between versions.

2. **Vision Framework Coordinate System**: The pitch/yaw/roll values follow specific conventions that may not match intuitive expectations. Always test with actual gestures.

3. **VNDetectFaceRectanglesRequest vs VNDetectFaceLandmarksRequest**:
   - Landmarks: facial feature positions only
   - FaceRectangles (rev 3): includes pitch, yaw, roll

4. **Layout in Popovers**: Native SwiftUI components like `ProgressView` are more stable than custom GeometryReader-based layouts in constrained contexts.

5. **SwiftUI Slider Steps**: The `step:` parameter renders visual tick marks. For clean sliders with discrete values, round in the binding instead.

---

## Session Summary

Successfully ported the Awareness Anchor mindfulness bell app from web (HTML/JavaScript/Tone.js) to native macOS. The native app runs as a menu bar application with:

- Random interval chime scheduling
- Response window with countdown timer
- "Already Present" and "Returned to Awareness" response tracking
- Head pose detection via front camera (optional)
- Global keyboard shortcuts
- Persistent statistics storage
- Settings panel for customization
