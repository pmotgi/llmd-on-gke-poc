#!/usr/bin/env bash
# teardown.sh — Tear down everything created by this POC.
# Order matters: workloads → GPU node pool → cluster.
set -uo pipefail        # NOT -e: we want best-effort, continue on errors
: "${PROJECT_ID:?source 00-env.sh first}"

echo "[!] This will DELETE the cluster, GPU node pool, and all workloads."
read -p "    Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 1; }

echo "[+] Deleting benchmark Jobs ..."
kubectl delete -f 03-benchmark/run-benchmark-vllm.yaml --ignore-not-found
kubectl delete -f 03-benchmark/run-benchmark-llmd.yaml --ignore-not-found

echo "[+] Uninstalling llm-d stack ..."
helmfile destroy -n "$NS_LLMD" || true
kubectl delete ns "$NS_LLMD" --ignore-not-found

echo "[+] Deleting vLLM baseline ..."
kubectl delete -f 01-vllm-baseline/ --ignore-not-found
kubectl delete ns "$NS_VLLM" --ignore-not-found
kubectl delete ns "$NS_BENCH" --ignore-not-found

echo "[+] Deleting compute class (no-op if Flex-start wasn't used) ..."
kubectl delete computeclass g4-flex-start --ignore-not-found

echo "[+] Deleting GPU node pool ..."
gcloud container node-pools delete "$GPU_NODEPOOL_NAME" \
  --cluster="$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID" --quiet

echo "[+] Deleting GKE cluster ..."
gcloud container clusters delete "$CLUSTER_NAME" \
  --region="$REGION" --project="$PROJECT_ID" --quiet

echo "[+] Done."
