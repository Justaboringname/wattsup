import sys, time, torch
secs = float(sys.argv[1]); n = int(sys.argv[2]); dt = {"f16": torch.float16, "f32": torch.float32}[sys.argv[3]]
d = torch.device("mps")
a = torch.randn(n, n, device=d, dtype=dt); b = torch.randn(n, n, device=d, dtype=dt)
t0 = time.time(); it = 0
while time.time() - t0 < secs:
    for _ in range(8):
        c = a @ b
        a = torch.tanh(c * 1e-3)
    torch.mps.synchronize(); it += 8
print(f"{it} matmuls of {n}x{n} {sys.argv[3]} in {time.time()-t0:.1f}s")
