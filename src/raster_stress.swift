// Metal 传统光栅压力(不碰光追、不碰张量)：离屏渲染目标上叠很多层半透明网格，
// 每个片元从一张放不进 SLC 的大贴图里做带依赖坐标的各向异性采样，再算一段 ALU。
// Apple GPU 是 TBDR + HSR，不透明层会被隐藏面剔除掉不执行，所以这里全程开 alpha 混合；
// 层分摊到多个 render pass，每个 pass 都 load/store 渲染目标，把 tile 内存和 DRAM 都拉进来。
//   raster_stress <秒> <宽> <高> <层数> <每片元采样数> <网格每边格数> <pass 数> <ALU 迭代>
import Foundation
import Metal

let a = CommandLine.arguments
func arg(_ i: Int, _ d: Int) -> Int { a.count > i ? Int(a[i])! : d }
let secs = a.count > 1 ? Double(a[1])! : 20
let W = arg(2, 5120), H = arg(3, 2880), layers = arg(4, 16), samples = arg(5, 8)
let grid = arg(6, 64), passes = max(1, min(arg(7, 4), layers)), alu = arg(8, 16)

guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
let queue = dev.makeCommandQueue()!

// 4096² rgba16Float 带 mip ≈ 170 MB，填随机数(均匀数据会被无损压缩，读起来就不费带宽了)
let T = 4096
let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: T, height: T, mipmapped: true)
texDesc.usage = .shaderRead
texDesc.storageMode = .private
let bigTex = dev.makeTexture(descriptor: texDesc)!
do {
    let rowBytes = T * 8
    let staging = dev.makeBuffer(length: rowBytes * T, options: .storageModeShared)!
    let p = staging.contents().bindMemory(to: UInt16.self, capacity: T * T * 4)
    var s: UInt64 = 0x9E3779B97F4A7C15
    for i in 0..<(T * T * 4) {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        p[i] = Float16(Float(s >> 40) / Float(1 << 24)).bitPattern
    }
    let cb = queue.makeCommandBuffer()!
    let blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * T,
              sourceSize: MTLSize(width: T, height: T, depth: 1), to: bigTex, destinationSlice: 0,
              destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.generateMipmaps(for: bigTex)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
}

let sd = MTLSamplerDescriptor()
sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
sd.maxAnisotropy = 16
sd.sAddressMode = .repeat; sd.tAddressMode = .repeat
let sampler = dev.makeSamplerState(descriptor: sd)!

// 网格：grid×grid 格铺满屏幕，每格两个三角形(不带索引)
var verts = [SIMD2<Float>]()
verts.reserveCapacity(grid * grid * 6)
for y in 0..<grid {
    for x in 0..<grid {
        let x0 = Float(x) / Float(grid) * 2 - 1, x1 = Float(x + 1) / Float(grid) * 2 - 1
        let y0 = Float(y) / Float(grid) * 2 - 1, y1 = Float(y + 1) / Float(grid) * 2 - 1
        verts += [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x0, y1), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]
    }
}
let vb = dev.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!

let src = """
#include <metal_stdlib>
using namespace metal;

struct Params { uint frame; uint samples; uint alu; uint firstLayer; };
struct VOut { float4 pos [[position]]; float2 uv; uint layer [[flat]]; };

vertex VOut vs(uint vid [[vertex_id]], uint iid [[instance_id]],
               const device float2 *v [[buffer(0)]], constant Params &p [[buffer(1)]]) {
    uint layer = p.firstLayer + iid;
    float2 q = v[vid];
    // 每层轻微扭一下，避免各层完全重合
    float k = float(layer) * 0.37 + float(p.frame) * 0.011;
    float2 w = q + 0.002 * float2(sin(q.y * 9.0 + k), cos(q.x * 7.0 - k));
    VOut o;
    o.pos = float4(w, 0.5, 1.0);
    o.uv = q * 0.5 + 0.5;
    o.layer = layer;
    return o;
}

fragment half4 fs(VOut in [[stage_in]], texture2d<half> tex [[texture(0)]], sampler smp [[sampler(0)]],
                  constant Params &p [[buffer(1)]]) {
    // 屏幕像素 ≈ 1 个 mip0 纹素，各层错开、各向拉伸让过滤走各向异性
    float2 base = in.uv * float2(1.25, 0.7) + float2(float(in.layer) * 0.1371, float(p.frame) * 0.0013);
    float2 dx = dfdx(base) * float2(4.0, 1.0), dy = dfdy(base);
    half4 c = half4(0.0h);
    float2 uv = base;
    for (uint s = 0; s < p.samples; s++) {
        half4 t = tex.sample(smp, uv, gradient2d(dx, dy));
        c += t;
        // 依赖读，但只在几个纹素内挪动：像游戏一样相邻像素读相邻纹素，命中纹理缓存。
        // (挪到贴图随机位置的版本每次都 miss，GPU 卡在等内存，功耗反而只有 30–40 W)
        uv = base + (float2(t.xy) + float2(float(s), float(s) * 0.5)) * (1.5 / 4096.0);
    }
    float x = float(c.x + c.y);
    for (uint i = 0; i < p.alu; i++) x = fma(x, 1.0001, sin(x) * 0.5);
    c.w = half(fract(x)) * 0.02h + 0.01h;
    return c / half(max(p.samples, 1u));
}
"""
let lib = try dev.makeLibrary(source: src, options: nil)
let pd = MTLRenderPipelineDescriptor()
pd.vertexFunction = lib.makeFunction(name: "vs")
pd.fragmentFunction = lib.makeFunction(name: "fs")
let ca = pd.colorAttachments[0]!
ca.pixelFormat = .rgba16Float
ca.isBlendingEnabled = true
ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
let pso = try dev.makeRenderPipelineState(descriptor: pd)

let rtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: false)
rtDesc.usage = [.renderTarget, .shaderRead]
rtDesc.storageMode = .private
let target = dev.makeTexture(descriptor: rtDesc)!

// 层数平均分到各个 pass
let perPass = (0..<passes).map { layers / passes + ($0 < layers % passes ? 1 : 0) }
let inflight = DispatchSemaphore(value: 3)
var frame: UInt32 = 0
var gpuErr: String? = nil
let t0 = Date()
while Date().timeIntervalSince(t0) < secs {
    inflight.wait()
    let cb = queue.makeCommandBuffer()!
    var first = 0
    for (pi, n) in perPass.enumerated() {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = pi == 0 ? .clear : .load
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pso)
        enc.setCullMode(.none)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        var p = (frame, UInt32(samples), UInt32(alu), UInt32(first))
        enc.setVertexBytes(&p, length: MemoryLayout.size(ofValue: p), index: 1)
        enc.setFragmentBytes(&p, length: MemoryLayout.size(ofValue: p), index: 1)
        enc.setFragmentTexture(bigTex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count, instanceCount: n)
        enc.endEncoding()
        first += n
    }
    cb.addCompletedHandler { c in
        if let e = c.error { gpuErr = "\(e)" }
        inflight.signal()
    }
    cb.commit()
    frame += 1
}
for _ in 0..<3 { inflight.wait() }
let el = Date().timeIntervalSince(t0)
if let e = gpuErr { print("GPU error: \(e)") }

// 抽查：读回中心一小块，确认真的画上去了
let rb = dev.makeBuffer(length: 64 * 64 * 8, options: .storageModeShared)!
do {
    let cb = queue.makeCommandBuffer()!
    let blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: W / 2 - 32, y: H / 2 - 32, z: 0),
              sourceSize: MTLSize(width: 64, height: 64, depth: 1), to: rb, destinationOffset: 0,
              destinationBytesPerRow: 64 * 8, destinationBytesPerImage: 64 * 64 * 8)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
}
let px = rb.contents().bindMemory(to: UInt16.self, capacity: 64 * 64 * 4)
var lum: Float = 0
for i in 0..<(64 * 64) { lum += Float(Float16(bitPattern: px[i * 4])) }
let frags = Double(frame) * Double(W * H) * Double(layers)
print(String(format: "%@ | %dx%d x %d layers in %d passes, %d tris/layer, %d samples + %d alu/frag | %d frames in %.1fs = %.1f fps | %.0f Mpix/s, %.0f Gtexel/s | center mean %.3f",
             dev.name, W, H, layers, passes, grid * grid * 2, samples, alu, frame, el, Double(frame) / el,
             frags / el / 1e6, frags * Double(samples) / el / 1e9, lum / 4096))
