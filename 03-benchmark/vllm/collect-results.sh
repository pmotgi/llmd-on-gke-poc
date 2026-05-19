#!/usr/bin/env bash
# collect-results.sh — Summarize the JSONs produced by run-sweep.sh.
#
# `vllm bench serve --save-result` writes a single JSON per run with keys like:
#   request_throughput, output_throughput, total_token_throughput,
#   mean_ttft_ms, p50_ttft_ms, p99_ttft_ms,
#   mean_tpot_ms, p50_tpot_ms, p99_tpot_ms,
#   mean_itl_ms, p99_itl_ms,
#   completed, total_input_tokens, total_output_tokens, duration, ...
#
# This script prints a comparison table per stack across all rates, plus an
# auto-detected "knee" — the highest rate that meets the SLOs below.
#
# Override SLOs:
#   TTFT_P99_SLO_MS=800 TPOT_P99_SLO_MS=80 bash collect-results.sh

set -euo pipefail
TTFT_P99_SLO_MS="${TTFT_P99_SLO_MS:-500}"
TPOT_P99_SLO_MS="${TPOT_P99_SLO_MS:-50}"

command -v jq >/dev/null || { echo "Need jq installed (apt/brew install jq)" >&2; exit 1; }

print_stack() {
  local stack="$1"
  local files=( ./results/${stack}-rate*.json )
  [[ -e "${files[0]}" ]] || { echo "  (no result files for $stack)"; return; }

  printf "\n  %-8s %-10s %-12s %-12s %-10s %-10s %-10s %-12s %s\n" \
    "rate" "req_thru" "out_tok/s" "tot_tok/s" "ttft_p50" "ttft_p99" "tpot_p50" "tpot_p99" "meets_slo"
  printf "  %s\n" "----------------------------------------------------------------------------------------------------"

  local knee_rate=0 knee_out_tps=0
  for f in $(ls ./results/${stack}-rate*.json | sort -t e -k3n); do
    local rate ttft50 ttft99 tpot50 tpot99 req_thru out_thru tot_thru meets
    rate=$(basename "$f" | sed -E "s/${stack}-rate([0-9]+)\.json/\1/")
    req_thru=$(jq -r '.request_throughput' "$f")
    out_thru=$(jq -r '.output_throughput' "$f")
    tot_thru=$(jq -r '.total_token_throughput' "$f")
    ttft50=$(jq -r '.p50_ttft_ms // .median_ttft_ms' "$f")
    ttft99=$(jq -r '.p99_ttft_ms' "$f")
    tpot50=$(jq -r '.p50_tpot_ms // .median_tpot_ms' "$f")
    tpot99=$(jq -r '.p99_tpot_ms' "$f")

    if awk -v a="$ttft99" -v b="$TTFT_P99_SLO_MS" -v c="$tpot99" -v d="$TPOT_P99_SLO_MS" \
         'BEGIN{exit !(a<=b && c<=d)}'; then
      meets="YES"
      # Track highest passing rate by output throughput
      if awk -v a="$out_thru" -v b="$knee_out_tps" 'BEGIN{exit !(a>b)}'; then
        knee_rate="$rate"; knee_out_tps="$out_thru"
      fi
    else
      meets="no"
    fi

    printf "  %-8s %-10.2f %-12.1f %-12.1f %-10.1f %-10.1f %-10.2f %-12.2f %s\n" \
      "$rate" "$req_thru" "$out_thru" "$tot_thru" "$ttft50" "$ttft99" "$tpot50" "$tpot99" "$meets"
  done

  if [[ "$knee_rate" != "0" ]]; then
    printf "\n  → KNEE for %s: rate=%s QPS, output=%.1f tok/s (passes p99 TTFT≤%sms, p99 TPOT≤%sms)\n" \
      "$stack" "$knee_rate" "$knee_out_tps" "$TTFT_P99_SLO_MS" "$TPOT_P99_SLO_MS"
  else
    printf "\n  → NO rate met SLOs for %s. Loosen SLOs or extend rate sweep.\n" "$stack"
  fi
}

echo "===================================================================="
echo "  BENCHMARK SUMMARY"
echo "  SLOs: p99 TTFT ≤ ${TTFT_P99_SLO_MS}ms,  p99 TPOT ≤ ${TPOT_P99_SLO_MS}ms"
echo "===================================================================="

echo
echo "STACK A — vLLM baseline"
print_stack vllm

echo
echo "STACK B — llm-d optimized"
print_stack llmd

echo
echo "Raw JSONs are in ./results/. Use jq to drill deeper, e.g.:"
echo "  jq '.input_lens, .output_lens' ./results/vllm-rate40.json"
