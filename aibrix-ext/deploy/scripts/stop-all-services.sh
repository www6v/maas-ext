#!/bin/bash
echo "Stopping AIBrix services..."

# Stop gateway-plugin
if ps aux | grep -v grep | grep -q "gateway-plugin"; then
    pkill -f "gateway-plugin"
    echo "✓ gateway-plugin stopped"
else
    echo "  gateway-plugin not running"
fi

# Stop metadata-service
if ps aux | grep -v grep | grep -q "aibrix_metadata"; then
    pkill -f "aibrix_metadata"
    echo "✓ metadata-service stopped"
else
    echo "  metadata-service not running"
fi

# Stop vLLM
if ps aux | grep -v grep | grep -q "vllm.entrypoints"; then
    pkill -f "vllm.entrypoints"
    echo "✓ vLLM stopped"
else
    echo "  vLLM not running"
fi

echo "  Redis still running (system service). To stop: echo '123' | sudo -S systemctl stop redis-server"
echo ""
echo "All AIBrix services stopped!"
