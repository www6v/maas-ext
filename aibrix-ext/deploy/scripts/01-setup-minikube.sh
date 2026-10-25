#!/bin/bash
# Minikube 集群设置脚本
# 用于创建支持 GPU 的单节点 Minikube 集群

set -e

echo "=== 检查 Minikube 是否已安装 ==="
if ! command -v minikube &> /dev/null; then
    echo "Minikube 未安装，正在安装..."
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
fi

echo "=== 检查 kubectl 是否已安装 ==="
if ! command -v kubectl &> /dev/null; then
    echo "kubectl 未安装，正在安装..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install kubectl /usr/local/bin/kubectl
    rm kubectl
fi

echo "=== 检查 NVIDIA Container Toolkit ==="
if ! command -v nvidia-container-runtime &> /dev/null; then
    echo "NVIDIA Container Toolkit 未安装"
    echo "请参考: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
    exit 1
fi

echo "=== 停止现有 Minikube 集群（如果存在）==="
minikube stop 2>/dev/null || true
minikube delete 2>/dev/null || true

echo "=== 启动 Minikube 集群（带 GPU 支持）==="
minikube start \
    --driver=docker \
    --container-runtime=containerd \
    --gpus=all \
    --cpus=8 \
    --memory=16g \
    --disk-size=50g \
    --kubernetes-version=v1.28.0

echo "=== 验证集群状态 ==="
kubectl cluster-info
kubectl get nodes

echo "=== 部署 NVIDIA Device Plugin ==="
kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.1/deployments/static/nvidia-device-plugin.yml

echo "=== 等待 NVIDIA Device Plugin 就绪 ==="
kubectl wait --for=condition=ready pod -l app=nvidia-device-plugin -n kube-system --timeout=300s

echo "=== 检查 GPU 资源 ==="
kubectl describe node minikube | grep -A 5 "Capacity:" | grep nvidia

echo "✓ Minikube 集群设置完成！"
