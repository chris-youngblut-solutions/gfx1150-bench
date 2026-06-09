# gfx1150-bench

> Reproducible llama.cpp benchmark harness + results for the AMD Radeon 890M iGPU
> (gfx1150, RDNA 3.5 — Ryzen AI 9 HX 370 "Strix Point"). Apache-2.0 OR MIT. Status: results of 2026-05-22.

## What

Two scripts and their raw results:

- `bench-matrix.sh` — sweeps `llama-bench` across backend (Vulkan / ROCm-HIP) ×
  quant (Q4_0 → F16) × flash-attention × RADV env flags. 8 models, 3 reps,
  `pp512` + `tg128`. Emits a labelled CSV + log.
- `spec-bench.sh` — speculative-decoding probe: 14B/Q4_0 target + 1.5B/Q4_0 draft
  at `draft-max ∈ {4, 8, 16}` vs the no-draft baseline.
- `results/` — the raw CSVs, logs, and summaries the tables below are derived from.
- `docs/methodology.md` — pinned environment, roofline method, full findings.

## Results (2026-05-22 — best result per model across the env sweep)

Token-generation ceiling = measured bandwidth (~96 GB/s) ÷ weights read per token.
Each cell is the best value that model achieved across the swept env passes
(baseline / `nogttspill` / `+bfloat16`); per-cell env and all raw numbers are in
`results/matrix-20260522-205342.csv`. The *recommended* config is baseline-env
(see methodology — `nogttspill` regresses large models).

| Model | wt GB | tg ceiling | Vulkan tg | % roof | ROCm tg | Vulkan pp | ROCm pp |
|---|---:|---:|---:|---:|---:|---:|---:|
| 4B/Q4_0 | 2.36 | 40.6 | **34.18** | 84% | 24.72 | 671 | **831** |
| 4B/Q4_K_M | 2.49 | 38.5 | **32.41** | 84% | 21.86 | 647 | **671** |
| 4B/Q5_K_M | 2.88 | 33.3 | **28.82** | 87% | 19.44 | 657 | **709** |
| 4B/Q6_K | 3.30 | 29.1 | **25.17** | 87% | 18.54 | **614** | 445 |
| 4B/Q8_0 | 4.27 | 22.5 | **19.62** | 87% | 14.87 | 653 | **765** |
| 4B/F16 | 8.05 | 11.9 | **9.74** | 82% | 8.90 | 401 | **540** |
| 14B/Q4_0 | 8.51 | 11.3 | **10.27** | 91% | 8.28 | 196 | **269** |
| 14B/Q4_K_M | 8.98 | 10.7 | **9.30** | 87% | 7.42 | 178 | **212** |

- Vulkan wins token generation in every cell — +9% to +48% (the F16 outlier is
  the +9%; the quant cells run +24% to +48%). ROCm wins prompt processing in
  every cell but one — +4% to +37%.
- Vulkan token generation sits at 82-91% of the memory-bandwidth wall across all
  quants — flag-level optimization is exhausted on this device.

Speculative decoding (the one lever that beats the wall — a **tuning/benchmark
result on upstream llama.cpp binaries**, not a daemon or patch):

| config | tg t/s | accept % | speedup |
|---|---:|---:|---:|
| 14B/Q4_0 baseline | 9.54 | — | 1.00× |
| + 1.5B draft, dmax=4 | 18.42 | 74.2% | 1.93× |
| + 1.5B draft, dmax=8 | 18.71 | 77.8% | 1.96× |
| + 1.5B draft, dmax=16 | **23.17** | 71.7% | **2.43×** |

## Run

```bash
# prereqs: llama.cpp built with -DGGML_VULKAN (and optionally a build-rocm/),
# the GGUFs below in $GGUF_DIR, GPU clock locked:
echo high | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level

LLAMA_DIR=~/llama.cpp GGUF_DIR=~/models/gguf ./bench-matrix.sh full
LLAMA_DIR=~/llama.cpp GGUF_DIR=~/models/gguf ./spec-bench.sh
```

Models required (exact filenames the scripts expect):
- `bench-matrix.sh` — `Qwen3-4B-Instruct-2507-{Q4_0,Q4_K_M}.gguf` (core mode);
  `full` mode adds `{Q5_K_M,Q6_K,Q8_0,F16}` and
  `Qwen2.5-Coder-14B-Instruct-{Q4_0,Q4_K_M}.gguf`.
- `spec-bench.sh` — `Qwen2.5-Coder-14B-Instruct-Q4_0.gguf` (target) +
  `Qwen2.5-Coder-1.5B-Instruct-Q4_0.gguf` (draft). Spec decoding needs a
  draft from the same family/tokenizer as the target — the Coder family
  ships a 1.5B sibling, which is why the spec probe uses Qwen2.5-Coder
  while the matrix sweeps the newer Qwen3-4B.

Output lands in `./results/` as timestamped CSV/log/summary files.

## Limits

- Single device (OneXPlayer X1 Pro), single kernel/Mesa/llama.cpp pin
  (6.19.12 / Mesa 25.3.6 RADV / b9282). Numbers transfer to other gfx1150
  devices only to the extent their memory and TDP match.
- TDP at platform default — not maximized. Memory clock capped at 937 MHz; a
  raised power budget may move the bandwidth wall itself (untested here).
- Spec-decode probe ran at `-c 1024` (GTT ceiling); longer contexts untested.
- `results/` paths are scrubbed to relative form; re-runs will embed your paths.

## License

Apache-2.0 OR MIT, at your option (`LICENSE-APACHE`, `LICENSE-MIT`).
