#!/usr/bin/env bash
# 01-install-llm-d.sh — Install the llm-d "optimized baseline" stack into the
# cluster, configured for Gemma + G4 GPUs.
#
# Follows the upstream guide:
#   https://llm-d.ai/docs/guide/Installation/inference-scheduling
#
# This version auto-discovers the path to the inference-scheduling chart
# instead of hardcoding it, since upstream renamed/restructured between
# releases.
set -euo pipefail
: "${PROJECT_ID:?source 00-env.sh first}"
: "${NS_LLMD:?source 00-env.sh first}"

# Capture our repo root BEFORE we cd anywhere, so we can find 02-values.yaml later.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALUES_SRC="$REPO_ROOT/02-llm-d/02-values.yaml"
[[ -f "$VALUES_SRC" ]] || { echo "ERROR: $VALUES_SRC not found" >&2; exit 1; }

WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

# Use `main` rather than a pinned tag — the upstream tagging convention has
# changed and `--branch v0.7.0` may resolve to a stale commit. If you need
# determinism, replace `main` with a specific commit hash.
echo "[+] Cloning llm-d (main) into $WORKDIR ..."
git clone --depth 1 https://github.com/llm-d/llm-d.git "$WORKDIR/llm-d"

# Find the inference-scheduling chart directory wherever it lives in this checkout.
# Recent layouts have it under guides/inference-scheduling/ rather than the older
# guides/optimized-baseline/ms-inference-scheduling/.
CHART_DIR=""
for candidate in \
    "$WORKDIR/llm-d/guides/inference-scheduling" \
    "$WORKDIR/llm-d/guides/optimized-baseline/ms-inference-scheduling" \
    "$WORKDIR/llm-d/guides/optimized-baseline"; do
  if [[ -d "$candidate" && ( -f "$candidate/helmfile.yaml" || -f "$candidate/helmfile.yaml.gotmpl" ) ]]; then
    CHART_DIR="$candidate"
    break
  fi
done

if [[ -z "$CHART_DIR" ]]; then
  echo "ERROR: could not find a helmfile.yaml under $WORKDIR/llm-d/guides/"
  echo "Available guide directories:"
  find "$WORKDIR/llm-d/guides" -maxdepth 2 -type d
  exit 1
fi
echo "[+] Using chart at: $CHART_DIR"

# Install client dependencies (kgateway/gke gateway provider, CRDs, helmfile plugins).
# The path to install-deps.sh also moved between releases — try both.
if   [[ -x "$WORKDIR/llm-d/helpers/client-setup/install-deps.sh" ]]; then
  DEPS_SCRIPT="$WORKDIR/llm-d/helpers/client-setup/install-deps.sh"
elif [[ -x "$CHART_DIR/install-deps.sh" ]]; then
  DEPS_SCRIPT="$CHART_DIR/install-deps.sh"
else
  DEPS_SCRIPT=""
fi

if [[ -n "$DEPS_SCRIPT" ]]; then
  echo "[+] Running $DEPS_SCRIPT ..."
  bash "$DEPS_SCRIPT"
else
  echo "[!] No install-deps.sh found in this checkout; assuming deps already installed."
fi

# Copy our overrides into the chart directory.
echo "[+] Overlaying Gemma+G4 values.yaml into $CHART_DIR ..."
cp "$VALUES_SRC" "$CHART_DIR/values-gemma-g4.yaml"

# Render with helmfile, targeting the GKE externally-managed gateway flavor.
cd "$CHART_DIR"
echo "[+] helmfile apply (environment=gke, namespace=$NS_LLMD) ..."
helmfile apply \
  -e gke \
  -n "$NS_LLMD" \
  --state-values-set "modelserver.values-file=values-gemma-g4.yaml"

echo "[+] Waiting for endpoint picker + model servers to come up..."
# Be tolerant of name changes; wait for whatever deploys came up in the namespace.
kubectl -n "$NS_LLMD" wait --for=condition=Available deploy --all --timeout=5m  || true
kubectl -n "$NS_LLMD" rollout status statefulset --timeout=15m || true

echo "[+] Applying HPA..."
kubectl apply -f "$REPO_ROOT/02-llm-d/03-hpa.yaml"

echo
echo "[+] llm-d is up. Resources in namespace $NS_LLMD:"
kubectl -n "$NS_LLMD" get gateway,inferencepool,inferenceobjective,deploy,sts,svc 2>/dev/null || true
echo
echo "Find the gateway service name with:"
echo "  kubectl -n $NS_LLMD get svc | grep gateway"
echo "And update --base-url in 03-benchmark/run-benchmark-llmd.yaml to match."
