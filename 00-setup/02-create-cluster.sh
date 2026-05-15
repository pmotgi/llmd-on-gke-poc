#!/usr/bin/env bash
# 02-create-cluster.sh — Create the GKE Standard cluster (CPU-only default pool).
# We use Standard (not Autopilot) because llm-d needs control over node-level
# things like custom compute classes and explicit node selectors, and we want
# explicit visibility into autoscaling behavior for the POC writeup.
set -euo pipefail
: "${PROJECT_ID:?source 00-env.sh first}"

EXISTS=$(gcloud container clusters list \
  --project="$PROJECT_ID" --region="$REGION" \
  --filter="name=$CLUSTER_NAME" --format="value(name)" || true)

if [[ -n "$EXISTS" ]]; then
  echo "[=] Cluster $CLUSTER_NAME already exists in $REGION. Skipping create."
else
  echo "[+] Creating GKE Standard cluster $CLUSTER_NAME (this takes ~6–8 min)..."
  gcloud container clusters create "$CLUSTER_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --release-channel="$RELEASE_CHANNEL" \
    --cluster-version="$CLUSTER_VERSION" \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --enable-image-streaming \
    --enable-managed-prometheus \
    --gateway-api=standard \
    --num-nodes=1 \
    --machine-type=e2-standard-4 \
    --enable-ip-alias \
    --enable-autoupgrade \
    --enable-autorepair \
    --addons=GcsFuseCsiDriver,HttpLoadBalancing
fi

echo "[+] Fetching kubeconfig..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region="$REGION" --project="$PROJECT_ID"

kubectl get nodes
echo "[+] Done."
