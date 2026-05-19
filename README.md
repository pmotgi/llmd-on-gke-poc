# Gemma on GKE — POC: vLLM Baseline vs. llm-d Optimized Baseline

End-to-end POC comparing **plain vLLM on GKE** vs. **llm-d Optimized Baseline on GKE** for serving Gemma 4 E4B-it (a Small Language Model) on **G4 GPU nodes (NVIDIA RTX PRO 6000 Blackwell)** with **HPA-driven autoscaling**, parameterized for **on-demand, Spot, or Flex-start** provisioning. Includes a benchmarking harness (`inference-perf` / `vllm bench serve`) that measures max sustainable throughput per GPU.

---

## 0. Model name

This POC uses `google/gemma-4-E4B-it` as the target model.

> **Note on "SLM"**: At ~8B raw / 4B effective parameters, FP16 weights consume ~8 GB GPU memory. A single G4 RTX PRO 6000 (96 GB) is **massively overprovisioned** for a single replica — which is exactly why this POC is interesting: the headroom lets you crank `--gpu-memory-utilization` high, run large KV caches, and showcase peak per-GPU throughput.

---

## 1. What this POC delivers

Two **side-by-side serving stacks** in the same GKE cluster, fronted by the same benchmark harness, so the customer can compare apples-to-apples:

```
                              ┌─────────────────────────┐
                              │  inference-perf client  │
                              │  (Job in cluster)       │
                              └────────────┬────────────┘
                                           │
                  ┌────────────────────────┼────────────────────────┐
                  ▼                                                 ▼
        ┌─────────────────────┐                          ┌─────────────────────┐
        │ Stack A: vLLM       │                          │ Stack B: llm-d      │
        │ Deployment + HPA    │                          │ InferencePool +     │
        │ (custom metrics)    │                          │ Inference Gateway   │
        │                     │                          │ + Endpoint Picker   │
        │ namespace: vllm-base│                          │ namespace: llm-d    │
        └──────────┬──────────┘                          └──────────┬──────────┘
                   │                                                 │
                   └────────────────┬───────────────────────────────┘
                                    ▼
                        ┌────────────────────────┐
                        │ G4 GPU node pool       │
                        │ g4-standard-48         │
                        │ (1× RTX PRO 6000 96GB) │
                        │ on-demand / spot /     │
                        │ flex-start (DWS)       │
                        └────────────────────────┘
```

**What each stack proves:**

- **Stack A (vLLM baseline)** — what most teams ship as a first cut. Single Deployment, K8s Service, HPA scaling on a custom vLLM metric (`vllm:num_requests_waiting`) collected via Managed Prometheus.
- **Stack B (llm-d optimized baseline)** — adds the GKE Inference Gateway + llm-d endpoint picker (EPP) in front of the same vLLM pods. Routing is KV-cache-aware and prefix-cache-aware; HPA scales on inference-aware signals (queue depth, KV-cache utilization).

The benchmarking job hits both endpoints with identical traffic and produces a comparison report.

---

## 2. Repo layout

```
gemma-gke-poc/
├── README.md                          ← you are here
├── 00-setup/
│   ├── 00-env.sh                      ← single source of truth for all env vars
│   ├── 01-enable-apis.sh
│   ├── 02-create-cluster.sh
│   ├── 03-create-gpu-nodepool.sh      ← supports ON_DEMAND | SPOT | FLEX_START
│   ├── 04-hf-secret.sh
│   └── 06-install-prereqs.sh          ← Gateway API CRDs, InferencePool CRDs, etc.
├── 01-vllm-baseline/
│   ├── 01-vllm-deployment.yaml
│   ├── 02-vllm-service.yaml
│   ├── 03-podmonitoring.yaml          ← Managed Prometheus scrape config
│   ├── 04-hpa.yaml                    ← scales on vllm:num_requests_waiting
│   ├── 05-custom-metrics-adapter.yaml
│   └── README.md
├── 02-igw-llmd/
│   ├── README.md                      ← Step-by-step guide for Stack B deployment
│   └── instros                        ← Detailed command transcript and output verified in the POC
├── 03-benchmark/
│   └── vllm/
│       ├── README.md                  ← details of the benchmark harness
│       ├── collect-results.sh         ← aggregates results and generates final metrics tables
│       ├── run-benchmark-llmd.yaml    ← K8s Job running benchmark against Stack B
│       ├── run-benchmark-vllm.yaml    ← K8s Job running benchmark against Stack A
│       ├── run-sweep.sh               ← automated sweep script through sequential rates
│       ├── results/                   ← holds raw benchmark output files
│       └── sn-result/                 
├── 04-cleanup/
│   └── teardown.sh                    ← teardown script to clean up cluster and nodes
└── docs/
    ├── PROVISIONING.md                ← deep dive on on-demand vs Spot vs Flex
    ├── AUTOSCALING.md                 ← HPA strategy details
    └── TROUBLESHOOTING.md
```

---

## 3. Prerequisites

On the workstation running this POC:

- `gcloud` ≥ 502.0.0
- `kubectl` ≥ 1.32
- `helm` ≥ 3.14
- `helmfile` ≥ 0.169 (for the llm-d stack)
- `kustomize` ≥ 5.4
- `git`, `jq`, `yq`
- A GCP project with **billing enabled** and quota for **G4 GPUs in your chosen region** (default `us-central1`)
- A HuggingFace account that has **accepted the Gemma license** for whichever model you pick
- A HuggingFace **read token**

> **Quota check** before starting: `gcloud compute regions describe us-central1 --format="value(quotas)" | grep -i RTX_PRO_6000`. You need at least the GPU count equal to your max HPA replicas (default 4) on each stack — i.e. plan for ≥4 RTX PRO 6000 GPUs.

---

## 4. Quickstart (run order)

```bash
# 0. Edit env vars (project ID, HF token, provisioning model, etc.)
vi 00-setup/00-env.sh
source 00-setup/00-env.sh

# 1. One-time GCP setup
bash 00-setup/01-enable-apis.sh
bash 00-setup/02-create-cluster.sh
bash 00-setup/03-create-gpu-nodepool.sh      # picks up PROVISIONING_MODEL
bash 00-setup/04-hf-secret.sh
bash 00-setup/06-install-prereqs.sh

# 2. Deploy Stack A (vLLM baseline)
kubectl apply -f 01-vllm-baseline/

# 3. Deploy Stack B (llm-d optimized baseline)
# Refer to 02-igw-llmd/README.md for manual setup steps (subnet provisioning,
# GKE L7 RILB gateway, helm chart install, and modelserver deployment).
# Note: These commands should be executed after switching context to the `llm-d` subdirectory.

# 4. Wait for both endpoints to be Ready, then benchmark
# Switch to the 03-benchmark/vllm directory and execute the sweep
cd 03-benchmark/vllm
bash run-sweep.sh both
bash collect-results.sh

# 5. Teardown
bash 04-cleanup/teardown.sh
```

Each phase is idempotent. Detailed walkthroughs live in the per-directory READMEs.

---

## 5. The three provisioning models — picking one

Set `PROVISIONING_MODEL` in `00-env.sh` to one of:

| Mode | When to use | Trade-off | How it works in this POC |
|---|---|---|---|
| `ON_DEMAND` | Demo runs, predictable SLAs, simplest path | Most expensive, but you always get the GPU | Plain `gcloud container node-pools create … --machine-type=g4-standard-48 --accelerator=type=nvidia-rtx-pro-6000,count=1` |
| `SPOT` | Cost-optimized inference (~60–70% cheaper) where pods can survive eviction | GPU can be reclaimed with 30s notice; pods will get rescheduled, which is fine for a stateless inference replica | Adds `--spot` and a node taint; deployments add a matching toleration |
| `FLEX_START` | Bursty / batch / non-urgent runs where you want the lowest price and are OK waiting ≤7 days for capacity | Capacity comes via Dynamic Workload Scheduler (DWS); pods stay `Pending` until allocated; runs for a bounded duration (default 7d) | Uses a **Custom Compute Class** with `flexStart: enabled: true`, and pods reference it via `cloud.google.com/compute-class` |

See `docs/PROVISIONING.md` for full configurations and how to combine them (e.g. Spot primary + on-demand fallback).

---

## 6. What "max utilization" means here

The benchmark reports the standard metrics — but for **per-GPU max utilization** specifically, you want:

1. **Throughput at saturation** — output tokens/sec/GPU at the point where p99 latency just starts climbing (the "knee"). This is your headline number.
2. **KV-cache utilization at the knee** — should be 85–95% to confirm you're memory-bound, not compute-bound.
3. **GPU SM utilization at the knee** — from `DCGM_FI_DEV_GR_ENGINE_ACTIVE` via NVIDIA DCGM exporter. Targeting 80%+ during decode.
4. **Goodput** — requests/sec that meet your TTFT + TPOT SLOs.

The benchmark harness sweeps QPS, measures all four, and prints a knee-point summary. See `03-benchmark/vllm/README.md`.

---

## 7. Next steps after the POC

- Turn on **predicted-latency scheduling** in the EPP (GA in llm-d v0.7)
- Try **prefill/decode disaggregation** if the customer's median input is large (>2K tokens) — splits the work across separate replicas
- Move to **GCS-backed model loading with Run:ai Model Streamer** to cut cold-start by 7×
- For higher-tier models (27B, 70B), step up to A3 (H100) or A4 (B200) and revisit tensor parallelism
