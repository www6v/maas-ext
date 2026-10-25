# PD 分离部署指南

## 项目概述

使用 vGPU time-slicing 方案在单卡 RTX 3090 上部署 Dynamo vLLM PD 分离。

## 当前状态

- ✅ K8s 基础设施：100% 完成
- ✅ 镜像构建：100% 完成（Python 3.12 + curand）
- ❌ 端到端推理：因磁盘空间不足未完成

详细状态见 [SUMMARY.md](./SUMMARY.md)

## 快速开始

### 1. 启动 minikube
```bash
minikube start --driver=docker --kubernetes-version=v1.30.0
```

### 2. 配置 vGPU
```bash
bash setup-vgpu.sh
```

### 3. 部署基础设施
```bash
bash setup-infra.sh
```

### 4. 加载镜像
```bash
docker save nvcr.io/nvidia/ai-dynamo/vllm-runtime:py312-curand | minikube image load -
```

### 5. 部署 workers
```bash
bash deploy.sh
```

### 6. 验证
```bash
bash verify-e2e.sh
```

## 文档

- [SUMMARY.md](./SUMMARY.md) - 当前状态总结
- [troubleshooting.md](./troubleshooting.md) - 问题诊断
- [deploy.sh](./deploy.sh) - 部署脚本
- [setup-vgpu.sh](./setup-vgpu.sh) - vGPU 配置脚本

## 关键发现

1. **Python 3.12 是正确选择** - 解决了所有 FlashInfer 兼容性问题
2. **vGPU time-slicing 有显存限制** - 不适合大模型 PD 分离
3. **磁盘空间管理很重要** - 需要预留足够空间

## 文件

### 文档
- `README.md` - 本文件
- `SUMMARY.md` - 当前状态总结
- `troubleshooting.md` - 问题诊断

### 脚本
- `deploy.sh` - 主部署脚本
- `setup-infra.sh` - 基础设施部署（NATS + etcd）
- `setup-vgpu.sh` - vGPU time-slicing 配置
- `verify-e2e.sh` - 端到端验证
- `test-vgpu-scheduling.sh` - vGPU 调度测试
- `cleanup.sh` - 清理资源

### Dockerfile
- `docker-build/Dockerfile.py312` - Python 3.12 基础镜像
- `docker-build/Dockerfile.py312-curand` - Python 3.12 + curand（推荐）

## 参考

- [Dynamo 官方文档](https://docs.nvidia.com/dynamo/)
- [vGPU Time-Slicing](https://gitlab.com/nvidia/kubernetes/device-plugin/-/tree/main)
- [PD 分离分析](/home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-disaggregated/)
