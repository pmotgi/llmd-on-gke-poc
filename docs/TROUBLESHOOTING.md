# Troubleshooting

## "Pods stuck in Pending: 0/N nodes are available, n Insufficient nvidia.com/gpu"

The GPU node pool either hasn't autoscaled yet or you're out of quota.

```bash
kubectl describe pod <pod> -n <ns> | tail -30          # confirm reason
gcloud container node-pools describe gpu-g4 \
  --cluster=$CLUSTER_NAME --region=$REGION              # check autoscaling.maxNodeCount
gcloud compute regions describe $REGION \
  --format="flattened(quotas)" | grep -i nvidia_rtx_pro_6000
```

If quota is the issue, file an increase via the Cloud Console (it's usually
fulfilled within a couple of business hours for reasonable amounts).

## "Pods stuck in Pending under FLEX_START for >1 hour"

DWS hasn't allocated capacity yet. This is normal during peak hours for newer
GPU types. Three options:
1. Wait — DWS Flex-start gives no SLA but typically fulfills within hours.
2. Switch `PROVISIONING_MODEL` to `SPOT` (next-cheapest option that's
   immediate-allocate).
3. Switch to `ON_DEMAND`.

Don't re-create the node pool repeatedly — each retry pushes you to the back
of the DWS queue. Just wait.

## vLLM crashes with OOM on startup

The `--gpu-memory-utilization=0.92` setting is aggressive on a 96 GB card.
Two known causes:
- **Other processes on the GPU** — DCGM exporter doesn't allocate VRAM, but a
  misconfigured device plugin can. `kubectl exec` into the pod and run
  `nvidia-smi` to confirm only vLLM is on the device.
- **Model is bigger than expected** — Gemma 3n E4B is ~8 GB BF16, but if
  `MODEL_ID` accidentally points at the 31B or 26B Gemma 4 variant, weights
  alone are 60+ GB. Double-check `MODEL_ID`.

Easy fix: lower `--gpu-memory-utilization` to 0.85 and retry. Won't change
the qualitative comparison between Stack A and Stack B.

## HPA shows `<unknown>/5` for the metric

The custom-metrics-stackdriver-adapter isn't reading the metric from Managed
Prometheus. Common causes:
- **PodMonitoring hasn't taken effect yet** — give it 60 seconds after first
  apply.
- **Workload Identity not configured** for the adapter. Re-run the IAM
  binding step in `06-install-prereqs.sh`.
- **Metric name typo**. The metric is namespaced as
  `prometheus.googleapis.com|<vllm-metric>|<type>`. Verify in Cloud Console
  → Monitoring → Metrics Explorer → search for `vllm:num_requests_waiting`.

## llm-d Gateway has no external address

```bash
kubectl -n llm-d get gateway
# If ADDRESS column is empty after 5 minutes:
kubectl -n llm-d describe gateway | tail -30
```

Likely cause: the cluster wasn't created with `--gateway-api=standard`.
Re-run `00-setup/02-create-cluster.sh` — it's idempotent and will enable
Gateway API on the existing cluster.

For the POC, you don't actually need an external IP — the benchmark runs
in-cluster against the ClusterIP service. Wait for `gateway-class` to be
Accepted=True and routes to be Programmed=True, that's enough.

## EPP logs show "no candidate pods" but pods are Ready

The InferencePool selector isn't matching the vLLM pods. Check:
```bash
kubectl -n llm-d get inferencepool ms-inference-scheduling -o yaml | yq .spec.selector
kubectl -n llm-d get pods --show-labels | grep ms-inference
```
Selector labels must match the StatefulSet's pod labels. If you customized
`02-values.yaml`, you may have broken this — revert and reapply.

## Benchmark Job pod stays Pending

The benchmark Job is CPU-only and shouldn't need a GPU node. If it's Pending,
it's almost always because we put it in the wrong namespace and the HF secret
isn't there. Verify:
```bash
kubectl -n bench get secret llm-d-hf-token
```

If missing, re-run `00-setup/04-hf-secret.sh`.

## Benchmark numbers look bad / inconsistent

In order of likelihood:
1. **The two stacks shared a GPU node**. K8s let one stack's pods evict
   the other under memory pressure. Run benchmarks sequentially, not in
   parallel — the `kubectl wait` calls in the README enforce this.
2. **Image streaming was off and the first stage cold-started.** Discard
   stage 1 ("warmup") from the analysis; it's there for exactly this reason.
3. **Spot eviction mid-run.** Re-run on ON_DEMAND for the headline numbers.
   Use Spot for cost messaging, not for raw performance numbers.
