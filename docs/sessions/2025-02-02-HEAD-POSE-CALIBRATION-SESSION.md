# Development Session - Head Pose Calibration UI & Screen Edge Glow

**Created:** 2025-02-02
**Updated:** 2025-02-02
**Status:** ACTIVE - Features implemented, testing in progress
**Branch:** main
**Focus:** SceneKit 3D calibration visualization, gradient screen edge glow

---

## Quick Context (For Context Compaction)

### Current State
- **SceneKit 3D Calibration UI: COMPLETE** - Replaced Canvas with full SceneKit scene (head + frustum + gaze vector)
- **Screen Edge Glow: COMPLETE** - Gradient glow with intensity-based opacity, wink animation on trigger
- **Head Pose Detection: IMPROVED** - Smoothing, dwell time, frame skipping, baseline capture fixes
- **Remaining blockers**: Threshold tuning may need adjustment based on user testing (minor)

### Key Files Modified (2025-02-02)
1. `Services/HeadPoseDetector.swift` - IIR smoothing, dwell time, frame skipping, gaze edge/intensity tracking, GazeEdge enum
2. `Views/HeadPoseSceneView.swift` - NEW: SceneKit 3D visualization (head ellipsoid, frustum, gaze vector)
3. `Views/HeadPoseCalibrationView.swift` - NEW: Calibration tab UI with test mode
4. `Views/SettingsView.swift` - Added Calibrate tab, updated labels
5. `AwarenessAnchorApp.swift` - GradientGlowView class, gaze edge observers, wink animation

### What Was Implemented
- SceneKit 3D preview: translucent head rotates with pose, frustum shows thresholds, gaze vector changes color
- IIR smoothing filter (configurable 0-0.7) reduces jitter in head pose detection
- Dwell time requirement (configurable 0-2s) prevents accidental triggers
- Frame skipping (3 frames) on camera start for stable baseline capture
- Gradient glow (100px deep) on screen edges showing current gaze direction
- Intensity-based opacity: 0% at center, increases toward threshold
- Wink animation: rapid 0→100%→0% pulse when response triggered

### What Still Needs Work
- User testing to validate threshold defaults (pitch: 0.12, yaw: 0.20)
- Consider adding glow to calibration preview (currently only during actual chime response)

---

## Session Details

### Problem: Pitch Detection Issues with External Monitors
When using external monitor above webcam, "turning" was detected as "tilting up" because user's starting position was already above camera.

**Solution:** Baseline/delta approach - capture user's actual position when chime starts, measure change from there.

### Problem: Jittery Detection
Raw Vision framework values fluctuated frame-to-frame.

**Solution:** IIR smoothing filter: `smoothed = alpha * new + (1 - alpha) * smoothed`

### Problem: Accidental Triggers
Quick glances would trigger responses unintentionally.

**Solution:** Dwell time requirement - gaze must stay outside threshold for configurable duration.

### Problem: Baseline Set to Wrong Position
First frame after camera start sometimes had stale/incorrect values.

**Solution:** Skip first 3 frames to let camera stabilize before setting baseline.

### Problem: Present (tilt up) Only Triggered Once
After first trigger, pitch detection stopped working in calibration mode.

**Solution:** Don't set `hasRespondedThisWindow = true` in calibration mode; properly reset dwell tracking.

### Problem: Left/Right Glow Swapped
Screen edge glow appeared on wrong side.

**Solution:** Swap mapping - positive yaw = left edge (camera mirror effect).

### Problem: SwiftUI in Overlay Window Crashed (from DEAD_ENDS)
Previous attempt using NSHostingView caused Metal/GPU errors.

**Solution:** Pure Core Animation approach using CAGradientLayer directly - no SwiftUI in overlay.

---

## Commits This Session

1. `c6eef0f` - Add head pose calibration UI with SceneKit 3D visualization

---

## Technical Notes

### SceneKit Scene Structure
```
SCNScene
├── Camera (3/4 oblique angle)
├── Ambient Light
├── Directional Light
├── Head Node (SCNSphere, scale 0.75/1.1/1.0, rotates with pose)
│   └── Nose Line (SCNCylinder)
├── Frustum Node (4 SCNPlanes: left/right orange, top green)
│   └── Edge Lines
└── Gaze Vector Node (SCNCylinder + SCNCone, color changes at threshold)
```

### Gaze Edge Detection Thresholds
- Trigger thresholds: pitch 0.12, yaw 0.20 (radians)
- Gaze indication uses full range: intensity = delta / threshold (clamped 0-1)
- Direction priority: yaw takes precedence over pitch

### Gradient Glow Implementation
- Uses CAGradientLayer directly (no SwiftUI)
- 100px depth from screen edge
- Opacity = intensity * 0.8 (max 80%)
- Wink animation: NSAnimationContext, 0.1s up + 0.15s down

---

## Workflow Improvements Identified

### Pattern: Name Output Criteria Explicitly
When debugging detection issues, explicitly state what correct behavior looks like:
- "Turning right should show glow on RIGHT edge"
- "Pitch delta should be ~0 when first starting test"

This prevents ambiguous debugging where you're not sure what "fixed" means.

### Pattern: Test Calibration Before Real Use
The calibration UI proved invaluable for understanding what the detector was seeing. Building debug/test UI pays off quickly.

### Pattern: Pure Core Animation for Overlays
SwiftUI in transparent overlay windows is unstable. Use CALayer/CAGradientLayer directly for screen-level visual effects.
