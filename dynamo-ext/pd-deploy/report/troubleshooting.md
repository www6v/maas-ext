# 问题诊断指南

## 快速排查流程

### 1. 检查 Pods 状态
```bash
kubectl -n dynamo-system get pods
```

**预期状态**：所有 pods 应为 `1/1 Running`

**常见问题**：
- `Pending` - GPU 资源不足或调度失败
- `CrashLoopBackOff` - 应用程序崩溃
- `ImagePullBackOff` - 镜像拉取失败
- `ErrImageNeverPull` - imagePullPolicy: Never 但镜像不存在

---

### 2. 检查 Pods 日志
```bash
kubectl -n dynamo-system logs deployment/vllm-disagg-prefill
kubectl -n dynamo-system logs deployment/vllm-disagg-decode
kubectl -n dynamo-system logs deployment/vllm-disagg-frontend
```

**关键日志**：
- ✅ `Loading model from scratch...` - 模型开始加载
- ✅ `Loading safetensors checkpoint shards: 100% Completed` - 模型加载成功
- ✅ `NIXL is available` - NIXL 初始化成功
- ✅ `Registered endpoint 'dynamo-system.prefill.generate'` - 注册成功
- ❌ `ERROR` - 错误信息
- ❌ `Traceback` - Python 异常

---

### 3. 检查 etcd 注册
```bash
kubectl -n dynamo-system exec deployment/etcd -- etcdctl get --prefix ""
```

**预期结果**：应有 16+ 行注册信息

**关键信息**：
- `v1/models/namespace/dynamo-system/component/prefill/endpoint/generate`
- `v1/models/namespace/dynamo-system/component/backend/endpoint/generate`

---

### 4. 检查模型下载
```bash
kubectl -n dynamo-system logs deployment/vllm-disagg-prefill | grep -E "Downloading|Loading|100%"
```

**预期结果**：
```
Loading safetensors checkpoint shards: 100% Completed | 1/1 [00:XX<00:00]
```

---

### 5. 测试端到端推理
```bash
kubectl -n dynamo-system port-forward svc/vllm-disagg-frontend 8000:8000 &
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-0.5B",
    "messages": [{"role":"user","content":"Hello"}],
    "max_tokens": 50
  }'
```

**预期结果**：HTTP 200 + 有效推理响应

---

## 常见问题及解决方案

### 问题 1: FlashInfer 编译错误

**错误信息**:
```
namespace "std" has no member "strlen"
namespace "std" has no member "memcpy"
```

**原因**: vLLM 版本不兼容

**解决方案**: 使用 vLLM 0.31.0
```bash
pip install vllm==0.31.0
```

---

### 问题 2: 模型下载失败

**错误信息**:
```
Failed to fetch model 'Qwen/Qwen3-0.6B' from HuggingFace
```

**原因**: 
1. 模型名称不正确
2. 网络无法访问 HuggingFace
3. 代理配置不正确

**解决方案**:
1. 使用正确的模型名称：`Qwen/Qwen2.5-0.5B`
2. 配置 Clash Verge 启用"局域网连接"
3. 配置 pods 使用代理：
   ```yaml
   env:
   - name: HTTP_PROXY
     value: http://192.168.49.1:7897
   - name: HTTPS_PROXY
     value: http://192.168.49.1:7897
   ```

---

### 问题 3: Workers 未注册到 etcd

**症状**:
- etcd 中无注册信息
- Frontend 返回 404

**原因**:
1. 缺少 `--namespace` 参数
2. 缺少 `--discovery-backend` 参数
3. 缺少 `DYN_NAMESPACE` 环境变量

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

### 问题 4: GPU 资源不足

**错误信息**:
```
0/1 nodes are available: 1 Insufficient nvidia.com/gpu.
```

**原因**: 旧 pods 占用 GPU 资源

**解决方案**:
```bash
kubectl -n dynamo-system delete pod <old-pod-name>
```

---

### 问题 5: KV cache 内存不足

**错误信息**:
```
ValueError: KV cache memory is insufficient
```

**原因**: `gpu_memory_utilization` 设置过高

**解决方案**:
```yaml
args:
- --gpu-memory-utilization
- "0.45"
- --max-model-len
- "8000"
```

---

### 问题 6: 磁盘空间不足

**错误信息**:
```
no space left on device
```

**原因**: 旧的构建文件或 Docker 镜像占用空间

**解决方案**:
```bash
# 清理旧构建文件
rm -f /tmp/build.*.tar

# 清理 Docker 资源
docker image prune -af
```

---

### 问题 7: 推理返回 404

**症状**:
```json
{"message":"Model not found","type":"Not Found","code":404}
```

**原因**:
1. 模型名称不匹配
2. Frontend 未发现 workers
3. Workers 未成功注册

**解决方案**:
1. 使用正确的模型名称：`Qwen/Qwen2.5-0.5B`
2. 检查 etcd 注册：`kubectl exec deployment/etcd -- etcdctl get --prefix ""`
3. 检查 workers 日志：`kubectl logs deployment/vllm-disagg-prefill`

---

### 问题 8: 代理配置问题

**症状**:
- 容器无法访问 HuggingFace
- 模型下载超时

**原因**: Clash Verge 未启用局域网连接

**解决方案**:
1. 打开 Clash Verge 设置
2. 启用"局域网连接"
3. 验证代理监听：`netstat -tlnp | grep 7897`
   - 应显示 `*:7897` 而不是 `127.0.0.1:7897`

---

## 诊断命令汇总

```bash
# 1. 检查 pods 状态
kubectl -n dynamo-system get pods

# 2. 检查 pods 日志
kubectl -n dynamo-system logs deployment/vllm-disagg-prefill --tail=50

# 3. 检查 etcd 注册
kubectl -n dynamo-system exec deployment/etcd -- etcdctl get --prefix ""

# 4. 检查前端服务
kubectl -n dynamo-system get svc vllm-disagg-frontend

# 5. 测试推理
kubectl -n dynamo-system port-forward svc/vllm-disagg-frontend 8000:8000 &
curl http://localhost:8000/v1/models

# 6. 检查 GPU 使用
minikube ssh -- nvidia-smi

# 7. 检查代理配置
netstat -tlnp | grep 7897

# 8. 测试 HuggingFace 访问
minikube ssh -- curl -s -o /dev/null -w "%{http_code}" --proxy http://192.168.49.1:7897 https://huggingface.co
```

---

## 参考文档

- [最终项目报告](./FINAL-PROJECT-REPORT-2026-10-26.md)
- [问题与解决方案](./PROBLEMS-SOLUTIONS.md)
- [部署指南](../README.md)

---

*文档更新时间: 2026-10-26 17:30 CST*
