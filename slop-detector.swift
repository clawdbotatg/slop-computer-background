// slop-detector.swift
// Captures a clean video window (default: "Camera Live", your Sony→Syphon feed)
// via ScreenCaptureKit, runs Apple Vision hand-pose on each frame, and POSTs the
// 21 hand landmarks (MediaPipe index order, top-left normalized) to the relay.
// The browser foreground becomes a pure renderer — no webcam, no feedback loop.
//
// Build:  swiftc slop-detector.swift -o slop-detector
// Run:    ./slop-detector ["Camera Live"] [http://localhost:9911/hands]
// Needs Screen Recording permission (System Settings → Privacy → Screen Recording).

import Foundation
import AppKit            // needed so ScreenCaptureKit has a WindowServer connection
import ScreenCaptureKit
import Vision
import CoreMedia
import CoreVideo
import CoreImage

// Capture a VIDEO window. Default: an OBS "Windowed Projector" of your CLEAN
// scene (Camera Live has no video window — it only outputs Syphon).
//   ./slop-detector [appSubstring] [titleSubstring] [postURL]
let args = CommandLine.arguments
let TARGET_APP   = args.count > 1 ? args[1] : "OBS"
let TARGET_TITLE = args.count > 2 ? args[2] : "Projector"
let POST_URL     = URL(string: args.count > 3 ? args[3] : "http://localhost:9911/hands")!
let FPS          = 10
// Auth for posting to the relay's /v1/hands (the "eye" pipeline). Unset when
// posting to the local slop-server, which needs none.
let GESTURE_KEY  = ProcessInfo.processInfo.environment["SLOP_GESTURE_KEY"]

// Vision joints in MediaPipe's 0..20 index order so the browser's existing
// finger-count/gesture logic works unchanged.
let JOINT_ORDER: [VNHumanHandPoseObservation.JointName] = [
    .wrist,
    .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
    .indexMCP, .indexPIP, .indexDIP, .indexTip,
    .middleMCP, .middlePIP, .middleDIP, .middleTip,
    .ringMCP, .ringPIP, .ringDIP, .ringTip,
    .littleMCP, .littlePIP, .littleDIP, .littleTip,
]

final class Detector: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    let session = URLSession(configuration: .ephemeral)
    let handReq: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 6   // the eye watches the whole room — host + guests
        return r
    }()
    let queue = DispatchQueue(label: "slop.detector")
    var frame = 0
    let ciContext = CIContext()
    // Written next to the executable so hands.html (served from the same folder) can show it.
    let captureJPG = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("slop-capture.jpg").path
    var diagPrinted = false

    func scheduleRestart(_ secs: Double, _ why: String) {
        FileHandle.standardError.write("(\(why)) — retrying in \(secs)s\n".data(using: .utf8)!)
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { Task { await self.start() } }
    }

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let windows = content.windows.filter {
                let owner = $0.owningApplication?.applicationName ?? ""
                let title = $0.title ?? ""
                return owner.localizedCaseInsensitiveContains(TARGET_APP)
                    && (TARGET_TITLE.isEmpty || title.localizedCaseInsensitiveContains(TARGET_TITLE))
                    && $0.frame.width > 40 && $0.frame.height > 40
                    && $0.isOnScreen   // a projector stranded on an inactive Space matches too but never repaints — zero frames
            }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }

            guard let win = windows.first else {
                if !diagPrinted {
                    diagPrinted = true
                    let obs = content.windows.filter { ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(TARGET_APP) }
                    if obs.isEmpty {
                        FileHandle.standardError.write("No \"\(TARGET_APP)\" windows. All titled windows visible:\n".data(using: .utf8)!)
                        for w in content.windows where !((w.title ?? "").isEmpty) {
                            FileHandle.standardError.write("  [\(w.owningApplication?.applicationName ?? "?")] \"\(w.title ?? "")\" \(Int(w.frame.width))x\(Int(w.frame.height))\n".data(using: .utf8)!)
                        }
                    } else {
                        FileHandle.standardError.write("\(TARGET_APP) windows (none matched title ~\"\(TARGET_TITLE)\"):\n".data(using: .utf8)!)
                        for w in obs {
                            FileHandle.standardError.write("  \"\(w.title ?? "")\" \(Int(w.frame.width))x\(Int(w.frame.height))\n".data(using: .utf8)!)
                        }
                    }
                }
                scheduleRestart(2.0, "no match yet")
                return
            }
            print("Capturing: [\(win.owningApplication!.applicationName)] \(win.title ?? "") \(Int(win.frame.width))x\(Int(win.frame.height))")
            fflush(stdout)

            let cfg = SCStreamConfiguration()
            cfg.width  = Int(win.frame.width)
            cfg.height = Int(win.frame.height)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(FPS))
            cfg.queueDepth = 4
            cfg.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: win)
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            self.stream = s
            let monitor = POST_URL.deletingLastPathComponent().appendingPathComponent("hands.html").absoluteString
            print("Detecting hands. Monitor → \(monitor)"); fflush(stdout)
        } catch {
            scheduleRestart(2.0, "start error: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // dump a debug JPEG of exactly what we're capturing (~1/sec) so hands.html
        // can show what Vision sees.
        if frame % FPS == 0 {
            let ci = CIImage(cvPixelBuffer: px)
            if let data = ciContext.jpegRepresentation(of: ci, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) {
                let tmp = captureJPG + ".tmp"
                if (try? data.write(to: URL(fileURLWithPath: tmp))) != nil {
                    try? FileManager.default.removeItem(atPath: captureJPG)
                    try? FileManager.default.moveItem(atPath: tmp, toPath: captureJPG)
                }
            }
        }

        let capW = CVPixelBufferGetWidth(px)
        let capH = CVPixelBufferGetHeight(px)
        let handler = VNImageRequestHandler(cvPixelBuffer: px, orientation: .up, options: [:])
        do { try handler.perform([handReq]) } catch { return }
        guard let results = handReq.results, !results.isEmpty else { post(hands: [], w: capW, h: capH); return }

        var hands: [[String: Any]] = []
        for obs in results {
            guard let pts = try? obs.recognizedPoints(.all) else { continue }
            var lm: [[Double]] = []
            for joint in JOINT_ORDER {
                if let p = pts[joint] {
                    // Vision is normalized, origin bottom-left → flip Y for top-left (browser) space
                    lm.append([Double(p.location.x), Double(1.0 - p.location.y)])
                } else {
                    lm.append([0, 0])
                }
            }
            let chir: String = obs.chirality == .left ? "left" : (obs.chirality == .right ? "right" : "unknown")
            hands.append(["chirality": chir, "lm": lm])
        }
        post(hands: hands, w: capW, h: capH)
        frame += 1
        if frame % FPS == 0 {  // ~once per second
            let labels = hands.map { ($0["chirality"] as? String) ?? "?" }.joined(separator: ",")
            FileHandle.standardError.write("hands: \(hands.count) [\(labels)]\n".data(using: .utf8)!)
        }
    }

    func post(hands: [[String: Any]], w: Int, h: Int) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["hands": hands, "w": w, "h": h]) else { return }
        var req = URLRequest(url: POST_URL)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = GESTURE_KEY { req.setValue(key, forHTTPHeaderField: "X-Gesture-Key") }
        session.dataTask(with: req).resume()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        scheduleRestart(1.5, "stream stopped: \(error.localizedDescription)")
    }
}

FileHandle.standardError.write("slop-detector: launched\n".data(using: .utf8)!)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // background agent: no dock icon, no menu bar
let detector = Detector()
Task { await detector.start() }
app.run()
