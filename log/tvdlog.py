#!/usr/bin/env python3
"""每 ~2 秒记一次：TVD* / TCMb 温度、CPU/GPU 最热、Super/Performance/GPU 频率、CPU/GPU 功耗、PSTR。
  tvdlog.py <秒数>   输出 CSV 到标准输出
"""
import json, os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import readings
secs = float(sys.argv[1]); t0 = time.time()
def smc(prefix):
    out = subprocess.run(["fanctl", "dump", prefix], capture_output=True, text=True).stdout
    return {l.split()[0]: float(l.split()[-1]) for l in out.splitlines() if " flt " in l}
print("t,TVDM,TVDC,TVD0,TVDG,TVDP,TCMb,Tp_max,Tg_max,super_mhz,perf_mhz,gpu_mhz,cpu_w,gpu_w,pstr", flush=True)
while time.time() - t0 < secs:
    tv, tc, tp, tg = smc("TV"), smc("TC"), smc("Tp0"), smc("Tg")
    ok = lambda d: [v for v in d.values() if 5 < v < 130]
    m = json.loads(subprocess.run(["macmon", "pipe", "-s", "1", "-i", "700"], capture_output=True, text=True).stdout.strip().splitlines()[-1])
    avg = lambda k: sum(c["freq_mhz"] for c in m.get(k, []) if isinstance(c, dict)) / max(1, len([c for c in m.get(k, []) if isinstance(c, dict)]))
    st = readings.fanctl_status()
    cw, gw, pw = f"{st['cpu_w']:.2f}", f"{st['gpu_w']:.2f}", f"{st['pstr_w']:.2f}"
    print(f"{time.time()-t0:.1f}," + ",".join(f"{tv.get(k, float('nan')):.1f}" for k in ("TVDM", "TVDC", "TVD0", "TVDG", "TVDP")) +
          f",{tc.get('TCMb', float('nan')):.1f},{max(ok(tp)):.1f},{max(ok(tg)):.1f},{avg('pcpu_cores'):.0f},{avg('ecpu_cores'):.0f},{(m.get('gpu_usage') or [0])[0]}," +
          f"{cw},{gw},{pw}", flush=True)
