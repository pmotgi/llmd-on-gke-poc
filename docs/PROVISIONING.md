# Provisioning Strategies — picking the right GPU consumption model

Three valid choices in this POC, each with different operational and economic
tradeoffs. The `PROVISIONING_MODEL` env var in `00-env.sh` flips the node-pool
creation logic in `03-create-gpu-nodepool.sh`.

## Decision matrix

| Question | If yes → use… |
|---|---|
| Need guaranteed GPU availability the moment the script runs? | **ON_DEMAND** |
| OK with pods getting evicted with 30s notice (stateless inference is)? Want ~60–70% off list price? | **SPOT** |
| Running a bounded experiment (hours/days) and OK waiting minutes-to-hours for GPUs to land? | **FLEX_START** |
| Production serving with SLA? | **ON_DEMAND** + reservations (out of scope for this POC) |

## 1. ON_DEMAND (the safe default)

What it looks like:

```bash
gcloud container node-pools create gpu-g4 \
  --machine-type=g4-standard-48 \
  --accelerator=type=nvidia-rtx-pro-6000,count=1,gpu-driver-version=LATEST \
  --enable-autoscaling --min-nodes=1 --max-nodes=4
```

- Capacity allocated immediately if available in the zone.
- HPA can scale up and down freely.
- This is what a customer demo on a fixed timeline should default to.

## 2. SPOT (cost-optimized inference)

What it looks like:

```bash
gcloud container node-pools create gpu-g4 \
  --machine-type=g4-standard-48 \
  --accelerator=type=nvidia-rtx-pro-6000,count=1,gpu-driver-version=LATEST \
  --spot \
  --enable-autoscaling --min-nodes=1 --max-nodes=4
```

- ~60–70% cheaper than on-demand.
- GKE adds `cloud.google.com/gke-spot=true` to the node label and a
  `cloud.google.com/gke-spot=true:NoSchedule` taint.
- Pods must tolerate that taint — **already included** in our manifests.
- Eviction notice: 30 seconds. vLLM pods are stateless, so K8s reschedules
  on another node; expected total downtime per eviction event is ~60–120s
  on warm cache (image streaming + already-pulled weights) or several minutes
  cold. HPA will quickly bring a new replica up.

**Strongly recommended pattern for production**: Spot primary pool + small
on-demand fallback pool. The custom compute class makes this clean:

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata: { name: g4-spot-then-od }
spec:
  priorities:
  - machineType: g4-standard-48
    gpu: { type: nvidia-rtx-pro-6000, count: 1 }
    spot: true
  - machineType: g4-standard-48          # fallback
    gpu: { type: nvidia-rtx-pro-6000, count: 1 }
  nodePoolAutoCreation: { enabled: true }
```

GKE picks the cheapest tier with available capacity; if Spot is unavailable,
falls through to on-demand automatically.

## 3. FLEX_START (DWS-backed bursts)

What it looks like (handled automatically by `03-create-gpu-nodepool.sh`):

```yaml
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata: { name: g4-flex-start }
spec:
  priorities:
  - machineType: g4-standard-48
    gpu: { type: nvidia-rtx-pro-6000, count: 1 }
    flexStart:
      enabled: true
      maxRunDurationSeconds: 604800   # 7 days, ceiling
  nodePoolAutoCreation: { enabled: true }
  autoscalingPolicy: { minNodeCount: 0, maxNodeCount: 4 }
```

Pods reference it via:

```yaml
spec:
  nodeSelector:
    cloud.google.com/compute-class: g4-flex-start
```

How it works:
1. Pod is created → stays `Pending` while GKE submits a DWS Flex-start request.
2. Dynamic Workload Scheduler queues your request behind other tenants but
   guarantees you'll get the GPU within the calendar window you requested.
3. Once allocated, runs for up to 7 days, then nodes are reclaimed.

Best for: **the benchmark sweep itself** — you only need GPUs for ~1 hour
total, and Flex-start is the cheapest way to get them.

Worst for: **interactive demos with executives in the room** — you cannot
guarantee the cluster is "live" at a specific minute.

## Combining provisioning models

Nothing in the POC stops you from running Stack A on Spot and Stack B on
Flex-start, etc. Use two compute classes and have the deployments reference
different `cloud.google.com/compute-class` selectors. The HPA, gateway, and
inference-perf harness are agnostic.
