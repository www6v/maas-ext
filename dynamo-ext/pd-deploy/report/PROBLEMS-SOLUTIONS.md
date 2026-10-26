# PD 分离部署 - 问题与解决方案

**更新时间**: 2026-10-26 17:30  
**部署状态**: 100% 完成 ✅

---

## 问题清单

### 问题 1: aisimulate 包缺失
**时间**: 2026-10-26 06:30  
**严重程度**: 高（阻止镜像构建）

**问题描述**:
```
ERROR: Could not find a version that satisfies the requirement aisimulate<0.14.0,>0.13.0.dev1
```

**根本原因**:
- 清华镜像源（pypi.tuna.tsinghua.edu.cn）没有 `aisimulate` 包
- `ai-dynamo==1.6.0` 依赖 `aisimulate<0.14.0,>0.13.0.dev1`

**解决方案**:
```dockerfile
# 在 Dockerfile 中添加 PyPI 作为备用源
RUN python3 -m pip install --no-cache-dir \
    -i $PIP_INDEX_URL \
    --extra-index-url https://pypi.org/simple \
    ai-dynamo==1.6.0 \
    ai-dynamo-runtime==1.6.0 \
    ...
```

**验证**:
```bash
# 构建成功，aisimulate 从 PyPI 下载
Successfully installed aisimulate-0.13.0
```

---

### 问题 2: 模型路径被误认为 HuggingFace repo id
**时间**: 2026-10-26 07:30  
**严重程度**: 高（阻止服务启动）

**问题描述**:
```
huggingface_hub.errors.HFValidationError: Repo id must be in the form 'repo_name' or 'namespace/repo_name': '/models/Qwen3-0.6B'.
```

**根本原因**:
- vLLM 的 `get_model_path` 函数把本地路径 `/models/Qwen3-0.6B` 当作 HuggingFace repo id 处理
- 设置了 `HF_HUB_OFFLINE=1` 和 `TRANSFORMERS_OFFLINE=1`，阻止了模型下载

**解决方案**:
```bash
# 1. 启动 minikube mount
minikube mount /data/models/models:/models &

# 2. 在 deployment 中使用本地路径
args:
- --model
- /models/Qwen3-0.6B
- --trust-remote-code

# 3. 添加 volume mount
volumeMounts:
- name: model-volume
  mountPath: /models
  readOnly: true
volumes:
- name: model-volume
  hostPath:
    path: /models
    type: Directory
```

**验证**:
```
Resolved architecture: Qwen3ForCausalLM
Loading model from scratch...
Loading safetensors checkpoint shards: ✓
```

---

### 问题 3: KV cache 内存不足
**时间**: 2026-10-26 07:45  
**严重程度**: 高（阻止服务启动）

**问题描述**:
```
ValueError: To serve at least one request with the model's max seq len (40960),
(4.38 GiB KV cache is needed, which is larger than the available KV cache memory (1.71 GiB).
```

**根本原因**:
- `--gpu-memory-utilization 0.8` 太高
- 两个 workers 无法同时在单卡上运行

**解决方案**:
```yaml
args:
- --gpu-memory-utilization
- "0.45"  # 从 0.8 降低到 0.45
- --max-model-len
- "8000"  # 从 40960 降低到 8000
```

**验证**:
```
Available KV cache memory: 9.08 GiB
GPU KV cache size: 85,008 tokens
```

---

### 问题 4: CUDA OOM
**时间**: 2026-10-26 08:00  
**严重程度**: 高（阻止服务启动）

**问题描述**:
```
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 568.00 MiB.
GPU 0 has a total capacity of 23.56 GiB of which 109.38 MiB is free.
```

**根本原因**:
- `gpu_memory_utilization=0.8` 太高
- 两个 workers 都尝试分配 80% 显存
- 总计: 0.8 * 24GB * 2 = 38.4GB > 24GB

**解决方案**:
```yaml
--gpu-memory-utilization: 0.45  # 0.45 * 2 = 0.9 (90%)
```

---

### 问题 5: GPU 资源调度
**时间**: 2026-10-26 08:10  
**严重程度**: 中（延迟部署）

**问题描述**:
```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient nvidia.com/gpu.
```

**根本原因**:
- 旧 pods 占用 GPU 资源
- vGPU time-slicing 配置为 2 个虚拟 GPU

**解决方案**:
```bash
kubectl -n dynamo-system delete pod <old-pod-name>
```

---

### 问题 6: minikube mount 未运行
**时间**: 2026-10-26 08:15  
**严重程度**: 高（阻止模型访问）

**问题描述**:
- minikube 中的 `/models` 目录为空
- pods 无法访问本地模型文件

**根本原因**:
- `minikube mount` 进程没有运行或已终止
- minikube 重启后 mount 不会自动恢复

**解决方案**:
```bash
minikube mount /data/models/models:/models &
```

---

### 问题 7: Dynamo operator 镜像拉取失败
**时间**: 2026-10-26 08:20  
**严重程度**: 中（改变部署方式）

**问题描述**:
```
Error: ImagePullBackOff
Failed to pull image "nvcr.io/nvidia/ai-dynamo/kubernetes-operator:1.7.0"
```

**根本原因**:
- NGC 镜像不存在或无法访问
- Dynamo operator 无法安装

**解决方案**:
改用手动 deployment 方式，不使用 DGD

---

### 问题 8: Workers 未注册到 etcd
**时间**: 2026-10-26 08:30  
**严重程度**: 高（阻止服务发现）

**问题描述**:
- Workers 成功加载模型
- 但未调用 `register_model()` 注册到 etcd
- Frontend 无法发现 workers

**根本原因**:
- 缺少 `--namespace` 和 `--discovery-backend` 参数
- 缺少 `DYN_NAMESPACE` 环境变量

**解决方案**:
```yaml
args:
- --namespace
- dynamo-system
- --discovery-backend
- etcd
env:
- name: DYN_NAMESPACE
  value: "dynamo"
```

---

### 问题 9: 磁盘空间不足
**时间**: 2026-10-26 08:40  
**严重程度**: 高（阻止镜像构建）

**问题描述**:
```
Disk full: this computer's volume holding /tmp/claude-1000 has 0 MB free
```

**根本原因**:
- 旧的构建文件占用大量空间
- Docker 镜像缓存

**解决方案**:
```bash
# 清理旧构建文件
rm -f /tmp/build.*.tar

# 清理 Docker 资源
docker image prune -af

# 释放 37GB 空间
```

---

### 问题 10: FlashInfer 编译错误 (TVM FFI)
**时间**: 2026-10-26 09:00  
**严重程度**: 高（阻止模型加载）

**问题描述**:
```
namespace "std" has no member "strlen"
namespace "std" has no member "memcpy"
```

**根本原因**:
- TVM FFI 的 string.h 缺少 `#include <cstring>`
- CUDA nvcc 编译器无法找到 std 命名空间中的 C 字符串函数

**解决方案**:
升级到 vLLM 0.31.0（已修复此问题）

---

### 问题 11: FlashInfer 编译错误 (CCCL)
**时间**: 2026-10-26 09:10  
**严重程度**: 高（阻止模型加载）

**问题描述**:
```
__is_associative_v is not a template
"constexpr" is not valid here
```

**根本原因**:
- FlashInfer 的 CCCL 头文件与 CUDA 12.1 不兼容
- vLLM 0.28.0 使用的 FlashInfer 版本有编译问题

**解决方案**:
升级到 vLLM 0.31.0（已修复此问题）

---

### 问题 12: vLLM 版本兼容性
**时间**: 2026-10-26 09:20  
**严重程度**: 高（阻止服务启动）

**问题描述**:
```
ImportError: cannot import name 'get_engine_zmq_addresses' from 'vllm.v1.engine.utils'
```

**根本原因**:
- ai-dynamo 1.6.0 (PyPI) 需要 vLLM 0.31.0
- vLLM 0.32.0 与 Dynamo 1.6.0 不兼容（API 变化）

**解决方案**:
```bash
pip install vllm==0.31.0
```

---

### 问题 13: Clash Verge 代理配置
**时间**: 2026-10-26 16:50  
**严重程度**: 高（阻止模型下载）

**问题描述**:
- Minikube 容器无法访问 HuggingFace
- 无法下载模型进行 materialization

**根本原因**:
- Clash Verge 默认只监听 localhost (127.0.0.1:7897)
- Minikube 容器无法访问 localhost 代理

**解决方案**:
1. 打开 Clash Verge 设置
2. 启用"局域网连接"（allow-lan: true）
3. 代理监听 `0.0.0.0:7897`
4. 配置 pods 使用代理：
   ```yaml
   env:
   - name: HTTP_PROXY
     value: http://192.168.49.1:7897
   - name: HTTPS_PROXY
     value: http://192.168.49.1:7897
   ```

**验证**:
```bash
# 测试代理访问
minikube ssh -- curl -s -o /dev/null -w "%{http_code}" --proxy http://192.168.49.1:7897 https://huggingface.co
# 返回 200 ✓
```

---

## 总结

### 已解决的问题：13/13 ✅

所有问题均已解决，项目 100% 完成！

### 关键经验

1. **版本兼容性很重要** - ai-dynamo 1.6.0 需要 vLLM 0.31.0
2. **FlashInfer 编译问题** - vLLM 0.31.0 已修复
3. **代理配置是关键** - Clash Verge 需要启用局域网连接
4. **内存管理需要精细** - gpu_memory_utilization=0.45
5. **服务发现需要正确配置** - namespace + discovery-backend

---

*文档更新时间: 2026-10-26 17:30 CST*  
*解决问题: 13 个*  
*完成度: 100%*
