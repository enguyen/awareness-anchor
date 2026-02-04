# Dead Ends - Awareness Anchor

This document captures approaches that were tried and failed, to prevent future time waste.

---

## Dead End #1: VNDetectFaceLandmarksRequest for Head Pose

### What We Tried
Used `VNDetectFaceLandmarksRequest` from Apple's Vision framework to detect head pose (pitch/yaw/roll) for responding to chimes with head gestures.

### Why It Failed
`VNDetectFaceLandmarksRequest` only provides facial feature positions (eyes, nose, mouth coordinates). It does **not** expose pitch, yaw, or roll values despite the name suggesting it might.

Debug output showed "Face found, no pose data" because the properties simply don't exist on the result object.

### What We Learned
- Vision framework has multiple face detection request types with different capabilities
- The naming is misleading - "landmarks" refers to 2D feature positions, not 3D orientation
- Always check actual API properties, not assumptions from naming

### Time Spent
- Total: ~45 minutes
- Wasted debugging non-existent properties: ~30 minutes

### When to Try This Approach
- When you need facial feature positions (eye corners, nose tip, lip contours)
- For face mesh/overlay applications
- For basic "is there a face" detection (though FaceRectangles is simpler)

### When to Avoid This Approach
- When you need head orientation (pitch/yaw/roll)
- When you need 3D pose estimation

### Alternative That Worked
`VNDetectFaceRectanglesRequest` with **revision 3** (`VNDetectFaceRectanglesRequestRevision3`) explicitly provides `pitch`, `yaw`, and `roll` properties on the face observation result.

```swift
let request = VNDetectFaceRectanglesRequest()
request.revision = VNDetectFaceRectanglesRequestRevision3
// Now face.pitch, face.yaw, face.roll are available
```

---

## Dead End #2: SwiftUI View in Overlay Window for Screen Glow

### What We Tried
Created an NSWindow overlay for screen edge glow effect, hosting a SwiftUI view with gradient and animation:

```swift
let glowWindow = NSWindow(...)
glowWindow.contentView = NSHostingView(rootView: GlowView())
```

### Why It Failed
Causes Metal/GPU allocation errors and app freeze (beach ball). Console showed:
- "
Validation failed for IOSurface 0x..."
- GPU memory allocation failures
- Eventually unresponsive requiring force quit

The issue appears to be SwiftUI's rendering pipeline conflicting with transparent overlay windows, especially during animations.

### What We Learned
- SwiftUI + transparent NSWindow + animation = unstable on macOS
- Metal compositor struggles with certain overlay configurations
- The crash is intermittent but reproducible under load

### Time Spent
- Total: ~60 minutes
- Initial implementation: ~20 minutes
- Debugging crashes: ~40 minutes

### When to Try This Approach
- For simple, non-animated overlays
- When the hosting window is a standard window (not level-above-all overlay)

### When to Avoid This Approach
- Screen-level overlays with animations
- High-frequency visual updates
- Transparent windows with SwiftUI content

### Alternative That Worked (Partial)
Currently using menu bar icon changes only. Proper fix requires:
- Pure Core Animation (CALayer + CABasicAnimation)
- No SwiftUI in the overlay
- Direct CALayer manipulation for gradient and pulse

This is documented as a Phase 2.5 roadmap item.

---

## Dead End #3: Slider with step: Parameter

### What We Tried
Used SwiftUI Slider with `step:` parameter for discrete interval values:

```swift
Slider(value: $interval, in: 3...300, step: 1)
```

### Why It Failed
SwiftUI renders visual tick marks at each step value. With a range of 3-300 and step of 1, this created 297 tiny dotted marks across the slider track, making it look broken.

### What We Learned
- `step:` is for discrete value snapping AND visual tick marks (can't separate them)
- For clean sliders with integer values, handle rounding in the binding

### Time Spent
- Total: ~15 minutes (noticed quickly, fixed quickly)

### When to Try This Approach
- When you want visible tick marks (e.g., 1-10 scale)
- Small number of discrete values

### When to Avoid This Approach
- Large numeric ranges
- When you want continuous visual appearance with discrete values

### Alternative That Worked
Round in the binding setter instead:

```swift
Slider(value: Binding(
    get: { interval },
    set: { interval = round($0) }
), in: 3...300)
```

---

## Pattern Recognition

Common themes in these dead ends:

1. **API naming misleads** - Always verify actual capabilities, not assumed ones
2. **SwiftUI edge cases** - Complex window configurations hit rough edges
3. **Visual parameters have hidden effects** - `step:` does more than just value snapping

When hitting similar situations, pivot after 15 minutes per the project's development patterns.

---

## Dead End #4: SQLite + Swift String Binding with SQLITE_STATIC

### What We Tried
Used `sqlite3_bind_text` with `nil` (which defaults to SQLITE_STATIC) to bind Swift String values to SQLite prepared statements:

```swift
sqlite3_bind_text(statement, 1, stringValue, -1, nil)
```

### Why It Failed
Swift Strings are temporary objects. When passed to C functions, they're often bridged as temporary pointers. With `SQLITE_STATIC`, SQLite assumes the string memory stays valid until query execution - but Swift may deallocate or move the string before then.

Result: Empty string columns in the database despite the Swift code showing correct values in debugger.

### What We Learned
- `SQLITE_STATIC` tells SQLite "I guarantee this memory stays valid"
- `SQLITE_TRANSIENT` tells SQLite "copy this immediately, I can't guarantee memory"
- Swift String bridging to C creates temporary memory that's immediately invalid
- This is a silent data corruption bug - no errors, just empty/wrong values

### Detection Method
Query the database directly with sqlite3 CLI:
```bash
sqlite3 ~/Library/Application\ Support/AwarenessAnchor/*.db "SELECT * FROM chime_events;"
```

If code looks correct but CLI shows empty strings, suspect string binding.

### Time Spent
- Total: ~90 minutes
- Debugging "why isn't data showing in stats": ~60 minutes
- Realizing it was a binding issue, not query issue: ~30 minutes

### When to Try SQLITE_STATIC
- When binding static C strings (`"literal"`)
- When you've explicitly managed memory lifetime

### When to Avoid SQLITE_STATIC (use SQLITE_TRANSIENT)
- Swift Strings (always)
- Any dynamically allocated strings
- When in doubt

### Alternative That Worked
```swift
sqlite3_bind_text(statement, 1, stringValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
// The -1 cast is SQLITE_TRANSIENT, which tells SQLite to copy the string
```

Or use a helper constant:
```swift
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
sqlite3_bind_text(statement, 1, stringValue, -1, SQLITE_TRANSIENT)
```
