import Foundation
import Vision
import AVFoundation

enum HeadPose {
    case neutral
    case tiltUp      // Pitch > threshold -> "Already present"
    case turnLeftRight  // Yaw > threshold -> "Returned to awareness"
}

class HeadPoseDetector: NSObject, ObservableObject {
    var onPoseDetected: ((HeadPose) -> Void)?

    // Debug: publish current values for UI display
    @Published var debugPitch: Float = 0
    @Published var debugYaw: Float = 0
    @Published var debugBaseline: String = "No baseline"
    @Published var faceDetected: Bool = false

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let processingQueue = DispatchQueue(label: "com.awarenessanchor.headpose")

    private var isActive = false
    private var isWindowActive = false

    // Thresholds in radians
    private let pitchThreshold: Float = 0.26  // ~15 degrees up
    private let yawThreshold: Float = 0.35    // ~20 degrees left/right

    // Track baseline pose
    private var baselinePitch: Float?
    private var baselineYaw: Float?
    private var hasRespondedThisWindow = false

    func startDetection() {
        guard captureSession == nil else { return }

        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .low  // Use low resolution for efficiency

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession?.canAddInput(input) == true else {
            print("Failed to access front camera")
            return
        }

        captureSession?.addInput(input)

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput?.alwaysDiscardsLateVideoFrames = true

        if let output = videoOutput, captureSession?.canAddOutput(output) == true {
            captureSession?.addOutput(output)
        }

        isActive = true
        // Don't start capture session until response window opens
    }

    func stopDetection() {
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
        isActive = false
        isWindowActive = false
    }

    func activateForWindow() {
        guard isActive else {
            print("[HeadPose] activateForWindow called but detector not active")
            return
        }

        print("[HeadPose] Window activated, starting camera...")
        isWindowActive = true
        hasRespondedThisWindow = false
        baselinePitch = nil
        baselineYaw = nil

        DispatchQueue.main.async {
            self.debugBaseline = "Calibrating..."
            self.faceDetected = false
        }

        // Start camera
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
            print("[HeadPose] Camera started")
        }
    }

    func deactivateWindow() {
        isWindowActive = false

        // Stop camera to save resources
        captureSession?.stopRunning()
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isWindowActive, !hasRespondedThisWindow else { return }

        // Use face rectangles request which provides pitch, yaw, roll
        let faceRequest = VNDetectFaceRectanglesRequest { [weak self] request, error in
            guard let self = self else { return }

            if let error = error {
                print("[HeadPose] Vision error: \(error)")
                return
            }

            guard let results = request.results as? [VNFaceObservation],
                  let face = results.first else {
                DispatchQueue.main.async {
                    self.faceDetected = false
                }
                return
            }

            self.analyzeFacePose(face, in: pixelBuffer)
        }

        // Use revision 3 which supports pitch/yaw/roll
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([faceRequest])
    }

    private func analyzeFacePose(_ face: VNFaceObservation, in buffer: CVPixelBuffer) {
        // VNFaceObservation provides pitch, yaw, roll as optional properties
        // Debug: print what we got
        print("[HeadPose] Face found - pitch: \(String(describing: face.pitch)), yaw: \(String(describing: face.yaw)), roll: \(String(describing: face.roll))")

        guard let pitch = face.pitch?.floatValue,
              let yaw = face.yaw?.floatValue else {
            DispatchQueue.main.async {
                self.faceDetected = true  // Face IS detected, just no pose data
                self.debugBaseline = "Face found, no pose data"
            }
            print("[HeadPose] No pitch/yaw data available (face detected but pose nil)")
            return
        }

        // Establish baseline on first reading
        if baselinePitch == nil {
            baselinePitch = pitch
            baselineYaw = yaw
            print("[HeadPose] Baseline set: pitch=\(pitch), yaw=\(yaw)")
            DispatchQueue.main.async {
                self.debugBaseline = String(format: "Baseline: P=%.2f, Y=%.2f", pitch, yaw)
            }
            return
        }

        let pitchDelta = pitch - (baselinePitch ?? 0)
        let yawDelta = abs(yaw - (baselineYaw ?? 0))

        // Update debug values on main thread
        DispatchQueue.main.async {
            self.faceDetected = true
            self.debugPitch = pitchDelta
            self.debugYaw = yawDelta
        }

        print("[HeadPose] Delta: pitch=\(pitchDelta) (need < -\(pitchThreshold) for up), yaw=\(yawDelta) (need >\(yawThreshold))")

        // Check for significant head movement
        // Note: Looking UP makes pitch more NEGATIVE in Vision's coordinate system
        if pitchDelta < -pitchThreshold {
            // Head tilted up -> "Already present"
            print("[HeadPose] TRIGGERED: Tilt Up (Present)")
            hasRespondedThisWindow = true
            DispatchQueue.main.async {
                self.onPoseDetected?(.tiltUp)
            }
        } else if yawDelta > yawThreshold {
            // Head turned left or right -> "Returned to awareness"
            print("[HeadPose] TRIGGERED: Turn Left/Right (Returned)")
            hasRespondedThisWindow = true
            DispatchQueue.main.async {
                self.onPoseDetected?(.turnLeftRight)
            }
        }
    }
}

extension HeadPoseDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processFrame(pixelBuffer)
    }
}
