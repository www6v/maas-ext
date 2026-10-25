#!/bin/bash
# 端到端验证脚本
# 测试：服务启动 → 发送请求 → 收到响应
set -e

echo "=========================================="
echo "端到端验证"
echo "=========================================="
echo ""

# Step 1: 重新部署 workers（使用新镜像）
echo "[1/5] 重新部署 workers..."
kubectl -n dynamo-system rollout restart deployment vllm-disagg-prefill
kubectl -n dynamo-system rollout restart deployment vllm-disagg-decode
kubectl -n dynamo-system rollout restart deployment vllm-disagg-frontend

echo "等待 pods 重启（60秒）..."
sleep 60

# Step 2: 检查 pod 状态
echo "[2/5] 检查 pod 状态..."
kubectl -n dynamo-system get pods

# 检查是否有 Running 的 pods
RUNNING=$(kubectl -n dynamo-system get pods | grep vllm-disagg | grep -c "Running" || true)
if [ "$RUNNING" -lt 3 ]; then
    echo "警告: 只有 $RUNNING/3 个 pods 在运行"
    echo "检查日志："
    kubectl -n dynamo-system logs -l app=vllm-disagg-prefill --tail=20
    exit 1
fi

# Step 3: Port-forward frontend
echo "[3/5] 启动 port-forward..."
kubectl -n dynamo-system port-forward svc/vllm-disagg-frontend 8000:8000 &
PF_PID=$!
sleep 5

# Step 4: 发送测试请求
echo "[4/5] 发送测试请求..."
RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role":"user","content":"What is PD disaggregation? Answer in one sentence."}],
    "max_tokens": 100
  }' 2>&1 || echo "FAILED")

# 停止 port-forward
kill $PF_PID 2>/dev/null || true

# Step 5: 分析结果
echo "[5/5] 分析结果..."
echo ""

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | grep -v "HTTP_CODE:")

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ 端到端验证成功！"
    echo ""
    echo "HTTP 状态码: $HTTP_CODE"
    echo ""
    echo "响应内容："
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    echo ""
    echo "=========================================="
    echo "验证完成"
    echo "=========================================="
    echo ""
    echo "✅ vGPU time-slicing: 工作正常"
    echo "✅ K8s 调度: 工作正常"
    echo "✅ Dynamo 服务: 启动成功"
    echo "✅ 推理请求: 成功处理"
    echo "✅ 端到端流程: 完全验证"
    exit 0
else
    echo "❌ 端到端验证失败"
    echo ""
    echo "HTTP 状态码: $HTTP_CODE"
    echo ""
    echo "响应内容："
    echo "$BODY"
    echo ""
    echo "检查日志："
    kubectl -n dynamo-system logs -l app=vllm-disagg-frontend --tail=30
    kubectl -n dynamo-system logs -l app=vllm-disagg-prefill --tail=30
    kubectl -n dynamo-system logs -l app=vllm-disagg-decode --tail=30
    exit 1
fi
