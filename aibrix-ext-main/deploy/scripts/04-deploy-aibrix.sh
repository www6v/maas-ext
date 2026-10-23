#!/bin/bash
# 部署 AIBrix 到 Minikube 集群
# 注意：由于 Docker Hub 无法直接访问，需要手动加载镜像

set -e

AIBRIX_VERSION="v0.7.0"
AIBRIX_DIR="$(dirname "$0")/../../aibrix"

echo "=== AIBrix 部署脚本 ==="
echo "版本: ${AIBRIX_VERSION}"

# 检查 Minikube 状态
echo "=== 检查 Minikube 状态 ==="
if ! minikube status | grep -q "Running"; then
    echo "✗ Minikube 未运行，请先执行 01-setup-minikube.sh"
    exit 1
fi

kubectl get nodes
echo ""

# 检查 AIBrix 源码
if [ ! -d "${AIBRIX_DIR}" ]; then
    echo "AIBrix 源码目录不存在，正在克隆..."
    git clone https://github.com/vllm-project/aibrix.git ${AIBRIX_DIR}
    cd ${AIBRIX_DIR}
    git checkout ${AIBRIX_VERSION} 2>/dev/null || git checkout main
fi

cd ${AIBRIX_DIR}

echo "=== 需要的 AIBrix 镜像列表 ==="
echo "由于 Docker Hub 无法直接访问，需要以下镜像："
echo "  - aibrix/controller-manager:${AIBRIX_VERSION}"
echo "  - aibrix/gateway-plugins:${AIBRIX_VERSION}"
echo "  - aibrix/metadata-service:${AIBRIX_VERSION}"
echo "  - aibrix/kuberay-operator:v1.2.1-patch-20250726"
echo "  - redis:latest"
echo "  - envoyproxy/envoy:v1.33.2"
echo "  - envoyproxy/gateway:v1.2.8"
echo ""

# 尝试从源码构建镜像
echo "=== 尝试构建 AIBrix 镜像 ==="
echo "注意：这需要能拉取基础镜像（golang, distroless 等）"

# 检查是否可以构建
if docker pull golang:1.22 > /dev/null 2>&1; then
    echo "可以拉取基础镜像，开始构建..."
    
    echo "构建 controller-manager..."
    make docker-build-controller-manager 2>&1 | tail -5 || echo "构建失败"
    
    echo "构建 gateway-plugins..."
    make docker-build-gateway-plugins 2>&1 | tail -5 || echo "构建失败"
    
    echo "构建 metadata-service..."
    make docker-build-metadata-service 2>&1 | tail -5 || echo "构建失败"
else
    echo "⚠ 无法拉取基础镜像"
    echo "请手动准备镜像或配置 Docker 代理"
    echo ""
    echo "替代方案："
    echo "1. 配置 Docker 使用代理"
    echo "2. 使用国内镜像源"
    echo "3. 手动下载镜像并 docker load"
fi

echo ""
echo "=== 部署 AIBrix CRDs ==="
kubectl apply -k config/crd --server-side 2>/dev/null || echo "CRDs 已存在"

echo "=== 部署 AIBrix 核心组件 ==="
# 使用 release overlay
kubectl apply -k config/overlays/release 2>/dev/null || {
    echo "使用默认配置部署..."
    kubectl apply -k config/default
}

echo "=== 等待 AIBrix 组件就绪 ==="
kubectl wait --for=condition=available deploy/aibrix-controller-manager -n aibrix-system --timeout=300s 2>/dev/null || echo "controller-manager 未就绪"

echo "=== 检查部署状态 ==="
kubectl get pods -n aibrix-system
kubectl get deploy -n aibrix-system

echo ""
echo "✓ AIBrix 部署脚本执行完成"
echo "注意：如果镜像拉取失败，需要手动解决网络问题"
