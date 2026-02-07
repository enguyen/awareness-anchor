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
    let isInCooldown: Bool
    let topIntensity: Float
    let leftIntensity: Float
    let rightIntensity: Float
    let activeSource: String       // "headPose", "mouse", "none"
    let normalizedMouseX: Float    // 0 = left, 1 = right
    let normalizedMouseY: Float    // 0 = bottom, 1 = top

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = context.coordinator.scene
        scnView.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.1, alpha: 1.0)
        scnView.antialiasingMode = .multisampling4X
        scnView.allowsCameraControl = false
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
            faceDetected: faceDetected,
            isInCooldown: isInCooldown,
            topIntensity: topIntensity,
            leftIntensity: leftIntensity,
            rightIntensity: rightIntensity,
            activeSource: activeSource,
            normalizedMouseX: normalizedMouseX,
            normalizedMouseY: normalizedMouseY
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
        private var reticleNode: SCNNode!

        // Materials for color changes
        private var gazeMaterial: SCNMaterial!
        private var leftFaceMaterial: SCNMaterial!
        private var rightFaceMaterial: SCNMaterial!
        private var topFaceMaterial: SCNMaterial!
        private var bottomFaceMaterial: SCNMaterial!
        private var reticleMaterial: SCNMaterial!
        private var reticleDotMaterial: SCNMaterial!
        private var mousePointerNode: SCNNode!
        private var mousePointerMaterial: SCNMaterial!

        // Cached frustum dimensions for reticle math
        private var cachedFarWidth: Float = 1.6
        private var cachedFarHeight: Float = 0.72
        private let frustumDepth: Float = 3.5
        private let frustumOffsetY: Float = 0.1

        // Gaze vector origin (matches createGazeVector position)
        private let gazeOriginX: Float = 0
        private let gazeOriginY: Float = 0.15
        private let gazeOriginZ: Float = 0.3

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

            createHead()
            createFrustumMaterials()
            createFrustum()
            createGazeVector()
            createReticle()
            createMousePointer()
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

        private func createFrustumMaterials() {
            // Per-face materials so each side can have independent opacity.
            // Use .constant lighting for reliable transparency on custom geometry.
            let sideColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.8, 0.5, 0.1)
            let topColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.2, 0.7, 0.3)

            leftFaceMaterial = makeFaceMaterial(color: sideColor)
            rightFaceMaterial = makeFaceMaterial(color: sideColor)
            bottomFaceMaterial = makeFaceMaterial(color: sideColor)
            topFaceMaterial = makeFaceMaterial(color: topColor)
        }

        private func makeFaceMaterial(color: (r: CGFloat, g: CGFloat, b: CGFloat)) -> SCNMaterial {
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(calibratedRed: color.r, green: color.g, blue: color.b, alpha: 0.08)
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            mat.blendMode = .alpha
            mat.writesToDepthBuffer = false
            return mat
        }

        private func updateFaceMaterialIntensity(_ material: SCNMaterial, intensity: Float,
                                                  color: (r: CGFloat, g: CGFloat, b: CGFloat)) {
            let t = CGFloat(min(max(intensity, 0), 1))
            // 0.08 at rest, up to 0.48 at full intensity
            let alpha = 0.08 + t * 0.40
            material.diffuse.contents = NSColor(calibratedRed: color.r, green: color.g, blue: color.b, alpha: alpha)
        }

        private func createFrustum() {
            frustumNode = SCNNode()
            frustumNode.position = SCNVector3(x: 0, y: CGFloat(frustumOffsetY), z: 0)
            scene.rootNode.addChildNode(frustumNode)

            rebuildFrustum(pitchThreshold: 0.12, yawThreshold: 0.20)
        }

        private func rebuildFrustum(pitchThreshold: Float, yawThreshold: Float) {
            frustumNode.childNodes.forEach { $0.removeFromParentNode() }

            let nearSize: Float = 0.1
            let farWidth = yawThreshold * 8
            let farHeight = pitchThreshold * 6

            // Cache for reticle positioning
            cachedFarWidth = farWidth
            cachedFarHeight = farHeight

            // Near face (at head)
            let n0 = SCNVector3(-nearSize, -nearSize * 0.5, 0)     // bottom-left
            let n1 = SCNVector3(nearSize, -nearSize * 0.5, 0)      // bottom-right
            let n2 = SCNVector3(nearSize, nearSize * 0.8, 0)       // top-right
            let n3 = SCNVector3(-nearSize, nearSize * 0.8, 0)      // top-left

            // Far face
            let depth = frustumDepth
            let f0 = SCNVector3(-farWidth, -farHeight * 0.3, -depth)   // bottom-left
            let f1 = SCNVector3(farWidth, -farHeight * 0.3, -depth)    // bottom-right
            let f2 = SCNVector3(farWidth, farHeight, -depth)           // top-right
            let f3 = SCNVector3(-farWidth, farHeight, -depth)          // top-left

            // Left face
            let leftPlane = createQuadGeometry(v0: n0, v1: n3, v2: f3, v3: f0)
            leftPlane.materials = [leftFaceMaterial]
            frustumNode.addChildNode(SCNNode(geometry: leftPlane))

            // Right face
            let rightPlane = createQuadGeometry(v0: n1, v1: f1, v2: f2, v3: n2)
            rightPlane.materials = [rightFaceMaterial]
            frustumNode.addChildNode(SCNNode(geometry: rightPlane))

            // Top face (pitch threshold)
            let topPlane = createQuadGeometry(v0: n3, v1: n2, v2: f2, v3: f3)
            topPlane.materials = [topFaceMaterial]
            frustumNode.addChildNode(SCNNode(geometry: topPlane))

            // Bottom face
            let bottomPlane = createQuadGeometry(v0: n0, v1: f0, v2: f1, v3: n1)
            bottomPlane.materials = [bottomFaceMaterial]
            frustumNode.addChildNode(SCNNode(geometry: bottomPlane))

            // Far face (projection plane, subtle)
            let farPlane = createQuadGeometry(v0: f0, v1: f3, v2: f2, v3: f1)
            let farMaterial = SCNMaterial()
            farMaterial.diffuse.contents = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.4, alpha: 0.08)
            farMaterial.lightingModel = .constant
            farMaterial.isDoubleSided = true
            farMaterial.blendMode = .alpha
            farMaterial.writesToDepthBuffer = false
            farPlane.materials = [farMaterial]
            frustumNode.addChildNode(SCNNode(geometry: farPlane))

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

        private func createReticle() {
            // Ring reticle on the far face projection plane
            let ring = SCNTorus(ringRadius: 0.1, pipeRadius: 0.012)
            reticleMaterial = SCNMaterial()
            reticleMaterial.diffuse.contents = NSColor.white
            reticleMaterial.emission.contents = NSColor(calibratedRed: 0.7, green: 0.85, blue: 1.0, alpha: 1.0)
            reticleMaterial.lightingModel = .constant
            ring.materials = [reticleMaterial]

            reticleNode = SCNNode(geometry: ring)
            reticleNode.eulerAngles.x = .pi / 2  // Lay flat on the projection plane
            reticleNode.isHidden = true

            // Center dot
            let dot = SCNSphere(radius: 0.025)
            reticleDotMaterial = SCNMaterial()
            reticleDotMaterial.diffuse.contents = NSColor.white
            reticleDotMaterial.emission.contents = NSColor(calibratedRed: 0.7, green: 0.85, blue: 1.0, alpha: 1.0)
            reticleDotMaterial.lightingModel = .constant
            dot.materials = [reticleDotMaterial]
            let dotNode = SCNNode(geometry: dot)
            reticleNode.addChildNode(dotNode)

            scene.rootNode.addChildNode(reticleNode)
        }

        private func createMousePointer() {
            // Classic cursor arrow shape using NSBezierPath + SCNShape.
            // Tip at origin, body extends down and to the right.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: 0))               // tip (hotspot)
            path.line(to: NSPoint(x: 0, y: -0.28))           // bottom of left edge
            path.line(to: NSPoint(x: 0.09, y: -0.19))        // notch
            path.line(to: NSPoint(x: 0.20, y: -0.30))        // tail end
            path.line(to: NSPoint(x: 0.12, y: -0.15))        // above notch
            path.close()

            let shape = SCNShape(path: path, extrusionDepth: 0.015)
            mousePointerMaterial = SCNMaterial()
            mousePointerMaterial.diffuse.contents = NSColor.white
            mousePointerMaterial.emission.contents = NSColor(calibratedRed: 0.7, green: 0.85, blue: 1.0, alpha: 1.0)
            mousePointerMaterial.lightingModel = .constant
            shape.materials = [mousePointerMaterial]

            mousePointerNode = SCNNode(geometry: shape)
            mousePointerNode.isHidden = true
            scene.rootNode.addChildNode(mousePointerNode)
        }

        private func createGazeVector() {
            gazeVectorNode = SCNNode()
            gazeVectorNode.position = SCNVector3(x: CGFloat(gazeOriginX), y: CGFloat(gazeOriginY), z: CGFloat(gazeOriginZ))
            scene.rootNode.addChildNode(gazeVectorNode)

            // Shaft (cylinder)
            let shaft = SCNCylinder(radius: 0.04, height: 2.5)
            gazeMaterial = SCNMaterial()
            gazeMaterial.diffuse.contents = NSColor(calibratedRed: 0.2, green: 0.6, blue: 1.0, alpha: 0.9)
            gazeMaterial.emission.contents = NSColor(calibratedRed: 0.1, green: 0.4, blue: 0.8, alpha: 0.5)
            gazeMaterial.lightingModel = .physicallyBased
            shaft.materials = [gazeMaterial]

            let shaftNode = SCNNode(geometry: shaft)
            shaftNode.position = SCNVector3(x: 0, y: 0, z: -1.25)
            shaftNode.eulerAngles.x = .pi / 2  // Point forward (along -Z)
            gazeVectorNode.addChildNode(shaftNode)

            // Arrowhead (cone)
            let arrowhead = SCNCone(topRadius: 0, bottomRadius: 0.1, height: 0.25)
            arrowhead.materials = [gazeMaterial]
            let arrowNode = SCNNode(geometry: arrowhead)
            arrowNode.position = SCNVector3(x: 0, y: 0, z: -2.6)
            arrowNode.eulerAngles.x = -.pi / 2
            gazeVectorNode.addChildNode(arrowNode)

            gazeVectorNode.isHidden = true
        }

        func updateScene(pitchThreshold: Float, yawThreshold: Float,
                         deltaPitch: Float, signedYawDelta: Float,
                         dwellProgress: Float, isTestActive: Bool, faceDetected: Bool,
                         isInCooldown: Bool,
                         topIntensity: Float, leftIntensity: Float, rightIntensity: Float,
                         activeSource: String, normalizedMouseX: Float, normalizedMouseY: Float) {

            rebuildFrustum(pitchThreshold: pitchThreshold, yawThreshold: yawThreshold)

            // Update frustum face opacities based on intensities
            let sideColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.8, 0.5, 0.1)
            let topColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.2, 0.7, 0.3)

            updateFaceMaterialIntensity(leftFaceMaterial, intensity: leftIntensity, color: sideColor)
            updateFaceMaterialIntensity(rightFaceMaterial, intensity: rightIntensity, color: sideColor)
            updateFaceMaterialIntensity(topFaceMaterial, intensity: topIntensity, color: topColor)
            updateFaceMaterialIntensity(bottomFaceMaterial, intensity: 0, color: sideColor)

            // Update head visibility/color based on face detection and cooldown state
            let showGrayState = !faceDetected || isInCooldown
            if let headGeometry = headNode.geometry as? SCNSphere,
               let material = headGeometry.materials.first {
                if showGrayState {
                    material.diffuse.contents = NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.4, alpha: 0.3)
                    material.emission.contents = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 0.1)
                } else {
                    material.diffuse.contents = NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.9, alpha: 0.4)
                    material.emission.contents = NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.8, alpha: 0.3)
                }
            }

            // Show/hide gaze vector based on test state
            gazeVectorNode.isHidden = !isTestActive

            if !isTestActive {
                headNode.eulerAngles = SCNVector3(x: 0, y: 0, z: 0)
                reticleNode.isHidden = true
                mousePointerNode.isHidden = true
            }

            if isTestActive {
                // Update head and gaze vector rotation based on deltas
                let pitchAngle = CGFloat(-deltaPitch) * 2.0
                let yawAngle = CGFloat(signedYawDelta) * 2.0

                headNode.eulerAngles = SCNVector3(
                    x: pitchAngle * 0.8,
                    y: yawAngle * 0.8,
                    z: 0
                )

                gazeVectorNode.eulerAngles = SCNVector3(
                    x: pitchAngle,
                    y: yawAngle,
                    z: 0
                )

                // Update reticle — follows primary input source
                updateReticle(
                    deltaPitch: deltaPitch,
                    signedYawDelta: signedYawDelta,
                    faceDetected: faceDetected,
                    isInCooldown: isInCooldown,
                    activeSource: activeSource,
                    normalizedMouseX: normalizedMouseX,
                    normalizedMouseY: normalizedMouseY
                )

                // Update gaze vector color based on threshold state
                let absYaw = abs(signedYawDelta)
                let pitchExceeded = deltaPitch < -pitchThreshold
                let yawExceeded = absYaw > yawThreshold

                let baseAlpha: CGFloat = dwellProgress > 0 ? 1.0 : 0.9
                let emissionAlpha: CGFloat = 0.3 + CGFloat(dwellProgress) * 0.4

                if yawExceeded {
                    gazeMaterial.diffuse.contents = NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.2, alpha: baseAlpha)
                    gazeMaterial.emission.contents = NSColor(calibratedRed: 0.8, green: 0.4, blue: 0.1, alpha: emissionAlpha)
                } else if pitchExceeded {
                    gazeMaterial.diffuse.contents = NSColor(calibratedRed: 0.3, green: 0.9, blue: 0.4, alpha: baseAlpha)
                    gazeMaterial.emission.contents = NSColor(calibratedRed: 0.2, green: 0.7, blue: 0.3, alpha: emissionAlpha)
                } else {
                    gazeMaterial.diffuse.contents = NSColor(calibratedRed: 0.2, green: 0.6, blue: 1.0, alpha: 0.9)
                    gazeMaterial.emission.contents = NSColor(calibratedRed: 0.1, green: 0.4, blue: 0.8, alpha: 0.3)
                }
            }
        }

        private func updateReticle(deltaPitch: Float, signedYawDelta: Float,
                                    faceDetected: Bool, isInCooldown: Bool,
                                    activeSource: String,
                                    normalizedMouseX: Float, normalizedMouseY: Float) {
            guard !isInCooldown else {
                reticleNode.isHidden = true
                mousePointerNode.isHidden = true
                return
            }

            var posX: Float
            var posY: Float
            let isMouse = activeSource == "mouse"

            if isMouse {
                // Map mouse normalized coords (0-1) to far face rectangle in world space.
                posX = -cachedFarWidth + 2.0 * cachedFarWidth * normalizedMouseX
                let farMinY = frustumOffsetY - cachedFarHeight * 0.3
                let farMaxY = frustumOffsetY + cachedFarHeight
                posY = farMinY + (farMaxY - farMinY) * normalizedMouseY

            } else if activeSource == "headPose" && faceDetected {
                // Project gaze vector onto the far face plane using actual euler angle math.
                let pitchAngle = -deltaPitch * 2.0
                let yawAngle = signedYawDelta * 2.0

                // Direction of the -Z axis after rotation (Ry * Rx applied to (0,0,-1)):
                let dx = -sin(yawAngle) * cos(pitchAngle)
                let dy = sin(pitchAngle)
                let dz = -cos(yawAngle) * cos(pitchAngle)

                guard dz != 0 else {
                    reticleNode.isHidden = true
                    mousePointerNode.isHidden = true
                    return
                }

                let t = (-frustumDepth - gazeOriginZ) / dz
                posX = gazeOriginX + t * dx
                posY = gazeOriginY + t * dy

            } else {
                reticleNode.isHidden = true
                mousePointerNode.isHidden = true
                return
            }

            let position = SCNVector3(
                x: CGFloat(posX),
                y: CGFloat(posY),
                z: CGFloat(-frustumDepth)
            )

            // Show cursor for mouse, reticle ring for head pose
            reticleNode.isHidden = isMouse
            mousePointerNode.isHidden = !isMouse

            if isMouse {
                mousePointerNode.position = position
            } else {
                reticleNode.position = position
            }

            // Color: white inside frustum, orange outside
            let farMinX = -cachedFarWidth
            let farMaxX = cachedFarWidth
            let farMinY = frustumOffsetY - cachedFarHeight * 0.3
            let farMaxY = frustumOffsetY + cachedFarHeight
            let outside = posX < farMinX || posX > farMaxX ||
                          posY < farMinY || posY > farMaxY

            let color: NSColor = outside
                ? NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.3, alpha: 1.0)
                : NSColor(calibratedRed: 0.7, green: 0.85, blue: 1.0, alpha: 1.0)

            if isMouse {
                mousePointerMaterial.emission.contents = color
            } else {
                reticleMaterial.emission.contents = color
                reticleDotMaterial.emission.contents = color
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
        faceDetected: true,
        isInCooldown: false,
        topIntensity: 0.3,
        leftIntensity: 0,
        rightIntensity: 0.7,
        activeSource: "headPose",
        normalizedMouseX: 0.5,
        normalizedMouseY: 0.5
    )
    .frame(width: 300, height: 300)
}
