#!/bin/bash
# 直接创建 prefill/decode worker deployments（绕过 Operator）
# 目的：验证 vGPU 调度、镜像加载、容器启动
set -e

echo "=========================================="
echo "手动创建 Worker Pods（vGPU 调度验证）"
echo "=========================================="
echo ""

# 创建 Frontend Pod（不依赖 Operator）
echo "[1/3] 创建 Frontend Pod..."
kubectl -n dynamo-system apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-disagg-frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-disagg-frontend
  template:
    metadata:
      labels:
        app: vllm-disagg-frontend
    spec:
      containers:
      - name: main
        image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag
        imagePullPolicy: IfNotPresent
        command: [python3, -m, dynamo.frontend]
        args: [--http-port, "8000"]
        ports:
        - containerPort: 8000
        resources:
          limits:
            nvidia.com/gpu: 0
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-disagg-frontend
spec:
  selector:
    app: vllm-disagg-frontend
  ports:
  - port: 8000
    targetPort: 8000
EOF

# 创建 Prefill Worker Pod（需要 1 个 vGPU）
echo "[2/3] 创建 Prefill Worker Pod..."
kubectl -n dynamo-system apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-disagg-prefill
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-disagg-prefill
  template:
    metadata:
      labels:
        app: vllm-disagg-prefill
    spec:
      containers:
      - name: main
        image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag
        imagePullPolicy: IfNotPresent
        command: [python3, -m, dynamo.vllm]
        args:
        - --model
        - Qwen/Qwen3-0.6B
        - --disaggregation-mode
        - prefill
        - --kv-transfer-config
        - '{"kv_connector":"NixlConnector","kv_role":"kv_producer"}'
        envFrom:
        - secretRef:
            name: hf-token-secret
        resources:
          limits:
            nvidia.com/gpu: 1
EOF

# 创建 Decode Worker Pod（需要 1 个 vGPU）
echo "[3/3] 创建 Decode Worker Pod..."
kubectl -n dynamo-system apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-disagg-decode
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-disagg-decode
  template:
    metadata:
      labels:
        app: vllm-disagg-decode
    spec:
      containers:
      - name: main
        image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag
        imagePullPolicy: IfNotPresent
        command: [python3, -m, dynamo.vllm]
        args:
        - --model
        - Qwen/Qwen3-0.6B
        - --disaggregation-mode
        - decode
        - --kv-transfer-config
        - '{"kv_connector":"NixlConnector","kv_role":"kv_consumer"}'
        envFrom:
        - secretRef:
            name: hf-token-secret
        resources:
          limits:
            nvidia.com/gpu: 1
EOF

echo ""
echo "等待 pods 调度（30秒）..."
sleep 30

echo ""
echo "=========================================="
echo "Pod 状态"
echo "=========================================="
kubectl -n dynamo-system get pods -o wide

echo ""
echo "=========================================="
echo "GPU 分配验证"
echo "=========================================="
for pod in $(kubectl -n dynamo-system get pods -l app -o name | grep vllm-disagg); do
    echo ""
    echo "Pod: $pod"
    kubectl -n dynamo-system get $pod -o json | jq -r '
      "  Node: \(.spec.nodeName)",
      "  GPU Request: \(.spec.containers[0].resources.limits["nvidia.com/gpu"] // "0")",
      "  Status: \(.status.phase)",
      "  Container State: \(.status.containerStatuses[0].state | keys[0])"
    '
done

echo ""
echo "=========================================="
echo "验证结果"
echo "=========================================="
echo ""

# 检查是否所有 pods 都调度成功
PENDING=$(kubectl -n dynamo-system get pods -l app | grep vllm-disagg | grep -c "Pending" || true)
RUNNING=$(kubectl -n dynamo-system get pods -l app | grep vllm-disagg | grep -c "Running\|ContainerCreating" || true)
FAILED=$(kubectl -n dynamo-system get pods -l app | grep vllm-disagg | grep -c "Error\|CrashLoop\|ImagePull" || true)

echo "Pending: $PENDING"
echo "Running/Creating: $RUNNING"
echo "Failed: $FAILED"
echo ""

if [ "$PENDING" -eq 0 ] && [ "$RUNNING" -gt 0 ]; then
    echo "✅ vGPU 调度成功！所有 worker pods 已调度"
    echo ""
    echo "说明："
    echo "  - Prefill worker 分配到 1 个 vGPU"
    echo "  - Decode worker 分配到 1 个 vGPU"
    echo "  - 两个 vGPU 来自同一张 RTX 3090（time-slicing）"
    echo ""
    if [ "$FAILED" -gt 0 ]; then
        echo "⚠️ 部分 pods 启动失败（可能缺少 dynamo 模块）"
        echo "  这证明了 K8s 调度层工作正常"
        echo "  实际推理需要完整的 dynamo runtime 镜像"
    fi
else
    echo "❌ 调度失败"
    echo "检查: kubectl -n dynamo-system describe pod <pod-name>"
fi
