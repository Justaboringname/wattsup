// 用系统自带的 Vision 模型压 Neural Engine：每个线程循环跑同一个请求，能选 ANE 的阶段都强制选 ANE。
//   ane_stress <秒> <线程数> <图片边长> <classify|feature|saliency|segment|pose|text|animals>
import CoreGraphics
import CoreML
import Foundation
import Vision

let a = CommandLine.arguments
let secs = Double(a[1])!, threads = Int(a[2])!, size = Int(a[3])!, kind = a[4]

func makeImage(_ n: Int) -> CGImage {
    var px = [UInt8](repeating: 0, count: n * n * 4)
    var s: UInt32 = 12345
    for i in 0..<px.count { s = s &* 1664525 &+ 1013904223; px[i] = UInt8(truncatingIfNeeded: s >> 24) }
    let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return ctx.makeImage()!
}

func makeRequest() -> VNRequest {
    switch kind {
    case "classify": return VNClassifyImageRequest()
    case "feature": return VNGenerateImageFeaturePrintRequest()
    case "saliency": return VNGenerateAttentionBasedSaliencyImageRequest()
    case "segment": let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = .accurate; return r
    case "pose": return VNDetectHumanBodyPoseRequest()
    case "text": let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; return r
    case "animals": return VNRecognizeAnimalsRequest()
    default: fatalError("unknown request \(kind)")
    }
}

func pinToANE(_ req: VNRequest, verbose: Bool) {
    guard let stages = try? req.supportedComputeStageDevices else { if verbose { print("  (no compute-device info)") }; return }
    for (stage, devs) in stages {
        let names = devs.map { d -> String in
            switch d { case .cpu: return "cpu"; case .gpu: return "gpu"; case .neuralEngine: return "ane"; @unknown default: return "?" }
        }
        let ane = devs.first { if case .neuralEngine = $0 { return true } else { return false } }
        if let ane { req.setComputeDevice(ane, for: stage) }
        if verbose { print("  stage \(stage.rawValue): \(names.joined(separator: ",")) -> \(ane != nil ? "ane" : "default")") }
    }
}

let img = makeImage(size)
let lock = NSLock()
var total = 0, errors = 0
let t0 = Date()
let group = DispatchGroup()
for t in 0..<threads {
    group.enter()
    Thread.detachNewThread {
        let req = makeRequest()
        pinToANE(req, verbose: t == 0)
        var n = 0, e = 0
        while Date().timeIntervalSince(t0) < secs {
            do { try VNImageRequestHandler(cgImage: img, options: [:]).perform([req]); n += 1 } catch { e += 1 }
        }
        lock.lock(); total += n; errors += e; lock.unlock()
        group.leave()
    }
}
group.wait()
let el = Date().timeIntervalSince(t0)
print(String(format: "%@ x%d threads, %dx%d: %d runs (%d errors) in %.1fs = %.1f/s", kind, threads, size, size, total, errors, el, Double(total) / el))
