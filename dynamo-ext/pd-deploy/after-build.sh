#!/bin/bash
# 构建完成后执行：加载镜像 + 重新部署 + 端到端测试
set -e

echo "=========================================="
echo "端到端验证（构建完成后）"
echo "=========================================="
echo ""

IMAGE="nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag"

# Step 1: 检查镜像
echo "[1/6] 检查镜像..."
if ! docker images | grep -q "vllm-runtime.*my-tag"; then
    echo "❌ 镜像未构建成功"
    tail -30 /tmp/dynamo-slim-build2.log
    exit 1
fi
echo "✓ 镜像存在"

# Step 2: 验证镜像内容
echo "[2/6] 验证镜像内容..."
docker run --rm "$IMAGE" python3 -c "
import vllm
print('vLLM:', vllm.__version__)
try:
    import dynamo
    print('Dynamo:', dynamo.__version__)
except ImportError:
    print('Dynamo: NOT FOUND (will mount source)')
try:
    import nixl
    print('NIXL: OK')
except ImportError:
    print('NIXL: NOT FOUND')
" 2>&1 | tail -10

# Step 3: 加载到 minikube
echo "[3/6] 加载镜像到 minikube..."
docker save "$IMAGE" | minikube image load -
echo "✓ 镜像已加载"

# Step 4: 删除旧的 pods，触发重新调度
echo "[4/6] 重新部署 workers..."
kubectl -n dynamo-system delete deployment vllm-disagg-prefill vllm-disagg-decode vllm-disagg-frontend 2>/dev/null || true

# 重新创建（使用 test-vgpu-scheduling.sh 的逻辑）
bash /home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-deploy/test-vgpu-scheduling.sh 2>&1 | tail -30

# Step 5: 等待 pods 启动
echo "[5/6] 等待 pods 启动（90秒）..."
sleep 90

echo ""
echo "Pod 状态："
kubectl -n dynamo-system get pods

# Step 6: 检查容器日志
echo "[6/6] 检查日志..."
echo ""
echo "=== Prefill Worker ==="
PREFILL_POD=$(kubectl -n dynamo-system get pods -l app=vllm-disagg-prefill -o name | head -1)
if [ -n "$PREFILL_POD" ]; then
    kubectl -n dynamo-system logs "$PREFILL_POD" --tail=30
fi

echo ""
echo "=== Decode Worker ==="
DECODE_POD=$(kubectl -n dynamo-system get pods -l app=vllm-disagg-decode -o name | head -1)
if [ -n "$DECODE_POD" ]; then
    kubectl -n dynamo-system logs "$DECODE_POD" --tail=30
fi

echo ""
echo "=========================================="
echo "验证状态"
echo "=========================================="
echo ""
kubectl -n dynamo-system get pods | grep vllm-disagg
echo ""
echo "如果 pods 都是 Running 且没有 crash，说明 dynamo 模块已加载成功。"
echo "下一步: 检查 worker 是否注册到 NATS，并测试端到端推理。"
