# Awareness Anchor - Project Status

**Last Updated:** 2025-02-05
**Current Phase:** 3 (Statistics & Optimization) - Time-in-state estimation complete, Phase 2 optimization planned

---

## Quick Context for New Sessions

### What This Is
Native macOS menu bar app for mindfulness bell reminders. Plays Tibetan bowl sounds at random intervals, prompts user to respond indicating awareness state (Present/Returned/Missed).

### Current State: WORKING
- App builds and runs
- Chimes play on schedule with 5 bundled Tibetan bowl MP3s
- Response tracking works via head pose AND/OR mouse edge detection
- SQLite persistence stores sessions and events
- Screen edge glow shows direction-aware feedback (gradient + wink animation)
- Time-in-state estimation with autocorrelation-adjusted confidence intervals
- Settings panel functional with Calibrate tab

### Active Work

1. **Phase 2 Awareness Optimization** (planned, not started)
   - Branch: `phase2-awareness-optimization` (not yet created)
   - Kaplan-Meier survival estimation for awareness duration
   - Optimal chime frequency recommendation
   - Plan at `.claude/plans/steady-enchanting-bentley.md`

2. **Calibration View Refinements** (just completed)
   - Reticle on frustum projection plane (head pose) / cursor arrow (mouse)
   - Intensity-driven frustum face opacity
   - Grayscale preview until tracking ready
   - 0.5s debounced input source switching

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Platform | Native Swift/SwiftUI | 4-6x less memory than Electron |
| Face detection | VNDetectFaceRectanglesRequest rev3 | Only API that provides pitch/yaw/roll |
| Persistence | SQLite (direct) | Simple, no dependencies |
| Global hotkeys | NSEvent.addGlobalMonitorForEvents | Works when app unfocused |
| Target OS | macOS 13.0+ | Broader compatibility |
| Input handling | InputCoordinator (unified) | Motion-based precedence between head pose and mouse |
| Screen glow | Pure Core Animation (CAGradientLayer) | SwiftUI in overlay windows crashes (see DEAD_ENDS) |
| Statistics | PASTA theorem + Wilson CI | Unbiased time proportion with autocorrelation correction |

---

## File Map

```
AwarenessAnchor/
  AwarenessAnchorApp.swift     # Entry point (AppDelegate), menu bar, glow overlays
  Models/
    AppState.swift             # Central state, chime scheduling, response recording
    ChimeEvent.swift           # Event data model (present/returned/missed)
    Session.swift              # Session data model
  Views/
    MenuBarView.swift          # Main popover UI + debug panel
    SettingsView.swift         # Settings tabs (General, Calibrate, Stats)
    StatsView.swift            # Time-in-awareness card, response distribution, practice time
    HeadPoseSceneView.swift    # SceneKit 3D calibration visualization
    HeadPoseCalibrationView.swift  # Calibration tab UI with preview mode
  Services/
    AudioPlayer.swift          # Sound playback (overlap prevention)
    ChimeScheduler.swift       # Random interval timing
    DataStore.swift            # SQLite persistence + time estimation statistics
    HeadPoseDetector.swift     # Vision framework face detection
    MouseEdgeDetector.swift    # Mouse proximity to screen edges
    InputCoordinator.swift     # Unified input: speed-based source precedence
    HotkeyManager.swift        # Global keyboard shortcuts
    Logger.swift               # File-based debug logging
  Resources/
    bowl-1.mp3 through bowl-5.mp3
```

---

## Resolved Issues (Reference)

### Input Coordination
- Mouse dwell near screen edge was interrupted by head pose micro-movements stealing active source
- Fix: Lock source to mouse during dwell, 0.5s debounce on source switching
- Mouse intensities leaked outside active windows; fix: guard on isWindowActive/isCalibrationMode/requiresReturnToNeutral

### Chime Overlap
- Overlapping chime audio and response windows corrupted data
- Fix: Guard in handleChime() checks both isInResponseWindow and audioPlayer.isChimePlaying

### SceneKit Frustum Transparency
- PBR materials on custom quad geometry ignored transparency settings
- Fix: Use .constant lighting + .alpha blend + writesToDepthBuffer=false

---

## Roadmap

### Phase 2 Optimization (Next)
- [ ] AwarenessOptimizer.swift: Kaplan-Meier survival, chime frequency optimization
- [ ] DataStore bridge methods for optimization stats
- [ ] StatsView cards: chime effectiveness, awareness duration, optimal frequency, trend

### Phase 4: Extensions (Backlog)
- Apple Watch companion
- macOS widgets
- iCloud sync

---

## Development Patterns

From `.claude/CLAUDE.md`:

- **15-Minute Pivot Rule**: If stuck >15 min, try completely different approach
- **Stuck Detector Signals**: 3+ minor variations, >20 min reading docs, complexity doubling
- **Logging**: Use `appLog()` not `print()` — logs at `~/Library/Logs/AwarenessAnchor/app.log`
- **SQLite verification**: `sqlite3` CLI first before assuming code bugs

---

## Session Continuation Checklist

When resuming work:
1. Read this STATUS.md for context
2. Check `docs/archive/sessions/` for detailed session logs
3. Check `.claude/plans/` for active implementation plans
4. Run app in Xcode to verify current state
