#!/usr/bin/env bash
# bench-matrix.sh — gfx1150 / Radeon 890M llama.cpp baseline benchmark sweep.
#
# Sweeps llama-bench across: backend (Vulkan / ROCm-HIP) x quant x -fa x RADV
# env flags. Writes a labelled CSV + raw log to results/.
#
# Usage:  ./bench-matrix.sh [core|full]
#   core  (default) — 4B, Q4_0 + Q4_K_M, both backends, -fa 0/1, baseline+nogttspill
#   full            — adds the quant sweep (Q5_K_M/Q6_K/Q8_0/fp16), the 14B, +bfloat16
#
# Paths (override via env):
#   LLAMA_DIR — llama.cpp checkout with build/ (Vulkan) and optionally build-rocm/
#   GGUF_DIR  — directory holding the GGUF models named below
#   ROCM_DIR  — ROCm toolchain root (only needed for the ROCm sweep; skipped if unset)
#   OUT_DIR   — results directory (default: ./results next to this script)
#
# Pre-req: GPU clock locked high —
#   echo high | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level
set -uo pipefail

LLAMA="${LLAMA_DIR:-$HOME/llama.cpp}"
GGUF="${GGUF_DIR:-$HOME/models/gguf}"
ROCM="${ROCM_DIR:-}"
OUT="${OUT_DIR:-$(cd "$(dirname "$0")" && pwd)/results}"
MODE="${1:-core}"
mkdir -p "$OUT"
STAMP=$(date +%Y%m%d-%H%M%S)
CSV="$OUT/matrix-$STAMP.csv"
LOG="$OUT/matrix-$STAMP.log"

# --- model set per mode ---------------------------------------------------
if [[ "$MODE" == full ]]; then
  MODELS_4B=( "$GGUF"/Qwen3-4B-Instruct-2507-{Q4_0,Q4_K_M,Q5_K_M,Q6_K,Q8_0,F16}.gguf )
  MODELS_14B=( "$GGUF"/Qwen2.5-Coder-14B-Instruct-{Q4_0,Q4_K_M}.gguf )
  ENVS=( "baseline:" "nogttspill:RADV_PERFTEST=nogttspill" \
         "nogttspill+bf16:RADV_PERFTEST=nogttspill,bfloat16" )
else
  MODELS_4B=( "$GGUF"/Qwen3-4B-Instruct-2507-{Q4_0,Q4_K_M}.gguf )
  MODELS_14B=()
  ENVS=( "baseline:" "nogttspill:RADV_PERFTEST=nogttspill" )
fi

# --- environment record ---------------------------------------------------
PERF=$(cat /sys/class/drm/card1/device/power_dpm_force_performance_level 2>/dev/null)
SCLK=$(grep '\*' /sys/class/drm/card1/device/pp_dpm_sclk 2>/dev/null | tr -d ' ')
{
  echo "# bench-matrix $STAMP  mode=$MODE"
  echo "# perf_level=$PERF  sclk(active)=$SCLK"
  echo "# mesa=$(rpm -q --qf '%{VERSION}' mesa-vulkan-drivers 2>/dev/null)  llama=$("$LLAMA/build/bin/llama-cli" --version 2>&1 | grep -oE 'b[0-9]+' | head -1)  kernel=$(uname -r)"
} | tee "$LOG"
[[ "$PERF" == high ]] || echo "WARN: GPU not clock-locked (perf_level=$PERF). Lock it before trusting numbers." | tee -a "$LOG"
echo "backend,env,model,size,params,test,t/s" > "$CSV"

# --- one sweep: backend x env, all models x -fa in a single llama-bench ----
sweep() {
  local backend="$1" bin="$2" env_tag="$3" env_kv="$4"; shift 4
  local margs=()
  for m in "$@"; do [[ -f "$m" ]] && margs+=( -m "$m" ) || echo "SKIP missing $m" | tee -a "$LOG"; done
  [[ ${#margs[@]} -eq 0 ]] && { echo "no models for $backend/$env_tag" | tee -a "$LOG"; return 0; }
  echo "=== $backend / $env_tag ===" | tee -a "$LOG"
  ( # subshell so per-backend env doesn't leak
    if [[ "$backend" == rocm ]]; then
      export ROCM_PATH="$ROCM" HIP_PATH="$ROCM" \
             PATH="$ROCM/bin:$PATH" LD_LIBRARY_PATH="$ROCM/lib:$ROCM/lib/llvm/lib"
    fi
    [[ -n "$env_kv" ]] && export "${env_kv%%=*}=${env_kv#*=}"
    "$bin" "${margs[@]}" -ngl 99 -fa 0 -fa 1 -p 512 -n 128 -r 3 -o csv \
      2>>"$LOG" | tail -n +2 | sed "s/^/$backend,$env_tag,/" >> "$CSV"
  )
}

VK="$LLAMA/build/bin/llama-bench"
HIP="$LLAMA/build-rocm/bin/llama-bench"
for e in "${ENVS[@]}"; do
  tag="${e%%:*}"; kv="${e#*:}"
  sweep vulkan "$VK"  "$tag" "$kv" "${MODELS_4B[@]}" "${MODELS_14B[@]}"
  # ROCm ignores RADV_* flags — only run it once, on the baseline env, and
  # only when a ROCm toolchain root was supplied.
  [[ "$tag" == baseline && -n "$ROCM" ]] && sweep rocm "$HIP" "$tag" "" "${MODELS_4B[@]}" "${MODELS_14B[@]}"
done

echo
echo "DONE -> $CSV"
column -t -s, "$CSV" | tee -a "$LOG"
