#!/usr/bin/env bash
# 00-env.sh — single source of truth for the entire POC.
# Edit values below, then `source 00-env.sh`.

# ----- GCP project / region -----
export PROJECT_ID="${PROJECT_ID:-northam-ce-mlai-tpu}"
export REGION="${REGION:-us-east5}"
export ZONE="${ZONE:-us-east5-a}"  # G4 fractional GPU types only in us-central1-b;
                                      # full g4-standard-48 is in more zones — see
                                      # https://docs.cloud.google.com/compute/docs/regions-zones/gpu-regions-zones

# ----- Cluster -----
export CLUSTER_NAME="${CLUSTER_NAME:-pmotgi-tr-llmd-poc}"
export CLUSTER_VERSION="${CLUSTER_VERSION:-1.34}"   # rapid channel
export RELEASE_CHANNEL="${RELEASE_CHANNEL:-rapid}"

# ----- GPU node pool -----
export GPU_NODEPOOL_NAME="${GPU_NODEPOOL_NAME:-gpu-g4-spot}"
export MACHINE_TYPE="${MACHINE_TYPE:-g4-standard-48}"
export GPU_TYPE="${GPU_TYPE:-nvidia-rtx-pro-6000}"
export GPU_COUNT_PER_NODE="${GPU_COUNT_PER_NODE:-1}"
export MIN_NODES="${MIN_NODES:-1}"
export MAX_NODES="${MAX_NODES:-8}"

# ----- Provisioning model: ON_DEMAND | SPOT | FLEX_START -----
# ON_DEMAND  — guaranteed capacity, highest cost
# SPOT       — ~60–70% cheaper, preemptible, 30s eviction notice
# FLEX_START — DWS-allocated, capacity request, runs ≤7 days, cheapest reliable burst
export PROVISIONING_MODEL="${PROVISIONING_MODEL:-SPOT}"

# ----- Model -----
# Pick ONE. Both work; gemma-3n is more battle-tested in vLLM today.
export MODEL_ID="${MODEL_ID:-google/gemma-4-E4B-it}"
# export MODEL_ID="google/gemma-4-E4B-it"

# HuggingFace token (read scope) — accept the model license first on hf.co
export HF_TOKEN="${HF_TOKEN:-hf_your_token_here}"

# ----- Namespaces -----
export NS_VLLM="${NS_VLLM:-vllm-base}"
export NS_LLMD="${NS_LLMD:-llm-d}"
export NS_BENCH="${NS_BENCH:-bench}"

# ----- Derived -----
export GKE_GATEWAY_CLASS="${GKE_GATEWAY_CLASS:-gke-l7-regional-external-managed}"

echo "===================================================================="
echo "  Project:       $PROJECT_ID"
echo "  Region/Zone:   $REGION / $ZONE"
echo "  Cluster:       $CLUSTER_NAME"
echo "  Machine type:  $MACHINE_TYPE  ($GPU_COUNT_PER_NODE × $GPU_TYPE)"
echo "  Provisioning:  $PROVISIONING_MODEL"
echo "  Model:         $MODEL_ID"
echo "===================================================================="
