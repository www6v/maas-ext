# 部署状态报告

**时间**：2026-10-24 13:45 CST  
**目标**：使用 vGPU time-slicing 在单卡 RTX 3090 上部署 Dynamo vLLM PD 分离

---

## 执行摘要

已成功完成 K8s 基础设施层面的验证（vGPU、NATS、etcd），遇到 K8s 版本兼容性阻塞，正在升级中。

---

## 已完成工作

### 1. vGPU Time-Slicing ✅

**配置**：
- ConfigMap: `kube-system/nvidia-device-plugin-config`
- Device Plugin DaemonSet 已 patch
- 验证通过：节点显示 `nvidia.com/gpu: 2`（从 1 个物理 RTX 3090 虚拟出 2 个 vGPU）

**脚本**：`setup-vgpu.sh`

### 2. NATS + etcd ✅

**部署**：
```bash
kubectl -n dynamo-system get pods
NAME                    READY   STATUS    RESTARTS   AGE
etcd-5cd487bbdb-zgl2p   1/1     Running   0          16s
nats-86f58c887c-58lps   1/1     Running   0          41s
```

**Services**：
- `nats.dynamo-system.svc:4222`
- `etcd.dynamo-system.svc:2379`（使用阿里云镜像 `registry.cn-hangzhou.aliyuncs.com/google_containers/etcd:3.5.21-0`）

### 3. Helm 依赖 ✅

已下载：
- nats-1.3.2
- etcd-12.0.18
- kai-scheduler-v0.17.0
- grove-charts-v0.1.0-alpha.15
- snapshot-0.2.0

---

## 遇到的问题

### 问题 1: K8s 版本不兼容 ❌

**错误**：
```
chart requires kubeVersion: >=1.30.0-0 which is incompatible with Kubernetes v1.28.0
```

**CRD 错误**（直接 apply 时）：
```
unknown field "spec.versions[0].schema.openAPIV3Schema.properties.spec.x-kubernetes-validations[0].optionalOldSelf"
ERROR: undeclared reference to 'quantity'
ERROR: undeclared reference to 'isGreaterThan'
```

**原因**：
- Dynamo 1.7.0 的 CRD 使用了 K8s 1.30+ 的特性：
  - `optionalOldSelf`（CRD validation ratcheting，K8s 1.30 引入）
  - CEL 函数 `quantity()` 和 `isGreaterThan()`（K8s 1.30+ 支持）

**解决方案**：升级 minikube 到 K8s 1.30+

**当前状态**：⏳ 正在执行 `minikube start --kubernetes-version=v1.30.0`

---

### 问题 2: 镜像可用性 ⚠️（待验证）

**预期问题**：
- `nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag` 在国内网络可能无法拉取
- 测试：`docker pull nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0` 超时

**解决方案**（按优先级）：
1. 配置 Docker 代理后拉取官方镜像
2. 从源码构建（`container/Dockerfile.template`）
3. 扩展现有的 `vllm-local:qwen3.5-4b` 镜像（需要安装 dynamo）

**当前状态**：⏸️ 等待 K8s 升级完成后验证

---

## 文件清单

```
/home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-deploy/
├── README.md              # 部署指南
├── troubleshooting.md     # 问题与解决方案（已更新）
├── STATUS.md              # 本文件
├── deploy.sh              # 主部署脚本
├── setup-vgpu.sh          # vGPU 配置脚本 ✅ 已验证
├── cleanup.sh             # 清理脚本
└── verify.sh              # 端到端验证脚本（待实现）
```

---

## 下一步计划

1. **等待 minikube 升级完成**（正在下载 K8s 1.30 镜像）
2. **重新配置 vGPU**（minikube 重建后需要重新 patch device plugin）
3. **重新部署 NATS + etcd**（命名空间已删除）
4. **安装 Dynamo CRDs**（应该能成功，K8s 1.30 支持所需特性）
5. **部署 Dynamo Operator**（或直接使用 CRD）
6. **准备 vLLM runtime 镜像**（可能需要代理或源码构建）
7. **提交 DGD** (`disagg.yaml`)
8. **验证端到端流程**

---

## 关键发现

### vGPU Time-Slicing 验证

**结论**：vGPU time-slicing 在 minikube + RTX 3090 上**完全可行**。

**验证方法**：
```bash
# 配置 ConfigMap
kubectl -n kube-system create configmap nvidia-device-plugin-config \
  --from-file=config.yaml=<(cat <<EOF
version: v1
sharing:
  timeSlicing:
    resources:
    - name: nvidia.com/gpu
      replicas: 2
EOF
)

# Patch DaemonSet
kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"device-plugin-config","configMap":{"name":"nvidia-device-plugin-config"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"device-plugin-config","mountPath":"/etc/kubernetes/device-plugin-config.yaml","subPath":"config.yaml"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"CONFIG_FILE","value":"/etc/kubernetes/device-plugin-config.yaml"}}
]'

# 验证
kubectl describe node minikube | grep "nvidia.com/gpu"
# 输出：nvidia.com/gpu: 2
```

**注意事项**：
- 两个 vGPU **共享** 24GB 显存（不是各 24GB）
- 计算通过时间分片复用（不是真正隔离）
- 适合验证 K8s 拓扑，**不适合性能测试**

---

## 技术细节

### 环境信息

```
OS: Ubuntu 22.04
GPU: NVIDIA GeForce RTX 3090 (24GB)
Driver: 535+
CUDA: 12.1
minikube: v1.39.0
K8s: v1.28.0 → v1.30.0 (升级中)
Docker: 24.0+
Helm: v3.22.0
```

### Dynamo 版本

```
ai-dynamo: 1.7.0
CRD API: nvidia.com/v1beta1
```

---

## 参考资料

- [Dynamo 源码](/home/wangwei/wei/workspacePy/maas/dynamo-main/)
- [PD 分离分析文档](/home/wangwei/wei/workspacePy/maas/maas-ext/dynamo-ext/pd-disaggregated/)
- [NVIDIA GPU Time-Slicing](https://gitlab.com/nvidia/kubernetes/device-plugin/-/tree/main?ref=main#configuration-for-time-slicing)
- [Dynamo K8s 部署指南](https://docs.nvidia.com/dynamo/dev/kubernetes/disaggregated-serving/overview)
