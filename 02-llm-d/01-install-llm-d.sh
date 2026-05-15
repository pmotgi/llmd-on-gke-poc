#!/usr/bin/env bash
# 01-install-llm-d.sh — Install the llm-d "optimized baseline" stack into the
# cluster, configured for Gemma + G4 GPUs.
#
# This follows the llm-d inference-scheduling guide:
#   https://llm-d.ai/docs/guide/Installation/inference-scheduling
#
# Key adaptations for GKE + G4:
#   • environment: gke (vs default cuda for self-hosted clusters) — picks up
#     the GKE-managed Gateway controller instead of installing istio
#   • modelArtifact pointed at Gemma (env-driven)
#   • resources scaled to a single RTX PRO 6000
#   • replicas: 1 by default; HPA from 03-hpa.yaml takes over
set -euo pipefail
: "${PROJECT_ID:?source 00-env.sh first}"
: "${NS_LLMD:?source 00-env.sh first}"

WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

echo "[+] Cloning llm-d (release v0.7) into $WORKDIR ..."
git clone --depth 1 --branch v0.7.0 https://github.com/llm-d/llm-d.git "$WORKDIR/llm-d"

cd "$WORKDIR/llm-d/guides/optimized-baseline"

# Each repo release ships an `install-deps.sh` that installs the
# Gateway API Inference Extension CRDs, Kgateway/GKE Gateway provider plumbing,
# and the helmfile chart dependencies. Idempotent.
echo "[+] Running llm-d install-deps.sh ..."
./install-deps.sh

# Copy our customized values.yaml on top of the shipped manifests.
echo "[+] Overlaying Gemma+G4 values.yaml ..."
cp "${OLDPWD:-$PWD/../../../..}/02-llm-d/02-values.yaml" \
   ./ms-inference-scheduling/values-gemma-g4.yaml

# Render with helmfile, targeting the gke external-managed gateway flavor.
# This deploys:
#   • InferencePool + InferenceObjective (selecting our vLLM pods)
#   • Endpoint Picker Pod (EPP) — the smart router; scores backends on
#     KV-cache util, queue depth, and prefix-cache locality
#   • Gateway + HTTPRoute (gateway class: gke-l7-regional-external-managed)
#   • vLLM model-server StatefulSet pinned to RTX PRO 6000 nodes
echo "[+] helmfile apply (environment=gke, namespace=$NS_LLMD) ..."
helmfile apply \
  -e gke \
  -n "$NS_LLMD" \
  --state-values-set "modelserver.values-file=values-gemma-g4.yaml"

echo "[+] Waiting for endpoint picker + model servers to come up..."
kubectl -n "$NS_LLMD" rollout status deploy/ms-inference-scheduling-epp --timeout=5m
kubectl -n "$NS_LLMD" rollout status statefulset/ms-inference-scheduling --timeout=15m

echo "[+] Applying HPA..."
kubectl apply -f "${OLDPWD:-$PWD/../../../..}/02-llm-d/03-hpa.yaml"

echo
echo "[+] llm-d is up. Gateway address:"
kubectl -n "$NS_LLMD" get gateway -o wide
echo
echo "Try it:"
echo "  GW=\$(kubectl -n $NS_LLMD get gateway -o jsonpath='{.items[0].status.addresses[0].value}')"
echo "  curl -s http://\$GW/v1/chat/completions -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
