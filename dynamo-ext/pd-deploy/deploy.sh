#!/bin/bash
# Dynamo vLLM PD 分离部署脚本（vGPU time-slicing 方案）
# 目标：在单 GPU 上通过 vGPU 虚拟化运行 2 worker 的 PD 分离
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Dynamo vLLM PD 分离部署（vGPU 方案）"
echo "=========================================="
echo ""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ----------------------------------------
# Step 1: 检查 minikube 状态
# ----------------------------------------
log_info "Step 1: 检查 minikube 状态..."
if ! minikube status | grep -q "Running"; then
    log_error "minikube 未运行，请先执行: minikube start --driver=docker --gpus=all"
    exit 1
fi
log_info "✓ minikube 运行中"

# ----------------------------------------
# Step 2: 创建命名空间
# ----------------------------------------
log_info "Step 2: 创建命名空间 dynamo-system..."
kubectl create namespace dynamo-system --dry-run=client -o yaml | kubectl apply -f -
log_info "✓ 命名空间就绪"

# ----------------------------------------
# Step 3: 配置 GPU time-slicing (1 物理 GPU → 2 vGPU)
# ----------------------------------------
log_info "Step 3: 配置 GPU time-slicing..."

# 检查是否已配置
if kubectl -n gpu-operator get configmap time-slicing-config &>/dev/null; then
    log_warn "time-slicing-config 已存在，跳过创建"
else
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: 2
EOF
    log_info "✓ time-slicing-config 已创建"
fi

# 配置 ClusterPolicy 使用 time-slicing
log_info "配置 ClusterPolicy..."
kubectl patch clusterpolicy cluster-policy \
  --type merge \
  -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}' 2>/dev/null || {
    log_warn "ClusterPolicy patch 失败（可能 gpu-operator 未安装），尝试直接配置 device plugin..."
}

# 重启 device plugin 使配置生效
log_info "重启 nvidia-device-plugin..."
kubectl -n gpu-operator rollout restart daemonset nvidia-device-plugin-daemonset 2>/dev/null || {
    log_warn "无法重启 device plugin daemonset，可能需要手动重启"
}

# 等待 vGPU 生效
log_info "等待 vGPU 配置生效（30秒）..."
sleep 30

# 验证 vGPU 数量
VGPU_COUNT=$(kubectl describe node minikube | grep "nvidia.com/gpu:" | grep Allocatable -A1 | tail -1 | awk '{print $2}')
if [ "$VGPU_COUNT" = "2" ]; then
    log_info "✓ vGPU 配置成功：检测到 $VGPU_COUNT 个虚拟 GPU"
else
    log_warn "vGPU 数量异常：期望 2，实际 $VGPU_COUNT"
    log_warn "继续部署，但可能会遇到 GPU 调度问题"
fi

# ----------------------------------------
# Step 4: 部署 NATS + etcd
# ----------------------------------------
log_info "Step 4: 部署 NATS + etcd..."

kubectl -n dynamo-system apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nats
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nats
  template:
    metadata:
      labels:
        app: nats
    spec:
      containers:
      - name: nats
        image: nats:latest
        ports:
        - containerPort: 4222
---
apiVersion: v1
kind: Service
metadata:
  name: nats
spec:
  selector:
    app: nats
  ports:
  - port: 4222
    targetPort: 4222
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: etcd
spec:
  replicas: 1
  selector:
    matchLabels:
      app: etcd
  template:
    metadata:
      labels:
        app: etcd
    spec:
      containers:
      - name: etcd
        image: quay.io/coreos/etcd:v3.5.21
        command:
        - etcd
        - --listen-client-urls
        - http://0.0.0.0:2379
        - --advertise-client-urls
        - http://0.0.0.0:2379
        ports:
        - containerPort: 2379
---
apiVersion: v1
kind: Service
metadata:
  name: etcd
spec:
  selector:
    app: etcd
  ports:
  - port: 2379
    targetPort: 2379
EOF

log_info "等待 NATS + etcd 就绪..."
kubectl -n dynamo-system rollout status deployment/nats --timeout=120s
kubectl -n dynamo-system rollout status deployment/etcd --timeout=120s
log_info "✓ NATS + etcd 就绪"

# ----------------------------------------
# Step 5: 安装 Dynamo Platform (Operator + CRD)
# ----------------------------------------
log_info "Step 5: 安装 Dynamo Platform..."

DYNAMO_ROOT="/home/wangwei/wei/workspacePy/maas/dynamo-main"
if [ ! -d "$DYNAMO_ROOT/deploy/helm/charts/platform" ]; then
    log_error "找不到 Dynamo Platform helm chart: $DYNAMO_ROOT/deploy/helm/charts/platform"
    exit 1
fi

helm install dynamo-platform "$DYNAMO_ROOT/deploy/helm/charts/platform/" \
  --namespace dynamo-system \
  --create-namespace 2>&1 | tee /tmp/helm-install.log || {
    log_warn "Helm install 失败，可能已安装，尝试升级..."
    helm upgrade dynamo-platform "$DYNAMO_ROOT/deploy/helm/charts/platform/" \
      --namespace dynamo-system
}

log_info "等待 Dynamo CRD 就绪..."
sleep 10
kubectl get crd | grep dynamo || {
    log_error "Dynamo CRD 未找到"
    exit 1
}
log_info "✓ Dynamo Platform 就绪"

# ----------------------------------------
# Step 6: 准备镜像
# ----------------------------------------
log_info "Step 6: 准备 vLLM runtime 镜像..."

# 使用国内可访问的镜像，或从本地加载
IMAGE_NAME="nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag"

# 检查镜像是否已存在
if docker images | grep -q "vllm-runtime.*my-tag"; then
    log_info "✓ 镜像已存在：$IMAGE_NAME"
else
    log_warn "镜像不存在，尝试拉取或构建..."

    # 尝试拉取官方镜像（可能需要代理）
    if docker pull nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0 2>/dev/null; then
        docker tag nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0 $IMAGE_NAME
        log_info "✓ 官方镜像拉取成功并打 tag"
    else
        log_warn "官方镜像拉取失败，尝试使用替代镜像..."
        # 这里可以添加从国内镜像拉取的逻辑
        # 或者提示用户手动构建
        cat <<EOF

${YELLOW}镜像准备失败。请手动执行以下步骤之一：${NC}

选项 1: 使用代理拉取官方镜像
  export HTTP_PROXY=http://your-proxy:port
  export HTTPS_PROXY=http://your-proxy:port
  docker pull nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0
  docker tag nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0 $IMAGE_NAME

选项 2: 从本地源码构建
  cd $DYNAMO_ROOT
  docker build -t $IMAGE_NAME -f container/Dockerfile.vllm .

选项 3: 使用国内镜像（如果有）
  docker pull <国内镜像>/vllm-runtime:<tag>
  docker tag <国内镜像>/vllm-runtime:<tag> $IMAGE_NAME

完成后重新运行此脚本。
EOF
        exit 1
    fi
fi

# 加载镜像到 minikube
log_info "加载镜像到 minikube..."
minikube image load $IMAGE_NAME 2>&1 | tail -5 || {
    log_warn "minikube image load 失败，尝试 docker save + load..."
    docker save $IMAGE_NAME | minikube image load -
}
log_info "✓ 镜像加载完成"

# ----------------------------------------
# Step 7: 创建 HF Token Secret
# ----------------------------------------
log_info "Step 7: 创建 HuggingFace Token Secret..."

HF_TOKEN_FILE="$HOME/.cache/huggingface/token"
if [ -f "$HF_TOKEN_FILE" ]; then
    HF_TOKEN=$(cat "$HF_TOKEN_FILE")
    kubectl -n dynamo-system create secret generic hf-token-secret \
      --from-literal=HF_TOKEN="$HF_TOKEN" \
      --dry-run=client -o yaml | kubectl apply -f -
    log_info "✓ HF Token Secret 已创建"
else
    log_warn "未找到 HF Token 文件: $HF_TOKEN_FILE"
    log_warn "创建空 secret（模型下载可能失败）..."
    kubectl -n dynamo-system create secret generic hf-token-secret \
      --from-literal=HF_TOKEN="placeholder" \
      --dry-run=client -o yaml | kubectl apply -f -
fi

# ----------------------------------------
# Step 8: 部署 vLLM PD 分离 (disagg.yaml)
# ----------------------------------------
log_info "Step 8: 部署 vLLM PD 分离..."

DISAGG_YAML="$DYNAMO_ROOT/examples/backends/vllm/deploy/disagg.yaml"
if [ ! -f "$DISAGG_YAML" ]; then
    log_error "找不到 disagg.yaml: $DISAGG_YAML"
    exit 1
fi

kubectl -n dynamo-system apply -f "$DISAGG_YAML"
log_info "✓ DGD 已提交"

# ----------------------------------------
# Step 9: 等待部署就绪
# ----------------------------------------
log_info "Step 9: 等待部署就绪（这可能需要几分钟）..."

# 等待 pods 启动
log_info "等待 pods 启动..."
sleep 30

# 检查 pod 状态
log_info "Pod 状态："
kubectl -n dynamo-system get pods -o wide

# 等待每个 pod ready
for component in frontend prefill decode; do
    log_info "等待 $component 就绪..."
    kubectl -n dynamo-system wait --for=condition=ready pod -l app=vllm-disagg-$component --timeout=300s 2>/dev/null || {
        log_warn "$component 未能在 5 分钟内就绪，检查日志..."
        kubectl -n dynamo-system logs -l app=vllm-disagg-$component --tail=50
    }
done

# ----------------------------------------
# Step 10: 端到端验证
# ----------------------------------------
log_info "Step 10: 端到端验证..."

# Port-forward frontend service
log_info "启动 port-forward..."
kubectl -n dynamo-system port-forward svc/vllm-disagg-frontend 8000:8000 &
PF_PID=$!
sleep 5

# 发送测试请求
log_info "发送测试请求..."
RESPONSE=$(curl -s -w "\n%{http_code}" http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [{"role":"user","content":"Hello, what is PD disaggregation?"}],
    "max_tokens": 64
  }' || echo "FAILED")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

# 停止 port-forward
kill $PF_PID 2>/dev/null || true

if [ "$HTTP_CODE" = "200" ]; then
    log_info "✓ 端到端验证成功！HTTP $HTTP_CODE"
    echo ""
    echo "响应内容："
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
else
    log_error "✗ 端到端验证失败：HTTP $HTTP_CODE"
    echo "$BODY"
    log_info "检查日志以诊断问题："
    log_info "  kubectl -n dynamo-system logs -l app=vllm-disagg-frontend"
    log_info "  kubectl -n dynamo-system logs -l app=vllm-disagg-prefill"
    log_info "  kubectl -n dynamo-system logs -l app=vllm-disagg-decode"
fi

echo ""
echo "=========================================="
log_info "部署完成！"
echo "=========================================="
echo ""
echo "常用命令："
echo "  查看 DGD 状态:    kubectl -n dynamo-system get dgd"
echo "  查看 pods:        kubectl -n dynamo-system get pods"
echo "  查看 frontend 日志: kubectl -n dynamo-system logs -f deploy/vllm-disagg-frontend"
echo "  删除部署:         kubectl -n dynamo-system delete dgd vllm-disagg"
echo ""
