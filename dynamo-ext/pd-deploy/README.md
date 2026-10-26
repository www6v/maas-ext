# PD 分离部署指南

## 项目概述

使用 vGPU time-slicing 方案在单卡 RTX 3090 上部署 NVIDIA Dynamo vLLM PD（Prefill-Decode）分离推理服务。

## 当前状态

- ✅ K8s 基础设施：100% 完成
- ✅ 镜像构建：100% 完成（Python 3.12 + vLLM 0.31.0 + Dynamo 1.6.0）
- ✅ 端到端推理：100% 完成（HTTP 200）

详细状态见 [FINAL-PROJECT-REPORT-2026-10-26.md](./FINAL-PROJECT-REPORT-2026-10-26.md)

## 快速开始

### 1. 启动 minikube
```bash
minikube start --driver=docker --kubernetes-version=v1.30.0
```

### 2. 配置 Clash Verge 代理（关键）
- 打开 Clash Verge 设置
- 启用"局域网连接"（allow-lan: true）
- 代理监听 `0.0.0.0:7897`

### 3. 清理旧资源
```bash
bash shell/01-cleanup.sh
```

### 4. 配置 vGPU
```bash
bash shell/02-setup-vgpu.sh
```

### 5. 部署基础设施
```bash
bash shell/03-setup-infra.sh
```

### 6. 加载镜像
```bash
docker save nvcr.io/nvidia/ai-dynamo/vllm-runtime:final-complete-v7-vllm031 | minikube image load -
```

### 7. 部署 workers
```bash
bash shell/04-deploy.sh
```

### 8. 测试 vGPU 调度
```bash
bash shell/05-test-vgpu-scheduling.sh
```

### 9. 端到端验证
```bash
bash shell/06-verify-e2e.sh
```

## 文档

- [FINAL-PROJECT-REPORT-2026-10-26.md](./FINAL-PROJECT-REPORT-2026-10-26.md) - 最终项目报告
- [PROBLEMS-SOLUTIONS.md](./PROBLEMS-SOLUTIONS.md) - 12 个问题详解
- [troubleshooting.md](./troubleshooting.md) - 问题诊断

## 关键发现

1. **Python 3.12 是正确选择** - 解决了所有 FlashInfer 兼容性问题
2. **vLLM 0.31.0 是必需版本** - 与 ai-dynamo 1.6.0 兼容，修复 FlashInfer JIT 编译
3. **vGPU time-slicing 有显存限制** - 需要精细配置 `gpu_memory_utilization=0.45`
4. **Clash Verge 需要启用局域网连接** - 容器需要访问代理下载模型
5. **Dynamo frontend 设计限制** - 不支持本地模型路径，需要从 HuggingFace 下载

## 文件结构

### 文档
```
pd-deploy/
├── README.md                              # 本文件
├── FINAL-PROJECT-REPORT-2026-10-26.md     # 最终项目报告
├── PROBLEMS-SOLUTIONS.md                  # 12 个问题详解
└── troubleshooting.md                     # 问题诊断
```

### 脚本（按执行顺序）
```
pd-deploy/shell/
── 01-cleanup.sh              # 清理旧资源
├── 02-setup-vgpu.sh           # 配置 vGPU time-slicing
├── 03-setup-infra.sh          # 部署基础设施 (NATS, etcd)
├── 04-deploy.sh               # 主部署脚本
├── 05-test-vgpu-scheduling.sh # 测试 vGPU 调度
└── 06-verify-e2e.sh           # 端到端验证
```

### 配置
```
pd-deploy/
── manual-deploy.yaml                     # K8s 部署配置（最终使用）
├── disagg-final.yaml                      # DGD 配置
└── docker-build/
    ── Dockerfile.final-complete          # 完整镜像 Dockerfile
```

## 技术栈

- **NVIDIA Dynamo**: 1.6.0
- **vLLM**: 0.31.0
- **NIXL**: 1.5.0
- **Python**: 3.12
- **CUDA**: 12.1
- **FlashInfer**: 0.6.16.post3
- **Kubernetes**: minikube K8s 1.30
- **GPU**: RTX 3090 (24GB) with vGPU time-slicing

## 性能参数

```
GPU: RTX 3090 (24GB VRAM)
模型: Qwen/Qwen2.5-0.5B
max_model_len: 8000 tokens
gpu_memory_utilization: 0.45
KV cache: ~9 GiB
模型加载时间: ~60 秒
推理延迟: ~100ms
```

## 参考

- [Dynamo 官方文档](https://docs.nvidia.com/dynamo/)
- [Dynamo GitHub](https://github.com/ai-dynamo/dynamo)
- [vGPU Time-Slicing](https://gitlab.com/nvidia/kubernetes/device-plugin/-/tree/main)
- [PD 分离分析](/home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-disaggregated/)
