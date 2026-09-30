# WattsUp

*[中文说明](README.zh.md)*

_Last updated: 2026-09-30_

**WattsUp** — what's up, and how many watts is your Mac burning right now? This is "heating-wire mode" for an Apple Silicon Mac: load the CPU, memory, GPU (hardware ray tracing plus Metal 4 tensor ops) and the Neural Engine at the same time, and log power, temperatures and clocks while it cooks. It doubles as a measured record of where every watt goes on one machine.

Script output is in Chinese; the numbers and file names are not.

## Test machine

| | |
|---|---|
| Model | Mac Studio (`Mac17,14`) |
| Chip | Apple M5 Max |
| CPU | 18 cores: 6 Super + 12 Performance |
| GPU | 32 cores (one neural accelerator per core) |
| Neural Engine | 16 cores |
| Memory | 36 GB unified |
| Storage | 1 TB SSD |
| OS | macOS 27.0.1 (26A434) |
| Peripherals | Studio Display XDR (self-powered, draws nothing from the Mac); a ~15 W desk lamp on a USB-C port |

## Record: 326 W

| | |
|---|---|
| Whole system, `PSTR` | **326.4 W** (325.7 W on a second run of the same config) |
| Of which USB-C output (the lamp) | 14.9 W |
| **The Mac itself** | **311.6 W** |
| Config | `./heater.sh peak`: 18 CPU threads + 4 memory threads + hardware ray tracing (5000 triangles) + 8 ANE threads, **no tensor work** |
| Conditions | 25 s runs, each started cold; fans pinned at 100%; sampled every 0.3 s; the peak came 2.6 s in |

- `PSTR` is the SMC's reading of the **internal PSU's 12 V DC output**, not power at the wall. Wall draw is higher by the PSU's conversion loss.
- The peak lasts about 10–15 s, until the Super cores throttle (see below). With fans at 100%, the `mix` config settles at about 250 W for the Mac itself. The `peak` config was only run for 25 s at a time, so its steady state was not measured.

## Per-unit measurements

Unless noted: one unit at a time, 10–25 s, fans on auto. GPU power always means "GPU + AFR0" (see [AFR0](#what-is-afr0)).

| Unit | Load | Power | Notes |
|---|---|---|---|
| CPU | Stockfish benchmark, 18 threads | 80–92 W | 79 W after 1.7 h; per core roughly 7.5 W Super, 3–3.5 W Performance |
| CPU | openssl sha256 × 18 processes | 83–84 W | |
| GPU | Hardware ray tracing, 5000 triangles | 116.6 W (96.5 core + 20 AFR) | 186 W whole system, the highest of any GPU-only load |
| GPU | Hardware ray tracing, 2000 triangles, 3 min | ~105 W (96 + 9.5) | 14.2 billion rays/s |
| GPU | Metal 4 tensor matmul (on-chip) | 88–95 W | ~52 TFLOPS (fp16 inputs), AFR < 1 W |
| GPU | PyTorch MPS fp16 matmul, 8192² | ~96 W (71.6 + 24.3 AFR) | ~42 TFLOPS, already on the neural accelerators |
| GPU | Ray tracing 5000 + tensor, two processes | ~118 W (106 + 12) | Highest GPU figure |
| ANE | Vision body-pose, 8 threads | 4.5–4.9 W | Throughput stops rising past 4 threads |
| Memory | `membw`, 4 threads, ~360 GB/s | 8.6 W DRAM | AMCC 9.3 W and DCS 7.7 W at the same time; overlap with DRAM unknown |
| Media engines | HEVC / H.264 hardware encode, 4K60 | ~0.7 W (`AVE0`) | ProRes encode 0.3–0.9 W (`MSR0`); negligible |

Combined:

| Config | Whole-system peak | Mac-itself peak |
|---|---|---|
| `peak` (ray tracing, no tensor) | 325.7 / 326.4 W | 310.8 / 311.6 W |
| `mix` (ray tracing + tensor) | 304.5 / 305.1 W | 289.7 / 290.2 W |
| 18 CPU threads + ray tracing (20k triangles) + tensor, fans auto | 280 W | 265 W |

### Why ray tracing alone beats ray tracing plus tensor work

The GPU itself sits at 116–118 W either way, which looks like its own ceiling. The difference is outside the GPU:

| On the GPU | GPU core | AFR0 | Whole system |
|---|---|---|---|
| Ray tracing 5000 only | 96.5 W | 20 W | 186 W |
| Ray tracing 5000 + tensor | 106 W | 12 W | 172 W |
| Tensor only | 95 W | 0.6 W | 125 W |

The tensor kernel keeps its matrices in on-chip memory and moves almost no data. Ray tracing keeps the path from the GPU to memory busy as well. Running both, the GPU time-slices between them, ray tracing gets about half the time, the memory side draws less, and the whole machine ends up a dozen watts lower.

I also tried putting ray tracing and tensor work in one kernel (`src/fused_stress.swift`) so both kinds of unit would be busy inside the same GPU core. It only reached 52–87 W: divergent ray paths within a thread group stall the matrix work.

## Throttling: what was measured

About 15–20 s into a full load, the six Super cores drop from 4608 MHz to about 2900–3500 MHz and CPU power falls from ~72 W to ~53 W. The Performance cores and the GPU stay close to full clocks.

**Ruled out by measurement:**
- **Not a total power limit of the PSU.** Switching the lamp off took 14 W off `PSTR`; the Mac's own power and the timing and depth of the throttling did not change.
- **Not the measured core temperatures.** With fans at 100%, the hottest physical CPU sensor read only 80–86 °C, and the system thermal pressure level (`com.apple.system.thermalpressurelevel`) stayed at 0 throughout.
- **Unlikely to be the PMIC overheating.** The IOHID sensors named `PMU tdie1–14` peaked at about 46 °C under load, and the external thermistors on it, `PMU tdev1–8`, at 61 °C. Per the Asahi Linux docs, the PMU is Apple's power management unit. Limits such as its current limit are not readable, so they can't be ruled out.

**Coincides with, causation not shown:**
- Throttling starts exactly when the SMC keys `TVDP` / `TVDC` / `TVD0` reach about 93 °C, 10–20 °C above every physical core sensor. After throttling, `TVDP` falls back to 84–86 °C.
- The readings suggest `TVD*` are hotspot estimates computed by the SMC rather than physical parts: `TVD0` always equals the maximum of the others, and `TVDC` and `TVDP` read exactly the same. `TVDP` follows CPU load (presumably the Super cores); `TVDG` follows GPU load. The key names are not publicly documented, so all of this is inference.
- IOReport "SoC Stats / Events" has a set of throttle-trigger states (`*_THROTTLE_{PPT,EXT,ADCLK,HW,SW,DITHER}_TRIG`, `CPU_SOCHOT*_L`). None recorded any activity. I can't tell whether they update at all.

**Scheduling doesn't raise the steady state.** Lowering CPU/memory priority, fewer Stockfish threads, a different ray-tracing scene or fewer memory threads all settle at 247–252 W for the Mac itself.

**Auto fans top out around 2500 rpm** under CPU-only and CPU+GPU load, then clocks come down instead. Manual full speed is 3625 rpm.

## What is AFR0

One of the IOReport energy channels. WattsUp counts it as GPU power:
- It has its own 13-state DVFS table, 338–1620 MHz, in the device tree under `pmgr` → `afr-perf-states`.
- The power-management coprocessor steps it according to GPU memory bandwidth: policy `agx-afr-bw-*`, thresholds in GB/s.
- 0 W at idle and under CPU-only load; under 1 W for pure GPU compute that doesn't touch memory; up to ~25 W for memory-heavy GPU work.
- Its full name is unknown. It does not double-count "GPU Energy": in a run where the GPU channel showed 44 W but the system was 101 W above idle, adding AFR0 closed most of the gap.

[`fanctl`](https://github.com/Justaboringname/fanctl) includes AFR0 in its GPU figure since `dceea80`; older versions list it separately under "Other channels". `log/readings.py` handles both and reports the same way.

## Usage

```sh
make                         # builds into bin/
./heater.sh                  # peak preset, 60 s
./heater.sh mix 30           # every unit at once, 30 s
./heater.sh rt 20            # GPU ray tracing only
RT_TRIS=10000 ./heater.sh peak 30   # any parameter can be overridden via environment
```

Presets:

| Preset | CPU threads | Memory threads | Ray-tracing triangles | Tensor | ANE threads |
|---|---|---|---|---|---|
| `peak` | 18 (niced) | 4 (niced) | 5000 | no | 8 |
| `mix` | 18 (niced) | 4 (niced) | 5000 | yes | 8 |
| `cpu` | 18 | — | — | — | — |
| `mem` | — | 4 | — | — | — |
| `gpu` | — | — | 5000 | yes | — |
| `rt` | — | — | 5000 | — | — |
| `tensor` | — | — | — | yes | — |
| `ane` | — | — | — | — | 8 |

Each run writes to `runs/<time>-<preset>/`: `slow.csv` every 3 s (power, temperatures, `TVD*`, fans, clocks) and `fast.csv` every 0.3 s (whole-system power). The peak and the last-30-second averages are printed at the end.

Standalone tools:

| File | Purpose |
|---|---|
| `bin/rt_stress <s> <triangles> <size> <bounces>` | Metal hardware ray-tracing load |
| `bin/na_stress <s> <threadgroups> <iters> <half\|float>` | Metal 4 tensor load (`matmul2d` from `MetalPerformancePrimitives`) |
| `bin/ane_stress <s> <threads> <size> <model>` | Neural Engine load using the system's built-in Vision models |
| `bin/membw <s> <threads>` | Memory-bandwidth load |
| `bin/fused_stress ...` | Fused ray-tracing + tensor kernel (negative result, kept for comparison) |
| `bin/throttlewatch <s> <interval>` | Prints changes in the IOReport throttle-trigger states |
| `bin/hidtemps` | Lists every IOHID temperature sensor, including `PMU tdie*` / `tdev*` |
| `log/tvdlog.py <s>` | Logs `TVD*`, core temperatures, cluster clocks and power every 2 s |
| `tools/gpu_torch.py <s> <n> <f16\|f32>` | PyTorch MPS matmul load |

## Requirements

- An Apple Silicon Mac. Hardware ray tracing needs M3 or later; the tensor kernel needs macOS 26 or later (Metal 4). Only tested on an M5 Max; whether it runs elsewhere, and what the numbers look like, is unverified.
- Xcode Command Line Tools (`swiftc`, `clang`) and Python 3.
- `brew install stockfish macmon`.
- [`fanctl`](https://github.com/Justaboringname/fanctl) for all power and temperature readings. On M5 the CPU, memory and ANE energy counters only advance while a root `powermetrics` samples, so install fanctl's background services as its README describes, or those readings stay empty.
- `tools/gpu_torch.py` needs PyTorch with MPS; nothing else does.

## Safety

- 300 W+ peaks and ~250 W sustained is a lot of heat. On auto fans the core sensors reach 98–103 °C; on full fans it is loud.
- The chip throttles to protect itself, but don't leave it running unattended for long, e.g. overnight. Runs default to 60 s.
- Ctrl-C stops every load and logger.

## License

MIT
