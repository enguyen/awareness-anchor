import XCTest
@testable import AwarenessAnchor

// MARK: - Test Helpers

/// Build a sequence of PoseFrames from compact tuples.
/// Each tuple: (pitch, yaw, boundingBoxWidth, timeOffset)
func makeFrames(_ data: [(Float, Float, Float, TimeInterval)]) -> [PoseFrame] {
    data.map { PoseFrame(pitch: $0.0, yaw: $0.1, boundingBoxWidth: $0.2, timestamp: $0.3) }
}

/// Run an engine through a sequence of frames and return all events.
func runEngine(_ engine: inout HeadPoseEngine, frames: [PoseFrame]) -> [EngineEvent] {
    var allEvents: [EngineEvent] = []
    for frame in frames {
        let events = engine.feed(pitch: frame.pitch, yaw: frame.yaw,
                                 boundingBoxWidth: frame.boundingBoxWidth,
                                 at: frame.timestamp)
        allEvents.append(contentsOf: events)
    }
    return allEvents
}

/// Check if events contain a trigger with the given pose.
func assertContainsTrigger(_ events: [EngineEvent], pose: HeadPose,
                           file: StaticString = #file, line: UInt = #line) {
    let triggers = events.compactMap { event -> (HeadPose, GazeEdge)? in
        if case .triggered(let p, let e) = event { return (p, e) }
        return nil
    }
    XCTAssertTrue(triggers.contains(where: { $0.0 == pose }),
                  "Expected trigger with pose \(pose), got triggers: \(triggers)",
                  file: file, line: line)
}

/// Check that events contain no triggers at all.
func assertNoTrigger(_ events: [EngineEvent],
                     file: StaticString = #file, line: UInt = #line) {
    let triggers = events.filter {
        if case .triggered = $0 { return true }
        return false
    }
    XCTAssertTrue(triggers.isEmpty,
                  "Expected no triggers, got: \(triggers)",
                  file: file, line: line)
}

/// Check if events contain a returnedToNeutral event.
func assertContainsReturn(_ events: [EngineEvent],
                          file: StaticString = #file, line: UInt = #line) {
    let returns = events.filter {
        if case .returnedToNeutral = $0 { return true }
        return false
    }
    XCTAssertFalse(returns.isEmpty,
                   "Expected returnedToNeutral event, got none",
                   file: file, line: line)
}

// MARK: - Synthetic Frame Generators

/// Generate neutral frames at a given baseline pose.
func neutralFrames(count: Int, pitch: Float = -0.25, yaw: Float = 0.07,
                   bbw: Float = 0.18, startTime: TimeInterval = 0,
                   fps: Float = 30) -> [(Float, Float, Float, TimeInterval)] {
    (0..<count).map { i in
        (pitch, yaw, bbw, startTime + TimeInterval(Float(i) / fps))
    }
}

/// Generate frames that ramp from one value to another over time.
func rampFrames(count: Int, startPitch: Float, endPitch: Float,
                startYaw: Float, endYaw: Float, bbw: Float = 0.18,
                startTime: TimeInterval, fps: Float = 30) -> [(Float, Float, Float, TimeInterval)] {
    (0..<count).map { i in
        let t = Float(i) / Float(count - 1)
        let pitch = startPitch + (endPitch - startPitch) * t
        let yaw = startYaw + (endYaw - startYaw) * t
        return (pitch, yaw, bbw, startTime + TimeInterval(Float(i) / fps))
    }
}

// MARK: - Tests: Manual Threshold Mode

final class HeadPoseEngineManualTests: XCTestCase {

    func makeManualConfig(pitch: Float = 0.16, yaw: Float = 0.28) -> EngineConfig {
        var config = EngineConfig()
        config.thresholdMode = .manual(pitch: pitch, yaw: yaw)
        config.smoothingFactor = 0.0  // No smoothing for predictable tests
        config.dwellTime = 0.2
        config.framesToSkip = 0  // No skip for synthetic data
        return config
    }

    // MARK: - Baseline

    func testBaselineSetFromFirstFrame() {
        var engine = HeadPoseEngine(config: makeManualConfig())
        let events = engine.feed(pitch: -0.25, yaw: 0.07, boundingBoxWidth: 0.18, at: 0)
        XCTAssertTrue(events.contains(where: {
            if case .baselineSet(let p, let y) = $0 { return p == -0.25 && y == 0.07 }
            return false
        }))
    }

    // MARK: - Clean tiltUp

    func testCleanTiltUpTriggers() {
        var engine = HeadPoseEngine(config: makeManualConfig())

        // Baseline frame
        let baseline = neutralFrames(count: 1, pitch: -0.25, yaw: 0.07)
        // Hold at neutral for 1 second
        let hold = neutralFrames(count: 30, pitch: -0.25, yaw: 0.07, startTime: 1.0 / 30.0)
        // Tilt up (pitch goes more negative = looking up)
        let tiltUp = neutralFrames(count: 15, pitch: -0.25 - 0.20, yaw: 0.07,
                                   startTime: 31.0 / 30.0)

        let frames = makeFrames(baseline + hold + tiltUp)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
    }

    // MARK: - Clean turnLeftRight

    func testCleanTurnLeftTriggers() {
        var engine = HeadPoseEngine(config: makeManualConfig())

        let baseline = neutralFrames(count: 1, pitch: -0.25, yaw: 0.07)
        let hold = neutralFrames(count: 30, pitch: -0.25, yaw: 0.07, startTime: 1.0 / 30.0)
        // Turn left (positive yaw delta > threshold)
        let turnLeft = neutralFrames(count: 15, pitch: -0.25, yaw: 0.07 + 0.35,
                                     startTime: 31.0 / 30.0)

        let frames = makeFrames(baseline + hold + turnLeft)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
    }

    // MARK: - Below threshold (no trigger)

    func testBelowThresholdNoTrigger() {
        var engine = HeadPoseEngine(config: makeManualConfig())

        let baseline = neutralFrames(count: 1, pitch: -0.25, yaw: 0.07)
        // Slight tilt, well below threshold
        let slight = neutralFrames(count: 60, pitch: -0.25 - 0.10, yaw: 0.07,
                                   startTime: 1.0 / 30.0)

        let frames = makeFrames(baseline + slight)
        let events = runEngine(&engine, frames: frames)
        assertNoTrigger(events)
    }

    // MARK: - Return to neutral

    func testReturnToNeutralAfterTrigger() {
        var engine = HeadPoseEngine(config: makeManualConfig())

        let baseline = neutralFrames(count: 1, pitch: -0.25, yaw: 0.07)
        // Tilt up to trigger
        let tiltUp = neutralFrames(count: 15, pitch: -0.25 - 0.20, yaw: 0.07,
                                   startTime: 1.0 / 30.0)
        // Return to neutral
        let returnNeutral = neutralFrames(count: 10, pitch: -0.25, yaw: 0.07,
                                          startTime: 16.0 / 30.0)

        let frames = makeFrames(baseline + tiltUp + returnNeutral)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
        assertContainsReturn(events)
    }

    // MARK: - Dwell blocked during cooldown

    func testCooldownBlocksTrigger() {
        var config = makeManualConfig()
        var engine = HeadPoseEngine(config: config)
        engine.isInCooldown = true

        let baseline = neutralFrames(count: 1, pitch: -0.25, yaw: 0.07)
        let tiltUp = neutralFrames(count: 15, pitch: -0.25 - 0.20, yaw: 0.07,
                                   startTime: 1.0 / 30.0)

        let frames = makeFrames(baseline + tiltUp)
        let events = runEngine(&engine, frames: frames)
        assertNoTrigger(events)
    }

    // MARK: - Yaw takes precedence over pitch

    func testYawPrecedenceOverPitch() {
        var engine = HeadPoseEngine(config: makeManualConfig())

        let baseline = neutralFrames(count: 1, pitch: -0.25, yaw: 0.07)
        // Both axes exceed threshold — yaw should win
        let both = neutralFrames(count: 15, pitch: -0.25 - 0.20, yaw: 0.07 + 0.35,
                                 startTime: 1.0 / 30.0)

        let frames = makeFrames(baseline + both)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
    }
}

// MARK: - Tests: Auto Threshold Mode

final class HeadPoseEngineAutoTests: XCTestCase {

    // MacBook 14" approximate dimensions
    func makeAutoConfig(screenW: Float = 0.311, screenH: Float = 0.215,
                        hfov: Float = 64, mult: Float = 1.3) -> EngineConfig {
        var config = EngineConfig()
        config.thresholdMode = .auto(screenWidthMeters: screenW,
                                     screenHeightMeters: screenH,
                                     cameraHFOVDegrees: hfov,
                                     sensitivityMultiplier: mult)
        config.smoothingFactor = 0.0
        config.dwellTime = 0.2
        config.framesToSkip = 0
        return config
    }

    func testAutoThresholdsComputedAtBaseline() {
        var engine = HeadPoseEngine(config: makeAutoConfig())
        let events = engine.feed(pitch: -0.25, yaw: 0.07, boundingBoxWidth: 0.18, at: 0)

        let autoEvents = events.compactMap { event -> (Float, Float, Float)? in
            if case .autoThresholdsComputed(let p, let y, let d) = event { return (p, y, d) }
            return nil
        }
        XCTAssertEqual(autoEvents.count, 1, "Should compute auto thresholds once at baseline")
        let (pitch, yaw, dist) = autoEvents[0]
        XCTAssertGreaterThan(pitch, 0, "Auto pitch threshold should be positive")
        XCTAssertGreaterThan(yaw, 0, "Auto yaw threshold should be positive")
        XCTAssertGreaterThan(dist, 0.3, "Distance should be reasonable (>0.3m)")
        XCTAssertLessThan(dist, 2.0, "Distance should be reasonable (<2m)")
    }

    func testAutoTiltUpTriggers() {
        var engine = HeadPoseEngine(config: makeAutoConfig())

        // Baseline with bbw=0.18 (typical laptop distance)
        let baseline = neutralFrames(count: 1, pitch: -0.25, yaw: 0.07, bbw: 0.18)

        // Compute what threshold would be to know how much to tilt
        let (pitchThresh, _) = engine.effectiveThresholds(boundingBoxWidth: 0.18)

        // Tilt well beyond threshold
        let tiltUp = neutralFrames(count: 15, pitch: -0.25 - pitchThresh - 0.05, yaw: 0.07,
                                   bbw: 0.18, startTime: 1.0 / 30.0)

        let frames = makeFrames(baseline + tiltUp)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
    }

    func testAutoThresholdsDifferByDistance() {
        // Closer face (larger bbox) → closer distance → screen subtends larger angle → larger threshold
        let config = makeAutoConfig()
        let engine = HeadPoseEngine(config: config)

        let (pitchClose, yawClose) = engine.effectiveThresholds(boundingBoxWidth: 0.25)
        let (pitchFar, yawFar) = engine.effectiveThresholds(boundingBoxWidth: 0.12)

        XCTAssertGreaterThan(pitchClose, pitchFar, "Closer face should have larger pitch threshold")
        XCTAssertGreaterThan(yawClose, yawFar, "Closer face should have larger yaw threshold")
    }

    func testSensitivityMultiplierScalesThresholds() {
        let config1 = makeAutoConfig(mult: 1.0)
        let config2 = makeAutoConfig(mult: 2.0)
        let engine1 = HeadPoseEngine(config: config1)
        let engine2 = HeadPoseEngine(config: config2)

        let (pitch1, _) = engine1.effectiveThresholds(boundingBoxWidth: 0.18)
        let (pitch2, _) = engine2.effectiveThresholds(boundingBoxWidth: 0.18)

        XCTAssertEqual(pitch2, pitch1 * 2.0, accuracy: 0.001,
                       "2x multiplier should double the threshold")
    }
}

// MARK: - Tests: Recorded Replay

final class HeadPoseEngineReplayTests: XCTestCase {

    // Recorded 2026-02-17: Clean tiltUp (Present) on MacBook laptop-only
    // Metadata: laptop mode, screen 0.291m x 0.189m, HFOV 64°, sensitivity 1.3
    // Gesture: neutral ~1.3s, then tilt up to trigger, hold, return
    static let cleanTiltUpLaptop: [(Float, Float, Float, TimeInterval)] = [
        // Neutral baseline (~1.3s)
        (-0.0537, 0.0951, 0.3001, 0.036),
        (-0.0499, 0.0920, 0.3005, 0.104),
        (-0.0422, 0.0905, 0.3008, 0.173),
        (-0.0545, 0.0997, 0.2992, 0.241),
        (-0.0476, 0.1058, 0.2983, 0.310),
        (-0.0268, 0.1028, 0.2996, 0.381),
        (-0.0100, 0.1074, 0.2994, 0.457),
        ( 0.0031, 0.1028, 0.3004, 0.504),
        (-0.0023, 0.1074, 0.3000, 0.566),
        ( 0.0015, 0.1089, 0.2985, 0.637),
        ( 0.0015, 0.1058, 0.2975, 0.704),
        ( 0.0092, 0.1028, 0.2975, 0.770),
        ( 0.0061, 0.1043, 0.2980, 0.840),
        ( 0.0092, 0.1028, 0.2958, 0.907),
        ( 0.0031, 0.0936, 0.2932, 0.977),
        (-0.0061, 0.0859, 0.2929, 1.047),
        ( 0.0000, 0.0844, 0.2943, 1.113),
        ( 0.0077, 0.0828, 0.2930, 1.179),
        ( 0.0031, 0.0767, 0.2950, 1.248),
        (-0.0176, 0.0614, 0.2918, 1.315),
        (-0.0130, 0.0614, 0.2917, 1.377),
        // Tilt up begins
        (-0.0798, 0.0721, 0.2932, 1.461),
        (-0.1235, 0.0598, 0.2915, 1.514),
        (-0.1434, 0.0690, 0.2882, 1.575),
        (-0.1994, 0.0552, 0.2852, 1.638),
        (-0.2255, 0.0353, 0.2876, 1.706),
        (-0.2454, 0.0337, 0.2839, 1.769),
        (-0.2661, 0.0337, 0.2833, 1.845),
        // Holding tilt (trigger should fire during dwell)
        (-0.2516, 0.0690, 0.2810, 1.912),
        (-0.2608, 0.0506, 0.2785, 1.975),
        (-0.2531, 0.0506, 0.2779, 2.042),
        (-0.2600, 0.0522, 0.2786, 2.107),
        (-0.2715, 0.0491, 0.2791, 2.176),
        (-0.3083, 0.0522, 0.2777, 2.240),
        (-0.3221, 0.0660, 0.2777, 2.309),
        (-0.3367, 0.0767, 0.2728, 2.379),
        (-0.3505, 0.0844, 0.2713, 2.445),
        (-0.3812, 0.0767, 0.2689, 2.511),
        (-0.3781, 0.0752, 0.2689, 2.579),
        (-0.3804, 0.0752, 0.2688, 2.643),
        (-0.3942, 0.0767, 0.2640, 2.708),
        (-0.3950, 0.0706, 0.2669, 2.767),
    ]

    func testReplayCleanTiltUpLaptopAuto() {
        // Use auto thresholds matching the recording metadata
        var config = EngineConfig()
        config.thresholdMode = .auto(
            screenWidthMeters: 0.2905,
            screenHeightMeters: 0.1889,
            cameraHFOVDegrees: 64,
            sensitivityMultiplier: 1.3
        )
        config.smoothingFactor = 0.5
        config.dwellTime = 0.2
        config.framesToSkip = 5
        var engine = HeadPoseEngine(config: config)

        let frames = makeFrames(Self.cleanTiltUpLaptop)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)

        // Verify triggered edge is .top
        let triggers = events.compactMap { e -> GazeEdge? in
            if case .triggered(_, let edge) = e { return edge }
            return nil
        }
        XCTAssertEqual(triggers.first, .top)
    }

    func testReplayCleanTiltUpManualThresholds() {
        // Same recording but with manual thresholds (external display scenario)
        var config = EngineConfig()
        config.thresholdMode = .manual(pitch: 0.16, yaw: 0.28)
        config.smoothingFactor = 0.5
        config.dwellTime = 0.2
        config.framesToSkip = 5
        var engine = HeadPoseEngine(config: config)

        let frames = makeFrames(Self.cleanTiltUpLaptop)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
    }

    func testReplayCleanTiltUpWithReturnToNeutral() {
        // Full recording including return — add remaining frames
        let returnFrames: [(Float, Float, Float, TimeInterval)] = [
            (-0.3827, 0.0736, 0.2667, 2.838),
            (-0.3858, 0.0706, 0.2647, 2.905),
            (-0.3843, 0.0690, 0.2665, 2.974),
            (-0.3697, 0.0690, 0.2654, 3.045),
            (-0.3497, 0.0736, 0.2646, 3.107),
            (-0.3405, 0.0736, 0.2657, 3.173),
            (-0.3444, 0.0752, 0.2650, 3.245),
            (-0.3505, 0.0752, 0.2664, 3.314),
            (-0.3336, 0.0736, 0.2674, 3.373),
            (-0.3306, 0.0736, 0.2668, 3.441),
            (-0.3306, 0.0690, 0.2676, 3.516),
            (-0.3497, 0.0568, 0.2654, 3.588),
            (-0.3137, 0.0598, 0.2664, 3.668),
            (-0.3030, 0.0476, 0.2698, 3.721),
            // Return to neutral
            (-0.2378, 0.0537, 0.2696, 3.791),
            (-0.2454, 0.0690, 0.2749, 3.863),
            (-0.2638, 0.0598, 0.2748, 3.917),
            (-0.2815, 0.0291, 0.2767, 3.990),
            (-0.2592, 0.0368, 0.2783, 4.058),
            (-0.2224, 0.0337, 0.2806, 4.121),
            (-0.1887, 0.0476, 0.2806, 4.186),
            (-0.1703, 0.0291, 0.2832, 4.260),
            (-0.2148, 0.0598, 0.2815, 4.326),
            (-0.1710, 0.0644, 0.2845, 4.391),
            (-0.1741, 0.0706, 0.2840, 4.466),
            (-0.1741, 0.0706, 0.2867, 4.544),
            (-0.1626, 0.0675, 0.2860, 4.598),
            (-0.1381, 0.0399, 0.2858, 4.659),
            (-0.1281, 0.0460, 0.2874, 4.724),
            (-0.1319, 0.0506, 0.2874, 4.791),
        ]

        var config = EngineConfig()
        config.thresholdMode = .auto(
            screenWidthMeters: 0.2905,
            screenHeightMeters: 0.1889,
            cameraHFOVDegrees: 64,
            sensitivityMultiplier: 1.3
        )
        config.smoothingFactor = 0.5
        config.dwellTime = 0.2
        config.framesToSkip = 5
        var engine = HeadPoseEngine(config: config)

        let allData = Self.cleanTiltUpLaptop + returnFrames
        let frames = makeFrames(allData)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
        assertContainsReturn(events)
    }
}

// MARK: - Tests: External Monitor Replay

final class HeadPoseEngineExternalReplayTests: XCTestCase {

    /// Manual config matching the external monitor recording metadata
    func makeExternalConfig() -> EngineConfig {
        var config = EngineConfig()
        config.thresholdMode = .manual(pitch: 0.1825, yaw: 0.3307)
        config.smoothingFactor = 0.5
        config.dwellTime = 0.2
        config.framesToSkip = 5
        return config
    }

    // Recording 120910: Clean tiltUp on external monitor, 58 frames ~4.0s
    // Pitch drops from -0.43 to -0.69, returns to -0.47
    static let externalTiltUp1: [(Float, Float, Float, TimeInterval)] = [
        (-0.4257, -0.0483, 0.2326, 0.027), (-0.4272, -0.0514, 0.2345, 0.099),
        (-0.4180, -0.0506, 0.2358, 0.165), (-0.4241, -0.0414, 0.2353, 0.235),
        (-0.4303, -0.0391, 0.2352, 0.300), (-0.4341, -0.0330, 0.2345, 0.370),
        (-0.4403, -0.0360, 0.2357, 0.435), (-0.4318, -0.0376, 0.2348, 0.498),
        (-0.4357, -0.0360, 0.2345, 0.561), (-0.4326, -0.0422, 0.2321, 0.631),
        (-0.4449, -0.0391, 0.2351, 0.698), (-0.4495, -0.0422, 0.2362, 0.768),
        (-0.4287, -0.0337, 0.2374, 0.833), (-0.4510, -0.0376, 0.2371, 0.900),
        (-0.4157, -0.0514, 0.2318, 0.965), (-0.4264, -0.0483, 0.2345, 1.033),
        (-0.4211, -0.0376, 0.2370, 1.100), (-0.4433, -0.0184, 0.2337, 1.165),
        (-0.4748, -0.0399, 0.2368, 1.233), (-0.4702, -0.0360, 0.2317, 1.304),
        (-0.5093, -0.0207, 0.2283, 1.371), (-0.4939, -0.0291, 0.2218, 1.433),
        (-0.5193, -0.0307, 0.2258, 1.497), (-0.5545, -0.0307, 0.2165, 1.569),
        (-0.5484, -0.0230, 0.2136, 1.634), (-0.5860, -0.0184, 0.2077, 1.695),
        (-0.6006, -0.0046, 0.2093, 1.769), (-0.5791, -0.0230, 0.2110, 1.835),
        (-0.5883, -0.0291, 0.2042, 1.898), (-0.5998, -0.0360, 0.2071, 1.966),
        (-0.6136, -0.0422, 0.2032, 2.035), (-0.6075, -0.0476, 0.2022, 2.098),
        (-0.6128, -0.0437, 0.2000, 2.166), (-0.6266, -0.0476, 0.2012, 2.232),
        (-0.6389, -0.0621, 0.2032, 2.298), (-0.6558, -0.0882, 0.1974, 2.365),
        (-0.6627, -0.0828, 0.1970, 2.430), (-0.6650, -0.0897, 0.1874, 2.499),
        (-0.6634, -0.0874, 0.2008, 2.567), (-0.6642, -0.0890, 0.1880, 2.633),
        (-0.6742, -0.0936, 0.1955, 2.699), (-0.6872, -0.0920, 0.1984, 2.764),
        (-0.6941, -0.1043, 0.1970, 2.831), (-0.6819, -0.0928, 0.1998, 2.900),
        // Return phase
        (-0.6435, -0.0744, 0.2054, 2.968), (-0.6044, 0.0061, 0.1964, 3.035),
        (-0.5806, 0.0199, 0.2008, 3.104), (-0.5246, 0.0245, 0.1981, 3.168),
        (-0.5085, 0.0107, 0.2115, 3.236), (-0.5262, 0.0077, 0.2170, 3.301),
        (-0.5438, -0.0061, 0.2141, 3.368), (-0.5430, -0.0176, 0.2190, 3.439),
        (-0.4978, 0.0383, 0.2149, 3.500), (-0.5001, 0.0430, 0.2234, 3.569),
        (-0.5154, 0.0506, 0.2171, 3.632), (-0.5077, 0.0430, 0.2240, 3.703),
        (-0.4847, 0.0322, 0.2251, 3.770), (-0.4617, 0.0261, 0.2220, 3.836),
        (-0.4694, 0.0199, 0.2273, 3.896), (-0.4663, 0.0199, 0.2217, 3.963),
        (-0.4656, 0.0107, 0.2300, 4.037),
    ]

    // Recording 120924: TiltUp with yaw shift on external monitor, 50 frames ~3.3s
    // Pitch drops from -0.36 to -0.70, yaw swings from +0.19 to -0.10 and back
    static let externalTiltUp2: [(Float, Float, Float, TimeInterval)] = [
        (-0.3620, 0.1871, 0.2496, 0.012), (-0.3613, 0.1887, 0.2512, 0.078),
        (-0.3567, 0.1979, 0.2515, 0.144), (-0.3513, 0.1933, 0.2492, 0.213),
        (-0.3582, 0.1933, 0.2535, 0.278), (-0.3628, 0.1856, 0.2522, 0.346),
        (-0.3628, 0.1902, 0.2513, 0.414), (-0.3659, 0.1963, 0.2528, 0.479),
        (-0.3705, 0.1917, 0.2528, 0.545), (-0.3306, 0.1825, 0.2477, 0.613),
        (-0.3904, 0.1396, 0.2526, 0.680), (-0.3942, 0.1764, 0.2472, 0.748),
        (-0.3942, 0.0675, 0.2435, 0.813), (-0.4717, 0.0199, 0.2401, 0.878),
        (-0.4640, -0.0245, 0.2314, 0.948), (-0.5108, -0.0284, 0.2238, 1.016),
        (-0.5760, -0.0322, 0.2099, 1.080), (-0.5929, -0.0353, 0.2073, 1.146),
        (-0.6228, -0.0322, 0.2041, 1.212), (-0.6803, -0.0491, 0.1974, 1.276),
        (-0.6780, -0.0291, 0.1934, 1.346), (-0.6627, 0.0307, 0.1948, 1.416),
        (-0.6573, 0.0215, 0.1848, 1.477), (-0.6581, 0.0046, 0.1872, 1.545),
        (-0.6450, 0.0291, 0.1813, 1.614), (-0.6435, 0.0291, 0.1832, 1.677),
        (-0.6619, 0.0414, 0.1849, 1.750), (-0.6604, 0.0261, 0.1805, 1.812),
        (-0.6596, 0.0184, 0.1805, 1.877), (-0.7033, 0.0199, 0.1809, 1.945),
        (-0.6849, 0.0506, 0.1796, 2.012), (-0.6826, 0.0445, 0.1743, 2.078),
        (-0.6880, 0.0199, 0.1796, 2.147), (-0.6941, 0.0230, 0.1755, 2.213),
        (-0.6980, 0.0261, 0.1854, 2.279), (-0.6780, 0.0230, 0.1832, 2.346),
        (-0.6734, 0.0337, 0.1909, 2.409), (-0.6427, 0.0568, 0.1953, 2.480),
        // Return phase
        (-0.5906, 0.0690, 0.2002, 2.550), (-0.5714, 0.1074, 0.2166, 2.615),
        (-0.5553, 0.0920, 0.2099, 2.682), (-0.5783, 0.1104, 0.2164, 2.748),
        (-0.5844, 0.1258, 0.2199, 2.826), (-0.5476, 0.1534, 0.2287, 2.876),
        (-0.5369, 0.1749, 0.2273, 2.947), (-0.5361, 0.1917, 0.2299, 3.018),
        (-0.5614, 0.2102, 0.2300, 3.077), (-0.5722, 0.2546, 0.2319, 3.146),
        (-0.5760, 0.2485, 0.2302, 3.214), (-0.6029, 0.2500, 0.2335, 3.277),
    ]

    // Recording 120934: TiltUp from offset start on external monitor, 43 frames ~2.9s
    // Starts with yaw -0.24, pitch drops from -0.26 to -0.67
    static let externalTiltUp3: [(Float, Float, Float, TimeInterval)] = [
        (-0.2646, -0.2385, 0.2403, 0.057), (-0.2638, -0.2393, 0.2386, 0.124),
        (-0.2608, -0.2347, 0.2376, 0.192), (-0.2715, -0.2332, 0.2386, 0.258),
        (-0.2462, -0.2140, 0.2404, 0.325), (-0.2915, -0.2102, 0.2369, 0.390),
        (-0.3221, -0.2332, 0.2440, 0.458), (-0.3014, -0.2178, 0.2347, 0.527),
        (-0.3697, -0.1917, 0.2356, 0.593), (-0.4318, -0.1841, 0.2350, 0.659),
        (-0.4088, -0.1227, 0.2314, 0.725), (-0.4449, -0.1204, 0.2214, 0.795),
        (-0.4771, -0.0644, 0.2162, 0.860), (-0.5469, -0.0637, 0.2155, 0.932),
        (-0.5553, -0.0629, 0.2058, 0.991), (-0.5722, -0.0606, 0.2021, 1.060),
        (-0.5622, -0.0506, 0.2041, 1.124), (-0.5967, -0.0360, 0.1990, 1.194),
        (-0.6082, -0.0376, 0.2006, 1.260), (-0.6251, -0.0468, 0.2061, 1.325),
        (-0.6197, -0.0706, 0.2058, 1.394), (-0.6144, -0.0736, 0.1948, 1.459),
        (-0.6251, -0.0782, 0.1969, 1.523), (-0.6389, -0.0859, 0.1905, 1.593),
        (-0.6450, -0.0897, 0.1925, 1.655), (-0.6389, -0.0874, 0.1910, 1.723),
        (-0.6435, -0.0951, 0.1887, 1.791), (-0.6642, -0.0943, 0.1958, 1.860),
        (-0.6650, -0.0989, 0.1914, 1.925), (-0.6550, -0.0951, 0.1866, 1.991),
        (-0.6489, -0.1043, 0.1911, 2.061), (-0.6535, -0.1066, 0.1955, 2.124),
        (-0.6634, -0.0943, 0.1879, 2.191), (-0.6665, -0.0951, 0.1838, 2.258),
        (-0.6473, -0.0828, 0.1795, 2.327), (-0.6443, -0.0752, 0.1959, 2.395),
        (-0.6366, -0.0598, 0.1923, 2.460), (-0.6351, -0.0284, 0.1928, 2.526),
        (-0.6328, -0.0153, 0.1905, 2.594), (-0.6013, 0.0107, 0.1967, 2.660),
        (-0.5890, 0.0092, 0.2042, 2.734), (-0.6021, 0.0414, 0.1987, 2.806),
        (-0.5990, 0.0844, 0.2141, 2.860),
    ]

    func testExternalTiltUp1TriggersPresent() {
        var config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.externalTiltUp1)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
    }

    func testExternalTiltUp1HasReturnToNeutral() {
        var config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.externalTiltUp1)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
        assertContainsReturn(events)
    }

    func testExternalTiltUp2TriggersPresent() {
        var config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.externalTiltUp2)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
    }

    func testExternalTiltUp3TriggersPresent() {
        var config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.externalTiltUp3)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
    }
}

// MARK: - Tests: External Monitor Returned (turnLeftRight) Replay

final class HeadPoseEngineExternalReturnedTests: XCTestCase {

    func makeExternalConfig() -> EngineConfig {
        var config = EngineConfig()
        config.thresholdMode = .manual(pitch: 0.1825, yaw: 0.3307)
        config.smoothingFactor = 0.5
        config.dwellTime = 0.2
        config.framesToSkip = 5
        return config
    }

    // Recording 124512: Right turn on external monitor, 61 frames ~4.2s
    // Yaw swings from 0.18 to 0.75, then returns to ~0.14
    static let externalTurnRight1: [(Float, Float, Float, TimeInterval)] = [
        (-0.5070, 0.1687, 0.2387, 0.029), (-0.5162, 0.1917, 0.2352, 0.100),
        (-0.5377, 0.1917, 0.2401, 0.164), (-0.5400, 0.1917, 0.2424, 0.230),
        (-0.5446, 0.1841, 0.2410, 0.299), (-0.5499, 0.1841, 0.2379, 0.364),
        (-0.5423, 0.1902, 0.2478, 0.432), (-0.5369, 0.1749, 0.2422, 0.498),
        (-0.5400, 0.1948, 0.2424, 0.563), (-0.5315, 0.1764, 0.2372, 0.631),
        (-0.5331, 0.1825, 0.2442, 0.699), (-0.5338, 0.1779, 0.2400, 0.764),
        (-0.5177, 0.1871, 0.2419, 0.837), (-0.5246, 0.2270, 0.2431, 0.899),
        (-0.5607, 0.2516, 0.2357, 0.966), (-0.5407, 0.2378, 0.2435, 1.033),
        (-0.5967, 0.3252, 0.2353, 1.110), (-0.4893, 0.4403, 0.2354, 1.166),
        (-0.5484, 0.5246, 0.2271, 1.233), (-0.5768, 0.6136, 0.2220, 1.302),
        (-0.5699, 0.7793, 0.2129, 1.362), (-0.5361, 0.7470, 0.1992, 1.432),
        (-0.4088, 0.6964, 0.1969, 1.501), (-0.4855, 0.6995, 0.1861, 1.564),
        (-0.5139, 0.7547, 0.1855, 1.633), (-0.5001, 0.7547, 0.1802, 1.697),
        (-0.4955, 0.7486, 0.1886, 1.766), (-0.5139, 0.7409, 0.1891, 1.831),
        (-0.5269, 0.7317, 0.1874, 1.901), (-0.5231, 0.7348, 0.1763, 1.966),
        (-0.5254, 0.7486, 0.1853, 2.034), (-0.5300, 0.7424, 0.1991, 2.102),
        (-0.5216, 0.7455, 0.1768, 2.166), (-0.5377, 0.7440, 0.1771, 2.233),
        (-0.5223, 0.7470, 0.1910, 2.299), (-0.5054, 0.7563, 0.1847, 2.370),
        (-0.4947, 0.7655, 0.1779, 2.432), (-0.5223, 0.7655, 0.1888, 2.499),
        (-0.5630, 0.7302, 0.1950, 2.567), (-0.5507, 0.6995, 0.1975, 2.632),
        // Return phase
        (-0.5783, 0.7332, 0.1904, 2.706), (-0.5635, 0.7240, 0.1981, 2.763),
        (-0.5952, 0.6734, 0.2135, 2.834), (-0.5990, 0.6995, 0.2170, 2.899),
        (-0.6251, 0.5937, 0.2333, 2.966), (-0.5400, 0.4924, 0.2310, 3.035),
        (-0.5791, 0.4556, 0.2402, 3.100), (-0.5039, 0.4602, 0.2356, 3.168),
        (-0.5545, 0.3988, 0.2328, 3.234), (-0.5476, 0.2945, 0.2412, 3.302),
        (-0.5645, 0.2347, 0.2443, 3.370), (-0.5170, 0.1841, 0.2348, 3.435),
        (-0.5369, 0.2777, 0.2414, 3.502), (-0.5361, 0.2531, 0.2443, 3.565),
        (-0.5154, 0.2102, 0.2435, 3.634), (-0.4893, 0.1856, 0.2436, 3.699),
        (-0.4901, 0.1457, 0.2419, 3.768), (-0.4617, 0.1779, 0.2482, 3.830),
        (-0.4686, 0.1718, 0.2431, 3.899), (-0.4671, 0.1611, 0.2450, 3.964),
        (-0.4778, 0.1442, 0.2467, 4.031), (-0.4970, 0.1442, 0.2477, 4.100),
        (-0.5108, 0.1411, 0.2468, 4.163),
    ]

    // Recording 124519: Left turn on external monitor, 41 frames ~2.7s
    // Yaw drops from 0.14 to -0.47
    static let externalTurnLeft1: [(Float, Float, Float, TimeInterval)] = [
        (-0.4985, 0.1396, 0.2455, 0.014), (-0.5031, 0.1534, 0.2472, 0.080),
        (-0.5039, 0.1534, 0.2491, 0.151), (-0.5100, 0.1519, 0.2452, 0.211),
        (-0.5062, 0.1503, 0.2455, 0.278), (-0.4970, 0.1411, 0.2441, 0.345),
        (-0.4932, 0.1473, 0.2466, 0.410), (-0.4939, 0.1381, 0.2490, 0.479),
        (-0.4924, 0.1488, 0.2479, 0.546), (-0.5016, 0.1442, 0.2465, 0.610),
        (-0.4847, 0.0966, 0.2404, 0.678), (-0.4364, 0.0506, 0.2328, 0.746),
        (-0.4610, 0.0660, 0.2265, 0.811), (-0.4004, 0.0199, 0.2383, 0.880),
        (-0.3873, -0.0614, 0.2270, 0.957), (-0.4057, -0.1074, 0.2375, 1.013),
        (-0.3919, -0.1933, 0.2373, 1.082), (-0.3275, -0.2615, 0.2306, 1.148),
        (-0.3728, -0.3237, 0.2347, 1.213), (-0.3682, -0.3543, 0.2218, 1.281),
        (-0.3705, -0.3988, 0.2243, 1.351), (-0.3758, -0.4441, 0.2253, 1.414),
        (-0.3605, -0.4487, 0.2160, 1.483), (-0.3674, -0.4487, 0.2114, 1.547),
        (-0.3651, -0.4587, 0.2183, 1.615), (-0.3651, -0.4510, 0.2171, 1.681),
        (-0.3574, -0.4579, 0.2142, 1.746), (-0.3743, -0.4617, 0.2147, 1.815),
        (-0.3743, -0.4594, 0.2162, 1.879), (-0.3697, -0.4548, 0.2199, 1.947),
        (-0.3551, -0.4556, 0.2204, 2.014), (-0.3712, -0.4510, 0.2201, 2.085),
        (-0.3774, -0.4648, 0.2165, 2.147), (-0.3758, -0.4610, 0.2182, 2.212),
        (-0.3797, -0.4671, 0.2138, 2.281), (-0.3889, -0.4686, 0.2325, 2.349),
        (-0.3735, -0.4472, 0.2212, 2.411), (-0.3804, -0.4464, 0.2156, 2.479),
        (-0.3873, -0.4272, 0.2219, 2.547), (-0.3873, -0.4126, 0.2244, 2.612),
        (-0.3866, -0.3850, 0.2163, 2.678),
    ]

    // Recording 124539: Large right turn + return on external monitor, 117 frames ~9.1s
    // Yaw from 0.55 to 1.0, long hold, then returns through large sweep
    static let externalTurnRight2: [(Float, Float, Float, TimeInterval)] = [
        (-0.4602, 0.5476, 0.2272, 0.041), (-0.4640, 0.5461, 0.2244, 0.108),
        (-0.4625, 0.5476, 0.2280, 0.174), (-0.4617, 0.5461, 0.2289, 0.241),
        (-0.4380, 0.5492, 0.2295, 0.311), (-0.4525, 0.5507, 0.2328, 0.376),
        (-0.4548, 0.5476, 0.2315, 0.440), (-0.4602, 0.5461, 0.2321, 0.508),
        (-0.4464, 0.5400, 0.2289, 0.573), (-0.4464, 0.5492, 0.2358, 0.640),
        (-0.4495, 0.5492, 0.2419, 0.709), (-0.4479, 0.5614, 0.2354, 0.776),
        (-0.4533, 0.5737, 0.2158, 0.843), (-0.4571, 0.5921, 0.2283, 0.909),
        (-0.4671, 0.6535, 0.2180, 0.973), (-0.5821, 0.7271, 0.1989, 1.042),
        (-0.5446, 0.6964, 0.2198, 1.115), (-0.5798, 0.7225, 0.1946, 1.181),
        (-0.5821, 0.7363, 0.1903, 1.246), (-0.5983, 0.7823, 0.1896, 1.314),
        (-0.6128, 0.8023, 0.1902, 1.377), (-0.5983, 0.8237, 0.1910, 1.444),
        (-0.6052, 0.9143, 0.1950, 1.518), (-0.6466, 0.9434, 0.1943, 1.582),
        (-0.6634, 0.9296, 0.1880, 1.646), (-0.6366, 0.9403, 0.1887, 1.716),
        (-0.6757, 0.9587, 0.1844, 1.780), (-0.6918, 0.9879, 0.1877, 1.845),
        (-0.6473, 0.9863, 0.1903, 1.915), (-0.6412, 0.9741, 0.1884, 1.976),
        (-0.6420, 0.9817, 0.1882, 2.041), (-0.6059, 0.9173, 0.1912, 2.112),
        (-0.6420, 0.9848, 0.1910, 2.178), (-0.6144, 0.9204, 0.1918, 2.245),
        (-0.6136, 0.9204, 0.1875, 2.313), (-0.6113, 0.9618, 0.1889, 2.381),
        (-0.6082, 0.9817, 0.1997, 2.449), (-0.5775, 0.9925, 0.1916, 2.513),
        (-0.5653, 1.0048, 0.1995, 2.580), (-0.5691, 1.0063, 0.1971, 2.644),
        (-0.5492, 0.9971, 0.1930, 2.712), (-0.6067, 0.9633, 0.1905, 2.778),
        (-0.6619, 0.9741, 0.1952, 2.845), (-0.6757, 0.9373, 0.1891, 2.912),
        (-0.6589, 0.8820, 0.1917, 2.980), (-0.5676, 0.8805, 0.1922, 3.046),
        // Return phase begins
        (-0.6673, 0.8237, 0.1851, 3.114), (-0.6013, 0.8268, 0.2057, 3.176),
        (-0.6573, 0.7133, 0.1912, 3.242), (-0.6596, 0.6657, 0.2165, 3.313),
        (-0.6358, 0.7210, 0.2099, 3.378), (-0.5829, 0.7072, 0.2229, 3.447),
        (-0.5775, 0.6228, 0.2277, 3.513), (-0.5990, 0.6688, 0.2269, 3.578),
        (-0.5668, 0.6688, 0.2268, 3.644), (-0.5377, 0.6750, 0.2292, 3.716),
        (-0.5377, 0.6673, 0.2339, 3.783), (-0.5346, 0.6443, 0.2334, 3.846),
        (-0.5545, 0.6182, 0.2276, 3.914), (-0.5147, 0.6228, 0.2399, 3.980),
        (-0.4548, 0.6151, 0.2256, 4.051), (-0.4364, 0.6090, 0.2354, 4.116),
        (-0.4180, 0.6228, 0.2351, 4.182), (-0.3804, 0.6289, 0.2349, 4.242),
        (-0.3659, 0.6381, 0.2393, 4.312), (-0.3528, 0.6504, 0.2370, 4.381),
        (-0.3497, 0.6489, 0.2360, 4.450), (-0.3283, 0.6550, 0.2337, 4.514),
        (-0.3106, 0.6581, 0.2313, 4.584), (-0.3229, 0.6443, 0.2327, 4.647),
        (-0.3099, 0.6535, 0.2350, 4.710), (-0.3206, 0.6581, 0.2407, 4.777),
        (-0.3175, 0.6561, 0.2407, 4.844), (-0.3221, 0.6673, 0.2378, 4.914),
        (-0.3359, 0.6611, 0.2351, 4.983), (-0.3390, 0.6611, 0.2379, 5.047),
        (-0.3505, 0.6642, 0.2317, 5.116), (-0.3766, 0.6366, 0.2344, 5.182),
        (-0.3613, 0.6289, 0.2285, 5.247), (-0.3689, 0.6581, 0.2367, 5.316),
        (-0.3743, 0.6688, 0.2356, 5.376), (-0.3797, 0.6627, 0.2417, 5.445),
        (-0.3651, 0.6627, 0.2345, 5.517), (-0.3567, 0.6688, 0.2310, 5.577),
        (-0.3643, 0.6642, 0.2389, 5.643), (-0.3889, 0.6688, 0.2370, 5.713),
        (-0.3889, 0.6596, 0.2348, 5.783), (-0.3935, 0.6627, 0.2343, 5.852),
        (-0.3973, 0.6627, 0.2345, 5.918), (-0.3766, 0.6581, 0.2371, 5.982),
        (-0.3766, 0.6550, 0.2376, 6.044), (-0.3919, 0.6596, 0.2394, 6.116),
        (-0.4019, 0.6642, 0.2308, 6.182), (-0.4027, 0.6688, 0.2289, 6.249),
        (-0.3981, 0.6688, 0.2218, 6.316), (-0.4103, 0.6734, 0.2385, 6.383),
        (-0.4019, 0.6719, 0.2270, 6.447), (-0.3981, 0.6796, 0.2248, 6.511),
        (-0.4218, 0.6811, 0.2160, 6.583), (-0.4165, 0.6765, 0.2273, 6.649),
        (-0.4226, 0.6826, 0.2371, 6.715), (-0.4287, 0.6811, 0.2317, 6.783),
        (-0.4226, 0.6842, 0.2330, 6.848), (-0.4249, 0.6811, 0.2343, 6.917),
        (-0.4119, 0.6811, 0.2371, 6.984), (-0.4165, 0.6857, 0.2383, 7.050),
        (-0.4180, 0.6826, 0.2270, 7.121), (-0.4165, 0.6857, 0.2415, 7.183),
        (-0.4249, 0.6888, 0.2370, 7.248), (-0.4318, 0.6888, 0.2228, 7.317),
        (-0.4203, 0.6888, 0.2272, 7.383), (-0.4418, 0.6918, 0.2367, 7.447),
        (-0.4203, 0.6642, 0.2388, 7.517),
        // Final return sweep
        (-0.4088, 0.6489, 0.2305, 7.588), (-0.3321, 0.5047, 0.2425, 7.649),
        (-0.3751, 0.4203, 0.2303, 7.717), (-0.3428, 0.2454, 0.2439, 7.785),
        (-0.3252, 0.0644, 0.2549, 7.851), (-0.2493, -0.0130, 0.2432, 7.922),
        (-0.2922, -0.0253, 0.2457, 7.986), (-0.3628, -0.0575, 0.2403, 8.052),
        (-0.3705, -0.1189, 0.2423, 8.118), (-0.3221, -0.1680, 0.2384, 8.180),
        (-0.3099, -0.2454, 0.2390, 8.249), (-0.3045, -0.2707, 0.2262, 8.316),
        (-0.2615, -0.2454, 0.2266, 8.383), (-0.3091, -0.2769, 0.2304, 8.449),
        (-0.2915, -0.2761, 0.2210, 8.518), (-0.2953, -0.2761, 0.2198, 8.585),
        (-0.2968, -0.2723, 0.2223, 8.649), (-0.2961, -0.2723, 0.2228, 8.714),
        (-0.2930, -0.2715, 0.2189, 8.785), (-0.2915, -0.2339, 0.2224, 8.850),
        (-0.2646, -0.2293, 0.2319, 8.918), (-0.2661, -0.2178, 0.2308, 8.984),
        (-0.2907, -0.1879, 0.2358, 9.049), (-0.2869, -0.1595, 0.2236, 9.122),
    ]

    func testExternalTurnRight1Triggers() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.externalTurnRight1)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
    }

    func testExternalTurnRight1HasReturn() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.externalTurnRight1)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
        assertContainsReturn(events)
    }

    func testExternalTurnLeft1Triggers() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.externalTurnLeft1)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
    }

    func testExternalTurnRight2Triggers() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.externalTurnRight2)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
    }

    func testExternalTurnRight2HasReturn() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.externalTurnRight2)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
        assertContainsReturn(events)
    }
}

// MARK: - Tests: Downward-Start Baseline (External Monitor)
// User looking downward when camera activates, then uses highlights to trigger.
// Baseline pitch is much higher (~-0.08 to -0.13) than typical (~-0.35 to -0.50).

final class HeadPoseEngineDownwardStartTests: XCTestCase {

    func makeExternalConfig() -> EngineConfig {
        var config = EngineConfig()
        config.thresholdMode = .manual(pitch: 0.1825, yaw: 0.3307)
        config.smoothingFactor = 0.5
        config.dwellTime = 0.2
        config.framesToSkip = 5
        return config
    }

    // Recording 124659: Present from downward start, 37 frames ~2.5s
    // Baseline pitch -0.13, drops to -0.54, returns to -0.10
    static let downwardPresent: [(Float, Float, Float, TimeInterval)] = [
        (-0.1342, 0.0491, 0.2514, 0.064), (-0.1335, 0.0476, 0.2457, 0.126),
        (-0.1358, 0.0460, 0.2395, 0.194), (-0.1381, 0.0476, 0.2433, 0.261),
        (-0.1319, 0.0430, 0.2395, 0.329), (-0.1158, 0.0399, 0.2381, 0.394),
        (-0.1235, 0.0046, 0.2456, 0.462), (-0.1680, 0.0337, 0.2442, 0.528),
        (-0.2470, 0.0813, 0.2352, 0.598), (-0.2853, 0.0721, 0.2404, 0.665),
        (-0.3758, 0.0614, 0.2469, 0.729), (-0.3797, 0.0813, 0.2406, 0.794),
        (-0.4801, 0.0614, 0.2333, 0.864), (-0.5070, 0.0460, 0.2356, 0.929),
        (-0.4970, 0.0153, 0.2249, 0.996), (-0.5123, 0.0107, 0.2311, 1.060),
        (-0.5208, 0.0368, 0.2302, 1.126), (-0.5200, 0.0276, 0.2231, 1.192),
        (-0.5277, 0.0199, 0.2262, 1.261), (-0.5254, 0.0215, 0.2254, 1.328),
        (-0.5262, 0.0307, 0.2259, 1.394), (-0.5361, 0.0199, 0.2237, 1.462),
        (-0.5208, 0.0184, 0.2119, 1.527), (-0.5315, 0.0123, 0.2214, 1.596),
        (-0.5246, 0.0276, 0.2323, 1.664), (-0.5100, 0.0291, 0.2324, 1.730),
        (-0.4932, 0.0598, 0.2221, 1.800), (-0.4794, 0.0476, 0.2270, 1.863),
        (-0.4564, 0.0215, 0.2355, 1.933), (-0.4548, 0.0153, 0.2390, 2.001),
        (-0.3758, 0.0322, 0.2398, 2.065), (-0.3474, 0.0276, 0.2462, 2.127),
        (-0.2577, 0.0491, 0.2454, 2.192), (-0.2385, 0.0537, 0.2423, 2.265),
        (-0.1733, 0.0291, 0.2444, 2.331), (-0.1289, 0.0399, 0.2344, 2.396),
        (-0.0974, 0.0506, 0.2443, 2.465),
    ]

    // Recording 124705: Returned (right turn) from downward start, 64 frames ~4.3s
    // Baseline yaw 0.04, swings to 0.77, returns
    static let downwardTurnRight: [(Float, Float, Float, TimeInterval)] = [
        (-0.0959, 0.0337, 0.2491, 0.063), (-0.0959, 0.0383, 0.2502, 0.136),
        (-0.0920, 0.0353, 0.2494, 0.203), (-0.1005, 0.0414, 0.2516, 0.272),
        (-0.1043, 0.0368, 0.2524, 0.337), (-0.0997, 0.0368, 0.2535, 0.404),
        (-0.0997, 0.0368, 0.2500, 0.471), (-0.1020, 0.0383, 0.2518, 0.543),
        (-0.1005, 0.0383, 0.2490, 0.604), (-0.1097, 0.0414, 0.2492, 0.673),
        (-0.1112, 0.0399, 0.2506, 0.745), (-0.1173, 0.0414, 0.2430, 0.805),
        (-0.1189, 0.0399, 0.2459, 0.872), (-0.1135, 0.0414, 0.2446, 0.939),
        (-0.1097, 0.0399, 0.2427, 1.003), (-0.1043, 0.0430, 0.2434, 1.074),
        (-0.1066, 0.0414, 0.2463, 1.134), (-0.1020, 0.0460, 0.2449, 1.200),
        (-0.0982, 0.0522, 0.2336, 1.271), (-0.1204, 0.1273, 0.2400, 1.342),
        (-0.0874, 0.1887, 0.2430, 1.408), (-0.0698, 0.2546, 0.2405, 1.473),
        (-0.0069, 0.3543, 0.2416, 1.539), (-0.0054, 0.4571, 0.2296, 1.606),
        (-0.1012, 0.5123, 0.2436, 1.670), (-0.1312, 0.5522, 0.2234, 1.740),
        (-0.0905, 0.6075, 0.2335, 1.805), (-0.1457, 0.5921, 0.2294, 1.872),
        (-0.1411, 0.6366, 0.2249, 1.940), (-0.2278, 0.6719, 0.2068, 2.005),
        (-0.2293, 0.6995, 0.2197, 2.073), (-0.2585, 0.7685, 0.2175, 2.140),
        (-0.3252, 0.7348, 0.2070, 2.201), (-0.3398, 0.7532, 0.2083, 2.267),
        (-0.3298, 0.7547, 0.2139, 2.337), (-0.3743, 0.7470, 0.2043, 2.404),
        (-0.3735, 0.7378, 0.2090, 2.474), (-0.3697, 0.7286, 0.2137, 2.540),
        (-0.3620, 0.7087, 0.2249, 2.604), (-0.3375, 0.7087, 0.2140, 2.669),
        (-0.3474, 0.6949, 0.2230, 2.737), (-0.3145, 0.6872, 0.2259, 2.803),
        (-0.3191, 0.6964, 0.2276, 2.871), (-0.3206, 0.7026, 0.2117, 2.942),
        (-0.3329, 0.7256, 0.2241, 3.007), (-0.3229, 0.7163, 0.2122, 3.072),
        (-0.3336, 0.7225, 0.2148, 3.139), (-0.3191, 0.7225, 0.2107, 3.204),
        (-0.3244, 0.7240, 0.2179, 3.271), (-0.3221, 0.7348, 0.2222, 3.337),
        (-0.3405, 0.7470, 0.2241, 3.410), (-0.3382, 0.7317, 0.2155, 3.470),
        (-0.2984, 0.6857, 0.2168, 3.540), (-0.3306, 0.6765, 0.2233, 3.606),
        (-0.2178, 0.6535, 0.1994, 3.675), (-0.2125, 0.6228, 0.2226, 3.737),
        (-0.1848, 0.5415, 0.2360, 3.807), (-0.1680, 0.4863, 0.2418, 3.874),
        (-0.1434, 0.4786, 0.2268, 3.939), (-0.1304, 0.3697, 0.2428, 4.006),
        (-0.1350, 0.3421, 0.2405, 4.073), (-0.0675, 0.2730, 0.2563, 4.138),
        (-0.0928, 0.2194, 0.2371, 4.206), (-0.0974, 0.1289, 0.2363, 4.272),
        (-0.0913, 0.1166, 0.2451, 4.339),
    ]

    // Recording 124711: Returned (left turn) from downward start, 56 frames ~3.9s
    // Baseline yaw 0.04, drops to -0.44, returns to 0.32
    static let downwardTurnLeft: [(Float, Float, Float, TimeInterval)] = [
        (-0.0775, 0.0414, 0.2539, 0.039), (-0.0744, 0.0491, 0.2490, 0.106),
        (-0.0759, 0.0430, 0.2478, 0.172), (-0.0844, 0.0414, 0.2375, 0.240),
        (-0.0928, 0.0399, 0.2457, 0.307), (-0.0890, 0.0414, 0.2382, 0.379),
        (-0.0859, 0.0307, 0.2417, 0.440), (-0.0821, 0.0077, 0.2418, 0.509),
        (-0.0905, 0.0092, 0.2396, 0.583), (-0.0215, -0.0537, 0.2424, 0.655),
        (-0.0813, -0.0660, 0.2471, 0.707), (-0.0430, -0.1028, 0.2422, 0.777),
        (-0.0383, -0.1825, 0.2399, 0.838), (-0.0913, -0.2301, 0.2394, 0.909),
        (-0.1066, -0.2692, 0.2395, 0.973), (-0.1220, -0.3191, 0.2236, 1.044),
        (-0.1810, -0.3390, 0.2249, 1.110), (-0.2171, -0.3651, 0.2232, 1.174),
        (-0.2148, -0.3858, 0.2291, 1.242), (-0.2339, -0.4195, 0.2316, 1.309),
        (-0.2309, -0.4349, 0.2300, 1.373), (-0.2186, -0.4395, 0.2272, 1.440),
        (-0.2270, -0.4303, 0.2225, 1.506), (-0.2309, -0.4372, 0.2243, 1.572),
        (-0.2439, -0.4387, 0.2258, 1.640), (-0.2431, -0.4357, 0.2334, 1.709),
        (-0.2470, -0.4372, 0.2290, 1.774), (-0.2539, -0.4395, 0.2359, 1.841),
        (-0.2562, -0.4303, 0.2305, 1.909), (-0.2523, -0.4142, 0.2290, 1.974),
        (-0.2546, -0.4080, 0.2282, 2.039), (-0.2600, -0.4088, 0.2261, 2.109),
        (-0.2485, -0.3904, 0.2302, 2.176), (-0.2485, -0.3467, 0.2261, 2.243),
        (-0.2017, -0.3206, 0.2241, 2.307), (-0.1887, -0.2086, 0.2308, 2.378),
        (-0.1480, -0.1296, 0.2336, 2.444), (-0.1672, -0.0245, 0.2367, 2.515),
        (-0.1749, 0.0245, 0.2452, 2.578), (-0.1542, 0.1718, 0.2415, 2.641),
        (-0.1887, 0.2255, 0.2401, 2.708), (-0.1396, 0.2961, 0.2493, 2.777),
        (-0.1273, 0.3191, 0.2515, 2.841), (-0.1427, 0.3712, 0.2576, 2.908),
        (-0.1081, 0.3835, 0.2511, 2.975), (-0.1327, 0.4249, 0.2330, 3.038),
        (-0.1519, 0.4172, 0.2448, 3.104), (-0.1902, 0.3574, 0.2384, 3.177),
        (-0.1756, 0.3912, 0.2442, 3.243), (-0.1818, 0.3697, 0.2355, 3.305),
        (-0.1948, 0.3620, 0.2440, 3.375), (-0.1963, 0.3329, 0.2414, 3.441),
        (-0.2109, 0.3344, 0.2328, 3.508), (-0.1856, 0.3528, 0.2376, 3.576),
        (-0.2071, 0.3421, 0.2311, 3.641), (-0.2079, 0.3329, 0.2305, 3.708),
        (-0.2025, 0.3237, 0.2440, 3.775), (-0.2071, 0.3129, 0.2429, 3.840),
        (-0.2056, 0.3160, 0.2468, 3.909),
    ]

    func testDownwardPresentTriggers() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.downwardPresent)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
    }

    func testDownwardPresentHasReturn() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.downwardPresent)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
        assertContainsReturn(events)
    }

    func testDownwardTurnRightTriggers() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.downwardTurnRight)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
    }

    func testDownwardTurnRightHasReturn() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.downwardTurnRight)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
        assertContainsReturn(events)
    }

    func testDownwardTurnLeftTriggers() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.downwardTurnLeft)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
    }

    func testDownwardTurnLeftHasReturn() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.downwardTurnLeft)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
        assertContainsReturn(events)
    }
}

// MARK: - Tests: Low Laptop Position (External Connected, Not Active)
// Laptop lower than usual, user looking further down. External monitor connected but inactive.
// Manual thresholds still apply (external display mode). Baseline pitch very high (~-0.08 to -0.10).

final class HeadPoseEngineLowLaptopTests: XCTestCase {

    func makeExternalConfig() -> EngineConfig {
        var config = EngineConfig()
        config.thresholdMode = .manual(pitch: 0.1825, yaw: 0.3307)
        config.smoothingFactor = 0.5
        config.dwellTime = 0.2
        config.framesToSkip = 5
        return config
    }

    // Recording 124904: Present from low laptop, 57 frames ~3.9s
    // Baseline pitch -0.09, drops to -0.43, returns to -0.07
    static let lowLaptopPresent: [(Float, Float, Float, TimeInterval)] = [
        (-0.0897, 0.0445, 0.2333, 0.005), (-0.0844, 0.0399, 0.2360, 0.074),
        (-0.0844, 0.0399, 0.2415, 0.137), (-0.0828, 0.0368, 0.2471, 0.207),
        (-0.0851, 0.0383, 0.2447, 0.270), (-0.0775, 0.0383, 0.2366, 0.337),
        (-0.0721, 0.0414, 0.2418, 0.404), (-0.0721, 0.0460, 0.2467, 0.469),
        (-0.0813, 0.0414, 0.2456, 0.538), (-0.0821, 0.0414, 0.2411, 0.602),
        (-0.1005, 0.0353, 0.2453, 0.670), (-0.1012, 0.0337, 0.2408, 0.738),
        (-0.0974, 0.0322, 0.2385, 0.802), (-0.0966, 0.0337, 0.2428, 0.865),
        (-0.0890, 0.0353, 0.2394, 0.933), (-0.0882, 0.0337, 0.2340, 1.004),
        (-0.0943, 0.0322, 0.2335, 1.072), (-0.0974, 0.0353, 0.2353, 1.138),
        (-0.0943, 0.0368, 0.2389, 1.206), (-0.0867, 0.0353, 0.2364, 1.272),
        (-0.0920, 0.0383, 0.2430, 1.338), (-0.0966, 0.0368, 0.2417, 1.406),
        (-0.0974, 0.0383, 0.2399, 1.477), (-0.1281, 0.0337, 0.2306, 1.539),
        (-0.1442, 0.0215, 0.2461, 1.606), (-0.2209, -0.0115, 0.2172, 1.675),
        (-0.2286, -0.0008, 0.2405, 1.737), (-0.2309, 0.0107, 0.2267, 1.807),
        (-0.2984, -0.0314, 0.2394, 1.875), (-0.3735, 0.0061, 0.2184, 1.935),
        (-0.3919, 0.0153, 0.2293, 2.003), (-0.3636, 0.0169, 0.2273, 2.070),
        (-0.4142, -0.0069, 0.2308, 2.137), (-0.4295, -0.0084, 0.2206, 2.205),
        (-0.4004, -0.0146, 0.2242, 2.270), (-0.4126, -0.0199, 0.2250, 2.337),
        (-0.4096, -0.0084, 0.2284, 2.404), (-0.4249, -0.0092, 0.2255, 2.469),
        (-0.4126, -0.0123, 0.2213, 2.538), (-0.4065, -0.0069, 0.2262, 2.605),
        (-0.4126, -0.0061, 0.2293, 2.674), (-0.4249, -0.0046, 0.2151, 2.740),
        (-0.4149, -0.0046, 0.2214, 2.805), (-0.4080, -0.0069, 0.2273, 2.872),
        // Return phase
        (-0.3705, 0.0061, 0.2339, 2.941), (-0.3582, 0.0169, 0.2367, 3.004),
        (-0.3735, 0.0153, 0.2321, 3.068), (-0.3168, 0.0138, 0.2366, 3.136),
        (-0.2355, 0.0598, 0.2296, 3.203), (-0.1879, 0.0828, 0.2259, 3.269),
        (-0.1526, 0.0568, 0.2362, 3.340), (-0.1565, 0.0445, 0.2329, 3.407),
        (-0.1595, 0.0644, 0.2364, 3.470), (-0.1404, 0.0905, 0.2469, 3.537),
        (-0.0974, 0.1012, 0.2446, 3.601), (-0.1104, 0.0736, 0.2287, 3.675),
        (-0.0844, 0.0782, 0.2404, 3.736), (-0.0782, 0.0721, 0.2271, 3.803),
        (-0.0721, 0.0752, 0.2367, 3.871),
    ]

    // Recording 124910: Returned (right turn) from low laptop, 33 frames ~2.2s
    // Baseline yaw 0.05, swings to 0.47
    static let lowLaptopTurnRight: [(Float, Float, Float, TimeInterval)] = [
        (-0.0966, 0.0506, 0.2498, 0.031), (-0.1035, 0.0568, 0.2372, 0.098),
        (-0.1020, 0.0614, 0.2400, 0.167), (-0.1028, 0.0614, 0.2452, 0.238),
        (-0.1104, 0.0629, 0.2367, 0.305), (-0.1097, 0.0629, 0.2423, 0.372),
        (-0.1028, 0.0598, 0.2456, 0.437), (-0.0828, 0.0660, 0.2411, 0.500),
        (-0.0775, 0.0966, 0.2423, 0.569), (-0.0759, 0.1350, 0.2457, 0.642),
        (-0.1220, 0.1994, 0.2380, 0.702), (-0.1166, 0.3252, 0.2393, 0.771),
        (-0.1051, 0.3513, 0.2360, 0.836), (-0.0913, 0.4433, 0.2369, 0.905),
        (-0.1028, 0.4955, 0.2254, 0.969), (-0.0721, 0.4556, 0.2281, 1.039),
        (-0.0736, 0.4556, 0.2228, 1.101), (-0.0798, 0.4617, 0.2306, 1.168),
        (-0.0897, 0.4541, 0.2355, 1.232), (-0.0890, 0.4556, 0.2324, 1.297),
        (-0.0936, 0.4510, 0.2339, 1.369), (-0.0936, 0.4541, 0.2291, 1.434),
        (-0.0890, 0.4617, 0.2292, 1.501), (-0.0974, 0.4587, 0.2364, 1.569),
        (-0.1066, 0.4587, 0.2171, 1.638), (-0.1020, 0.4648, 0.2243, 1.703),
        (-0.0867, 0.4571, 0.2278, 1.771), (-0.0913, 0.4418, 0.2402, 1.838),
        (-0.0982, 0.4587, 0.2322, 1.904), (-0.0874, 0.4587, 0.2298, 1.966),
        (-0.0629, 0.3774, 0.2342, 2.039), (-0.1005, 0.3129, 0.2368, 2.104),
        (-0.1465, 0.2715, 0.2441, 2.168),
    ]

    // Recording 124917: Returned (left turn) from low laptop, 32 frames ~2.1s
    // Baseline yaw 0.08, drops to -0.40, starts returning
    static let lowLaptopTurnLeft: [(Float, Float, Float, TimeInterval)] = [
        (-0.0936, 0.0782, 0.2451, 0.032), (-0.1028, 0.0782, 0.2389, 0.099),
        (-0.0805, 0.0752, 0.2357, 0.167), (-0.0775, 0.0721, 0.2475, 0.235),
        (-0.0614, 0.0598, 0.2370, 0.303), (-0.0844, 0.0215, 0.2376, 0.366),
        (-0.0629, 0.0138, 0.2272, 0.433), (-0.0430, -0.0345, 0.2382, 0.501),
        (-0.0376, -0.0997, 0.2355, 0.569), (-0.0445, -0.1511, 0.2389, 0.633),
        (-0.0437, -0.1848, 0.2382, 0.704), (-0.0176, -0.2608, 0.2386, 0.767),
        (-0.0330, -0.2938, 0.2325, 0.837), (-0.0391, -0.3590, 0.2339, 0.901),
        (-0.0545, -0.3904, 0.2378, 0.969), (-0.0736, -0.3843, 0.2405, 1.032),
        (-0.0713, -0.3889, 0.2422, 1.099), (-0.0721, -0.3965, 0.2396, 1.166),
        (-0.0759, -0.3904, 0.2370, 1.233), (-0.0759, -0.3942, 0.2372, 1.299),
        (-0.0736, -0.3912, 0.2417, 1.367), (-0.0736, -0.3981, 0.2373, 1.432),
        (-0.0644, -0.3873, 0.2393, 1.495), (-0.0522, -0.3919, 0.2379, 1.564),
        (-0.0552, -0.3873, 0.2328, 1.631), (-0.0522, -0.3935, 0.2382, 1.699),
        (-0.0453, -0.3850, 0.2387, 1.767), (-0.0606, -0.3804, 0.2406, 1.834),
        (-0.0468, -0.3689, 0.2326, 1.899), (-0.0345, -0.3574, 0.2306, 1.968),
        (-0.0353, -0.2876, 0.2287, 2.035), (-0.0399, -0.2447, 0.2298, 2.104),
    ]

    func testLowLaptopPresentTriggers() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.lowLaptopPresent)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
    }

    func testLowLaptopPresentHasReturn() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.lowLaptopPresent)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .tiltUp)
        assertContainsReturn(events)
    }

    func testLowLaptopTurnRightTriggers() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.lowLaptopTurnRight)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
    }

    func testLowLaptopTurnLeftTriggers() {
        let config = makeExternalConfig()
        var engine = HeadPoseEngine(config: config)
        let frames = makeFrames(Self.lowLaptopTurnLeft)
        let events = runEngine(&engine, frames: frames)
        assertContainsTrigger(events, pose: .turnLeftRight)
    }
}

// MARK: - Tests: Frame Skip & Reset

final class HeadPoseEngineResetTests: XCTestCase {

    func testFrameSkip() {
        var config = EngineConfig()
        config.thresholdMode = .manual(pitch: 0.16, yaw: 0.28)
        config.framesToSkip = 3
        config.smoothingFactor = 0.0
        var engine = HeadPoseEngine(config: config)

        // First 3 frames should be skipped
        for i in 0..<3 {
            let events = engine.feed(pitch: -0.25, yaw: 0.07, boundingBoxWidth: 0.18,
                                     at: TimeInterval(i) / 30.0)
            XCTAssertTrue(events.contains(where: {
                if case .skippingFrame = $0 { return true }
                return false
            }), "Frame \(i) should be skipped")
        }

        // Frame 4 should set baseline
        let events = engine.feed(pitch: -0.25, yaw: 0.07, boundingBoxWidth: 0.18, at: 0.1)
        XCTAssertTrue(events.contains(where: {
            if case .baselineSet = $0 { return true }
            return false
        }))
    }

    func testResetClearsState() {
        var config = EngineConfig()
        config.thresholdMode = .manual(pitch: 0.16, yaw: 0.28)
        config.framesToSkip = 0
        config.smoothingFactor = 0.0
        var engine = HeadPoseEngine(config: config)

        // Set baseline
        _ = engine.feed(pitch: -0.25, yaw: 0.07, boundingBoxWidth: 0.18, at: 0)
        XCTAssertNotNil(engine.baselinePitch)

        engine.reset()
        XCTAssertNil(engine.baselinePitch)
        XCTAssertNil(engine.baselineYaw)
    }
}
