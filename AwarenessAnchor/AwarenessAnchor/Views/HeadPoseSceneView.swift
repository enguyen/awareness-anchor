import SwiftUI
import SceneKit

/// A 3D SceneKit visualization of head pose with threshold frustum
struct HeadPoseSceneView: NSViewRepresentable {
    let pitchThreshold: Float
    let yawThreshold: Float
    let deltaPitch: Float
    let signedYawDelta: Float
    let dwellProgress: Float
    let isTestActive: Bool
    let faceDetected: Bool

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = context.coordinator.scene
        scnView.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.1, alpha: 1.0)
        scnView.antialiasingMode = .multisampling4X
        scnView.allowsCameraControl = false  // Don't allow user rotation
        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        context.coordinator.updateScene(
            pitchThreshold: pitchThreshold,
            yawThreshold: yawThreshold,
            deltaPitch: deltaPitch,
            signedYawDelta: signedYawDelta,
            dwellProgress: dwellProgress,
            isTestActive: isTestActive,
            faceDetected: faceDetected
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        let scene: SCNScene
        private var headNode: SCNNode!
        private var gazeVectorNode: SCNNode!
        private var frustumNode: SCNNode!

        // Materials for color changes
        private var gazeMaterial: SCNMaterial!
        private var topPlaneMaterial: SCNMaterial!
        private var sidePlaneMaterial: SCNMaterial!

        init() {
            scene = SCNScene()
            setupScene()
        }

        private func setupScene() {
            // Camera
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.usesOrthographicProjection = false
            cameraNode.camera?.fieldOfView = 45
            // Position camera at 3/4 oblique angle (looking down and to the side)
            cameraNode.position = SCNVector3(x: 2.5, y: 2.0, z: 4.0)
            cameraNode.look(at: SCNVector3(x: 0, y: 0.3, z: -1.5))
            scene.rootNode.addChildNode(cameraNode)

            // Ambient light
            let ambientLight = SCNNode()
            ambientLight.light = SCNLight()
            ambientLight.light?.type = .ambient
            ambientLight.light?.color = NSColor(white: 0.4, alpha: 1.0)
            scene.rootNode.addChildNode(ambientLight)

            // Directional light for depth
            let directionalLight = SCNNode()
            directionalLight.light = SCNLight()
            directionalLight.light?.type = .directional
            directionalLight.light?.color = NSColor(white: 0.6, alpha: 1.0)
            directionalLight.position = SCNVector3(x: 5, y: 5, z: 5)
            directionalLight.look(at: SCNVector3(x: 0, y: 0, z: 0))
            scene.rootNode.addChildNode(directionalLight)

            // Create head
            createHead()

            // Create frustum
            createFrustum()

            // Create gaze vector
            createGazeVector()
        }

        private func createHead() {
            // Ellipsoid head shape
            let sphere = SCNSphere(radius: 0.5)
            sphere.segmentCount = 48

            // X-ray blue translucent material
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.9, alpha: 0.4)
            material.emission.contents = NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.8, alpha: 0.3)
            material.transparent.contents = NSColor.white
            material.transparency = 0.6
            material.isDoubleSided = true
            material.blendMode = .add
            material.lightingModel = .physicallyBased
            sphere.materials = [material]

            headNode = SCNNode(geometry: sphere)
            // Narrower side-to-side (X), taller (Y), deeper front-to-back (Z)
            // This makes yaw rotation more visible
            headNode.scale = SCNVector3(0.75, 1.1, 1.0)
            headNode.position = SCNVector3(x: 0, y: 0, z: 0)
            scene.rootNode.addChildNode(headNode)

            // Add subtle facial features suggestion (nose ridge line)
            let noseLine = SCNCylinder(radius: 0.02, height: 0.3)
            let noseMaterial = SCNMaterial()
            noseMaterial.diffuse.contents = NSColor(calibratedRed: 0.3, green: 0.6, blue: 1.0, alpha: 0.3)
            noseMaterial.emission.contents = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.2)
            noseLine.materials = [noseMaterial]
            let noseNode = SCNNode(geometry: noseLine)
            noseNode.position = SCNVector3(x: 0, y: 0.05, z: 0.4)
            noseNode.eulerAngles.x = .pi / 2
            headNode.addChildNode(noseNode)
        }

        private func createFrustum() {
            frustumNode = SCNNode()
            frustumNode.position = SCNVector3(x: 0, y: 0.1, z: 0)
            scene.rootNode.addChildNode(frustumNode)

            // Create materials
            sidePlaneMaterial = SCNMaterial()
            sidePlaneMaterial.diffuse.contents = NSColor(calibratedRed: 0.8, green: 0.5, blue: 0.1, alpha: 0.35)
            sidePlaneMaterial.emission.contents = NSColor(calibratedRed: 0.6, green: 0.4, blue: 0.1, alpha: 0.1)
            sidePlaneMaterial.transparent.contents = NSColor.white
            sidePlaneMaterial.transparency = 0.65
            sidePlaneMaterial.isDoubleSided = true
            sidePlaneMaterial.lightingModel = .physicallyBased

            topPlaneMaterial = SCNMaterial()
            topPlaneMaterial.diffuse.contents = NSColor(calibratedRed: 0.2, green: 0.7, blue: 0.3, alpha: 0.4)
            topPlaneMaterial.emission.contents = NSColor(calibratedRed: 0.1, green: 0.5, blue: 0.2, alpha: 0.15)
            topPlaneMaterial.transparent.contents = NSColor.white
            topPlaneMaterial.transparency = 0.6
            topPlaneMaterial.isDoubleSided = true
            topPlaneMaterial.lightingModel = .physicallyBased

            // Initial frustum build
            rebuildFrustum(pitchThreshold: 0.12, yawThreshold: 0.20)
        }

        private func rebuildFrustum(pitchThreshold: Float, yawThreshold: Float) {
            // Remove old frustum children
            frustumNode.childNodes.forEach { $0.removeFromParentNode() }

            // Frustum dimensions based on thresholds
            let depth: Float = 3.5
            let nearSize: Float = 0.1
            let farWidth = Float(yawThreshold) * 8  // Scale for visual
            let farHeight = Float(pitchThreshold) * 6

            // Define vertices for the frustum (truncated pyramid)
            // Near face (at head)
            let n0 = SCNVector3(-nearSize, -nearSize * 0.5, 0)     // bottom-left
            let n1 = SCNVector3(nearSize, -nearSize * 0.5, 0)      // bottom-right
            let n2 = SCNVector3(nearSize, nearSize * 0.8, 0)       // top-right
            let n3 = SCNVector3(-nearSize, nearSize * 0.8, 0)      // top-left

            // Far face
            let f0 = SCNVector3(-farWidth, -farHeight * 0.3, -depth)   // bottom-left
            let f1 = SCNVector3(farWidth, -farHeight * 0.3, -depth)    // bottom-right
            let f2 = SCNVector3(farWidth, farHeight, -depth)           // top-right
            let f3 = SCNVector3(-farWidth, farHeight, -depth)          // top-left

            // Create planes for each face
            // Left face
            let leftPlane = createQuadGeometry(v0: n0, v1: n3, v2: f3, v3: f0)
            leftPlane.materials = [sidePlaneMaterial]
            let leftNode = SCNNode(geometry: leftPlane)
            frustumNode.addChildNode(leftNode)

            // Right face
            let rightPlane = createQuadGeometry(v0: n1, v1: f1, v2: f2, v3: n2)
            rightPlane.materials = [sidePlaneMaterial]
            let rightNode = SCNNode(geometry: rightPlane)
            frustumNode.addChildNode(rightNode)

            // Top face (pitch threshold)
            let topPlane = createQuadGeometry(v0: n3, v1: n2, v2: f2, v3: f3)
            topPlane.materials = [topPlaneMaterial]
            let topNode = SCNNode(geometry: topPlane)
            frustumNode.addChildNode(topNode)

            // Bottom face
            let bottomPlane = createQuadGeometry(v0: n0, v1: f0, v2: f1, v3: n1)
            bottomPlane.materials = [sidePlaneMaterial]
            let bottomNode = SCNNode(geometry: bottomPlane)
            frustumNode.addChildNode(bottomNode)

            // Far face (optional, for visual closure)
            let farPlane = createQuadGeometry(v0: f0, v1: f3, v2: f2, v3: f1)
            let farMaterial = SCNMaterial()
            farMaterial.diffuse.contents = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.4, alpha: 0.15)
            farMaterial.isDoubleSided = true
            farPlane.materials = [farMaterial]
            let farNode = SCNNode(geometry: farPlane)
            frustumNode.addChildNode(farNode)

            // Add edge lines for better visibility
            addEdgeLines(n0: n0, n1: n1, n2: n2, n3: n3, f0: f0, f1: f1, f2: f2, f3: f3)
        }

        private func createQuadGeometry(v0: SCNVector3, v1: SCNVector3, v2: SCNVector3, v3: SCNVector3) -> SCNGeometry {
            let vertices: [SCNVector3] = [v0, v1, v2, v3]
            let indices: [Int32] = [0, 1, 2, 0, 2, 3]

            let vertexSource = SCNGeometrySource(vertices: vertices)
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

            return SCNGeometry(sources: [vertexSource], elements: [element])
        }

        private func addEdgeLines(n0: SCNVector3, n1: SCNVector3, n2: SCNVector3, n3: SCNVector3,
                                  f0: SCNVector3, f1: SCNVector3, f2: SCNVector3, f3: SCNVector3) {
            let edgeColor = NSColor(calibratedRed: 0.9, green: 0.6, blue: 0.2, alpha: 0.8)
            let topEdgeColor = NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 0.8)

            // Side edges
            addLine(from: n0, to: f0, color: edgeColor)
            addLine(from: n1, to: f1, color: edgeColor)
            addLine(from: n2, to: f2, color: topEdgeColor)
            addLine(from: n3, to: f3, color: topEdgeColor)

            // Near face edges
            addLine(from: n0, to: n1, color: edgeColor)
            addLine(from: n2, to: n3, color: topEdgeColor)

            // Far face edges
            addLine(from: f0, to: f1, color: edgeColor)
            addLine(from: f2, to: f3, color: topEdgeColor)
            addLine(from: f0, to: f3, color: edgeColor)
            addLine(from: f1, to: f2, color: edgeColor)
        }

        private func addLine(from: SCNVector3, to: SCNVector3, color: NSColor) {
            let vertices: [SCNVector3] = [from, to]
            let indices: [Int32] = [0, 1]

            let vertexSource = SCNGeometrySource(vertices: vertices)
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)

            let lineGeometry = SCNGeometry(sources: [vertexSource], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.emission.contents = color
            lineGeometry.materials = [material]

            let lineNode = SCNNode(geometry: lineGeometry)
            frustumNode.addChildNode(lineNode)
        }

        private func createGazeVector() {
            gazeVectorNode = SCNNode()
            gazeVectorNode.position = SCNVector3(x: 0, y: 0.15, z: 0.3)
            scene.rootNode.addChildNode(gazeVectorNode)

            // Shaft (cylinder)
            let shaft = SCNCylinder(radius: 0.04, height: 2.5)
            gazeMaterial = SCNMaterial()
            gazeMaterial.diffuse.contents = NSColor(calibratedRed: 0.2, green: 0.6, blue: 1.0, alpha: 0.9)
            gazeMaterial.emission.contents = NSColor(calibratedRed: 0.1, green: 0.4, blue: 0.8, alpha: 0.5)
            gazeMaterial.lightingModel = .physicallyBased
            shaft.materials = [gazeMaterial]

            let shaftNode = SCNNode(geometry: shaft)
            shaftNode.position = SCNVector3(x: 0, y: 0, z: -1.25)  // Center along length
            shaftNode.eulerAngles.x = .pi / 2  // Point forward (along -Z)
            gazeVectorNode.addChildNode(shaftNode)

            // Arrowhead (cone)
            let arrowhead = SCNCone(topRadius: 0, bottomRadius: 0.1, height: 0.25)
            arrowhead.materials = [gazeMaterial]
            let arrowNode = SCNNode(geometry: arrowhead)
            arrowNode.position = SCNVector3(x: 0, y: 0, z: -2.6)
            arrowNode.eulerAngles.x = -.pi / 2  // Point forward
            gazeVectorNode.addChildNode(arrowNode)

            // Initially hide gaze vector until test starts
            gazeVectorNode.isHidden = true
        }

        func updateScene(pitchThreshold: Float, yawThreshold: Float,
                         deltaPitch: Float, signedYawDelta: Float,
                         dwellProgress: Float, isTestActive: Bool, faceDetected: Bool) {

            // Rebuild frustum if thresholds changed significantly
            rebuildFrustum(pitchThreshold: pitchThreshold, yawThreshold: yawThreshold)

            // Update head visibility/color based on face detection
            if let headGeometry = headNode.geometry as? SCNSphere,
               let material = headGeometry.materials.first {
                if faceDetected {
                    material.diffuse.contents = NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.9, alpha: 0.4)
                    material.emission.contents = NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.8, alpha: 0.3)
                } else {
                    material.diffuse.contents = NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.4, alpha: 0.3)
                    material.emission.contents = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 0.1)
                }
            }

            // Show/hide gaze vector based on test state
            gazeVectorNode.isHidden = !isTestActive

            if !isTestActive {
                // Reset head to neutral when test is not active
                headNode.eulerAngles = SCNVector3(x: 0, y: 0, z: 0)
            }

            if isTestActive {
                // Update head and gaze vector rotation based on deltas
                // Pitch rotates around X axis (negative pitch = look up = positive rotation)
                // Yaw rotates around Y axis (positive = turn right, vector points right)
                let pitchAngle = CGFloat(-deltaPitch) * 2.0  // Scale for visual effect
                let yawAngle = CGFloat(signedYawDelta) * 2.0  // No negation - natural direction

                // Rotate the head with the pose
                headNode.eulerAngles = SCNVector3(
                    x: pitchAngle * 0.8,  // Slightly less rotation for head than vector
                    y: yawAngle * 0.8,
                    z: 0
                )

                gazeVectorNode.eulerAngles = SCNVector3(
                    x: pitchAngle,
                    y: yawAngle,
                    z: 0
                )

                // Update gaze vector color based on threshold state
                let absYaw = abs(signedYawDelta)
                let pitchExceeded = deltaPitch < -pitchThreshold
                let yawExceeded = absYaw > yawThreshold

                let baseAlpha: CGFloat = dwellProgress > 0 ? 1.0 : 0.9
                let emissionAlpha: CGFloat = 0.3 + CGFloat(dwellProgress) * 0.4

                if yawExceeded {
                    // Orange for turn
                    gazeMaterial.diffuse.contents = NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.2, alpha: baseAlpha)
                    gazeMaterial.emission.contents = NSColor(calibratedRed: 0.8, green: 0.4, blue: 0.1, alpha: emissionAlpha)
                } else if pitchExceeded {
                    // Green for tilt up
                    gazeMaterial.diffuse.contents = NSColor(calibratedRed: 0.3, green: 0.9, blue: 0.4, alpha: baseAlpha)
                    gazeMaterial.emission.contents = NSColor(calibratedRed: 0.2, green: 0.7, blue: 0.3, alpha: emissionAlpha)
                } else {
                    // Blue for normal
                    gazeMaterial.diffuse.contents = NSColor(calibratedRed: 0.2, green: 0.6, blue: 1.0, alpha: 0.9)
                    gazeMaterial.emission.contents = NSColor(calibratedRed: 0.1, green: 0.4, blue: 0.8, alpha: 0.3)
                }
            }
        }
    }
}

#Preview {
    HeadPoseSceneView(
        pitchThreshold: 0.12,
        yawThreshold: 0.20,
        deltaPitch: -0.05,
        signedYawDelta: 0.1,
        dwellProgress: 0.3,
        isTestActive: true,
        faceDetected: true
    )
    .frame(width: 300, height: 300)
}
