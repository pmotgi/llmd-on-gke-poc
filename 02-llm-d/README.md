# Stack B — llm-d Optimized Baseline on GKE

This is the [llm-d v0.7 "optimized baseline"](https://github.com/llm-d/llm-d/tree/main/guides/optimized-baseline)
wired up for **Gemma on G4 GPUs**.

## What llm-d adds over Stack A

| Layer | Stack A (vLLM baseline) | Stack B (llm-d) |
|---|---|---|
| Routing | K8s Service round-robin | **GKE Inference Gateway** + **EPP (Endpoint Picker)** with prefix-cache- and KV-cache-aware scoring |
| Discovery | Pod IPs from Service endpoints | **InferencePool** CRD; EPP watches it and tracks per-pod inference state |
| Autoscale signal | `num_requests_waiting` | KV-cache utilization (proactive) + queue depth (reactive) |
| Cold start | Pod ready when /health 200s | Same, but EPP only routes to pods marked Ready by the InferencePool |

The model server itself (vLLM) is **identical** between the two stacks — same
image, same args. That's deliberate. The only thing changing is what's in front
of vLLM.

## Files

| File | Purpose |
|---|---|
| `01-install-llm-d.sh` | Clones llm-d v0.7, runs `install-deps.sh`, then `helmfile apply -e gke`. |
| `02-values.yaml` | Overrides for the `ms-inference-scheduling` chart: Gemma model URI, G4 resources, prefix-cache scoring, GKE gateway class. |
| `03-hpa.yaml` | HPA scaling on KV-cache utilization (80% target) + queue depth fallback. |

## Apply

```bash
bash 02-llm-d/01-install-llm-d.sh
```

The script will install ~3 deployments, a StatefulSet of vLLM pods, an
InferencePool, an InferenceObjective, a Gateway, and an HTTPRoute. It blocks
until everything is Ready.

## Verify routing works

```bash
GW=$(kubectl -n llm-d get gateway -o jsonpath='{.items[0].status.addresses[0].value}')
curl -s http://$GW/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "google/gemma-3n-E4B-it",
    "messages": [{"role":"user","content":"Say hi in 5 words."}],
    "max_tokens": 32
  }' | jq .
```

## Watch inference-aware autoscaling in action

```bash
# Window 1: HPA + replica state
watch -n2 'kubectl -n llm-d get hpa,pods,inferencepool'

# Window 2: EPP routing decisions log
kubectl -n llm-d logs -l app=ms-inference-scheduling-epp -f | grep -i route
```

When you ramp the benchmark load, you'll see the EPP balance requests away
from pods with high KV-cache utilization — and the HPA will spin up a new
replica *before* the queue actually backs up.
