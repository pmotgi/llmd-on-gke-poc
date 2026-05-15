# Benchmarking — measuring max utilization on the chip

The benchmark layer uses **`vllm bench serve`** — vLLM's own built-in load
generator, shipped in the same `vllm/vllm-openai` image you serve from.

## Why `vllm bench serve` instead of inference-perf

For this POC, the win is operational simplicity:

| | vllm bench serve | inference-perf |
|---|---|---|
| Extra image to pull | none (same image as the server) | yes (`inference-perf:latest`) |
| Extra ConfigMap to apply | none | yes |
| QPS sweep | one Job per rate (script loops) | single Job, multi-stage |
| Output | one JSON per run | one JSON across all stages |
| Tokenizer matching | automatic (uses --model) | requires tokenizer config |

For the comparison metrics this POC wants (TTFT, TPOT, throughput, knee-point),
they produce equivalent numbers. We use vllm bench because it's one less moving
part to debug.

## What's in here

| File | Purpose |
|---|---|
| `run-benchmark-vllm.yaml` | K8s Job: `vllm bench serve` against Stack A endpoint. |
| `run-benchmark-llmd.yaml` | K8s Job: same, but against Stack B's Inference Gateway. |
| `run-sweep.sh`            | Loops through QPS rates and runs the Job for each. |
| `collect-results.sh`      | Parses the JSONs and prints a side-by-side knee table. |

## Single-run smoke test

To confirm everything is wired up before running a full sweep:

```bash
kubectl apply -f 03-benchmark/run-benchmark-vllm.yaml
kubectl -n bench wait --for=condition=complete --timeout=10m job/bench-vllm-baseline
kubectl -n bench logs -l job-name=bench-vllm-baseline --tail=40
```

You should see a `vllm bench serve` summary table like:

```
============ Serving Benchmark Result ============
Successful requests:                     1200
Benchmark duration (s):                  120.4
Total input tokens:                      245301
Total generated tokens:                  198122
Request throughput (req/s):              9.97
Output token throughput (tok/s):         1645.2
Total Token throughput (tok/s):          3683.7
---------------Time to First Token----------------
Mean TTFT (ms):                          88.4
Median TTFT (ms):                        76.1
P99 TTFT (ms):                           312.5
-----Time per Output Token (excl. 1st)------
Mean TPOT (ms):                          15.2
Median TPOT (ms):                        14.8
P99 TPOT (ms):                           38.9
==================================================
```

## Full QPS sweep (the real comparison)

```bash
# Run both stacks across rates 5, 10, 20, 40, 80 QPS. Sequential, ~30 min total.
bash 03-benchmark/run-sweep.sh both

# Then summarize:
bash 03-benchmark/collect-results.sh
```

You'll get output like:

```
====================================================================
  BENCHMARK SUMMARY
  SLOs: p99 TTFT ≤ 500ms,  p99 TPOT ≤ 50ms
====================================================================

STACK A — vLLM baseline
  rate     req_thru   out_tok/s    ttft_p50   ttft_p99   tpot_p50   tpot_p99     meets_slo
  ----------------------------------------------------------------------------------------
  5        4.98       820.3        65.2       180.4      13.1       28.4         YES
  10       9.95       1645.2       76.1       312.5      14.8       38.9         YES
  20       19.81      3210.7       95.3       420.1      18.2       45.7         YES
  40       38.42      6105.6       180.4      890.3      28.1       72.3         no
  80       58.10      8240.1       720.5      2100.4     45.9       180.2        no
  → KNEE for vllm: rate=20 QPS, output=3210.7 tok/s

STACK B — llm-d optimized
  ...
  → KNEE for llmd: rate=40 QPS, output=6105.6 tok/s
```

The **knee** number is the headline: max sustainable per-replica throughput
before SLOs break. `output_tok/s ÷ replicas_at_knee` = per-GPU peak utilization.

## Tuning the sweep

Edit `run-sweep.sh`:

```bash
RATES=(5 10 20 40 80)       # add more granular steps near the expected knee
NUM_PROMPTS=600              # bump to 1200+ for tighter percentiles at high QPS
```

For a single-run "what's the absolute max" measurement (no sweep), edit the
Job YAML and set `--request-rate=inf` — vllm bench will send requests as fast
as the server can accept them, and `--max-concurrency` becomes the cap.

## Tweaking the SLOs

The knee finder uses these defaults:
- p99 TTFT ≤ 500 ms
- p99 TPOT ≤ 50 ms

Override per-run:

```bash
TTFT_P99_SLO_MS=800 TPOT_P99_SLO_MS=80 bash 03-benchmark/collect-results.sh
```

These should match your customer's latency budget. For a chatbot, the defaults
are reasonable. For batch/offline, you can loosen them dramatically and the
knee shifts way higher.

## Confirming HPA actually scaled

The benchmark drives load but doesn't directly observe replica count. Watch
during the sweep:

```bash
watch -n2 'kubectl -n vllm-base get hpa,pods,nodes -l workload=inference'
# in another terminal for Stack B:
watch -n2 'kubectl -n llm-d get hpa,pods'
```

At the higher rates (40, 80 QPS) HPA should scale 1→2→3 replicas. If it stays
at 1, check the HPA metric value (`kubectl get hpa -A -o wide`) and confirm
the custom-metrics adapter is reading from Managed Prometheus correctly — see
`docs/TROUBLESHOOTING.md`.
