#!/usr/bin/env bash
# 01-enable-apis.sh — Enable all GCP APIs needed for the POC.
set -euo pipefail
: "${PROJECT_ID:?source 00-env.sh first}"

gcloud config set project "$PROJECT_ID"

echo "[+] Enabling APIs (this is idempotent and may take ~2 min)..."
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  artifactregistry.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  networkservices.googleapis.com \
  trafficdirector.googleapis.com \
  --project="$PROJECT_ID"

echo "[+] Done."
