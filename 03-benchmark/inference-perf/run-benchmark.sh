#!/usr/bin/env bash
# run-benchmark.sh — Run inference-perf against llm-d and/or vllm-base
# across multiple configurations (multi-turn, distributions, plain).
#
# Usage:
#   bash run-benchmark.sh llmd     # benchmark llm-d (EPP optimized)
#   bash run-benchmark.sh vllm     # benchmark vllm baseline
#   bash run-benchmark.sh both     # benchmark both sequentially

set -euo pipefail

TARGET="${1:-both}"
NS="bench"

CONFIGS=("plain" "distributions" "multi-turn")

mkdir -p results

run_one() {
  local target="$1"
  local config_name="$2"
  local job_file
  local job_name
  local prefix

  # Map config file name
  local config_file="config-${config_name}.yml"

  case "$target" in
    llmd)
      job_file="run-benchmark-llmd.yaml"
      job_name="bench-inference-perf-llmd"
      prefix="llmd_${config_name}"
      ;;
    vllm)
      job_file="run-benchmark-vllm.yaml"
      job_name="bench-inference-perf-vllm"
      prefix="vllm_${config_name}"
      ;;
    *)
      echo "Unknown target: $target" >&2
      exit 1
      ;;
  esac

  echo ""
  echo "========================================================================"
  echo "  [Config: $config_name] Starting Benchmark: $target"
  echo "  Job: $job_name ($job_file) with $config_file"
  echo "========================================================================"

  echo "[+] Updating ConfigMap inference-perf-config in namespace $NS with $config_file..."
  kubectl -n "$NS" create configmap inference-perf-config \
    --from-file=config.yml="$config_file" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "[+] Cleaning up any existing job of the same name..."
  kubectl -n "$NS" delete job "$job_name" --ignore-not-found --wait=true

  echo "[+] Applying job (with report prefix $prefix)..."
  sed -e "s|report_file_prefix llmd|report_file_prefix ${prefix}|" \
      -e "s|report_file_prefix vllm|report_file_prefix ${prefix}|" \
      -e "s|/results/llmd|/results/${prefix}|" \
      -e "s|/results/vllm|/results/${prefix}|" \
      "$job_file" | kubectl apply -f -

  echo "[+] Waiting for job to complete (timeout: 45m)..."
  kubectl -n "$NS" wait --for=condition=complete --timeout=45m "job/$job_name" \
    || {
      echo "[-] ERROR: Job $job_name failed or timed out. Fetching tail of pod logs..." >&2
      kubectl -n "$NS" logs -l job-name="$job_name" --tail=100 >&2
      exit 1
    }

  echo "[+] Job completed! Fetching logs and saving to local results..."
  local pod_name
  pod_name=$(kubectl -n "$NS" get pod -l job-name="$job_name" -o jsonpath='{.items[0].metadata.name}')
  
  # Save the raw logs
  kubectl -n "$NS" logs "$pod_name" > "results/inference-perf-${prefix}.log"
  echo "[+] Raw logs saved to results/inference-perf-${prefix}.log"

  # Output a summary
  echo ""
  echo "========================================= SUMMARY OF RESULTS ($prefix) ========================================="
  kubectl -n "$NS" logs "$pod_name" | awk '/--- REPORT CONTENTS ---/{flag=1; next} /--- BENCHMARK COMPLETED ---/{flag=0} flag' || true
  echo "================================================================================================================"
}

case "$TARGET" in
  llmd)
    for cfg in "${CONFIGS[@]}"; do
      run_one llmd "$cfg"
    done
    ;;
  vllm)
    for cfg in "${CONFIGS[@]}"; do
      run_one vllm "$cfg"
    done
    ;;
  both)
    for cfg in "${CONFIGS[@]}"; do
      run_one vllm "$cfg"
      run_one llmd "$cfg"
    done
    ;;
  *)
    echo "Usage: $0 {llmd|vllm|both}" >&2
    exit 1
    ;;
esac

echo ""
echo "[+] ALL benchmark sweeps finished. Raw logs and report contents saved to local results directory."
