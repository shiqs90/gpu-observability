#!/usr/bin/env bash
# Generate inference traffic through the router so the Grafana panels populate.
# (TTFT, KV-cache %, throughput and cost/1M-tokens are per-request metrics — an idle
# cluster shows "No data" or extreme values.)
#
# Usage:
#   ./generate-load.sh                 # 30 sequential requests, 64 tokens each
#   REQUESTS=40 CONCURRENT=true MAX_TOKENS=512 ./generate-load.sh
#                                      # 40 simultaneous long generations: KV-cache visibly
#                                      # fills, GPU util pegs, cost/1M drops hardest
set -uo pipefail

MODEL="${MODEL:-Qwen/Qwen2.5-7B-Instruct-AWQ}"
REQUESTS="${REQUESTS:-30}"
MAX_TOKENS="${MAX_TOKENS:-64}"
CONCURRENT="${CONCURRENT:-false}"
PORT=30080

PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Port-forward localhost:${PORT} -> router service (backgrounded, auto-cleaned on exit)"
echo "\$ kubectl port-forward svc/vllm-router-service ${PORT}:80"
kubectl port-forward svc/vllm-router-service "${PORT}:80" >/tmp/loadgen-pf.log 2>&1 &
PF_PID=$!
for i in $(seq 1 15); do
  curl -sf "http://localhost:${PORT}/v1/models" >/dev/null 2>&1 && break
  sleep 1
  [ "$i" = "15" ] && { echo "FAIL: router tunnel never came up. See /tmp/loadgen-pf.log"; exit 1; }
done

BODY="{\"model\":\"${MODEL}\",\"prompt\":\"Write a detailed explanation of GPU computing\",\"max_tokens\":${MAX_TOKENS}}"
echo "==> Sending ${REQUESTS} requests (model=${MODEL}, max_tokens=${MAX_TOKENS}, concurrent=${CONCURRENT})"
echo "\$ curl -s http://localhost:${PORT}/v1/completions -H 'Content-Type: application/json' -d '${BODY}'"

if [ "$CONCURRENT" = "true" ]; then
  # All at once: vLLM batches them -> KV-cache fills, GPU util pegs, cost/token drops
  for i in $(seq 1 "$REQUESTS"); do
    curl -s "http://localhost:${PORT}/v1/completions" -H "Content-Type: application/json" -d "$BODY" >/dev/null &
  done
  wait
else
  for i in $(seq 1 "$REQUESTS"); do
    curl -s "http://localhost:${PORT}/v1/completions" -H "Content-Type: application/json" -d "$BODY" >/dev/null
    echo "  req $i/${REQUESTS}"
  done
fi

echo "==> Done. Watch the dashboard for the next ~1-2 min (Prometheus scrapes every 30s)."
