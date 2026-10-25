#!/bin/bash
# PD 分离部署恢复脚本
# 用于在磁盘空间清理后恢复部署

set -e

echo "=========================================="
echo "PD 分离部署恢复"
echo "=========================================="
echo ""

# Step 1: 检查磁盘空间
echo "[1/6] 检查磁盘空间..."
df -h / | tail -1
minikube ssh -- df -h / | tail -1
echo ""

# Step 2: 验证新镜像
echo "[2/6] 验证新镜像..."
docker images | grep "vllm-runtime:my-tag"
echo ""

# Step 3: 加载镜像到 minikube
echo "[3/6] 加载镜像到 minikube（需要约 10GB 空间）..."
docker save 04ac7611ee0d | minikube image load -
echo "✅ 镜像加载完成"
echo ""

# Step 4: 验证 gcc
echo "[4/6] 验证镜像中的 gcc..."
minikube ssh -- docker run --rm nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag bash -c "which gcc && gcc --version | head -1"
echo ""

# Step 5: 重启 deployments
echo "[5/6] 重启 deployments..."
kubectl -n dynamo-system scale deployment vllm-disagg-prefill --replicas=1
kubectl -n dynamo-system scale deployment vllm-disagg-decode --replicas=1
kubectl -n dynamo-system scale deployment vllm-disagg-frontend --replicas=1
echo "✅ Deployments 已启动"
echo ""

# Step 6: 等待并验证
echo "[6/6] 等待 pods 启动（120秒）..."
sleep 120

echo ""
echo "=== Pods 状态 ==="
kubectl -n dynamo-system get pods

echo ""
echo "=== Prefill Worker 日志 ==="
kubectl -n dynamo-system logs deployment/vllm-disagg-prefill --tail=30 | grep -E "INFO|ERROR|loaded|ready|GPU blocks|KV cache" | tail -15

echo ""
echo "=== Decode Worker 日志 ==="
kubectl -n dynamo-system logs deployment/vllm-disagg-decode --tail=30 | grep -E "INFO|ERROR|loaded|ready|GPU blocks|KV cache" | tail -15

echo ""
echo "=========================================="
echo "部署恢复完成！"
echo "=========================================="
echo ""
echo "下一步：测试端到端推理"
echo "  kubectl -n dynamo-system port-forward svc/vllm-disagg-frontend 8000:8000"
echo "  curl http://localhost:8000/v1/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\": \"/models/Qwen3-0.6B\", \"prompt\": \"Hello\", \"max_tokens\": 50}'"
