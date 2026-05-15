# Autoscaling — what scales, when, and why

Two layers scale independently in this POC. Understanding the difference is
critical when reading benchmark results.

## Layer 1: HPA (pod replicas)

- **Stack A target**: `vllm:num_requests_waiting`, AverageValue=5.
  → "if there are ≥5 queued requests per replica on average for 15s, add a pod."
- **Stack B target**: `vllm:gpu_cache_usage_perc`, AverageValue=0.80.
  → "if avg KV-cache utilization across the pool is ≥80%, add a pod."
  Plus a secondary queue-depth gate for safety.

Why the difference? Queue depth is a **reactive** signal — requests must
already be backed up before HPA notices. KV-cache utilization is **proactive**
— a saturated cache predicts queue depth ~5–10 seconds in the future. Stack
B's smart router (EPP) keeps queue depth artificially low by routing away
from hot replicas, which means queue-depth-based scaling under-scales the
pool. Hence the metric swap.

### Scale-up vs scale-down behavior

Both HPAs are tuned asymmetrically:
- Scale **up** within 15 seconds (`stabilizationWindowSeconds: 15`).
- Scale **down** only after 5 minutes of sustained underuse (`300`).

Reason: GPUs are expensive to provision (cold node = ~3 min + weight load
= ~2 more min on a cold cache), so the cost of a wrong scale-down is high.
Scaling up early is cheap (you eat a few extra GPU-minutes); scaling down
prematurely is expensive (a traffic blip means a 5-min cold start).

## Layer 2: Cluster Autoscaler (nodes)

Independent of HPA. When HPA creates a pod that can't schedule (no Ready node
has a free `nvidia.com/gpu` resource), Cluster Autoscaler asks the node pool
to provision another node:

- **ON_DEMAND** → ~3 minutes to a Ready node.
- **SPOT** → ~3 minutes (when capacity is available; can fail if Spot is
  out and your node pool isn't using a fallback compute class).
- **FLEX_START** → minutes to hours, dictated by DWS.

The benchmark's 8-stage QPS ramp gives both layers time to react. If you
shorten the per-stage `duration`, you'll measure autoscaling lag instead of
steady-state throughput — be intentional.

## Watching it live

```bash
# In one terminal:
watch -n2 'kubectl -n llm-d get hpa,pods,nodes -l workload=inference'

# In another:
kubectl -n llm-d get events --watch | grep -E "Scale|Schedule"
```

## What if I want SLO-aware autoscaling instead?

llm-d v0.7 ships a GA **workload-variant autoscaler** that scales on
SLO compliance directly (TTFT/TPOT thresholds) rather than utilization
proxies. To enable it, replace `02-llm-d/03-hpa.yaml` with the
InferenceAutoscaling CRD shipped by llm-d:

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha1
kind: InferenceAutoscaling
metadata: { name: ms-inference-scheduling, namespace: llm-d }
spec:
  targetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: ms-inference-scheduling
  minReplicas: 1
  maxReplicas: 4
  slos:
    - { metric: ttft_p99, threshold: 500ms }
    - { metric: tpot_p99, threshold: 50ms }
```

This is the future direction; the HPA v2 manifest in this POC is the
broadly compatible version.
