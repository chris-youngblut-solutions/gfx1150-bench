#!/usr/bin/env bash
# spec-bench.sh — speculative-decoding probe for the 14B coder on gfx1150.
#
# Baseline: llama-completion on the 14B target alone.
# Speculative: llama-speculative (target + 1.5B draft) at draft-max ∈ {4,8,16}.
# Per-run output saved to results/spec-$STAMP-<label>.log; perf is parsed from each.
#
# Paths (override via env):
#   LLAMA_DIR — llama.cpp checkout with build/bin
#   GGUF_DIR  — directory holding the GGUF models named below
#   OUT_DIR   — results directory (default: ./results next to this script)
#
# Note: -c 1024 keeps total GPU memory within a 13.5 GiB GTT ceiling (raise
# amdgpu.gttsize to lift it). Pre-req: power_dpm_force_performance_level=high.
set -uo pipefail

D="${LLAMA_DIR:-$HOME/llama.cpp}/build/bin"
GGUF="${GGUF_DIR:-$HOME/models/gguf}"
TARGET="$GGUF/Qwen2.5-Coder-14B-Instruct-Q4_0.gguf"
DRAFT="$GGUF/Qwen2.5-Coder-1.5B-Instruct-Q4_0.gguf"
OUT="${OUT_DIR:-$(cd "$(dirname "$0")" && pwd)/results}"
STAMP=$(date +%Y%m%d-%H%M%S)
N=256
CTX=1024

mkdir -p "$OUT"
PERF=$(cat /sys/class/drm/card1/device/power_dpm_force_performance_level)
SUM="$OUT/spec-$STAMP.md"
{
  echo "# spec-bench $STAMP"
  echo
  echo "- perf_level: $PERF   ·   n_predict: $N   ·   ctx: $CTX"
  echo "- target: 14B/Q4_0  ·  draft: 1.5B/Q4_0  ·  both fully offloaded (-ngl 99 -ngld 99)"
  echo "- baseline binary: llama-completion   ·   spec binary: llama-speculative"
  echo
  echo "| config | tg t/s | accept rate | notes |"
  echo "|---|---:|---:|---|"
} | tee "$SUM"

PROMPT="Write a Python function that finds all prime numbers up to N using the Sieve of Eratosthenes. Include type hints and a docstring, then add a small example call printing the primes up to 100."

# --- Baseline ---
LBL="baseline"
L="$OUT/spec-$STAMP-$LBL.log"
echo "=== running $LBL ==="
"$D/llama-completion" -m "$TARGET" -ngl 99 -fa 1 -c "$CTX" -p "$PROMPT" -n "$N" </dev/null > "$L" 2>&1
TG=$(grep -E 'common_perf_print:\s+eval time' "$L" | tail -1 | grep -oE '[0-9.]+ tokens per second' | head -1)
echo "| $LBL | ${TG:-?} | — | — |" | tee -a "$SUM"

# --- Speculative sweep ---
for DMAX in 4 8 16; do
  LBL="spec-dmax$DMAX"
  L="$OUT/spec-$STAMP-$LBL.log"
  echo "=== running $LBL ==="
  "$D/llama-speculative" -m "$TARGET" -md "$DRAFT" \
      -ngl 99 -ngld 99 -fa 1 -c "$CTX" \
      --spec-draft-n-max "$DMAX" --spec-draft-n-min 1 \
      -p "$PROMPT" -n "$N" </dev/null > "$L" 2>&1
  # llama-speculative prints a final summary block — capture the key fields.
  # The decode line reads "decoded N tokens in S seconds, speed: X t/s".
  TG=$(grep -E 'decoded' "$L" | tail -1 | grep -oE '[0-9]+(\.[0-9]+)? t(okens?)?/s' | head -1)
  if [[ -z "$TG" ]]; then
    TG=$(grep -E 'encoded|decoded|drafted|accept' "$L" | tail -8 | grep -oE '[0-9]+(\.[0-9]+)? t(okens?)?/s' | head -1)
  fi
  if [[ -z "$TG" ]]; then
    TG=$(grep -E 'common_perf_print:\s+eval time' "$L" | tail -1 | grep -oE '[0-9.]+ tokens per second' | head -1)
  fi
  # The accept line reads "accept    = NN.NNN%"
  ACC=$(grep -E '^.*accept\s+=' "$L" | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | head -1)
  if [[ -z "$ACC" ]]; then
    ACC=$(grep -E 'accept' "$L" | tail -2 | tr '\n' ' ' | grep -oE 'n_accept = [0-9]+|accept_rate[^ ]*[ =:][^ ]*' | head -1)
  fi
  echo "| $LBL | ${TG:-?} | ${ACC:-—} | dmax=$DMAX |" | tee -a "$SUM"
done

echo
echo "DONE — summary: $SUM"
echo "Per-run logs: $OUT/spec-$STAMP-*.log"
