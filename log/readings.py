"""读 fanctl / macmon 的读数。只读，不改任何设置。

GPU 功耗统一按「GPU Energy + AFR0」算：AFR0 是 GPU 到内存那一路单独的供电(见 README)。
新版 fanctl 的 GPU 已经含 AFR 并多打一行 "GPU includes X W on AFR"；旧版 fanctl 的 GPU
不含 AFR，AFR0 列在 "Other channels" 里 —— 两种都认，结果口径一致。
"""
import json, re, subprocess


def _run(*cmd, timeout=20):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout


def fanctl_status():
    out = _run("fanctl", "status")
    g = lambda pat: (m.group(1) if (m := re.search(pat, out)) else None)
    f = lambda pat: float(v) if (v := g(pat)) is not None else float("nan")
    gpu = f(r"Power: CPU [\d.]+ W \| GPU ([\d.]+) W")
    afr_in_gpu = g(r"GPU includes ([\d.]+) W on AFR")
    if afr_in_gpu is not None:
        afr = float(afr_in_gpu)
    else:                                   # 旧版 fanctl：把 AFR0 加回 GPU
        afr = f(r"AFR0\s+([\d.]+) W")
        if afr == afr:
            gpu += afr
    return {
        "cpu_w": f(r"Power: CPU ([\d.]+) W"), "gpu_w": gpu, "afr_w": afr,
        "ane_w": f(r"ANE ([\d.]+) W"), "dram_w": f(r"DRAM ([\d.]+) W"),
        "pstr_w": f(r"System \(SMC PSTR\): ([\d.]+) W"), "body_w": f(r"Mac body[^:]*: ([\d.]+) W"),
        "cpu_t_avg": f(r"CPU avg\s+([\d.]+)"), "cpu_t_max": f(r"CPU avg\s+[\d.]+ °C\s+\(max\s+([\d.]+)"),
        "gpu_t_max": f(r"GPU avg\s+[\d.]+ °C\s+\(max\s+([\d.]+)"),
        "fan0_rpm": f(r"Fan0\s+(\d+) rpm"), "fan1_rpm": f(r"Fan1\s+(\d+) rpm"),
        "fan_mode": g(r"Fan0 .*range \S+\s+(\S+)") or "",
    }


def smc(prefix):
    """fanctl dump <前缀> 里所有浮点键，{键: 值}。"""
    out = _run("fanctl", "dump", prefix, timeout=10)
    return {l.split()[0]: float(l.split()[-1]) for l in out.splitlines() if " flt " in l}


def macmon():
    """各簇平均/最低频率、GPU 频率和占用。macmon 把 12 个 Performance 核叫 ecpu、6 个 Super 核叫 pcpu。"""
    d = json.loads(_run("macmon", "pipe", "-s", "1", "-i", "1000").strip().splitlines()[-1])
    r = {"cpu_usage": d.get("cpu_usage_pct", float("nan"))}
    gu = d.get("gpu_usage") or [float("nan"), float("nan")]
    r["gpu_mhz"], r["gpu_usage"] = gu[0], gu[1]
    for key, name in (("ecpu_cores", "perf"), ("pcpu_cores", "super")):
        fs = [c["freq_mhz"] for c in d.get(key, []) if isinstance(c, dict) and c.get("freq_mhz")]
        r[f"{name}_mhz_avg"] = sum(fs) / len(fs) if fs else float("nan")
        r[f"{name}_mhz_min"] = min(fs) if fs else float("nan")
    return r
