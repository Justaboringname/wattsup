// Metal 硬件光追压力：对一堆随机三角形建加速结构，compute kernel 里每个像素连续弹射 N 次。
//   rt_stress <秒> <三角形数> <贴图边长> <每像素弹射次数>
import Foundation
import Metal

let args = CommandLine.arguments
let secs = args.count > 1 ? Double(args[1])! : 20
let nTri = args.count > 2 ? Int(args[2])! : 1_000_000
let size = args.count > 3 ? Int(args[3])! : 2048
let bounces = args.count > 4 ? Int(args[4])! : 32

guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
guard dev.supportsRaytracing else { fatalError("device does not support ray tracing") }
let queue = dev.makeCommandQueue()!

// 单位立方体里撒 nTri 个小三角形(边长约 0.02)；不带索引，每 3 个顶点一个三角形
var state: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Float {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return Float(state >> 40) / Float(1 << 24)
}
var verts = [SIMD3<Float>]()
verts.reserveCapacity(nTri * 3)
for _ in 0..<nTri {
    let c = SIMD3<Float>(rnd(), rnd(), rnd())
    for _ in 0..<3 { verts.append(c + (SIMD3<Float>(rnd(), rnd(), rnd()) - 0.5) * 0.02) }
}
let stride = MemoryLayout<SIMD3<Float>>.stride
let vb = dev.makeBuffer(bytes: verts, length: verts.count * stride, options: .storageModeShared)!

let geo = MTLAccelerationStructureTriangleGeometryDescriptor()
geo.vertexBuffer = vb
geo.vertexStride = stride
geo.triangleCount = nTri
let desc = MTLPrimitiveAccelerationStructureDescriptor()
desc.geometryDescriptors = [geo]
let sizes = dev.accelerationStructureSizes(descriptor: desc)
let accel = dev.makeAccelerationStructure(size: sizes.accelerationStructureSize)!
let scratch = dev.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate)!
let tBuild = Date()
do {
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeAccelerationStructureCommandEncoder()!
    enc.build(accelerationStructure: accel, descriptor: desc, scratchBuffer: scratch, scratchBufferOffset: 0)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    if let e = cb.error { fatalError("BVH build failed: \(e)") }
}
let buildSecs = Date().timeIntervalSince(tBuild)

let src = """
#include <metal_stdlib>
using namespace metal;
using namespace raytracing;

struct Params { uint frame; uint bounces; };

static inline float rnd(uint &s) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return float(s & 0xFFFFFFu) / 16777216.0; }

kernel void rt(texture2d<float, access::write> out [[texture(0)]],
               primitive_acceleration_structure accel [[buffer(0)]],
               constant Params &p [[buffer(1)]],
               uint2 tid [[thread_position_in_grid]]) {
    uint w = out.get_width(), h = out.get_height();
    if (tid.x >= w || tid.y >= h) return;
    uint seed = (tid.x * 1973u + tid.y * 9277u + p.frame * 26699u) | 1u;
    intersector<triangle_data> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    float2 uv = (float2(tid) + 0.5) / float2(w, h) * 2.0 - 1.0;
    ray r;
    r.origin = float3(0.5 + uv.x * 0.6, 0.5 + uv.y * 0.6, -1.0);
    r.direction = normalize(float3(uv.x * 0.2, uv.y * 0.2, 1.0));
    r.min_distance = 1e-4;
    r.max_distance = INFINITY;
    float3 acc = float3(0.0);
    uint hits = 0;
    for (uint b = 0; b < p.bounces; b++) {
        intersection_result<triangle_data> hit = isect.intersect(r, accel);
        float3 d = normalize(float3(rnd(seed), rnd(seed), rnd(seed)) * 2.0 - 0.999);
        if (hit.type == intersection_type::none) {
            r.origin = float3(rnd(seed), rnd(seed), rnd(seed));      // 飞出去了：在立方体里重新起一条
        } else {
            r.origin = r.origin + r.direction * hit.distance + d * 1e-3;
            acc += float3(hit.triangle_barycentric_coord, hit.distance);
            hits++;
        }
        r.direction = d;
    }
    out.write(float4(acc / float(max(p.bounces, 1u)), float(hits)), tid);
}
"""
let lib = try dev.makeLibrary(source: src, options: nil)
let pso = try dev.makeComputePipelineState(function: lib.makeFunction(name: "rt")!)
let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size, height: size, mipmapped: false)
td.usage = [.shaderWrite, .shaderRead]
td.storageMode = .shared
let tex = dev.makeTexture(descriptor: td)!

let inflight = DispatchSemaphore(value: 3)
var frame: UInt32 = 0
let tw = pso.threadExecutionWidth, th = pso.maxTotalThreadsPerThreadgroup / pso.threadExecutionWidth
let t0 = Date()
while Date().timeIntervalSince(t0) < secs {
    inflight.wait()
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setTexture(tex, index: 0)
    enc.setAccelerationStructure(accel, bufferIndex: 0)
    var p = (frame, UInt32(bounces))
    enc.setBytes(&p, length: MemoryLayout.size(ofValue: p), index: 1)
    enc.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    enc.endEncoding()
    cb.addCompletedHandler { _ in inflight.signal() }
    cb.commit()
    frame += 1
}
for _ in 0..<3 { inflight.wait() }
let el = Date().timeIntervalSince(t0)

// 抽查：中心一小块像素里平均命中了几次(确认光线真的打到了三角形)
var px = [UInt16](repeating: 0, count: 64 * 64 * 4)
tex.getBytes(&px, bytesPerRow: 64 * 8, from: MTLRegionMake2D(size / 2 - 32, size / 2 - 32, 64, 64), mipmapLevel: 0)
var hitSum: Float = 0
for i in 0..<(64 * 64) { hitSum += Float(Float16(bitPattern: px[i * 4 + 3])) }
let rays = Double(frame) * Double(size) * Double(size) * Double(bounces)
print(String(format: "%@ | %d tris (BVH %.2fs, %.0f MB) | %d frames %dx%d x %d bounces in %.1fs | %.0f Mrays/s | avg hits/pixel %.1f of %d",
             dev.name, nTri, buildSecs, Double(sizes.accelerationStructureSize) / 1e6, frame, size, size, bounces, el,
             rays / el / 1e6, hitSum / 4096, bounces))
