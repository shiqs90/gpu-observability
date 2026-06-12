# Project 4 — GPU Observability (DCGM → Prometheus → Grafana + cost panel)

Layer GPU-level metrics and a **cost-per-million-tokens** panel on top of the Project 2 stack.
The DCGM exporter (GPU util/memory) was ALREADY running — the GPU Operator deployed it in
Project 1; this project finally scrapes it.

**Checkpoint:** one Grafana dashboard you can screenshot and narrate panel-by-panel:
GPU util, GPU memory, TTFT p99, KV-cache usage, cost/1M tokens, tokens/s.

## Hardware

No new compute — observes the existing 2× **g6.xlarge** (NVIDIA L4 24 GB) GPU nodes via their
DCGM exporter pods. Prometheus + Grafana run on the **m7i.large** CPU system node, whose root
disk was bumped **20→50 GB** after a 5.3 GB router image triggered an ephemeral-storage eviction.

## Deploy
```bash
# 1. Upgrade the existing helm release with observability enabled (Prometheus + Grafana +
#    ServiceMonitors + DCGM scrape). Same release, revision +1 — engines keep running.
helm upgrade vllm vllm/vllm-stack -f values-observability.yaml

# 2. Wait for the monitoring pods (Prometheus, Grafana, operator) to come up on the system node
kubectl get pods -w

# 3. Open Grafana: tunnel localhost:3000 -> the Grafana service inside the cluster
kubectl port-forward svc/vllm-grafana 3000:80
#    Login: admin / vllm-demo  (set in values; demo only)

# 4. Import the dashboard: Grafana UI -> Dashboards -> New -> Import -> upload
#    dashboard-gpu-cost.json  (select the bundled Prometheus as data source)

# 5. Generate load so panels move (a few completions through the router):
kubectl port-forward svc/vllm-router-service 30080:80 &
for i in $(seq 1 20); do curl -s http://localhost:30080/v1/completions -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct-AWQ","prompt":"Write one line about GPUs","max_tokens":64}' >/dev/null; done
```

## The cost panel (the differentiator)
```
cost per 1M tokens = (GPU $/hr) / (tokens/sec x 3600 / 1,000,000)
                   = (2 x $0.805) / (generation rate scaled to M tokens/hr)
```
PromQL: `(2 * 0.805) / clamp_min((sum(rate(vllm:generation_tokens_total[5m])) * 3600) / 1e6, 0.001)`
Narrative: idle GPUs are pure cost (rate→0 ⇒ cost→huge); batching more requests onto the same
GPU drives cost/token DOWN — this single panel ties GPU economics to serving efficiency, and is
the metric an inference platform is actually run on.

## Metric sources
| Panel | Metric | Exporter |
|---|---|---|
| GPU util / memory | `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED` | DCGM exporter (gpu-operator ns) |
| TTFT p99 | `vllm:time_to_first_token_seconds_bucket` | vLLM engines (/metrics) |
| KV-cache % | `vllm:kv_cache_usage_perc` | vLLM engines |
| Cost & throughput | `vllm:generation_tokens_total` | vLLM engines |
