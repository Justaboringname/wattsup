# heatwire

_Last updated: 2026-09-30_

> **EN TL;DR** — "Heating-wire mode" for an Apple Silicon Mac: load the CPU, memory, GPU (hardware ray tracing and Metal 4 tensor ops on the M5 neural accelerators) and the Neural Engine at the same time, and log where every watt goes. On a Mac Studio (M5 Max, `Mac17,14`) the highest reading was **326.4 W** from the SMC's `PSTR` (internal PSU DC output, not wall power), of which 14.9 W went to a desk lamp on a USB-C port, so **311.6 W for the Mac itself**. That peak lasts ~10 s. After that the six Super cores throttle and the machine settles near 250 W. Counterintuitively, ray tracing *alone* on the GPU draws more whole-system power than ray tracing plus tensor work. Power and temperatures are read with [`fanctl`](https://github.com/Justaboringname/fanctl). Tested on one machine only. The UI text is Chinese.

把 Apple Silicon Mac 当电暖器用的"电阻丝模式"：CPU、内存、GPU（硬件光追 + Metal 4 张量）、Neural Engine 同时拉满，边烤边记录功耗、温度、频率。顺便是一份"这台机器的电都花在哪了"的实测记录。

## 测试机器

| | |
|---|---|
| 机型 | Mac Studio（`Mac17,14`） |
| 芯片 | Apple M5 Max |
| CPU | 18 核：6 个 Super 核 + 12 个 Performance 核 |
| GPU | 32 核（每核一个神经加速器） |
| Neural Engine | 16 核 |
| 内存 | 36 GB 统一内存 |
| 存储 | 1 TB SSD |
| 系统 | macOS 27.0.1（26A434） |
| 外设 | Studio Display XDR（自带电源，不从 Mac 取电）；USB-C 口上接了一盏约 15 W 的台灯 |

## 最高功耗记录：326 W

| | |
|---|---|
| 整机 `PSTR` | **326.4 W**（同配置第二次 325.7 W） |
| 其中 USB 口对外供电（台灯） | 14.9 W |
| **Mac 本体** | **311.6 W** |
| 配置 | `./heater.sh peak`：CPU 18 线程 + 内存 4 线程 + 硬件光追（5000 三角形）+ ANE 8 线程，**不跑张量** |
| 条件 | 每次从凉的状态开跑 25 秒；风扇手动全速；每 0.3 秒采样一次，峰值在开跑后 2.6 秒 |

- `PSTR` 是 SMC 读到的**内部电源 12 V 直流输出**，不是插座端的功率；插座端还要再加上电源本身的转换损耗。
- 这个峰值只维持约 10–15 秒，之后 Super 核开始降频（见下文）。同样全速风扇下，`mix` 配置的稳态是 Mac 本体约 250 W；`peak` 配置每次只跑了 25 秒，没测稳态。

## 各单元实测

除注明外，都是单独跑 10–25 秒、风扇自动。GPU 功耗一律按"GPU + AFR0"计（见 [AFR0](#afr0-是什么)）。

| 单元 | 负载 | 功耗 | 备注 |
|---|---|---|---|
| CPU | Stockfish 跑分，18 线程 | 80–92 W | 连跑 1.7 小时后稳态 79 W；平摊每核 Super ≈ 7.5 W、Performance ≈ 3–3.5 W |
| CPU | openssl sha256 × 18 进程 | 83–84 W | |
| GPU | 硬件光追，5000 三角形 | 116.6 W（本体 96.5 + AFR 20） | 整机 186 W，是 GPU 单烤里整机最高的 |
| GPU | 硬件光追，2000 三角形，连跑 3 分钟 | 约 105 W（96 + 9.5） | 142 亿光线/秒 |
| GPU | Metal 4 张量（片上矩阵乘） | 88–95 W | 约 52 TFLOPS（fp16 输入），AFR < 1 W |
| GPU | PyTorch MPS fp16 矩阵乘 8192² | 约 96 W（71.6 + AFR 24.3） | 约 42 TFLOPS，已经用上神经加速器 |
| GPU | 光追 5000 + 张量，两个进程并跑 | 约 118 W（106 + 12） | GPU 本体最高 |
| ANE | Vision 人体姿态识别，8 线程 | 4.5–4.9 W | 4 线程以后吞吐不再涨 |
| 内存 | `membw` 4 线程，约 360 GB/s | DRAM 8.6 W | 同时 AMCC 9.3 W、DCS 7.7 W，和 DRAM 是否重叠不清楚 |
| 媒体引擎 | HEVC / H.264 硬件编码 4K60 | `AVE0` 约 0.7 W | ProRes 编码 `MSR0` 0.3–0.9 W，都可以忽略 |

组合：

| 配置 | 整机峰值 | Mac 本体峰值 |
|---|---|---|
| `peak`（光追不加张量） | 325.7 / 326.4 W | 310.8 / 311.6 W |
| `mix`（光追 + 张量） | 304.5 / 305.1 W | 289.7 / 290.2 W |
| CPU 18 线程 + 光追（2 万三角形）+ 张量，风扇自动 | 280 W | 265 W |

### 为什么光追单跑反而比加上张量更费电

GPU 本体在两种情况下都在 116–118 W，像是碰到了 GPU 自己的上限。区别在 GPU 以外：

| GPU 上跑什么 | GPU 本体 | AFR0 | 整机 |
|---|---|---|---|
| 只跑光追 5000 | 96.5 W | 20 W | 186 W |
| 光追 5000 + 张量 | 106 W | 12 W | 172 W |
| 只跑张量 | 95 W | 0.6 W | 125 W |

张量内核把矩阵放在片上内存里反复算，几乎不搬数据；光追会让 GPU 到内存那一侧一起忙起来。两者并跑时 GPU 分时，光追只拿到一半左右的时间，内存那一侧的功耗跟着掉，整机反而少了十几瓦。

我还试过把光追和张量写进同一个内核（`src/fused_stress.swift`），想让两种单元在同一个 GPU 核里同时忙，结果只有 52–87 W：同一组线程里各条光线路径发散，会拖住矩阵运算。

## 降频：测到了什么

满载约 15–20 秒后，6 个 Super 核从 4608 MHz 掉到约 2900–3500 MHz，CPU 功耗从约 72 W 降到约 53 W；Performance 核和 GPU 基本保持满频。

**测过、排除掉的：**
- **不是电源总功率上限**：关掉台灯让 `PSTR` 少了 14 W，Mac 本体功耗、降频时间点和幅度都没变。
- **不是实测的核心温度**：风扇全速时，CPU 最热的物理传感器只有 80–86 °C；系统的热压力等级（`com.apple.system.thermalpressurelevel`）全程是 0。
- **不像电源管理芯片（PMIC）过热**：IOHID 里名为 `PMU tdie1–14` 的传感器满载时最高约 46 °C，接在它上面的外部热敏 `PMU tdev1–8` 最高 61 °C。按 Asahi Linux 文档，PMU 就是 Apple 的电源管理单元。它的电流上限这类限制读不到，没法排除。

**吻合但未证明因果的：**
- 降频开始的时刻，SMC 键 `TVDP` / `TVDC` / `TVD0` 正好到约 93 °C，比所有物理核心传感器高 10–20 °C；降频后 `TVDP` 回落到 84–86 °C。
- 从读数看 `TVD*` 更像是 SMC 估算出来的芯片内部热点，不是某个物理元件：`TVD0` 始终等于其他几个里的最大值，`TVDC` 和 `TVDP` 的读数完全一样。`TVDP` 跟 CPU 负载走（推测对应 Super 核），`TVDG` 跟 GPU 负载走。键名的含义没有公开资料，以上都是推断。
- IOReport "SoC Stats / Events" 里有一组降频触发状态（`*_THROTTLE_{PPT,EXT,ADCLK,HW,SW,DITHER}_TRIG`、`CPU_SOCHOT*_L`），全程没有记录到任何触发。它们是否真的在更新，我不确定。

**改调度也拉不高稳态**：降低 CPU/内存优先级、减少 Stockfish 线程、换光追场景、减少内存线程，稳态都停在 Mac 本体 247–252 W。

**自动风扇封顶约 2500 转**：CPU 单烤、CPU+GPU 双烤时都一样，之后靠降频控温；手动全速是 3625 转。

## AFR0 是什么

IOReport 能耗通道里的一路，这里把它算进 GPU 功耗：
- 它有自己的一张 13 档调频表，338–1620 MHz，在设备树 `pmgr` 的 `afr-perf-states` 里。
- 档位由电源协处理器按 GPU 的内存带宽来升降：策略名 `agx-afr-bw-*`，阈值单位是 GB/s。
- 空闲和纯 CPU 负载时是 0 W；GPU 纯计算、不碰内存时不到 1 W；吃内存的 GPU 负载下能到约 25 W。
- 全称没查到。它不和 "GPU Energy" 重复：GPU 通道只有 44 W 而整机比空闲多 101 W 的情况下，加上 AFR0 才补得上大半。

[`fanctl`](https://github.com/Justaboringname/fanctl) 新版的 GPU 功耗已经包含 AFR0；旧版把它单列在 "Other channels" 里。`log/readings.py` 两种都认，结果口径一致。

## 用法

```sh
make                         # 编译到 bin/
./heater.sh                  # 默认 peak 预设，跑 60 秒
./heater.sh mix 30           # 所有单元都拉满，30 秒
./heater.sh rt 20            # 只烤 GPU 光追
RT_TRIS=10000 ./heater.sh peak 30   # 任意参数都能用环境变量覆盖
```

预设：

| 预设 | CPU 线程 | 内存线程 | 光追三角形 | 张量 | ANE 线程 |
|---|---|---|---|---|---|
| `peak` | 18（降优先级） | 4（降优先级） | 5000 | 否 | 8 |
| `mix` | 18（降优先级） | 4（降优先级） | 5000 | 是 | 8 |
| `cpu` | 18 | — | — | — | — |
| `mem` | — | 4 | — | — | — |
| `gpu` | — | — | 5000 | 是 | — |
| `rt` | — | — | 5000 | — | — |
| `tensor` | — | — | — | 是 | — |
| `ane` | — | — | — | — | 8 |

每次运行的记录放在 `runs/<时间>-<预设>/`：`slow.csv` 每 3 秒一行（功耗、温度、`TVD*`、风扇、频率），`fast.csv` 每 0.3 秒一行整机功耗，跑完自动打印峰值和最后 30 秒的平均。

单独的工具：

| 文件 | 作用 |
|---|---|
| `bin/rt_stress <秒> <三角形数> <边长> <弹射次数>` | Metal 硬件光追压力 |
| `bin/na_stress <秒> <线程组> <迭代> <half\|float>` | Metal 4 张量（`MetalPerformancePrimitives` 的 `matmul2d`）压力 |
| `bin/ane_stress <秒> <线程> <边长> <模型>` | 用系统自带的 Vision 模型压 Neural Engine |
| `bin/membw <秒> <线程>` | 内存带宽压力 |
| `bin/fused_stress ...` | 光追 + 张量融合内核（负面结果，留作对照） |
| `bin/throttlewatch <秒> <间隔>` | 打印 IOReport 降频触发状态的变化 |
| `bin/hidtemps` | 列出所有 IOHID 温度传感器（含 `PMU tdie*` / `tdev*`） |
| `log/tvdlog.py <秒>` | 每 2 秒记 `TVD*`、核心温度、各簇频率、功耗 |
| `tools/gpu_torch.py <秒> <n> <f16\|f32>` | PyTorch MPS 矩阵乘压力 |

## 依赖

- Apple Silicon Mac。硬件光追需要 M3 或更新的芯片；张量内核需要 macOS 26 以上（Metal 4）。只在 M5 Max 上测过，别的芯片能不能跑、数值如何都没验证。
- Xcode Command Line Tools（`swiftc`、`clang`）、Python 3。
- `brew install stockfish macmon`。
- [`fanctl`](https://github.com/Justaboringname/fanctl)：读功耗和温度都靠它。M5 上 CPU、内存、ANE 的能耗计数器只在有 root 的 `powermetrics` 采样时才更新，要按 fanctl 的说明装好它的后台服务，否则这几项会读不到。
- `tools/gpu_torch.py` 需要装了 MPS 支持的 PyTorch，其他部分不需要。

## 安全提示

- 峰值 300 W 以上、稳态约 250 W 会持续发热；风扇自动时核心传感器会到 98–103 °C，风扇全速时很吵。
- 芯片会自己降频保护，但别让它无人看管地长时间跑，比如整夜。默认只跑 60 秒。
- 按 Ctrl-C 会停掉所有负载和记录。

## License

MIT
