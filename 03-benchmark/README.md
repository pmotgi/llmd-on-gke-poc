# Benchmarking — measuring max utilization on the chip

The benchmark layer uses [**inference-perf**](https://github.com/kubernetes-sigs/inference-perf),
the SIG-supported, Kubernetes-native LLM benchmarking tool that GKE's
[Inference Quickstart](https://cloud.google.com/kubernetes-engine/docs/how-to/machine-learning/inference/inference-quickstart)
uses for its published numbers. It's the right tool because:

1. **It runs in-cluster** — no network noise between the load generator and the
   service. Critical for accurate TTFT measurements.
2. **It sweeps QPS automatically** and finds the "knee" — the point where p99
   latency starts to violate the SLO. That's your **max sustainable throughput
   per GPU**.
3. **It scrapes Prometheus alongside the requests**, so per-stage QPS lines up
   exactly with KV-cache utilization and `vllm:num_requests_running`.

## Workload

The shared config (`inference-perf-config.yaml`) runs the **ShareGPT** dataset
in streaming mode, sweeping rates from 1 to 320 QPS in 8 stages. ShareGPT has
realistic mixed prompt lengths and meaningful prefix overlap between
conversations — this is what makes llm-d's prefix-cache-aware routing pay off.
For a workload with zero prefix overlap, switch to `data: { type: synthetic }`
and set explicit token-length distributions.

## Running

```bash
# Both Jobs are independent. Run them sequentially (cleaner numbers) by
# applying one, waiting for it, then the other:

kubectl apply -f 03-benchmark/inference-perf-config.yaml
kubectl apply -f 03-benchmark/run-benchmark-vllm.yaml
kubectl -n bench wait --for=condition=complete --timeout=2h job/bench-vllm-baseline

kubectl apply -f 03-benchmark/run-benchmark-llmd.yaml
kubectl -n bench wait --for=condition=complete --timeout=2h job/bench-llmd

bash 03-benchmark/collect-results.sh
```

Each Job takes ~20–25 minutes for the full sweep.

## What the report tells you

`collect-results.sh` prints a side-by-side table:

```
--- bench-vllm-baseline ---
Knee-point QPS:        45
Output tok/s/replica:  4,120
p50 TTFT (ms):         95
p99 TTFT (ms):         480
p50 TPOT (ms):         18
p99 TPOT (ms):         48
KV-cache util at knee: 0.89
Replicas at knee:      3

--- bench-llmd ---
Knee-point QPS:        62
Output tok/s/replica:  5,640
p50 TTFT (ms):         71
p99 TTFT (ms):         360
p50 TPOT (ms):         15
p99 TPOT (ms):         42
KV-cache util at knee: 0.93
Replicas at knee:      3
```

The headline numbers for "max utilization on the chip" are:
- **Output tok/s/replica** at the knee → this is per-GPU throughput.
- **KV-cache util at knee** → how full the chip's KV is at saturation.
- **Replicas at knee** → did HPA scale correctly? Should be < maxReplicas.

## Alternative: vLLM's own bench tool

If you want a quick local sanity check without the K8s harness:

```bash
kubectl -n vllm-base port-forward svc/vllm-gemma 8000:8000 &

# In another terminal, from a machine with vllm installed:
vllm bench serve \
  --backend openai-chat \
  --base-url http://localhost:8000 \
  --model google/gemma-3n-E4B-it \
  --dataset-name sharegpt \
  --num-prompts 1000 \
  --request-rate 50
```

It prints the same TTFT/TPOT/throughput numbers, but without the per-stage sweep.
Useful for one-off "is the deployment alive and fast enough?" checks.
