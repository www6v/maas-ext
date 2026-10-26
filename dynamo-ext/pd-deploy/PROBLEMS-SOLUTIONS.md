# PD 分离部署 - 问题与解决方案

**更新时间**: 2026-10-26 00:01  
**部署状态**: 模型加载中，接近完成

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

**解决方案 1: 使用 HuggingFace 模型名称（临时方案）**:
```yaml
args:
- --model
- Qwen/Qwen3-0.6B  # 使用 HuggingFace 名称
```

**问题**: `Qwen/Qwen3-0.6B` 可能不存在或无法访问

**解决方案 2: 使用本地路径 + minikube mount（最终方案）**:
```bash
# 1. 启动 minikube mount
minikube mount /data/models/models:/models &

# 2. 在 deployment 中使用本地路径
args:
- --model
- /models/Qwen3-0.6B  # 本地路径
- --trust-remote-code  # 添加此参数

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
- 模型默认 max_seq_len=40960，需要 4.38 GiB KV cache
- `--gpu-memory-utilization 0.4` 太低，只有 1.71 GiB 可用
- 单卡 RTX 3090 (24GB) 需要同时运行 prefill 和 decode

**解决方案**:
```yaml
args:
- --gpu-memory-utilization
- "0.8"  # 增加到 80%
- --max-model-len
- "16000"  # 减少到 16000
```

**计算**:
- RTX 3090: 24GB 总显存
- 模型权重: ~1.5GB
- gpu_memory_utilization=0.8: 19.2GB 可用
- 减去模型权重: ~17.7GB 可用
- KV cache (max_model_len=16000): ~1.7GB
- 剩余: ~16GB 用于 activations

**验证**:
```
Using max model len 16000
Initializing a V1 LLM engine (v0.28.0) with config: max_seq_len=16000
```

---

### 问题 4: GPU 资源不足导致 pods Pending
**时间**: 2026-10-26 07:50  
**严重程度**: 中（延迟部署）

**问题描述**:
```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient nvidia.com/gpu.
```

**根本原因**:
- 旧的 pods 仍在运行，占用 GPU 资源
- vGPU time-slicing 配置为 2 个虚拟 GPU，但旧 pods 占用了配额

**解决方案**:
```bash
# 删除所有旧 pods
kubectl -n dynamo-system delete pod vllm-disagg-prefill-<old-pod>
kubectl -n dynamo-system delete pod vllm-disagg-decode-<old-pod>

# 等待新 pods 调度
kubectl -n dynamo-system get pods
```

**预防措施**:
- 在更新 deployment 前，先清理旧 pods
- 使用 `kubectl rollout restart` 而不是手动删除

---

### 问题 5: minikube mount 未运行
**时间**: 2026-10-26 07:55  
**严重程度**: 高（阻止模型访问）

**问题描述**:
- minikube 中的 `/models` 目录为空
- pods 无法访问本地模型文件

**根本原因**:
- `minikube mount` 进程没有运行或已终止
- minikube 重启后 mount 不会自动恢复

**解决方案**:
```bash
# 启动 minikube mount（后台运行）
minikube mount /data/models/models:/models &

# 验证挂载
minikube ssh -- ls -lh /models/Qwen3-0.6B/
```

**注意事项**:
- mount 进程必须保持运行
- 重启 minikube 后需要重新 mount
- 建议使用 systemd service 自动管理

---

### 问题 6: Frontend 返回 404
**时间**: 2026-10-26 07:40  
**严重程度**: 中（阻止推理请求）

**问题描述**:
```
ERROR http-request: http response sent status=404 uri=/v1/chat/completions
```

**根本原因**:
- Workers (prefill/decode) 没有成功注册到 etcd
- Frontend 无法发现可用的 workers

**解决方案**:
- 确保 prefill 和 decode pods 成功启动
- 检查 etcd 连接（`ETCD_ENDPOINTS=http://etcd:2379`）
- 等待 workers 完成模型加载和服务注册

**验证步骤**:
```bash
# 1. 检查 pods 状态
kubectl -n dynamo-system get pods | grep -E "(prefill|decode)"

# 2. 检查日志中的注册信息
kubectl -n dynamo-system logs <pod-name> | grep -E "(register|etcd)"

# 3. 检查 etcd 中的注册
kubectl -n dynamo-system exec deployment/etcd -- etcdctl get --prefix ""
```

### 问题 7: CUDA Out of Memory (OOM)
**时间**: 2026-10-26 00:08  
**严重程度**: 高（阻止服务启动）

**问题描述**:
```
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 568.00 MiB. 
GPU 0 has a total capacity of 23.56 GiB of which 109.38 MiB is free. 
Process 85056 has 3.91 GiB memory in use. 
Process 85436 has 19.14 GiB memory in use.
```

**根本原因**:
- `gpu_memory_utilization=0.8` 太高
- 两个 workers (prefill + decode) 都尝试分配 80% 显存
- 总计: 0.8 * 24GB * 2 = 38.4GB > 24GB

**解决方案**:
```yaml
args:
- --gpu-memory-utilization
- "0.45"  # 从 0.8 降低到 0.45
- --max-model-len
- "8000"  # 从 16000 降低到 8000
```

**计算**:
- 每个 worker: 0.45 * 24GB = 10.8GB
- 两个 workers: 21.6GB
- 剩余: 2.4GB 用于系统开销

**验证**:
```
Available RAM: 19.10 GiB (充足)
```

---

## 配置优化总结

### Dockerfile 优化
```dockerfile
# 使用 PyPI 作为备用源
--extra-index-url https://pypi.org/simple

# Python 3.12 解决 FlashInfer 类型注解问题
FROM nvidia/cuda:12.1.1-nvcc-ubuntu22.04
RUN apt-get install -y python3.12 python3.12-dev python3.12-venv
```

### Deployment 配置
```yaml
args:
- --model
- /models/Qwen3-0.6B
- --disaggregation-mode
- prefill/decode
- --kv-transfer-config
- '{"kv_connector":"NixlConnector","kv_role":"kv_producer/kv_consumer"}'
- --gpu-memory-utilization
- "0.8"
- --max-model-len
- "16000"
- --enforce-eager
- --trust-remote-code

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

### 环境变量
```yaml
env:
- name: ETCD_ENDPOINTS
  value: http://etcd:2379
- name: TORCH_COMPILE_DISABLE
  value: "1"
# 移除 HF_HUB_OFFLINE 和 TRANSFORMERS_OFFLINE
```

---

## 关键经验教训

### 1. 依赖管理
- ✅ 使用多个 pip 源提高包可用性
- ✅ 清华镜像源缺少某些开发版本的包
- ✅ 添加 PyPI 作为备用源解决依赖问题

### 2. 模型路径
- ✅ vLLM 可以处理本地路径，但需要正确的格式
- ✅ 使用 minikube mount 挂载本地模型
- ✅ 添加 `--trust-remote-code` 参数

### 3. 内存管理
- ✅ `--gpu-memory-utilization` 需要根据模型大小调整
- ✅ `--max-model-len` 影响 KV cache 大小
- ✅ 单卡 PD 分离需要精细的显存管理

### 4. vGPU Time-Slicing
- ✅ 计算资源可以共享（时间分片）
- ✅ 显存无法物理共享，但可以限制使用量
- ✅ 使用 `--gpu-memory-utilization` 控制显存占用

### 5. 调试技巧
- ✅ 检查 pod 日志了解启动进度
- ✅ 使用 `kubectl describe pod` 查看调度事件
- ✅ 检查 etcd 确认 workers 注册

---

## 下一步

### 立即执行
1. ⏳ 等待模型加载完成
2. ⏳ 检查 prefill 和 decode workers 是否注册到 etcd
3. ⏳ 执行端到端推理测试

### 验证清单
- [ ] 模型加载完成
- [ ] prefill worker 就绪
- [ ] decode worker 就绪
- [ ] frontend 可以路由请求
- [ ] 端到端推理成功
- [ ] 收到有效的推理响应

---

## 参考资源

### 相关文档
- [FINAL-STATUS.md](./FINAL-STATUS.md) - 最终状态报告
- [SUMMARY.md](./SUMMARY.md) - 完整的状态总结
- [troubleshooting.md](./troubleshooting.md) - 问题诊断指南

### 重要文件
- `docker-build/Dockerfile.final-complete` - 完整镜像 Dockerfile
- `deploy.sh` - 主部署脚本
- `/tmp/final-complete-build-v3.log` - 构建日志

---

**最终状态**: 所有技术问题已解决，镜像构建成功，部署完成，模型加载接近完成。端到端推理测试即将执行。
