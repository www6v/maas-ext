#!/bin/bash
# 配置 GPU time-slicing 并验证
set -e

echo "配置 GPU time-slicing..."

# Patch device plugin daemonset
kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "device-plugin-config",
      "configMap": {
        "name": "nvidia-device-plugin-config"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "device-plugin-config",
      "mountPath": "/etc/kubernetes/device-plugin-config.yaml",
      "subPath": "config.yaml"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "CONFIG_FILE",
      "value": "/etc/kubernetes/device-plugin-config.yaml"
    }
  }
]'

echo "等待 device plugin 重启..."
kubectl -n kube-system rollout status ds nvidia-device-plugin-daemonset --timeout=60s

echo "等待 30 秒让配置生效..."
sleep 30

echo ""
echo "验证 vGPU 数量："
kubectl describe node minikube | grep -A3 "Allocatable:" | grep "nvidia.com/gpu"

echo ""
echo "如果看到 nvidia.com/gpu: 2，说明 time-slicing 配置成功！"
