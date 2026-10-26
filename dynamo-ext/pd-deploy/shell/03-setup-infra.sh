#!/bin/bash
# 部署基础设施（NATS + etcd + Dynamo CRDs）- 使用国内镜像
set -e

echo "部署 NATS（阿里云镜像）..."
kubectl -n dynamo-system apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: nats}
spec:
  replicas: 1
  selector: {matchLabels: {app: nats}}
  template:
    metadata: {labels: {app: nats}}
    spec:
      containers:
      - {name: nats, image: registry.cn-hangzhou.aliyuncs.com/google_containers/nats:2.10.10, ports: [{containerPort: 4222}]}
---
apiVersion: v1
kind: Service
metadata: {name: nats}
spec:
  selector: {app: nats}
  ports: [{port: 4222, targetPort: 4222}]
EOF

echo "部署 etcd（阿里云镜像）..."
kubectl -n dynamo-system apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: etcd}
spec:
  replicas: 1
  selector: {matchLabels: {app: etcd}}
  template:
    metadata: {labels: {app: etcd}}
    spec:
      containers:
      - name: etcd
        image: registry.cn-hangzhou.aliyuncs.com/google_containers/etcd:3.5.21-0
        command: [etcd, --listen-client-urls, http://0.0.0.0:2379, --advertise-client-urls, http://0.0.0.0:2379]
        ports: [{containerPort: 2379}]
---
apiVersion: v1
kind: Service
metadata: {name: etcd}
spec:
  selector: {app: etcd}
  ports: [{port: 2379, targetPort: 2379}]
EOF

echo "等待 NATS + etcd 就绪..."
kubectl -n dynamo-system rollout status deployment/nats --timeout=120s
kubectl -n dynamo-system rollout status deployment/etcd --timeout=120s

echo "安装 Dynamo CRDs..."
cd /home/wangwei/wei/workspacePy/maas/dynamo-main/deploy/operator
# 只安装能成功的 CRDs（有些需要 K8s 1.30+ 特性）
kubectl apply -f config/crd/bases/nvidia.com_dynamographdeployments.yaml 2>&1 | tail -5 || echo "DGD CRD 安装失败"
kubectl apply -f config/crd/bases/nvidia.com_dynamocomponentdeployments.yaml 2>&1 | tail -5 || echo "DCD CRD 安装失败"
kubectl apply -f config/crd/bases/nvidia.com_dynamomodels.yaml 2>&1 | tail -5 || echo "Model CRD 安装失败"

echo ""
echo "验证部署："
kubectl -n dynamo-system get pods
echo "---"
kubectl get crd | grep nvidia.com | head -5
echo ""
echo "✓ 基础设施部署完成"
