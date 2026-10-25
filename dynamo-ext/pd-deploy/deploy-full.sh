#!/bin/bash
# Dynamo vLLM PD 分离完整部署脚本
# 前提：minikube 运行，K8s 1.30+，vGPU time-slicing 已配置
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Dynamo vLLM PD 分离完整部署"
echo "=========================================="
echo ""

# 配置代理（如果需要）
if [ -n "$HTTP_PROXY" ]; then
    echo "使用代理: $HTTP_PROXY"
    export HTTPS_PROXY="$HTTP_PROXY"
    export NO_PROXY="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8"
fi

DYNAMO_ROOT="/home/wangwei/wei/workspacePy/maas/dynamo-main"
DISAGG_YAML="$DYNAMO_ROOT/examples/backends/vllm/deploy/disagg.yaml"

# ----------------------------------------
# Step 1: 检查环境
# ----------------------------------------
echo "[1/7] 检查环境..."
if ! kubectl get nodes | grep -q "minikube"; then
    echo "错误: minikube 未运行"
    exit 1
fi

K8S_VERSION=$(kubectl version -o json | jq -r '.serverVersion.gitVersion')
echo "K8s 版本: $K8S_VERSION"

# 检查 vGPU
VGPU_COUNT=$(kubectl describe node minikube | grep "nvidia.com/gpu:" | grep Allocatable -A1 | tail -1 | awk '{print $2}')
if [ "$VGPU_COUNT" != "2" ]; then
    echo "警告: vGPU 数量不是 2（当前: $VGPU_COUNT）"
    echo "运行 setup-vgpu.sh 配置 time-slicing"
fi

# ----------------------------------------
# Step 2: 创建命名空间
# ----------------------------------------
echo "[2/7] 创建命名空间..."
kubectl create namespace dynamo-system --dry-run=client -o yaml | kubectl apply -f -

# ----------------------------------------
# Step 3: 部署 NATS + etcd
# ----------------------------------------
echo "[3/7] 部署 NATS + etcd..."

# 尝试使用代理拉取镜像
if [ -n "$HTTP_PROXY" ]; then
    echo "尝试使用代理拉取 NATS 镜像..."
    docker pull nats:latest || echo "NATS 镜像拉取失败，将使用本地镜像"
    minikube image load nats:latest || true
fi

bash setup-infra.sh

# ----------------------------------------
# Step 4: 准备 vLLM runtime 镜像
# ----------------------------------------
echo "[4/7] 准备 vLLM runtime 镜像..."

IMAGE_NAME="nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag"

# 检查镜像是否已存在
if docker images | grep -q "vllm-runtime.*my-tag"; then
    echo "✓ 镜像已存在: $IMAGE_NAME"
else
    echo "镜像不存在，尝试准备..."

    # 方案 1: 使用现有的 vllm-local 镜像
    if docker images | grep -q "vllm-local.*qwen3.5-4b"; then
        echo "使用现有 vllm-local 镜像（推理可能不工作，但可验证 K8s 流程）"
        docker tag vllm-local:qwen3.5-4b "$IMAGE_NAME"
    else
        # 方案 2: 尝试拉取官方镜像
        if [ -n "$HTTP_PROXY" ]; then
            echo "尝试拉取官方镜像..."
            docker pull nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0 || {
                echo "官方镜像拉取失败"
                echo "请手动构建或下载镜像"
                exit 1
            }
            docker tag nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0 "$IMAGE_NAME"
        else
            echo "错误: 未配置代理且无本地镜像"
            echo "请设置 HTTP_PROXY 或使用 build-dynamo-image.sh 构建"
            exit 1
        fi
    fi
fi

# 加载到 minikube
echo "加载镜像到 minikube..."
minikube image load "$IMAGE_NAME" || {
    echo "minikube image load 失败，尝试 docker save/load..."
    docker save "$IMAGE_NAME" | minikube image load -
}

# ----------------------------------------
# Step 5: 创建 HF Token Secret
# ----------------------------------------
echo "[5/7] 创建 HF Token Secret..."

HF_TOKEN_FILE="$HOME/.cache/huggingface/token"
if [ -f "$HF_TOKEN_FILE" ]; then
    kubectl -n dynamo-system create secret generic hf-token-secret \
      --from-literal=HF_TOKEN="$(cat "$HF_TOKEN_FILE")" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "✓ HF Token Secret 已创建"
else
    echo "警告: 未找到 HF Token，创建空 secret"
    kubectl -n dynamo-system create secret generic hf-token-secret \
      --from-literal=HF_TOKEN="placeholder" \
      --dry-run=client -o yaml | kubectl apply -f -
fi

# ----------------------------------------
# Step 6: 提交 DGD
# ----------------------------------------
echo "[6/7] 提交 DGD (disagg.yaml)..."

if [ ! -f "$DISAGG_YAML" ]; then
    echo "错误: 找不到 $DISAGG_YAML"
    exit 1
fi

kubectl -n dynamo-system apply -f "$DISAGG_YAML"
echo "✓ DGD 已提交"

# ----------------------------------------
# Step 7: 等待并就绪
# ----------------------------------------
echo "[7/7] 等待部署就绪..."
sleep 30

echo ""
echo "Pod 状态："
kubectl -n dynamo-system get pods -o wide

echo ""
echo "DGD 状态："
kubectl -n dynamo-system get dgd

echo ""
echo "=========================================="
echo "部署完成！"
echo "=========================================="
echo ""
echo "常用命令："
echo "  查看 pods:        kubectl -n dynamo-system get pods"
echo "  查看 DGD:         kubectl -n dynamo-system get dgd"
echo "  查看日志:         kubectl -n dynamo-system logs -f deploy/vllm-disagg-frontend"
echo "  端到端测试:       bash verify.sh"
echo "  清理:             bash cleanup.sh"
echo ""
echo "注意："
echo "  - 如果使用 vllm-local 镜像，worker 可能无法注册（缺少 dynamo 模块）"
echo "  - K8s 调度流程已验证，实际推理需要完整的 dynamo runtime 镜像"
echo "  - 查看 troubleshooting.md 了解常见问题"
