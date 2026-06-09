# Methodology — gfx1150 llama.cpp baseline and optimization

Token generation is memory-bandwidth-bound — it streams the whole model once per
token — so the work here is measuring the distance to a fixed roofline and closing
it, not collecting flags.

## Why a controlled re-baseline

An earlier Vulkan-vs-ROCm comparison on this device (4B: 23.6 vs 10.1 t/s
generation) was not trustworthy:

1. **Uncontrolled GPU clock.** `pp_dpm_sclk` showed the iGPU parked at
   600-625 MHz against a 2900 MHz ceiling (`power_dpm = auto`). Runs may not have
   been at full clock.
2. **K-quant weights, not the standard comparison quant.** Q5_K_M / Q4_K_M carry
   per-backend dequant variance. Scoreboards standardize on Q4_0 — the simplest
   quant, most uniformly optimized across backends — to isolate the backend.

The controlled re-run changed the conclusions materially: Vulkan 4B tg went
23.6 → 34.2 (+45%), 14B/Q4_K_M went 5.9 → 9.3 (+58%), and ROCm went
10.1 → 24.7 (+144% — it was hurt more by the parked clock). The original
"Vulkan wins decisively" overstated the gap roughly 3×.

## Pinned environment (every result is comparable to this)

| | |
|---|---|
| SoC | AMD Ryzen AI 9 HX 370 (Strix Point, Zen 5) |
| iGPU | Radeon 890M — gfx1150, RDNA 3.5, 16 CU |
| Memory | LPDDR5x — 120 GB/s theoretical, **~96 GB/s measured** (Vulkan) |
| Kernel | 6.19.12 (6.17 had a ~10% RADV decode regression) |
| Vulkan | Mesa 25.3.6 RADV (`VK_KHR_cooperative_matrix` rev 2; no coopmat2) |
| llama.cpp | b9282, `-DGGML_NATIVE=ON -DGGML_LTO=ON` |
| TDP | platform default — no TDP tooling active. Stable, not maximized. |
| GPU clock | `power_dpm_force_performance_level=high` for every run |

## The roofline

Ceiling ≈ bandwidth ÷ bytes-read-per-token. At ~96 GB/s measured:

| Model / quant | Weights | tg ceiling |
|---|---:|---:|
| 4B Q4_0 | 2.36 GB | ~40.6 t/s |
| 14B Q4_0 | 8.51 GB | ~11.3 t/s |

The wall moves only with faster RAM or a wider bus (a 256-bit Strix Halo reaches
~53 t/s where Strix Point reaches ~22). On this device the wall is fixed;
optimization = closing the gap to it. Prefill is compute-bound with a separate,
higher ceiling.

## Matrix findings (full tables in the README and `results/`)

1. **Vulkan token generation sits at 82-91% of the wall in every cell.** There is
   no meaningful kernel/flag headroom left; further gains require breaking the
   wall (speculative decoding) or moving it (memory clock / TDP).
2. **Vulkan wins tg (+9% to +48%; quant cells +24-48%, the F16 cell +9%), ROCm
   wins pp (+4% to +37%)** — consistently across the
   matrix (one outlier: 4B/Q6_K, where Vulkan also wins pp). Chat workloads favor
   Vulkan; long-context prefill favors ROCm.
3. **Flash attention is a win in every configuration tested** on RDNA 3.5 /
   Mesa 25.3.6 / b9282. The older "AMD iGPU FA falls back to CPU" behavior does
   not reproduce here. Keep `-fa 1`.
4. **`RADV_PERFTEST=nogttspill` regresses large models** (4B/Q8_0 tg −10%,
   14B/Q4_K_M tg −11%) and is a wash on small ones. Dropped from the baseline.
5. **`RADV_PERFTEST=bfloat16` is noise** (≤0.6% on Q4_0). Dropped.
6. **Quant ladder (Vulkan tg, 4B):** Q4_0 34.2 → Q4_K_M 32.4 → Q5_K_M 28.8 →
   Q6_K 25.2 → Q8_0 19.6 → F16 9.7 — tracks model size, as expected for a
   bandwidth-bound workload.

Best-known-good configuration:

```
Backend : Vulkan          Quant : Q4_0 (Q4_K_M for −5% tg / small quality gain)
Env     : none            Flags : -ngl 99 -fa 1
Clock   : power_dpm_force_performance_level=high
Build   : llama.cpp b9282  -DGGML_VULKAN -DGGML_NATIVE -DGGML_LTO
```

## Speculative decoding — breaking the wall

This is a **tuning/benchmark result against upstream llama.cpp binaries**
(`llama-completion` / `llama-speculative`), not a patch or a shipped service.

14B/Q4_0 target + 1.5B/Q4_0 draft, both fully offloaded, `-fa 1`, `-c 1024`:

| config | tg t/s | accept % | speedup |
|---|---:|---:|---:|
| baseline (no draft) | 9.54 | — | 1.00× |
| dmax=4 | 18.42 | 74.2% | 1.93× |
| dmax=8 | 18.71 | 77.8% | 1.96× |
| **dmax=16** | **23.17** | 71.7% | **2.43×** |

One verify pass over the 14B amortizes across ~11 accepted tokens at dmax=16 —
the result exceeds the single-stream bandwidth ceiling rather than approaching
it. dmax=16 beats dmax=8
despite a lower accept rate: per-batch amortization outweighs the wasted draft
tokens. The 14B moves from 9.5 to 23.2 t/s — past the dense 4B/Q8_0 (19.6) and
near the 4B/Q5_K_M (28.8).

## Untested levers

- **TDP raise** — memory clock caps at 937 MHz at the default power budget; a
  higher budget may widen bandwidth (the wall itself). Untested: needs a
  deliberate platform-power change and thermal headroom on a handheld.
- **MoE models** — low-active-parameter MoEs read only the active experts per
  token, so tg tracks active params, not total. Structurally dodges the wall.
  Untested here.
- **Longer-context spec-decode** — blocked at `-c 1024` by the default GTT
  ceiling; raising `amdgpu.gttsize` lifts it.

## Reproduce

`./bench-matrix.sh full` and `./spec-bench.sh` with `LLAMA_DIR` / `GGUF_DIR` set
(see README). Raw outputs for every number above are in `results/`.
