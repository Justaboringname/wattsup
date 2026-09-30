// 融合内核：同一个线程组里交替做 Metal 4 张量乘加(神经加速器)和硬件光追求交(光追单元)，
// 让两种单元在同一个 GPU 核里同时忙，而不是两个进程分时。
//   fused_stress <秒> <三角形数> <线程组数> <迭代次数> <每次迭代的矩阵乘次数> <每次迭代每线程的光线数>
import Foundation
import Metal

let args = CommandLine.arguments
let secs = Double(args[1])!, nTri = Int(args[2])!, groups = Int(args[3])!
var params: (UInt32, UInt32, UInt32) = (UInt32(args[4])!, UInt32(args[5])!, UInt32(args[6])!)
let dev = MTLCreateSystemDefaultDevice()!
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
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace metal;
using namespace raytracing;
using namespace mpp::tensor_ops;

struct P { uint iters, mm, rays; };
static inline float rnd(thread uint &s) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return float(s & 0xFFFFFFu) / 16777216.0; }

kernel void fused(device const half *Ab [[buffer(0)]], device const half *Bb [[buffer(1)]],
                  device float *out [[buffer(2)]], constant P &p [[buffer(3)]],
                  primitive_acceleration_structure accel [[buffer(4)]],
                  uint tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]])
{
    threadgroup half sA[64 * 64];
    threadgroup half sB[64 * 32];
    for (uint i = tid; i < 64 * 64; i += 128) sA[i] = Ab[i];
    for (uint i = tid; i < 64 * 32; i += 128) sB[i] = Bb[i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    auto tA = tensor<threadgroup half, dextents<int32_t, 2>, tensor_inline>(sA, dextents<int32_t, 2>(64, 64));
    auto tB = tensor<threadgroup half, dextents<int32_t, 2>, tensor_inline>(sB, dextents<int32_t, 2>(32, 64));
    constexpr auto desc = matmul2d_descriptor(64, 32, 64, false, false, false, matmul2d_descriptor::mode::multiply_accumulate);
    matmul2d<desc, execution_simdgroups<4>> op;
    auto cT = op.get_destination_cooperative_tensor<decltype(tA), decltype(tB), half>();
    for (auto e = cT.begin(); e != cT.end(); e++) *e = 0;

    intersector<triangle_data> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    uint seed = (tg * 1973u + tid * 9277u) | 1u;
    ray r;
    r.origin = float3(rnd(seed), rnd(seed), rnd(seed));
    r.direction = normalize(float3(rnd(seed), rnd(seed), rnd(seed)) * 2.0 - 0.999);
    r.min_distance = 1e-4; r.max_distance = INFINITY;
    float acc = 0;
    for (uint it = 0; it < p.iters; ++it) {
        for (uint m = 0; m < p.mm; ++m) op.run(tA, tB, cT);
        for (uint k = 0; k < p.rays; ++k) {
            intersection_result<triangle_data> hit = isect.intersect(r, accel);
            float3 d = normalize(float3(rnd(seed), rnd(seed), rnd(seed)) * 2.0 - 0.999);
            if (hit.type == intersection_type::none) r.origin = float3(rnd(seed), rnd(seed), rnd(seed));
            else { r.origin = r.origin + r.direction * hit.distance + d * 1e-3; acc += hit.distance; }
            r.direction = d;
        }
    }
    float s = acc;
    for (auto e = cT.begin(); e != cT.end(); e++) s += float(*e);
    out[tg * 128 + tid] = s;
}
"""
let opts = MTLCompileOptions()
opts.languageVersion = .version4_0
let lib: MTLLibrary
do { lib = try dev.makeLibrary(source: src, options: opts) } catch { print("COMPILE ERROR:\n\(error)"); exit(1) }
let pso = try dev.makeComputePipelineState(function: lib.makeFunction(name: "fused")!)
var hA = [Float16](repeating: 0, count: 64 * 64), hB = [Float16](repeating: 0, count: 64 * 32)
for i in hA.indices { hA[i] = Float16(Float((i * 37) % 17) / 1700.0) }
for i in hB.indices { hB[i] = Float16(Float((i * 11) % 13) / 1300.0) }
let bA = dev.makeBuffer(bytes: hA, length: hA.count * 2)!, bB = dev.makeBuffer(bytes: hB, length: hB.count * 2)!
let bOut = dev.makeBuffer(length: groups * 128 * 4, options: .storageModeShared)!
let inflight = DispatchSemaphore(value: 3)
var dispatches = 0
let t0 = Date()
while Date().timeIntervalSince(t0) < secs {
    inflight.wait()
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(bA, offset: 0, index: 0); enc.setBuffer(bB, offset: 0, index: 1); enc.setBuffer(bOut, offset: 0, index: 2)
    enc.setBytes(&params, length: 12, index: 3)
    enc.setAccelerationStructure(accel, bufferIndex: 4)
    enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
    enc.endEncoding()
    cb.addCompletedHandler { c in if let e = c.error { print("GPU error: \(e)") }; inflight.signal() }
    cb.commit()
    dispatches += 1
}
for _ in 0..<3 { inflight.wait() }
let el = Date().timeIntervalSince(t0)
let work = Double(dispatches) * Double(groups) * Double(params.0)
print(String(format: "fused tris=%d groups=%d iters=%d mm=%d rays=%d: %.1f TFLOPS + %.0f Mrays/s in %.1fs",
             nTri, groups, params.0, params.1, params.2,
             work * Double(params.1) * 2 * 64 * 32 * 64 / el / 1e12, work * 128 * Double(params.2) / el / 1e6, el))
