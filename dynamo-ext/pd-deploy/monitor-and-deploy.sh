#!/bin/bash
# 等待镜像构建完成并部署

echo "=== 监控镜像构建 ==="

# 等待构建完成
while ps -p 195693 > /dev/null 2>&1; do
    echo "$(date +%H:%M:%S) - 构建进行中..."
    tail -3 /tmp/dynamo-build-with-gcc.log | grep -E "Downloading|Successfully|Step" | tail -1
    sleep 30
done

echo ""
echo "=== 构建完成！==="
tail -20 /tmp/dynamo-build-with-gcc.log

# 检查是否成功
if tail -20 /tmp/dynamo-build-with-gcc.log | grep -q "Successfully built"; then
    echo "✅ 镜像构建成功"

    # 检查镜像
    echo ""
    echo "=== 检查新镜像 ==="
    docker images | grep "vllm-runtime:my-tag"

    # 加载到 minikube
    echo ""
    echo "=== 加载镜像到 minikube ==="
    docker save nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag | pv | minikube image load -

    # 重启 pods
    echo ""
    echo "=== 重启 pods ==="
    kubectl -n dynamo-system rollout restart deployment vllm-disagg-prefill
    kubectl -n dynamo-system rollout restart deployment vllm-disagg-decode

    # 等待 pods 启动
    echo ""
    echo "=== 等待 pods 启动（120秒）==="
    sleep 120

    # 检查状态
    echo ""
    echo "=== Pods 状态 ==="
    kubectl -n dynamo-system get pods

    # 检查日志
    echo ""
    echo "=== Prefill Worker 日志 ==="
    kubectl -n dynamo-system logs deployment/vllm-disagg-prefill --tail=30 | grep -E "INFO|ERROR|loaded|ready|GPU blocks|KV cache" | tail -15

    echo ""
    echo "=== Decode Worker 日志 ==="
    kubectl -n dynamo-system logs deployment/vllm-disagg-decode --tail=30 | grep -E "INFO|ERROR|loaded|ready|GPU blocks|KV cache" | tail -15

    # 测试推理
    echo ""
    echo "=== 测试端到端推理 ==="
    sleep 60  # 再等一下确保模型加载完成

    # Port forward
    kubectl -n dynamo-system port-forward svc/vllm-disagg-frontend 8000:8000 &
    PF_PID=$!
    sleep 5

    # 发送请求
    curl -s http://localhost:8000/v1/completions \
      -H "Content-Type: application/json" \
      -d '{
        "model": "/data/models/models/Qwen3-0.6B",
        "prompt": "What is PD disaggregation?",
        "max_tokens": 50
      }' | jq '.'

    # 停止 port forward
    kill $PF_PID 2>/dev/null

    echo ""
    echo "=== 部署完成！==="
else
    echo "❌ 镜像构建失败"
    tail -50 /tmp/dynamo-build-with-gcc.log
    exit 1
fi
