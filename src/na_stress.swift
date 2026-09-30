// Metal 4 张量(MPP matmul2d)压力：每个线程组把一小块 A/B 放进 threadgroup 内存，
// 然后反复做 C += A×B(C 在寄存器里的 cooperative tensor)。数据不出片上，专门烤 GPU 核里的神经加速器。
//   na_stress <秒> <每次派发的线程组数> <每个线程组的迭代次数> <half|float 累加类型>
import Foundation
import Metal

let a = CommandLine.arguments
let secs = Double(a[1])!, groups = Int(a[2])!, iters = UInt32(a[3])!, acc = a.count > 4 ? a[4] : "float"

let dev = MTLCreateSystemDefaultDevice()!
let queue = dev.makeCommandQueue()!
let src = """
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace metal;
using namespace mpp::tensor_ops;

kernel void na(device const half *Ab [[buffer(0)]], device const half *Bb [[buffer(1)]],
               device float *out [[buffer(2)]], constant uint &iters [[buffer(3)]],
               uint tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]])
{
    threadgroup half sA[64 * 64];   // A: M=64 行 x K=64 列
    threadgroup half sB[64 * 32];   // B: K=64 行 x N=32 列
    for (uint i = tid; i < 64 * 64; i += 128) sA[i] = Ab[i];
    for (uint i = tid; i < 64 * 32; i += 128) sB[i] = Bb[i];
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // extent(0) 是连续的那一维：A 是 (K, M)，B 是 (N, K)
    auto tA = tensor<threadgroup half, dextents<int32_t, 2>, tensor_inline>(sA, dextents<int32_t, 2>(64, 64));
    auto tB = tensor<threadgroup half, dextents<int32_t, 2>, tensor_inline>(sB, dextents<int32_t, 2>(32, 64));

    constexpr auto desc = matmul2d_descriptor(64, 32, 64, false, false, false,
                                              matmul2d_descriptor::mode::multiply_accumulate);
    matmul2d<desc, execution_simdgroups<4>> op;
    auto cT = op.get_destination_cooperative_tensor<decltype(tA), decltype(tB), ACC>();
    for (auto e = cT.begin(); e != cT.end(); e++) *e = 0;

    for (uint it = 0; it < iters; ++it) op.run(tA, tB, cT);

    float s = 0;
    for (auto e = cT.begin(); e != cT.end(); e++) s += float(*e);
    out[tg * 128 + tid] = s;
}
"""
let opts = MTLCompileOptions()
opts.languageVersion = .version4_0
opts.preprocessorMacros = ["ACC": acc as NSString]
let lib: MTLLibrary
do { lib = try dev.makeLibrary(source: src, options: opts) } catch { print("COMPILE ERROR:\n\(error)"); exit(1) }
let pso = try dev.makeComputePipelineState(function: lib.makeFunction(name: "na")!)

var hA = [Float16](repeating: 0, count: 64 * 64), hB = [Float16](repeating: 0, count: 64 * 32)
for i in hA.indices { hA[i] = Float16(Float((i * 37) % 17) / 170.0) }
for i in hB.indices { hB[i] = Float16(Float((i * 11) % 13) / 130.0) }
let bA = dev.makeBuffer(bytes: hA, length: hA.count * 2)!, bB = dev.makeBuffer(bytes: hB, length: hB.count * 2)!
let bOut = dev.makeBuffer(length: groups * 128 * 4, options: .storageModeShared)!

let inflight = DispatchSemaphore(value: 3)
var dispatches = 0
var it = iters
let t0 = Date()
while Date().timeIntervalSince(t0) < secs {
    inflight.wait()
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(bA, offset: 0, index: 0); enc.setBuffer(bB, offset: 0, index: 1); enc.setBuffer(bOut, offset: 0, index: 2)
    enc.setBytes(&it, length: 4, index: 3)
    enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
    enc.endEncoding()
    cb.addCompletedHandler { c in if let e = c.error { print("GPU error: \(e)") }; inflight.signal() }
    cb.commit()
    dispatches += 1
}
for _ in 0..<3 { inflight.wait() }
let el = Date().timeIntervalSince(t0)
let flops = Double(dispatches) * Double(groups) * Double(iters) * 2 * 64 * 32 * 64
let o = bOut.contents().bindMemory(to: Float.self, capacity: groups * 128)
print(String(format: "acc=%@ groups=%d iters=%d: %d dispatches in %.1fs = %.1f TFLOPS (fp16 inputs) | sample out %.3f",
             acc, groups, iters, dispatches, el, flops / el / 1e12, o[0]))
