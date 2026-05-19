#!/usr/bin/env bash
# run-sweep.sh — Sweep request rates against both stacks and find the knee.
#
# vllm bench serve runs one rate per invocation, so a sweep = a loop. For each
# rate, this script:
#   1. Templates the Job manifest with that rate.
#   2. Submits + waits.
#   3. Copies the JSON result to ./results/<stack>-rate<N>.json.
#
# The total time is ~ (sum of (num-prompts / rate) for each rate) plus pod
# startup overhead. With defaults below: ~15 min per stack.
#
# Usage:
#   bash run-sweep.sh vllm     # benchmark Stack A only
#   bash run-sweep.sh llmd     # benchmark Stack B only
#   bash run-sweep.sh both     # both, sequentially (don't run in parallel!)

set -euo pipefail
TARGET="${1:-both}"
RATES=(5 10 20 40 80)      # QPS levels to sweep. Edit if you want finer/coarser.
NUM_PROMPTS=600            # per run. With rate=10 → ~60s of traffic.
NS="${NS_BENCH:-bench}"

mkdir -p results

run_one() {
  local stack="$1" rate="$2"
  local job_file
  case "$stack" in
    vllm) job_file="run-benchmark-vllm.yaml"; job_name="bench-vllm-baseline"; result_file="bench-vllm-baseline.json" ;;
    llmd) job_file="run-benchmark-llmd.yaml"; job_name="bench-llmd";          result_file="bench-llmd.json" ;;
    *) echo "Unknown stack: $stack" >&2; exit 1 ;;
  esac

  echo
  echo "================================================================"
  echo "  [$stack] rate=${rate} QPS, num_prompts=${NUM_PROMPTS}"
  echo "================================================================"

  # Delete any prior Job of the same name (kubectl apply won't replace a
  # completed Job's pod template).
  kubectl -n "$NS" delete job "$job_name" --ignore-not-found --wait=true

  # Render with overrides via kubectl patch-style sed (no kustomize needed).
  sed -e "s|--request-rate=10|--request-rate=${rate}|" \
      -e "s|--num-prompts=1200|--num-prompts=${NUM_PROMPTS}|" \
      "$job_file" | kubectl apply -f -

  echo "[+] Waiting for job to complete (timeout 30m)..."
  kubectl -n "$NS" wait --for=condition=complete --timeout=30m "job/$job_name" \
    || { echo "ERROR: job did not complete"; kubectl -n "$NS" logs -l job-name="$job_name" --tail=50; return 1; }

  POD=$(kubectl -n "$NS" get pod -l job-name="$job_name" -o jsonpath='{.items[0].metadata.name}')
  kubectl -n "$NS" logs "$POD" | awk '/--- RESULT JSON START ---/{flag=1; next} /--- RESULT JSON END ---/{flag=0} flag' > "./results/${stack}-rate${rate}.json"
  if [[ ! -s "./results/${stack}-rate${rate}.json" ]]; then
    echo "ERROR: Failed to extract JSON result from pod logs for ${stack} rate ${rate}" >&2
    return 1
  fi
  echo "[+] Saved ./results/${stack}-rate${rate}.json"
}

case "$TARGET" in
  vllm) for r in "${RATES[@]}"; do run_one vllm "$r"; done ;;
  llmd) for r in "${RATES[@]}"; do run_one llmd "$r"; done ;;
  both)
    for r in "${RATES[@]}"; do run_one vllm "$r"; done
    for r in "${RATES[@]}"; do run_one llmd "$r"; done
    ;;
  *) echo "Usage: $0 {vllm|llmd|both}" >&2; exit 1 ;;
esac

echo
echo "[+] Sweep complete. Run 'bash collect-results.sh' for the summary table."
