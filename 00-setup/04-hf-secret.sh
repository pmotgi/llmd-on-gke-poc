#!/usr/bin/env bash
# 04-hf-secret.sh — Create the HuggingFace token secret in every namespace
# that needs to pull the Gemma weights. llm-d helmfiles expect a secret
# named `llm-d-hf-token` with key `HF_TOKEN`; the vLLM baseline pulls the
# same secret by its own name.
set -euo pipefail
: "${HF_TOKEN:?source 00-env.sh first}"
if [[ "$HF_TOKEN" == "hf_your_token_here" ]]; then
  echo "ERROR: HF_TOKEN is still the placeholder. Edit 00-env.sh." >&2
  exit 1
fi

for ns in "$NS_VLLM" "$NS_LLMD" "$NS_BENCH"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ns" create secret generic llm-d-hf-token \
    --from-literal=HF_TOKEN="$HF_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "[+] Secret 'llm-d-hf-token' applied to namespace '$ns'."
done
