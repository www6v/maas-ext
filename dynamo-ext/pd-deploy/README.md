# Dynamo vLLM PD 分离部署（vGPU Time-Slicing 方案）

## 目标

在单张 RTX 3090 上，通过 GPU time-slicing 虚拟化出 2 个 vGPU，运行 Dynamo vLLM PD 分离部署（`disagg.yaml`），验证 K8s 部署流程。

## 环境要求

- ✅ minikube（已安装，v1.28.0）
- ✅ RTX 3090 24GB（单卡）
- ✅ NVIDIA GPU Operator（minikube 插件已启用）
- ⚠️ 网络：需要能访问 Docker Hub / quay.io（etcd 镜像）
- ❌ 镜像：`nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag` 需要从国内镜像或源码构建

## 部署步骤

### 快速开始

```bash
cd /home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-deploy
bash deploy.sh
```

### 手动步骤

详见 [deploy.sh](./deploy.sh) 中的注释。

## 核心概念

### vGPU Time-Slicing

NVIDIA GPU time-slicing 允许将单个物理 GPU 暴露为多个虚拟 GPU：

```
物理 GPU (RTX 3090, 24GB)
    ├── vGPU 0 (12GB 等效)  → prefill worker pod
    └── vGPU 1 (12GB 等效)  → decode worker pod
```

**关键特点**：
- 两个 vGPU **共享**物理显存（总 24GB，不是各 24GB）
- 计算通过时间分片复用（不是真正的隔离）
- 适合验证 K8s 拓扑，**不适合性能测试**

### PD 分离拓扑

```
┌─────────────┐
│  Frontend   │  (HTTP ingress)
└──────┬──────┘
       │
   ┌───┴────┐
   │        │
   ▼        ▼
┌──────┐ ┌──────┐
│Prefill│ │Decode│  ← 2 个 vGPU（同一物理卡）
│Worker │ │Worker│
└──────┘ └──────┘
   │        │
   └──NIXL──┘  (KV cache transfer, CUDA IPC)
```

## 已知问题

详见 [troubleshooting.md](./troubleshooting.md)

## 验证清单

- [ ] minikube 运行，GPU 可见
- [ ] vGPU time-slicing 配置，`kubectl describe node` 显示 `nvidia.com/gpu: 2`
- [ ] NATS + etcd 部署，Service 可达
- [ ] Dynamo Operator 安装，CRD 注册
- [ ] DGD 提交，Operator reconcile 成功
- [ ] 3 个 pods (frontend, prefill, decode) Running
- [ ] 每个 worker pod 分配到 1 个 vGPU
- [ ] Worker 注册到 NATS
- [ ] Frontend 发现 PrefillRouter
- [ ] 端到端请求（需要可用的 vLLM + Dynamo 镜像）

## 文件说明

| 文件 | 说明 |
|---|---|
| `deploy.sh` | 主部署脚本 |
| `troubleshooting.md` | 遇到的问题及解决方案 |
| `cleanup.sh` | 清理部署 |
| `verify.sh` | 端到端验证脚本 |

## 常用命令

```bash
# 查看 DGD 状态
kubectl -n dynamo-system get dgd

# 查看 pods
kubectl -n dynamo-system get pods -o wide

# 查看日志
kubectl -n dynamo-system logs -f deploy/vllm-disagg-frontend
kubectl -n dynamo-system logs -f deploy/vllm-disagg-prefill
kubectl -n dynamo-system logs -f deploy/vllm-disagg-decode

# 删除部署
kubectl -n dynamo-system delete dgd vllm-disagg

# 清理所有
bash cleanup.sh
```
