#!/usr/bin/env bash
# 06-install-prereqs.sh — Install cluster-wide prerequisites used by both stacks.
#   • Gateway API CRDs (already on by --gateway-api=standard, but we ensure InferencePool too)
#   • InferenceObjective + InferencePool CRDs (gateway-api-inference-extension)
#   • Custom Metrics Stackdriver Adapter (so HPA can read Prometheus metrics)
#   • DCGM exporter (NVIDIA GPU metrics) — optional but useful for the POC writeup
set -euo pipefail

echo "[+] Installing InferencePool / InferenceObjective CRDs (gateway-api-inference-extension v1)..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.0.1/manifests.yaml

echo "[+] Installing Custom Metrics Stackdriver Adapter (needed for vLLM HPA on vllm:num_requests_waiting)..."
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml

# Grant the adapter Workload Identity to read Cloud Monitoring metrics.
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[custom-metrics/custom-metrics-stackdriver-adapter]" \
  --role="roles/monitoring.viewer" \
  --condition=None >/dev/null
kubectl annotate serviceaccount --namespace custom-metrics custom-metrics-stackdriver-adapter \
  "iam.gke.io/gcp-service-account=${PROJECT_ID}.svc.id.goog[custom-metrics/custom-metrics-stackdriver-adapter]" \
  --overwrite

echo "[+] Installing NVIDIA DCGM exporter for GPU utilization metrics..."
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: gmp-public
spec:
  selector:
    matchLabels: { app: dcgm-exporter }
  template:
    metadata:
      labels: { app: dcgm-exporter }
    spec:
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        cloud.google.com/gke-accelerator: nvidia-rtx-pro-6000
      containers:
      - name: dcgm-exporter
        image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.1-ubuntu22.04
        ports:
        - { name: metrics, containerPort: 9400 }
        securityContext: { runAsNonRoot: false, runAsUser: 0 }
        volumeMounts:
        - { name: pod-gpu-resources, mountPath: /var/lib/kubelet/pod-resources, readOnly: true }
      volumes:
      - name: pod-gpu-resources
        hostPath: { path: /var/lib/kubelet/pod-resources }
---
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: dcgm-exporter
  namespace: gmp-public
spec:
  selector:
    matchLabels: { app: dcgm-exporter }
  endpoints:
  - port: metrics
    interval: 15s
EOF

echo "[+] Prereqs done. Sleeping 30s for CRDs/adapters to register..."
sleep 30
kubectl get crd | grep -E "inferencepool|inferenceobjective|gateway"
