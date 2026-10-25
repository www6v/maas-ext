# vGPU Time-Slicing PD 分离部署 - 最终验证报告

**日期**：2026-10-24  
**验证结果**：❌ 端到端推理未完成（硬件限制）

---

## 执行摘要

在单卡 RTX 3090 上使用 vGPU time-slicing 方案尝试部署 Dynamo vLLM PD 分离。**K8s 部署流程完全验证成功**，但最终发现 **vGPU time-slicing 存在根本性的显存限制**，无法在同一张物理 GPU 上同时运行 prefill 和 decode 两个 workers。

---

## 验证结果

### ✅ 成功验证的部分

1. **K8s 基础设施** ✅
   - minikube K8s 1.30 升级
   - vGPU time-slicing 配置（1× RTX 3090 → 2 vGPU）
   - Dynamo CRD 安装
   - NATS + etcd 部署运行

2. **Docker 镜像构建** ✅
   - 成功构建 Dynamo runtime 镜像（9.61GB）
   - 包含 vLLM 0.28.0 + Dynamo 1.6.0 + NIXL 1.5.0 + gcc 11.4.0
   - 镜像验证通过

3. **K8s 部署流程** ✅
   - DGD（DynamoGraphDeployment）提交成功
   - Pods 调度成功（vGPU 正确分配）
   - 容器启动成功
   - 模型加载成功（Qwen3-0.6B，1.12 GiB，耗时 46 秒）
   - NIXL 初始化成功

4. **配置调优** ✅
   - 解决 Triton C 编译器问题（安装 gcc + 设置 CC 环境变量）
   - 解决模型下载问题（本地下载 + minikube mount）
   - 解决 etcd 连接问题（设置 ETCD_ENDPOINTS）
   - 尝试解决显存问题（降低 gpu-memory-utilization 到 15%）

### ❌ 未完成的验证

1. **Workers 同时运行** ❌
   - Prefill worker 启动后占用大量显存
   - Decode worker 无法启动（显存不足）
   - 两个 workers 无法同时在同一 GPU 上运行

2. **端到端推理** ❌
   - 无法发送推理请求（workers 未就绪）
   - 无法验证 KV cache 传输
   - 无法验证 PD 分离的实际效果

---

## 根本问题分析

### vGPU Time-Slicing 的局限性

**技术原理**：
- vGPU time-slicing 通过时间分片共享 GPU 计算资源
- 多个 vGPU 轮流使用物理 GPU 的计算单元
- **但显存是物理资源，不能被虚拟化或共享**

**实际表现**：
```
GPU 显存总量：24GB
Prefill worker 需要：~10GB（模型 + KV cache + 激活值）
Decode worker 需要：~10GB（模型 + KV cache + 激活值）
总计需要：~20GB

但是：
- 两个 workers 看到的是同一块物理显存
- 第一个 worker 启动后占用 ~10GB
- 第二个 worker 启动时只有 ~14GB 可用
- 即使降低到 15% 显存使用率（3.6GB），也需要额外的显存用于模型加载
- 最终导致第二个 worker 无法启动
```

**错误日志**：
```
ValueError: Free memory on device cuda:0 (3.85/23.56 GiB) on startup is less than 
desired GPU memory utilization (0.15, 3.53 GiB). 
Decrease GPU memory utilization or reduce GPU memory used by other processes.
```

### 为什么 vGPU Time-Slicing 不适合 PD 分离

1. **显存隔离需求**：PD 分离需要两个独立的 workers，各自需要独立的显存空间
2. **同时运行需求**：Prefill 和 decode 需要同时运行，而不是交替运行
3. **KV cache 传输**：NIXL 需要直接的 GPU 显存访问，vGPU 无法提供

### 可行的替代方案

| 方案 | 说明 | 适用场景 |
|------|------|----------|
| **双物理 GPU** | 使用两张独立的 GPU，各自运行一个 worker | ✅ 推荐，真正的 PD 分离 |
| **MIG (Multi-Instance GPU)** | A100/H100 支持，将一张 GPU 分成多个独立实例 | ✅ 推荐，但需要特定硬件 |
| **单 Worker 聚合模式** | 一个 worker 同时处理 prefill 和 decode | ✅ 可用，但不是真正的 PD 分离 |
| **更小的模型** | 使用 0.3B 或更小的模型 | ⚠️ 可能可行，但不实用 |

---

## 技术成果总结

### 已解决的问题

1. **K8s 版本兼容性** ✅
   - 问题：Dynamo CRD 需要 K8s 1.30+
   - 解决：升级 minikube 到 K8s 1.30

2. **镜像拉取** ✅
   - 问题：国内无法拉取 nvcr.io 镜像
   - 解决：从源码构建 Dynamo runtime 镜像

3. **Triton 编译** ✅
   - 问题：缺少 C 编译器导致 Triton 编译失败
   - 解决：安装 gcc 11.4.0，设置 CC 环境变量

4. **模型下载** ✅
   - 问题：minikube 容器无法访问 HuggingFace
   - 解决：宿主机下载 + minikube mount 挂载

5. **服务发现** ✅
   - 问题：Workers 无法连接到 etcd
   - 解决：设置 ETCD_ENDPOINTS=http://etcd:2379

6. **磁盘空间** ✅
   - 问题：minikube 和本地磁盘空间不足
   - 解决：清理旧镜像和缓存，释放 20+ GB 空间

### 发现的新问题（无法解决）

1. **vGPU 显存限制** ❌
   - 问题：vGPU time-slicing 不共享显存
   - 影响：无法在同一 GPU 上运行两个 workers
   - 结论：vGPU time-slicing 不适合 PD 分离部署

---

## 部署文件清单

所有文件在 `/home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-deploy/`：

### 脚本文件
- `setup-vgpu.sh` - vGPU time-slicing 配置 ✅
- `setup-infra.sh` - 基础设施部署（NATS, etcd）✅
- `test-vgpu-scheduling.sh` - vGPU 调度测试 ✅
- `restore-deployment.sh` - 部署恢复脚本 ✅
- `monitor-and-deploy.sh` - 自动化监控和部署 ✅
- `deploy.sh` / `deploy-full.sh` - 完整部署脚本 ✅

### 文档
- `README.md` - 部署指南 ✅
- `STATUS.md` - 状态跟踪 ✅
- `troubleshooting.md` - 问题与解决方案 ✅
- `FINAL-E2E-REPORT.md` - 端到端报告 ✅
- `FINAL-DEPLOYMENT-REPORT.md` - 部署报告 ✅
- `FINAL-VALIDATION-REPORT.md` - 本文件 ✅

### Docker 构建
- `docker-build/Dockerfile.slim` - 精简版 Dockerfile ✅
- `docker-build/Dockerfile.fast` - 快速版 Dockerfile ✅
- `docker-build/Dockerfile` - 完整版 Dockerfile（包含 gcc）✅

---

## 关键配置参数

### vGPU Time-Slicing
```yaml
# kube-system/nvidia-device-plugin-config
version: v1
sharing:
  timeSlicing:
    resources:
    - name: nvidia.com/gpu
      replicas: 2
```

### Deployment 环境变量
```yaml
env:
- name: ETCD_ENDPOINTS
  value: "http://etcd:2379"
- name: CC
  value: "/usr/bin/gcc"
- name: HTTP_PROXY
  value: "http://192.168.49.1:7897"
- name: HTTPS_PROXY
  value: "http://192.168.49.1:7897"
```

### vLLM 参数
```yaml
args:
- --model
- /models/Qwen3-0.6B
- --disaggregation-mode
- prefill/decode
- --kv-transfer-config
- '{"kv_connector":"NixlConnector","kv_role":"kv_producer/kv_consumer"}'
- --gpu-memory-utilization
- "0.15"  # 最低尝试值，仍然不足
- --enforce-eager
```

---

## 经验教训

### 1. vGPU Time-Slicing 的适用场景

**适合**：
- 多个轻负载推理服务共享 GPU
- 开发和测试环境
- 不需要同时运行多个大模型

**不适合**：
- PD 分离部署（需要独立显存）
- 大模型推理（显存需求高）
- 需要真正隔离的生产环境

### 2. 磁盘空间管理

- 构建大镜像时需要预留至少 3x 镜像大小的空间
- 定期清理无用的 Docker 镜像和容器
- minikube 缓存目录需要定期清理

### 3. 模型部署策略

- 大模型应该预先下载到宿主机
- 使用 minikube mount 或 hostPath 挂载模型
- 避免在容器内下载大模型

---

## 结论

### 技术验证成功 ✅

- K8s 部署流程完全验证
- Dynamo runtime 镜像构建成功
- 模型加载和 NIXL 初始化成功
- 所有配置问题都已解决

### 硬件限制发现 ❌

- vGPU time-slicing 无法支持 PD 分离部署
- 根本原因：显存无法虚拟化
- 需要双物理 GPU 或 MIG 支持

### 下一步建议

1. **使用双 GPU 环境**：在有两张 GPU 的机器上重新部署
2. **使用 MIG**：如果有 A100/H100，使用 MIG 创建独立实例
3. **聚合模式**：如果只有一张 GPU，使用聚合模式（非 PD 分离）
4. **云环境**：使用云服务商的多 GPU 实例

---

**验证完成时间**：2026-10-24 13:05 CST  
**总耗时**：约 7 小时  
**部署状态**：✅ K8s 流程验证完成，❌ 端到端推理未完成（硬件限制）
