#!/bin/bash
set -e

echo "Starting AIBrix services..."

# Start Redis (if not already running)
if ! redis-cli ping > /dev/null 2>&1; then
    echo "Starting Redis..."
    echo "123" | sudo -S systemctl start redis-server
    sleep 2
fi
echo "✓ Redis: $(redis-cli ping)"

# Start metadata-service
if ! ps aux | grep -v grep | grep -q aibrix_metadata; then
    echo "Starting metadata-service..."
    cd /home/wangwei/wei/workspacePy/maas/aibrix/python/aibrix
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
    REDIS_HOST=127.0.0.1 REDIS_PORT=6379 setsid poetry run aibrix_metadata \
        --host 0.0.0.0 --port 8090 --enable-k8s-support \
        > /tmp/metadata-service.log 2>&1 &
    disown
    sleep 3
fi
echo "✓ metadata-service: $(curl -s http://localhost:8090/healthz)"

# Start gateway-plugin
if ! ps aux | grep -v grep | grep -q gateway-plugin; then
    echo "Starting gateway-plugin..."
    cd /home/wangwei/wei/workspacePy/maas/aibrix-ext/deploy/bin
    REDIS_HOST=127.0.0.1 REDIS_PORT=6379 POD_NAME=gateway-plugin-host POD_NAMESPACE=aibrix-system \
        setsid ./gateway-plugin --kubeconfig=/home/wangwei/.kube/config \
        > /tmp/gateway-plugin.log 2>&1 &
    disown
    sleep 3
fi
echo "✓ gateway-plugin: $(ps aux | grep -v grep | grep gateway-plugin | wc -l) process(es)"

# Start vLLM (if not already running)
if ! curl -s http://localhost:8000/v1/models > /dev/null 2>&1; then
    echo "Starting vLLM..."
    if [ -f /home/wangwei/wei/workspacePy/maas/aibrix-ext/deploy/scripts/03-start-vllm.sh ]; then
        /home/wangwei/wei/workspacePy/maas/aibrix-ext/deploy/scripts/03-start-vllm.sh
    fi
    sleep 5
fi
if curl -s http://localhost:8000/v1/models > /dev/null 2>&1; then
    MODEL=$(curl -s http://localhost:8000/v1/models | python3 -c 'import sys,json; d=json.load(sys.stdin)["data"]; print(d[0]["id"] if d else "no models")' 2>/dev/null)
    echo "✓ vLLM: $MODEL"
else
    echo "✗ vLLM: not running"
fi

echo ""
echo "=== All services started! ==="
echo ""
echo "Service endpoints:"
echo "  Redis:            127.0.0.1:6379 (host)"
echo "  metadata-service: http://localhost:8090 (host)"
echo "  gateway-plugin:   localhost:50052 (gRPC), localhost:8080 (metrics)"
echo "  vLLM:             http://localhost:8000 (host)"
echo "  controller-mgr:   K8s pod in aibrix-system namespace"
