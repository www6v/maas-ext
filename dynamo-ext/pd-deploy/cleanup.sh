#!/bin/bash
# 清理 Dynamo PD 分离部署
set -e

echo "=========================================="
echo "清理 Dynamo PD 分离部署"
echo "=========================================="
echo ""

# 删除 DGD
echo "删除 DGD..."
kubectl -n dynamo-system delete dgd vllm-disagg 2>/dev/null || echo "DGD 不存在"

# 删除 NATS/etcd
echo "删除 NATS + etcd..."
kubectl -n dynamo-system delete deployment nats etcd 2>/dev/null || true
kubectl -n dynamo-system delete service nats etcd 2>/dev/null || true

# 删除 HF secret
echo "删除 HF Token Secret..."
kubectl -n dynamo-system delete secret hf-token-secret 2>/dev/null || true

# 卸载 Dynamo Platform
echo "卸载 Dynamo Platform..."
helm uninstall dynamo-platform -n dynamo-system 2>/dev/null || true

# 删除命名空间（可选，谨慎）
# echo "删除命名空间 dynamo-system..."
# kubectl delete namespace dynamo-system

# 停止 port-forward
echo "停止 port-forward 进程..."
pkill -f "port-forward.*8000" 2>/dev/null || true

echo ""
echo "✓ 清理完成"
echo ""
echo "注意：vGPU time-slicing 配置保留。如需清理："
echo "  kubectl -n gpu-operator delete configmap time-slicing-config"
echo "  kubectl patch clusterpolicy cluster-policy --type=json -p='[{\"op\": \"remove\", \"path\": \"/spec/devicePlugin/config\"}]'"
