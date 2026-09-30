#!/usr/bin/env python3
"""每 ~0.3 秒读一次 SMC 的 PSTR(整机)和 USB 口对外供电，用来抓降频前那几秒的峰值。
  pstrfast.py <输出.csv> <阶段文件>
"""
import subprocess, sys, time
out, phase_file = open(sys.argv[1], "a"), sys.argv[2]


def val(k):
    o = subprocess.run(["fanctl", "dump", k], capture_output=True, text=True).stdout.split()
    return float(o[-1]) if o else float("nan")


while True:
    try:
        ph = open(phase_file).read().strip()
    except OSError:
        ph = ""
    usb = sum(val(k) for k in ("PU1C", "PU2C", "PU3C", "PUAC"))
    out.write(f"{time.time():.2f},{val('PSTR'):.2f},{usb:.2f},{ph}\n")
    out.flush()
    time.sleep(0.3)
