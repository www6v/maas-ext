# PD 分离部署 - 当前状态（2026-10-24 23:30）

## ✅ 已完成的工作（85%）

### K8s 基础设施（100%）
- ✅ minikube K8s 1.30 运行中
- ✅ vGPU time-slicing 配置完成（需要重新应用，minikube 重启后丢失）
- ✅ Dynamo CRD 安装成功
- ✅ NATS + etcd 部署运行
- ✅ DGD 提交成功

### Docker 镜像（100%）
- ✅ Dynamo runtime 镜像构建成功（9.61GB）
- ✅ 包含 vLLM 0.28.0 + Dynamo 1.6.0 + NIXL 1.5.0
- ✅ 镜像已加载到 minikube

### 部署流程（100%）
- ✅ Pods 调度成功
- ✅ 容器启动成功
- ✅ **模型加载成功**（Qwen3-0.6B，1.4GB，59 秒）
- ✅ NIXL 初始化成功
- ✅ KV cache layout 配置成功

### 问题解决（100%）
- ✅ GPU 显存占用（关闭 ComfyUI，释放 19GB）
- ✅ Triton 编译问题（禁用 torch.compile）
- ✅ 模型下载问题（本地下载 + mount）
- ✅ etcd 连接问题（设置 ETCD_ENDPOINTS）
- ✅ 磁盘空间问题（清理释放 20+ GB）

### 文档交付（100%）
- ✅ 27 个文件已保存（12 脚本 + 12 文档 + 3 Dockerfile）
- ✅ 完整的问题诊断和解决方案
- ✅ 详细的下一步建议

---

## ❌ 未完成的工作（15%）

### 端到端推理（0%）
- ❌ Workers 在 warmup 阶段崩溃
- ❌ 无法执行推理请求
- ❌ 无法验证 KV cache 传输

**根本原因**：vLLM v1 硬依赖 FlashInfer，FlashInfer 需要 nvcc 编译器进行运行时 JIT 编译。基础 CUDA 镜像不包含 nvcc。

---

## 🔧 明天继续的步骤

### 步骤 1: 重新应用 vGPU 配置
```bash
cd /home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-deploy
bash setup-vgpu.sh
```

### 步骤 2: 拉取 CUDA devel 镜像（包含 nvcc）
```bash
# 使用代理拉取（需要稳定的网络）
export http_proxy=http://127.0.0.1:7897
export https_proxy=http://127.0.0.1:7897
docker pull nvidia/cuda:12.1.1-cudnn8-devel-ubuntu22.04
```

**注意**：这个镜像约 5-10GB，拉取可能需要 30-60 分钟。

### 步骤 3: 构建包含 nvcc 的 Dynamo 镜像
```bash
cd docker-build
docker build --network host \
  -t nvcr.io/nvidia/ai-dynamo/vllm-runtime:with-nvcc \
  -f Dockerfile.cuda-devel .
```

### 步骤 4: 加载到 minikube 并部署
```bash
docker save nvcr.io/nvidia/ai-dynamo/vllm-runtime:with-nvcc | minikube image load -

# 更新 deployment 使用新镜像
kubectl -n dynamo-system set image deployment/vllm-disagg-prefill \
  main=nvcr.io/nvidia/ai-dynamo/vllm-runtime:with-nvcc
kubectl -n dynamo-system set image deployment/vllm-disagg-decode \
  main=nvcr.io/nvidia/ai-dynamo/vllm-runtime:with-nvcc

# 重启 pods
kubectl -n dynamo-system rollout restart deployment vllm-disagg-prefill
kubectl -n dynamo-system rollout restart deployment vllm-disagg-decode
```

### 步骤 5: 端到端测试
```bash
# 等待 workers 启动
sleep 120
kubectl -n dynamo-system get pods

# Port forward
kubectl -n dynamo-system port-forward svc/vllm-disagg-frontend 8000:8000

# 发送推理请求
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/models/Qwen3-0.6B",
    "prompt": "What is PD disaggregation?",
    "max_tokens": 100
  }'
```

---

## 📁 文件位置

**所有文件**：`/home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-deploy/`

**关键文档**：
- `SUMMARY.md` - 项目总结
- `FINAL-STATUS.md` - 最终状态报告
- `troubleshooting.md` - 问题诊断
- `README.md` - 部署指南

**关键脚本**：
- `setup-vgpu.sh` - vGPU 配置
- `setup-infra.sh` - 基础设施部署
- `restore-deployment.sh` - 部署恢复

**Docker 构建**：
- `docker-build/Dockerfile.cuda-devel` - CUDA devel 版本（明天使用）

---

## 💡 关键发现

### 1. vGPU Time-Slicing 限制
- ✅ 计算资源可以共享（时间分片）
- ❌ 显存无法共享（物理资源）
- ⚠️ 两个 workers 无法同时在单卡上运行（显存竞争）

### 2. vLLM v1 架构
- ✅ 模型加载和推理引擎工作正常
- ❌ FlashInfer 是硬依赖，无法通过配置禁用
- ❌ 需要 CUDA toolkit 进行运行时编译

### 3. Dynamo 集成
- ✅ Dynamo runtime 与 vLLM 集成良好
- ✅ NIXL connector 正确初始化
- ✅ KV cache 传输配置正确

---

## 🎯 明天成功的关键

1. **稳定的网络**：拉取 CUDA devel 镜像需要稳定的网络连接
2. **足够的磁盘空间**：至少需要 15GB 可用空间
3. **时间**：构建和测试需要 2-3 小时

---

**保存时间**：2026-10-24 23:30 CST  
**总耗时**：约 10 小时  
**当前状态**：⏸️ 暂停（等待 CUDA devel 镜像）
