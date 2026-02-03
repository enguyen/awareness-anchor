# Awareness Anchor - Project Status

**Last Updated:** 2025-02-02
**Current Phase:** 2.5 (Visual Feedback Enhancement) - Screen Edge Glow Implemented

---

## Quick Context for New Sessions

### What This Is
Native macOS menu bar app for mindfulness bell reminders. Plays Tibetan bowl sounds at random intervals, prompts user to respond indicating awareness state (Present/Returned/Missed).

### Current State: WORKING
- App builds and runs
- Chimes play on schedule with 5 bundled Tibetan bowl MP3s
- Response tracking works (keyboard shortcuts + head pose)
- SQLite persistence stores sessions and events
- Settings panel functional

### Active Blockers

1. **Screen Glow Crashes** (Phase 2.5 feature, disabled)
   - Metal/GPU errors when creating NSWindow overlay for screen edge glow
   - Symptom: Beach ball, unresponsive app
   - Root cause: SwiftUI view inside overlay window causes GPU allocation failures
   - **Next step:** Reimplement using pure Core Animation (CALayer + CABasicAnimation)
   - Workaround: Visual feedback currently only changes menu bar icon

2. **Threshold Tuning** (minor)
   - Pitch threshold: 0.12 radians (~7 degrees)
   - Yaw threshold: 0.20 radians (~11 degrees)
   - May need adjustment based on user testing

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Platform | Native Swift/SwiftUI | 4-6x less memory than Electron |
| Face detection | VNDetectFaceRectanglesRequest rev3 | Only API that provides pitch/yaw/roll |
| Persistence | SQLite (direct) | Simple, no dependencies |
| Global hotkeys | NSEvent.addGlobalMonitorForEvents | Works when app unfocused |
| Target OS | macOS 13.0+ | Broader compatibility |

---

## File Map

```
AwarenessAnchor/
  AwarenessAnchorApp.swift     # Entry point, menu bar, hotkeys, visual feedback
  Models/
    AppState.swift             # Central state, response callbacks
    ChimeEvent.swift           # Event data model
    Session.swift              # Session data model
  Views/
    MenuBarView.swift          # Main popover UI + debug panel
    SettingsView.swift         # Settings tabs (redesigned)
    StatsView.swift            # Statistics display
  Services/
    AudioPlayer.swift          # Sound playback
    ChimeScheduler.swift       # Random interval timing
    DataStore.swift            # SQLite persistence
    HeadPoseDetector.swift     # Vision framework face detection
    HotkeyManager.swift        # Global keyboard shortcuts
    Logger.swift               # File-based debug logging (NEW)
  Resources/
    bowl-1.mp3 through bowl-5.mp3
```

---

## Resolved Debug Loops (Reference)

These issues were resolved in the 2025-02-01 session. Documented here for future reference:

1. **Missing AppKit imports** - SwiftUI doesn't auto-include AppKit for NSEvent/NSSound
2. **macOS 14+ APIs** - onChange(initial:), SettingsLink, openSettings need version checks
3. **GeometryReader in popover** - Causes layout recursion; use native ProgressView instead
4. **VNDetectFaceLandmarksRequest** - Does NOT provide pitch/yaw; use VNDetectFaceRectanglesRequest rev3
5. **Vision pitch coordinates** - Looking UP makes pitch MORE NEGATIVE (counterintuitive)
6. **Slider tick marks** - `step:` parameter renders visual ticks; round in binding instead

---

## Roadmap

### Phase 2.5: Visual Feedback Enhancement (Next)
- [ ] Direction-aware screen edge glow (top/left/right based on head direction)
- [ ] Pulse animation using Core Animation (not SwiftUI in overlay)
- [ ] Tests for head pose threshold logic

### Phase 3: Analytics Dashboard (Future)
- [ ] Daily/weekly/monthly charts (SwiftUI Charts)
- [ ] Time-of-day awareness patterns
- [ ] CSV export

### Phase 4: Extensions (Backlog)
- Apple Watch companion
- macOS widgets
- iCloud sync

---

## Development Patterns

From `.claude/CLAUDE.md`:

- **15-Minute Pivot Rule**: If stuck >15 min, try completely different approach
- **Stuck Detector Signals**: 3+ minor variations, >20 min reading docs, complexity doubling
- **Test -> Single -> Batch**: For any operation with cost or risk

---

## Session Continuation Checklist

When resuming work:
1. Read this STATUS.md for context
2. Check `docs/archive/sessions/` for detailed session logs
3. Run app in Xcode to verify current state
4. Check Console.app for any runtime warnings
