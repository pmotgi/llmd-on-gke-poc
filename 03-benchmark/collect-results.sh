#!/usr/bin/env bash
# collect-results.sh — Wait for both benchmark Jobs to finish, then pull
# their results into ./results/ and print a side-by-side summary.
set -euo pipefail
: "${NS_BENCH:?source 00-env.sh first}"

mkdir -p results

for job in bench-vllm-baseline bench-llmd; do
  echo "[+] Waiting for $job ..."
  kubectl -n "$NS_BENCH" wait --for=condition=complete --timeout=2h "job/$job"

  POD=$(kubectl -n "$NS_BENCH" get pod -l job-name=$job -o jsonpath='{.items[0].metadata.name}')
  echo "[+] Copying results from $POD ..."
  kubectl -n "$NS_BENCH" cp "$POD:/results" "./results/$job" || true
  kubectl -n "$NS_BENCH" logs "$POD" > "./results/$job.log" || true
done

echo
echo "============================================================"
echo "                 BENCHMARK SUMMARY"
echo "============================================================"
for job in bench-vllm-baseline bench-llmd; do
  SUMMARY="./results/$job/summary.json"
  if [[ -f "$SUMMARY" ]]; then
    echo
    echo "--- $job ---"
    jq -r '
      "Knee-point QPS:       " + (.knee.qps           | tostring),
      "Output tok/s/replica: " + (.knee.output_tps    | tostring),
      "p50 TTFT (ms):        " + (.knee.ttft_p50_ms   | tostring),
      "p99 TTFT (ms):        " + (.knee.ttft_p99_ms   | tostring),
      "p50 TPOT (ms):        " + (.knee.tpot_p50_ms   | tostring),
      "p99 TPOT (ms):        " + (.knee.tpot_p99_ms   | tostring),
      "KV-cache util at knee:" + (.knee.kv_cache_util | tostring),
      "Replicas at knee:     " + (.knee.replicas      | tostring)
    ' "$SUMMARY"
  else
    echo "WARN: no summary.json for $job — check ./results/$job.log"
  fi
done
echo
echo "Full per-request traces and time series are in ./results/"
