#!/usr/bin/env bash
# 03-create-gpu-nodepool.sh — Provision the G4 GPU node pool.
#
# Branches on PROVISIONING_MODEL:
#   ON_DEMAND   → plain node pool, autoscaling 1–MAX_NODES
#   SPOT        → node pool with --spot + nvidia.com/gpu NoSchedule taint
#                 (Spot is the right default for inference replicas: stateless,
#                  fast restart, ~60–70% cheaper). Pods get matching toleration.
#   FLEX_START  → uses a custom compute class with flexStart enabled. Pods get
#                 created Pending; DWS allocates capacity for up to 7 days.
#                 Best for bursty benchmark runs you can wait a few minutes for.
#
# References:
#   • Accelerator-optimized G4: https://docs.cloud.google.com/compute/docs/accelerator-optimized-machines
#   • Cost-optimized provisioning on GKE: https://cloud.google.com/kubernetes-engine/docs/how-to/dws-flex-start-inference
set -euo pipefail
: "${PROJECT_ID:?source 00-env.sh first}"

case "$PROVISIONING_MODEL" in
  ON_DEMAND|SPOT|FLEX_START) ;;
  *) echo "ERROR: PROVISIONING_MODEL must be ON_DEMAND, SPOT, or FLEX_START" >&2; exit 1 ;;
esac

EXISTS=$(gcloud container node-pools list \
  --cluster="$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID" \
  --filter="name=$GPU_NODEPOOL_NAME" --format="value(name)" || true)

if [[ -n "$EXISTS" ]]; then
  echo "[=] Node pool $GPU_NODEPOOL_NAME already exists. Skipping create."
  echo "    Delete it first if you want to change provisioning mode:"
  echo "    gcloud container node-pools delete $GPU_NODEPOOL_NAME --cluster=$CLUSTER_NAME --region=$REGION"
  exit 0
fi

COMMON_ARGS=(
  --cluster="$CLUSTER_NAME"
  --project="$PROJECT_ID"
  --region="$REGION"
  --node-locations="$ZONE"
  --machine-type="$MACHINE_TYPE"
  --accelerator="type=$GPU_TYPE,count=$GPU_COUNT_PER_NODE,gpu-driver-version=LATEST"
  --node-taints="nvidia.com/gpu=present:NoSchedule"
  --node-labels="workload=inference,gpu=rtx-pro-6000"
  --ephemeral-storage-local-ssd count=4
  --disk-size="200"
  --image-type="COS_CONTAINERD"
  --enable-autoupgrade
  --enable-autorepair
  --enable-gvnic
  --scopes="https://www.googleapis.com/auth/cloud-platform"
)

case "$PROVISIONING_MODEL" in

  ON_DEMAND)
    echo "[+] Creating ON-DEMAND G4 node pool (autoscale ${MIN_NODES}–${MAX_NODES})..."
    gcloud container node-pools create "$GPU_NODEPOOL_NAME" \
      "${COMMON_ARGS[@]}" \
      --num-nodes="$MIN_NODES" \
      --enable-autoscaling \
      --min-nodes="$MIN_NODES" \
      --max-nodes="$MAX_NODES"
    ;;

  SPOT)
    echo "[+] Creating SPOT G4 node pool (autoscale ${MIN_NODES}–${MAX_NODES})..."
    gcloud container node-pools create "$GPU_NODEPOOL_NAME" \
      "${COMMON_ARGS[@]}" \
      --spot \
      --num-nodes="$MIN_NODES" \
      --enable-autoscaling \
      --min-nodes="$MIN_NODES" \
      --max-nodes="$MAX_NODES"

    echo "[+] Spot nodes carry an additional cloud.google.com/gke-spot=true label."
    echo "    All workload manifests in this POC already include the matching toleration."
    ;;

FLEX_START)
    echo "[+] Creating FLEX-START G4 node pool via Custom Compute Class..."
    gcloud container node-pools create "$GPU_NODEPOOL_NAME" \
      "${COMMON_ARGS[@]}" \
      --flex-start \
      --num-nodes=0 \
      --enable-autoscaling --min-nodes=0 --max-nodes="${MAX_NODES}" \
      --location-policy=ANY \
      --reservation-affinity=none \
      --no-enable-autorepair
    ;;
  esac

echo "[+] Done. Waiting briefly for nodes to register..."
sleep 20
kubectl get nodes -l workload=inference -o wide || true
