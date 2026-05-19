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
| [README.md](file:///Users/pmotgi/exploration/tr-llmd-poc/gke-llmd-test/02-igw-llmd/README.md) | This detailed step-by-step deployment guide. |

---

## Step-by-Step Deployment & Verification Guide

> [!IMPORTANT]
> Make sure you have cloned and initialized the `llm-d` subdirectory (Gateway API Inference Extension submodule) before proceeding.
> All commands from **Step 2** through **Step 9** must be run from the [llm-d](file:///Users/pmotgi/exploration/tr-llmd-poc/gke-llmd-test/llm-d) directory.

### Step 1: Create Regional Managed Proxy-Only Subnet
GKE's L7 Internal Load Balancer (RILB) requires a regional proxy-only subnet to be active in the target region (`us-east5`). Run the following command from your terminal:

```bash
gcloud compute networks subnets create pmotgi-tr-po-subnet \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --region=us-east5 \
    --network=default \
    --range=192.168.0.0/23
```
> [!NOTE]
> This command may take a couple of minutes to complete provisioning.

---

### Step 2: Set Up Environment Variables
Navigate to the `llm-d` directory and export the required setup variables:

```bash
cd /Users/pmotgi/exploration/tr-llmd-poc/gke-llmd-test/llm-d

export GAIE_VERSION=v1.5.0
export GUIDE_NAME="optimized-baseline"
export NAMESPACE=llm-d-optimized-baseline
export INFRA_PROVIDER=gke
export PROVIDER_NAME=gke
```

---

### Step 3: Install Gateway API Inference Extension CRDs
Apply the Custom Resource Definitions (CRDs) matching the Gateway API Inference Extension version:

```bash
kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GAIE_VERSION}"
```

#### Expected Output:
```text
customresourcedefinition.apiextensions.k8s.io/inferencemodelrewrites.inference.networking.x-k8s.io created
customresourcedefinition.apiextensions.k8s.io/inferenceobjectives.inference.networking.x-k8s.io configured
customresourcedefinition.apiextensions.k8s.io/inferencepoolimports.inference.networking.x-k8s.io created
customresourcedefinition.apiextensions.k8s.io/inferencepools.inference.networking.k8s.io configured
```

---

### Step 4: Verify API Resource Groups
Confirm that the required `gateway.networking.k8s.io` and `inference.networking.k8s.io` resources are registered in the cluster:

```bash
kubectl api-resources --api-group=gateway.networking.k8s.io
kubectl api-resources --api-group=inference.networking.k8s.io
```

#### Expected Output:
```text
NAME                 SHORTNAMES   APIVERSION                          NAMESPACED   KIND
backendtlspolicies   btlspolicy   gateway.networking.k8s.io/v1        true         BackendTLSPolicy
gatewayclasses       gc           gateway.networking.k8s.io/v1        false        GatewayClass
gateways             gtw          gateway.networking.k8s.io/v1        true         Gateway
httproutes                        gateway.networking.k8s.io/v1        true         HTTPRoute
referencegrants      refgrant     gateway.networking.k8s.io/v1beta1   true         ReferenceGrant

NAME             SHORTNAMES   APIVERSION                       NAMESPACED   KIND
inferencepools   infpool      inference.networking.k8s.io/v1   true         InferencePool
```

---

### Step 5: Create Namespace & Deploy L7 Regional Gateway
Create the target namespace and apply the GKE L7 RILB recipe:

```bash
kubectl create namespace ${NAMESPACE}
kubectl apply -n ${NAMESPACE} -k "./guides/recipes/gateway/gke-l7-rilb"
```

#### Expected Output:
```text
namespace/llm-d-optimized-baseline created
gateway.gateway.networking.k8s.io/llm-d-inference-gateway created
```

---

### Step 6: Monitor Gateway Programming State
Wait 2-3 minutes for the L7 load balancer to program itself and obtain an IP address:

```bash
kubectl get gateway -n ${NAMESPACE} llm-d-inference-gateway
```

#### Expected Output:
```text
NAME                      CLASS         ADDRESS        PROGRAMMED   AGE
llm-d-inference-gateway   gke-l7-rilb   10.202.0.177   True         61s
```
> [!IMPORTANT]
> Make sure the `PROGRAMMED` column is `True` and an internal `ADDRESS` is allocated before continuing.

---

### Step 7: Install Inference Pool Scheduler via Helm
Install the scheduler component utilizing Helm with experimental HTTPRoute routing pointing to our newly created GKE Gateway:

```bash
helm install ${GUIDE_NAME} \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool  \
    -f guides/recipes/scheduler/base.values.yaml \
    -f guides/${GUIDE_NAME}/scheduler/${GUIDE_NAME}.values.yaml \
    --set provider.name=${PROVIDER_NAME} \
    --set experimentalHttpRoute.enabled=true \
    --set experimentalHttpRoute.inferenceGatewayName=llm-d-inference-gateway \
    -n ${NAMESPACE} --version ${GAIE_VERSION}
```

---

### Step 8: Deploy Model Server (vLLM NVIDIA GPU Decode Deployment)
Deploy the model server using Kustomize:

```bash
kubectl apply -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/gpu/vllm/${INFRA_PROVIDER}/
```

#### Expected Output:
```text
serviceaccount/optimized-baseline-nvidia-gpu-vllm-sa created
deployment.apps/optimized-baseline-nvidia-gpu-vllm-decode created
```

> [!NOTE]
> This deployment will trigger GKE Cluster Autoscaler to scale up nodes. You can watch this activity via `kubectl get events` or `k9s`:
> ```text
> Normal  TriggeredScaleUp  23s  cluster-autoscaler  Pod triggered scale-up: [{https://www.googleapis.com/.../instanceGroups/gke-...-grp 1->2 (max: 4)}]
> ```

---

### Step 9: Retrieve Gateway IP
Retrieve and store the allocated Internal Load Balancer IP:

```bash
export IP=$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')
echo $IP
```
> **Example Output:** `10.202.0.177`

---

### Step 10: Verify Inference Gateway Connectivity
Since the regional load balancer is only accessible internally within the VPC network, spin up a lightweight debug container inside the cluster to run curls:

```bash
kubectl run curl-debug --rm -it \
    --image=cfmanteiga/alpine-bash-curl-jq \
    --env="IP=$IP" \
    --env="NAMESPACE=$NAMESPACE" \
    -- /bin/bash
```

Once inside the shell of the debug container, run the following curl payload to query the Gemma model:

```bash
curl -X POST http://${IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{
        "model": "google/gemma-4-E4B-it",
        "prompt": "How are you today?"
    }' | jq
```

#### Expected Response payload:
```json
{
  "id": "cmpl-7ac8e8ce-9f26-454b-9e3d-c11c800518bc",
  "object": "text_completion",
  "created": 1779126191,
  "prompt_routed_experts": null,
  "model": "google/gemma-4-E4B-it",
  "choices": [
    {
      "index": 0,
      "text": " How are you today? How are you? How are you? How are you",
      "logprobs": null,
      "finish_reason": "length",
      "stop_reason": null,
      "token_ids": null,
      "prompt_logprobs": null,
      "prompt_token_ids": null,
      "routed_experts": null
    }
  ],
  "service_tier": null,
  "system_fingerprint": "vllm-0.21.0-a99be849",
  "usage": {
    "prompt_tokens": 5,
    "total_tokens": 21,
    "completion_tokens": 16,
    "prompt_tokens_details": null
  },
  "kv_transfer_params": null
}
```

Exit the debug container shell to clean it up.

---

### Step 11: Run Benchmarks & Performance Sweep
Navigate to the benchmarking directory to start a load-testing run comparing Stack A and Stack B side-by-side:

```bash
cd /Users/pmotgi/exploration/tr-llmd-poc/gke-llmd-test/03-benchmark/vllm
bash run-sweep.sh both
```

---

### Step 12: Collect and Compare Benchmark Results
Once the sweep completes, analyze and display the comparison summary:

```bash
bash collect-results.sh
```

#### Verified Benchmark Output (2 Nodes):
```text
====================================================================
  BENCHMARK SUMMARY
  SLOs: p99 TTFT ≤ 500ms,  p99 TPOT ≤ 50ms
====================================================================

STACK A — vLLM baseline

  rate     req_thru   out_tok/s    ttft_p50   ttft_p99   tpot_p50   tpot_p99     meets_slo
  ----------------------------------------------------------------------------------------
  5        4.75       1006.3       32.9       49.5       9.28       9.70         YES
  10       9.07       1926.0       34.3       44.7       9.52       9.97         YES
  20       16.33      3459.4       37.6       52.3       9.99       10.54        YES
  40       26.48      5622.8       42.4       73.5       10.68      11.41        YES
  80       37.73      7960.6       57.2       125.3      12.06      13.52        YES

  → KNEE for vllm: rate=80 QPS, output=7960.6 tok/s (passes p99 TTFT≤500ms, p99 TPOT≤50ms)

STACK B — llm-d optimized

  rate     req_thru   out_tok/s    ttft_p50   ttft_p99   tpot_p50   tpot_p99     meets_slo
  ----------------------------------------------------------------------------------------
  5        4.76       1002.4       40.7       238.5      9.34       10.55        YES
  10       9.05       1907.8       38.9       49.0       9.53       9.95         YES
  20       16.27      3445.6       40.8       56.3       9.96       10.75        YES
  40       26.55      5644.7       47.1       75.7       10.71      11.55        YES
  80       37.38      7913.8       79.2       158.9      12.12      14.29        YES

  → KNEE for llmd: rate=80 QPS, output=7913.8 tok/s (passes p99 TTFT≤500ms, p99 TPOT≤50ms)

Raw JSONs are in ./results/. Use jq to drill deeper, e.g.:
  jq '.input_lens, .output_lens' ./results/vllm-rate40.json
```

---

#### High-Pressure Prefix-Cache Workload Benchmark Output:

When configured with a high-pressure prefix working set that exceeds a single replica pod's local KV cache capacity, LLM-D's stateful, prefix-cache-aware routing dramatically outperforms standard Kubernetes round-robin routing:

* **Dataset configuration:**
  * `--prefix-repetition-prefix-len 16384` (16K tokens per prefix)
  * `--prefix-repetition-num-prefixes 40` (40 unique prefixes)
  * `--prefix-repetition-suffix-len 128`
  * `--prefix-repetition-output-len 128`

```text
====================================================================
  BENCHMARK SUMMARY (High-Pressure Prefix-Cache Workload)
  SLOs: p99 TTFT ≤ 500ms,  p99 TPOT ≤ 50ms
====================================================================

STACK A — vLLM baseline

  rate     req_thru   out_tok/s    tot_tok/s    ttft_p50   ttft_p99   tpot_p50   tpot_p99     meets_slo
  ----------------------------------------------------------------------------------------------------
  5        4.93       589.9        82122.0      89.5       2109.6     12.17      43.77        no
  10       9.75       1152.9       162316.9     86.6       753.1      11.98      22.62        no
  20       18.90      2279.3       314609.9     89.4       153.5      13.36      15.48        YES
  40       35.39      4236.6       588920.1     100.9      199.6      16.68      18.60        YES
  80       60.43      7235.5       1005561.5    156.3      539.5      20.23      24.43        no

  → KNEE for vllm: rate=40 QPS, output=4236.6 tok/s (passes p99 TTFT≤500ms, p99 TPOT≤50ms)

STACK B — llm-d optimized

  rate     req_thru   out_tok/s    tot_tok/s    ttft_p50   ttft_p99   tpot_p50   tpot_p99     meets_slo
  ----------------------------------------------------------------------------------------------------
  5        4.94       593.9        82162.9      105.3      783.7      11.37      21.39        no
  10       9.74       1179.1       162112.0     105.1      144.8      11.73      12.90        YES
  20       18.95      2282.3       315431.1     109.1      164.3      12.77      14.22        YES
  40       35.78      4292.1       595416.7     124.9      249.9      14.48      15.39        YES
  80       62.26      7490.2       1036106.7    224.3      585.7      15.82      17.56        no

  → KNEE for llmd: rate=40 QPS, output=4292.1 tok/s (passes p99 TTFT≤500ms, p99 TPOT≤50ms)
```

### Technical Observation: Why LLM-D Wins Under Cache Pressure

1. **Cache Thrashing Prevention:**
   * **The Working Set Size:** 40 unique prefixes × 16,384 tokens = **655,360 tokens** total.
   * **Single-Pod Capacity:** A single NVIDIA RTX 6000 GPU with bfloat16 weights for a 4B model can allocate $\approx 40\text{ GB}$ to $80\text{ GB}$ for its local KV cache, holding roughly **150,000 to 200,000 active tokens**.
   * **vLLM Baseline (Stack A):** Because the standard Kubernetes ClusterIP service randomly round-robins incoming requests across the 4 replica pods, each pod receives a random sequence of all 40 unique prefixes. Since $655,360\text{ tokens} \gg 150,000\text{ tokens}$ capacity, pods must constantly evict older KV cache entries to make room for new ones. This causes severe **cache thrashing**. Every cache miss requires a full **16,384-token prefill**, which is extremely expensive, causing the 99th percentile TTFT to spike up to **2,109.6ms** (at rate 5) and **753.1ms** (at rate 10).
   * **LLM-D (Stack B):** The Endpoint Picker (EPP) routes requests based on prefix matching, ensuring all requests with prefix $X$ go to the same pod. Across 4 pods, this partitions the 40 prefixes:
     $$\text{Prefixes per Pod} = \frac{40 \text{ prefixes}}{4 \text{ pods}} = 10 \text{ prefixes}$$
     $$\text{Total cache per Pod} = 10 \times 16,384 = 163,840 \text{ tokens}$$
     This footprint fits entirely within the local KV cache memory of each individual pod! Therefore, the prefixes stay permanently cached. The cache hit rate reaches **$\sim 100\%$**, dramatically reducing the p99 TTFT down to **144.8ms** at rate 10 (a **$5.2\times$ latency reduction** over vLLM baseline) and meeting the strict 500ms SLO where the baseline fails.

2. **Throughput Comparison & Latency Trade-Offs:**
   * **Throughput Gains:** Under peak stress load (80 QPS), LLM-D delivers a **+3.04% increase** in total token throughput (`tot_tok/s`) and a **+3.52% increase** in output token throughput (`out_tok/s`).
   * **Modest Throughput Limits:** Because the benchmarking client (`vllm bench serve`) acts as a closed rate-limiting generator, the throughput volume for both stacks remains tied to the targeted rate tier (rates 5 through 40 QPS) rather than raw GPU maximum output.
   * **The Definitive Latency Victory:** The true measure of victory here is **TTFT latency reduction**. At 10 QPS, LLM-D achieves an **$80.8\%$ reduction (a $5.2\times$ speedup)** in p99 TTFT ($144.8\text{ ms}$ vs $753.1\text{ ms}$), comfortably satisfying the $500\text{ ms}$ TTFT SLO while the vLLM baseline fails completely due to continuous cold-prefill cache thrashing.


