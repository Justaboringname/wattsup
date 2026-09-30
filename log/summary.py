#!/usr/bin/env python3
"""汇总一次 heater.sh 的运行：整机峰值(0.3 秒采样)和最后 30 秒的稳态。
  summary.py runs/<运行目录>
"""
import csv, math, os, sys

run = sys.argv[1]
nan = float("nan")
num = lambda v: float(v) if v not in ("", None) else nan

fast = [l.strip().split(",", 3) for l in open(os.path.join(run, "fast.csv")) if l.count(",") >= 3]
load = [(float(t), float(p), float(u)) for t, p, u, ph in fast if ph == "load"]
if load:
    t0 = load[0][0]
    t, p, u = max(load, key=lambda x: x[1])
    print(f"整机峰值 {p:.1f} W（Mac 本体 {p - u:.1f} W，USB 口对外 {u:.1f} W），开跑后 {t - t0:.1f} 秒")

rows = [r for r in csv.DictReader(open(os.path.join(run, "slow.csv"))) if r["phase"] == "load"]
if rows:
    end = float(rows[-1]["epoch"])
    last = [r for r in rows if end - float(r["epoch"]) <= 30]
    m = lambda k: sum(num(r[k]) for r in last) / len(last)
    print(f"最后 30 秒平均：整机 {m('pstr_w'):.1f} W，本体 {m('body_w'):.1f} W | CPU {m('cpu_w'):.1f} W，"
          f"GPU {m('gpu_w'):.1f} W（含 AFR {m('afr_w'):.1f}），ANE {m('ane_w'):.1f} W，内存 {m('dram_w'):.1f} W")
    print(f"               频率 Super {m('super_mhz_avg'):.0f} / Performance {m('perf_mhz_avg'):.0f} / GPU {m('gpu_mhz'):.0f} MHz | "
          f"CPU 最热 {m('cpu_t_max'):.1f} °C，GPU 最热 {m('gpu_t_max'):.1f} °C，TVDP {m('tvdp'):.1f} °C | 风扇 {m('fan0_rpm'):.0f} rpm")
for name in ("cpu", "mem", "rt", "tensor", "ane"):
    p = os.path.join(run, name + ".log")
    if os.path.exists(p):
        txt = [l.strip() for l in open(p) if l.strip()]
        keep = [l for l in txt if any(k in l for k in ("Nodes/second", "GB/s", "Mrays", "TFLOPS", "runs"))]
        print(f"  {name:6s} {(keep or txt[-1:] or [''])[-1]}")
