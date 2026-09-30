#!/usr/bin/env python3
"""每 <间隔> 秒记一行：功耗、温度、TVD*、风扇、频率，以及当前阶段(读 <阶段文件>)。
  thermlog.py <输出.csv> <间隔秒> <阶段文件>
"""
import csv, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import readings

out, interval, phase_file = sys.argv[1], float(sys.argv[2]), sys.argv[3]
COLS = ["time", "epoch", "phase", "cpu_w", "gpu_w", "afr_w", "ane_w", "dram_w", "pstr_w", "body_w",
        "cpu_t_avg", "cpu_t_max", "gpu_t_max", "tvdp", "tvdg", "tvd0", "fan0_rpm", "fan1_rpm", "fan_mode",
        "super_mhz_avg", "super_mhz_min", "perf_mhz_avg", "perf_mhz_min", "gpu_mhz", "gpu_usage", "cpu_usage"]
new = not os.path.exists(out)
fh = open(out, "a", newline="")
w = csv.DictWriter(fh, fieldnames=COLS, extrasaction="ignore")
if new:
    w.writeheader()
while True:
    t = time.time()
    row = {"time": time.strftime("%H:%M:%S"), "epoch": f"{t:.1f}"}
    try:
        row["phase"] = open(phase_file).read().strip()
    except OSError:
        row["phase"] = ""
    for f in (readings.fanctl_status, readings.macmon):
        try:
            row.update(f())
        except Exception as exc:
            print(f"{f.__name__}: {exc}", file=sys.stderr)
    try:
        v = readings.smc("TVD")
        row.update(tvdp=v.get("TVDP"), tvdg=v.get("TVDG"), tvd0=v.get("TVD0"))
    except Exception as exc:
        print(f"smc: {exc}", file=sys.stderr)
    w.writerow({k: (f"{v:.2f}" if isinstance(v, float) else v) for k, v in row.items()})
    fh.flush()
    time.sleep(max(0.0, interval - (time.time() - t)))
