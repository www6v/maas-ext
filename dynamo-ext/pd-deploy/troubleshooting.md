# 部署问题与解决方案

## 问题列表

### 问题 1: vGPU Time-Slicing 显存限制（根本性问题）

**现象**：
```
ValueError: Free memory on device cuda:0 (3.85/23.56 GiB) on startup is less than 
desired GPU memory utilization (0.15, 3.53 GiB).
```

**根本原因**：
- vGPU time-slicing 只共享计算资源（时间分片），**不共享显存**
- 显存是物理资源，无法被虚拟化
- Prefill worker 启动后占用 ~10GB 显存
- Decode worker 启动时没有足够的显存

**解决方案**：❌ **无解**（硬件限制）

**替代方案**：
1. **使用双物理 GPU**：每张 GPU 运行一个 worker（推荐）
2. **使用 MIG**：A100/H100 支持，创建独立 GPU 实例
3. **聚合模式**：单 worker 同时处理 prefill 和 decode（非真正 PD 分离）

**结论**：vGPU time-slicing 不适合 PD 分离部署，只适合轻负载推理服务共享。

---

### 1. GPU Time-Slicing 配置

**问题**：minikube 默认只暴露 1 个物理 GPU，`disagg.yaml` 需要 2 个 GPU。

**解决方案**：配置 NVIDIA GPU time-slicing。

```bash
# 创建 time-slicing ConfigMap
kubectl -n gpu-operator apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
data:
  any: |-
    version: v1
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: 2
EOF

# 配置 ClusterPolicy
kubectl patch clusterpolicy cluster-policy \
  --type merge \
  -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'

# 重启 device plugin
kubectl -n gpu-operator rollout restart daemonset nvidia-device-plugin-daemonset

# 等待生效
sleep 30

# 验证
kubectl describe node minikube | grep "nvidia.com/gpu"
# 应该看到 Allocatable: nvidia.com/gpu: 2
```

**注意**：
- 两个 vGPU 共享 24GB 显存，不是各 24GB
- 计算通过时间分片，性能会下降（验证流程 OK，性能测试无意义）

---

### 2. 镜像拉取失败（国内网络）

**问题**：`nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag` 无法拉取（ngc.nvidia.com 在国内访问慢/不稳定）。

**解决方案**：

#### 方案 A：使用代理

```bash
# 配置 Docker 代理
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7897"
Environment="HTTPS_PROXY=http://127.0.0.1:7897"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8"
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker

# 拉取镜像
docker pull nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0
docker tag nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0 nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag
```

#### 方案 B：从源码构建（推荐，但耗时长）

```bash
cd /home/wangwei/wei/workspacePy/maas/dynamo-main/container

# 渲染 Dockerfile
python3 render.py --framework vllm --target runtime

# 构建镜像（可能需要 30-60 分钟）
docker build -t nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag \
  -f Dockerfile.vllm.runtime .
```

#### 方案 C：扩展现有 vllm-local 镜像

```bash
# 基于现有的 vllm-local:qwen3.5-4b 镜像，安装 dynamo
docker run --rm -it vllm-local:qwen3.5-4b bash

# 在容器内
pip install ai-dynamo==1.7.0 ai-dynamo-runtime==1.7.0 nixl
exit

# 提交为新镜像
docker commit <container_id> nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag
```

**注意**：方案 C 可能需要额外安装 Rust 工具链和编译 dynamo-runtime，比较复杂。

---

### 3. NATS / etcd 镜像拉取

**问题**：`quay.io/coreos/etcd` 在国内可能拉取慢。

**解决方案**：使用国内镜像。

```bash
# 使用阿里云镜像替代
# 修改 deploy.sh 中的 etcd 镜像为：
# registry.cn-hangzhou.aliyuncs.com/google_containers/etcd:3.5.21-0
```

---

### 4. 两个 Worker 同时启动导致 OOM

**问题**：prefill 和 decode worker 同时加载模型时，瞬时显存占用可能超过 24GB。

**解决方案**：串行启动。

```bash
# 先部署 DGD
kubectl -n dynamo-system apply -f disagg.yaml

# Scale down decode
kubectl -n dynamo-system scale statefulset/vllm-disagg-decode --replicas=0

# 等 prefill ready
kubectl -n dynamo-system wait --for=condition=ready pod -l app=vllm-disagg-prefill --timeout=300s

# 再 scale up decode
kubectl -n dynamo-system scale statefulset/vllm-disagg-decode --replicas=1
```

或修改 `disagg.yaml`，减小显存占用：

```yaml
args:
- --model
- Qwen/Qwen3-0.6B
- --gpu-memory-utilization
- "0.4"        # 每个 worker 只用 40% 显存
- --max-model-len
- "2048"       # 减小 context
```

---

### 5. Dynamo Operator 安装失败

**问题**：Helm chart 可能有依赖或配置问题。

**解决方案**：

```bash
# 检查 helm chart
cd /home/wangwei/wei/workspacePy/maas/dynamo-main
helm template dynamo-platform deploy/helm/charts/platform/ | head -50

# 尝试 dry-run
helm install dynamo-platform deploy/helm/charts/platform/ \
  --namespace dynamo-system --dry-run --debug

# 查看详细错误日志
helm install dynamo-platform deploy/helm/charts/platform/ \
  --namespace dynamo-system 2>&1 | tee /tmp/helm-install.log
```

---

### 6. HF Token 问题

**问题**：模型下载需要有效的 HuggingFace token。

**解决方案**：

```bash
# 登录 HuggingFace
huggingface-cli login

# 或手动创建 token 文件
mkdir -p ~/.cache/huggingface
echo "hf_xxxxx" > ~/.cache/huggingface/token

# 创建 K8s secret
kubectl -n dynamo-system create secret generic hf-token-secret \
  --from-literal=HF_TOKEN=$(cat ~/.cache/huggingface/token)
```

---

### 7. Pod 调度失败（Insufficient GPU）

**问题**：vGPU 配置未生效，pod 报 `Insufficient nvidia.com/gpu`。

**诊断**：

```bash
# 检查节点 GPU 容量
kubectl describe node minikube | grep -A5 "Allocatable"

# 检查 device plugin 日志
kubectl -n gpu-operator logs -l app=nvidia-device-plugin --tail=50

# 检查 time-slicing config
kubectl -n gpu-operator get configmap time-slicing-config -o yaml
```

**解决**：

```bash
# 强制重启 device plugin
kubectl -n gpu-operator delete pod -l app=nvidia-device-plugin
# DaemonSet 会自动重建

# 或重启整个 gpu-operator
kubectl -n gpu-operator rollout restart deployment/gpu-operator
```

---

### 8. NIXL 初始化失败

**问题**：NIXL 日志显示 backend 初始化失败。

**可能原因**：
- `/dev/shm` 太小
- CUDA 版本不兼容
- 两个 vGPU 的 IPC 通信问题

**解决方案**：

```yaml
# 在 pod spec 中挂载大的 /dev/shm
volumes:
- name: dshm
  emptyDir:
    medium: Memory
    sizeLimit: 2Gi

containers:
- volumeMounts:
  - name: dshm
    mountPath: /dev/shm
```

---

## 调试命令

```bash
# 查看所有 pods
kubectl -n dynamo-system get pods -o wide

# 查看 pod 详情（事件）
kubectl -n dynamo-system describe pod <pod-name>

# 查看日志
kubectl -n dynamo-system logs <pod-name>
kubectl -n dynamo-system logs <pod-name> --previous  # 看上次崩溃的日志

# 进入 pod 调试
kubectl -n dynamo-system exec -it <pod-name> -- bash

# 查看 DGD 状态
kubectl -n dynamo-system describe dgd vllm-disagg

# 查看 Operator 日志
kubectl -n dynamo-system logs -l app=dynamo-operator

# Port-forward 测试
kubectl -n dynamo-system port-forward svc/vllm-disagg-frontend 8000:8000
curl http://localhost:8000/v1/models
```

---

## 预期结果

### 成功场景

```bash
$ kubectl -n dynamo-system get pods
NAME                          READY   STATUS    RESTARTS   AGE
nats-xxx                      1/1     Running   0          10m
etcd-xxx                      1/1     Running   0          10m
vllm-disagg-frontend-xxx      1/1     Running   0          5m
vllm-disagg-prefill-xxx       1/1     Running   0          5m
vllm-disagg-decode-xxx        1/1     Running   0          4m

$ kubectl -n dynamo-system get dgd
NAME            STATUS   AGE
vllm-disagg     Ready    5m

$ curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hello"}]}'
{"id":"...","object":"chat.completion","model":"Qwen/Qwen3-0.6B",...}
```

### 部分成功（K8s 流程 OK，推理失败）

如果镜像有问题，可能看到：
- Pods Running，但 worker 注册失败
- Frontend 起不来 PrefillRouter
- 请求返回 503

这种情况下，**K8s 部署流程已验证成功**，只是推理层需要修复镜像。

---

## 部署进度

### ✅ 已完成

1. **vGPU Time-Slicing 配置成功**
   - ConfigMap: `nvidia-device-plugin-config` (kube-system)
   - Device Plugin 已 patch 并重启
   - 验证：`kubectl describe node minikube` 显示 `nvidia.com/gpu: 2`

2. **NATS + etcd 部署成功**
   - NATS: `nats.dynamo-system.svc:4222`
   - etcd: `etcd.dynamo-system.svc:2379`（使用阿里云镜像）
   - 状态：Running

3. **Helm 依赖下载成功**
   - nats, etcd, kai-scheduler, grove-charts, snapshot 已下载

### ❌ 遇到的问题

#### 问题 1: K8s 版本不兼容

**现象**：
```
Error: INSTALLATION FAILED: chart requires kubeVersion: >=1.30.0-0 which is incompatible with Kubernetes v1.28.0
```

**原因**：
- Dynamo CRD 使用了 K8s 1.30+ 的特性：
  - `optionalOldSelf`（CRD validation ratcheting）
  - CEL 函数 `quantity()` 和 `isGreaterThan()`
- minikube 默认安装的是 K8s 1.28.0

**解决方案**：
```bash
# 升级 minikube 到 K8s 1.30+
minikube delete
minikube start --driver=docker --kubernetes-version=v1.30.0

# 然后重新配置 vGPU time-slicing（因为 minikube 重建了）
bash setup-vgpu.sh
```

**状态**：⏳ 正在执行升级

#### 问题 2: 镜像拉取（待验证）

**预期问题**：`nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag` 在国内网络可能无法拉取。

**解决方案**：见 [README.md](./README.md) 中的"镜像准备"部分。

---

## 下一步

1. 等待 minikube 升级到 K8s 1.30
2. 重新配置 vGPU time-slicing
3. 重新部署 NATS + etcd
4. 安装 Dynamo Operator（或直接 apply CRDs）
5. 提交 DGD (disagg.yaml)
6. 验证端到端流程

---

## 总结

| 验证点 | 状态 | 说明 |
|---|---|---|
| vGPU time-slicing | ✅ | 已验证，node 显示 2 个 vGPU |
| NATS/etcd | ✅ | 已部署，Service 可达 |
| K8s 版本升级 | ⏳ | minikube 正在升级到 1.30 |
| Dynamo CRD | ⏳ | 依赖 K8s 1.30+ |
| Operator reconcile | ⏳ | 待 CRD 安装 |
| Pod 调度 | ⏳ | 待 Operator 就绪 |
| Worker 注册 | ⏳ | 待 Pod 启动 |
| 端到端推理 | ⏳ | 依赖镜像可用性 |
