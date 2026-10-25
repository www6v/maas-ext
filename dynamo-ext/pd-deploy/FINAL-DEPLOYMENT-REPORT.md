# PD 分离部署最终报告

**日期**：2026-10-24  
**状态**：⚠️ 部署未完成（磁盘空间不足）

---

## 执行摘要

尝试在单卡 RTX 3090 上使用 vGPU time-slicing 方案部署 Dynamo vLLM PD 分离。完成了 K8s 基础设施搭建、镜像构建、模型下载，但最终因**磁盘空间不足**未能完成端到端推理验证。

---

## 已完成的工作 ✅

### 1. K8s 基础设施
- ✅ minikube 升级到 K8s 1.30
- ✅ vGPU time-slicing 配置（1× RTX 3090 → 2 vGPU）
- ✅ Dynamo CRD 安装
- ✅ NATS + etcd 部署运行
- ✅ DGD（DynamoGraphDeployment）提交

### 2. 模型准备
- ✅ 下载 Qwen3-0.6B 模型（1.5GB）
- ✅ 模型放置在 `/data/models/models/Qwen3-0.6B`
- ✅ minikube mount 配置

### 3. Docker 镜像构建
- ✅ 构建 Dynamo runtime 镜像（9.61GB）
  - 基于 `nvidia/cuda:12.1.1-base-ubuntu22.04`
  - 安装 vLLM 0.28.0
  - 安装 ai-dynamo 1.6.0 + runtime
  - 安装 NIXL 1.5.0
  - 安装 gcc 11.4.0（解决 Triton 编译问题）
- ✅ 镜像验证通过（gcc 可用）

### 4. 部署配置
- ✅ Frontend deployment（HTTP 服务 8000 端口）
- ✅ Prefill worker deployment（1 vGPU）
- ✅ Decode worker deployment（1 vGPU）
- ✅ 环境变量配置（ETCD_ENDPOINTS, CC, proxy 等）

---

## 未完成的工作 ❌

### 1. Workers 启动失败
- ❌ Prefill worker：反复崩溃重启
- ❌ Decode worker：反复崩溃重启
- **原因**：磁盘空间不足，无法加载新镜像

### 2. 端到端推理验证
- ❌ 未发送推理请求
- ❌ 未收到有效响应
- **原因**：workers 未能成功启动

---

## 遇到的问题与解决方案

### 问题 1: K8s 版本不兼容
**错误**：`chart requires kubeVersion: >=1.30.0-0 which is incompatible with Kubernetes v1.28.0`  
**解决**：升级 minikube 到 K8s 1.30

### 问题 2: 镜像拉取失败
**错误**：国内无法拉取 `nvcr.io/nvidia/ai-dynamo/vllm-runtime`  
**解决**：从源码构建镜像（使用 Dockerfile.slim）

### 问题 3: 模型下载失败
**错误**：minikube 容器无法访问 HuggingFace  
**解决**：在宿主机下载模型，通过 minikube mount 挂载

### 问题 4: Triton 编译失败
**错误**：`RuntimeError: Failed to find C compiler`  
**解决**：在 Dockerfile 中安装 gcc，设置 CC 环境变量

### 问题 5: 磁盘空间不足
**错误**：`no space left on device`  
**状态**：**未解决** - 需要手动清理磁盘空间

---

## 磁盘使用情况

### 本地磁盘
```
文件系统         大小  已用  可用 已用%
/dev/nvme0n1p10  147G  124G   16G   89%  /data
/dev/nvme0n1p7    73G   58G   12G   84%  /
/dev/nvme0n1p9    59G   53G  3.2G   95%  /home
```

### Docker 镜像
```
REPOSITORY                            TAG       SIZE
nvcr.io/nvidia/ai-dynamo/vllm-runtime my-tag    9.61GB  ✅ 新镜像（有 gcc）
nvcr.io/nvidia/ai-dynamo/vllm-runtime my-tag    9.37GB  ❌ 旧镜像（无 gcc）
vllm-local                            qwen3.5-4b 13.7GB ⚠️ 可删除
nvidia/cuda                           12.1.1    238MB
```

### minikube 虚拟机
```
文件系统    大小  已用  可用 已用%
overlay    147G  124G   16G   89%
```

---

## 恢复步骤

### 1. 清理磁盘空间
```bash
# 清理 Docker
docker system prune -a --volumes

# 删除旧镜像
docker rmi vllm-local:qwen3.5-4b
docker rmi <旧镜像ID>

# 清理 minikube
minikube ssh -- sudo rm -rf /tmp/*
minikube ssh -- docker system prune -af --volumes

# 清理 Claude Code 临时文件
rm -rf /tmp/claude-*
```

### 2. 重新加载镜像
```bash
cd /home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-deploy
bash restore-deployment.sh
```

### 3. 验证端到端推理
```bash
# Port forward
kubectl -n dynamo-system port-forward svc/vllm-disagg-frontend 8000:8000 &

# 发送推理请求
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/models/Qwen3-0.6B",
    "prompt": "What is PD disaggregation?",
    "max_tokens": 50
  }'
```

---

## 技术验证总结

### ✅ 已验证
1. **vGPU time-slicing**：RTX 3090 → 2 vGPU 成功
2. **K8s 调度**：Pods 正确调度，vGPU 正确分配
3. **Dynamo runtime**：镜像构建成功，gcc 可用
4. **模型加载**：模型文件完整，挂载正确
5. **基础设施**：NATS、etcd、Frontend 运行正常

### ❌ 未验证
1. **Workers 启动**：因磁盘空间不足失败
2. **KV cache 传输**：NIXL 未测试
3. **端到端推理**：未发送请求

---

## 交付物清单

### 脚本文件
- `setup-vgpu.sh` - vGPU 配置 ✅
- `setup-infra.sh` - 基础设施部署 ✅
- `test-vgpu-scheduling.sh` - vGPU 调度测试 ✅
- `restore-deployment.sh` - 部署恢复 ✅
- `monitor-and-deploy.sh` - 监控和部署 ✅

### 文档
- `README.md` - 部署指南 ✅
- `STATUS.md` - 状态跟踪 ✅
- `troubleshooting.md` - 问题与解决方案 ✅
- `FINAL-E2E-REPORT.md` - 端到端报告 ✅
- `FINAL-DEPLOYMENT-REPORT.md` - 本文件 ✅

### Docker 构建
- `docker-build/Dockerfile.slim` - 精简版 Dockerfile ✅
- `docker-build/Dockerfile.fast` - 快速版 Dockerfile ✅

---

## 结论

### 成功之处 ✅
1. **完整的 K8s 部署流程**：从 vGPU 配置到 DGD 提交
2. **Dynamo runtime 镜像构建**：成功构建包含 gcc 的完整镜像
3. **模型准备**：成功下载并挂载模型
4. **问题诊断能力**：识别并解决了多个技术问题

### 失败之处 ❌
1. **磁盘空间管理**：未充分考虑镜像大小，导致空间不足
2. **端到端验证**：未能完成最终的推理测试
3. **资源清理**：未及时清理旧镜像和临时文件

### 经验教训 💡
1. **磁盘空间规划**：构建大镜像时需要预留至少 2x 镜像大小的空间
2. **增量构建**：使用 Docker 层缓存减少重复构建
3. **定期清理**：部署过程中定期清理无用的镜像和容器
4. **监控资源**：实时监控磁盘、内存、CPU 使用情况

---

## 下一步建议

1. **立即执行**：清理磁盘空间（至少释放 20GB）
2. **运行恢复脚本**：`bash restore-deployment.sh`
3. **验证推理**：发送测试请求，验证端到端流程
4. **性能测试**：如果推理成功，进行性能基准测试
5. **文档完善**：更新 troubleshooting.md，记录最终的解决方案

---

## 参考资源

- [Dynamo 官方文档](https://docs.nvidia.com/dynamo/)
- [vGPU time-slicing 配置](https://gitlab.com/nvidia/kubernetes/device-plugin/-/tree/main)
- [PD 分离分析文档](/home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-disaggregated/)

---

**报告生成时间**：2026-10-24 19:35 CST  
**总耗时**：约 6 小时  
**部署状态**：⚠️ 未完成（等待磁盘空间清理）
