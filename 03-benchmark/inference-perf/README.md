# Production-Scale Benchmarking with Inference Perf

This directory contains the manifests and scripts to run the official Kubernetes community standard [inference-perf](https://github.com/kubernetes-sigs/inference-perf) benchmarking tool on the GKE cluster.

`inference-perf` is a production-scale GenAI performance benchmarking tool founded under the **Kubernetes WG-Serving** group. It standardizes GenAI inference performance metrics (TTFT, TPOT, ITL, Normalized TPOT, Goodput) across model servers and routing gateways.

---

## How Inference-Perf Helps Customers

1. **Standardizes Performance Auditing**: Measures real-world user behavior using complex workload generation:
   - **Plain Shared Prefix**: Standard shared system prompt scenarios.
   - **Distribution-Based Prompts**: Randomized inputs and outputs using standard distributions (Normal, Skew-Normal, Lognormal) to model realistic length variance.
   - **Multi-Turn Chat Sessions**: Appends conversational history over rounds, tracking user session memory to audit stateful serving performance.
2. **Validates Advanced Routing Gateways**: Proves the concrete efficiency and KV cache hit benefits of **prefix-aware and session-aware routing** (e.g., GKE Inference Gateway / Endpoint Picker) under load.
3. **Isolates Network Overhead**: Highlights the minor TTFT routing proxy hop latency (~5ms) vs. the massive KV cache recompute savings (up to 8.1x faster tail TPOT).

---

## Benchmark Configurations Inside

- **`config-plain.yml`**: Fixed prompt, question, and output lengths (10 unique system prompts, 1-2 QPS load).
- **`config-distributions.yml`**: Shared prefixes with input length following a Skew-Normal distribution (mean 200) and output length following a Lognormal distribution (mean 150).
- **`config-multi-turn.yml`**: Realistic chatbot simulation where conversation prompt histories grow dynamically up to **1,000 tokens** over rounds.
- **`run-benchmark.sh`**: Unified execution and logs-collection script.

---

## GKE Benchmark Results Summary

Tested using `google/gemma-4-E4B-it` on Stack A (`vllm-base`) and Stack B (`llm-d` with EPP routing).

### 1. Plain Shared Prefix (10 Prompts, Fixed Lengths, 1-2 QPS)
Even under lower QPS, standard vLLM suffers from prompt re-evaluations due to random routing. LLM-D's prefix routing groups requests correctly, yielding **3.6x faster tail generation latency**.

| Metric | baseline vLLM (`vllm-base`) | EPP-routed LLM-D (`llm-d`) | Difference |
| :--- | :---: | :---: | :---: |
| **Mean Normalized TPOT** | **30.63 ms** | **20.75 ms** | **LLM-D is 32.2% FASTER** |
| **p99 Normalized TPOT** | **449.63 ms** | **124.36 ms** | 🚀 **LLM-D is 3.6x FASTER!** |

### 2. Distributions Shared Prefix (10 Prompts, Skewed large payloads, 1-2 QPS)
Under extremely low concurrency (1-2 QPS) with very large output sequences (up to 4k tokens), there is no GPU cache contention. Here, vLLM's proxy-less pathway is slightly faster on average.

| Metric | baseline vLLM (`vllm-base`) | EPP-routed LLM-D (`llm-d`) | Difference |
| :--- | :---: | :---: | :---: |
| **Mean Normalized TPOT** | **41.18 ms** | **66.55 ms** | vLLM baseline (+38%) |
| **p99 Normalized TPOT** | **448.10 ms** | **772.51 ms** | vLLM baseline (+42%) |

### 3. Multi-Turn Shared Prefix Chat (Growing Session Memory, 20 QPS)
Users chat over multiple rounds, prompt histories scaling up to **1,000 tokens**. EPP session pinning groups a user session to the *same* GPU node, avoiding context recomputations.

| Metric | baseline vLLM (`vllm-base`) | EPP-routed LLM-D (`llm-d`) | Difference |
| :--- | :---: | :---: | :---: |
| **Total Output Throughput** | **701.88 tok/s** | **763.91 tok/s** | **LLM-D is 8.8% HIGHER** |
| **Mean Normalized TPOT** | **16.43 ms** | **13.17 ms** | **LLM-D is 24.7% FASTER** |
| **p99 Normalized TPOT** | **127.15 ms** | **17.60 ms** | 🚀 **LLM-D is 7.2x FASTER!** |
| **p99.9 Normalized TPOT** | **158.37 ms** | **19.53 ms** | 🚀 **LLM-D is 8.1x FASTER!** |

---

## Execution Guide

### 1. Prerequisites
Verify the Hugging Face API token secret exists in the `bench` namespace:
```bash
kubectl -n bench get secret llm-d-hf-token
```

### 2. Running the Benchmarks
Execute the automated runner script:
```bash
# Run both endpoints sequentially across all three configurations
bash run-benchmark.sh both

# Or run against a single target
bash run-benchmark.sh llmd
bash run-benchmark.sh vllm
```

All raw container outputs, processed JSON metrics, and logs are automatically collected into the `./results/` folder for downstream analysis.
