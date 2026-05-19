# Stack A — Plain vLLM on GKE (baseline)

This is the "what most teams ship first" reference deployment. One vLLM
container per pod, one GPU per pod, standard K8s Service, HPA scaling on
vLLM's own queue-depth metric via Managed Prometheus.

## What's in here

| File | Purpose |
|---|---|
| `01-vllm-deployment.yaml` | The Deployment. Bumps `--gpu-memory-utilization` to 0.92 and `--max-num-seqs` to 256 to max out the 96 GB RTX PRO 6000. |
| `02-vllm-service.yaml`    | ClusterIP service on port 8000. |
| `03-podmonitoring.yaml`   | Managed Prometheus scrape config for vLLM's `/metrics`. |
| `04-hpa.yaml`             | HPA that scales on `vllm:num_requests_waiting` (≥5 queued per replica → scale up). |

## Apply

```bash
kubectl apply -f 01-vllm-baseline/
kubectl -n vllm-base rollout status deploy/vllm-gemma --timeout=10m
```

First rollout takes 3–5 minutes (image pull + ~8 GB weight download). Subsequent
rollouts are <1 min because the HF cache is on the node's ephemeral storage.

## Smoke test

```bash
kubectl -n vllm-base port-forward svc/vllm-gemma 8000:8000 &
curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "google/gemma-4-E4B-it",
    "messages": [{"role":"user","content":"Say hi in 5 words."}],
    "max_tokens": 32
  }' | jq .
```

## Watch autoscaling

```bash
# In one window:
watch -n2 'kubectl -n vllm-base get hpa,pods'

# In another window, generate load (see 03-benchmark/) and watch the HPA
# scale from 1 → 4 replicas as queue depth crosses 5.
```

## Why this is the "baseline"

This stack has **no inference-aware routing**. The K8s Service load-balances
round-robin, which means a fresh request can land on a replica whose KV cache
is already at 95% capacity even when another replica is idle — degrading p99
latency. That's exactly the gap Stack B (llm-d) closes.
