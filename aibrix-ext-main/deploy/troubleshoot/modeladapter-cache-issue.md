# ModelAdapter 缓存问题故障排除

**日期**: 2026-09-30  
**状态**: ✅ 已解决

---

## 问题描述

ModelAdapter 控制器持续报错：

```
E0930 10:47:30.050327 1 controller.go:316] "msg"="Reconciler error" 
"error"="key does not exist in the cache: default/vllm-qwen35-4b-694b64b466-kc47x"
```

ModelAdapter 状态一直为 `Pending`，无法找到 vLLM Pod。

---

## 根本原因

AIBrix Controller Manager 使用内部缓存（`pkg/cache`）来跟踪 Pod 和模型映射。
缓存通过 Kubernetes Discovery Provider（`pkg/cache/discovery/kubernetes.go`）监听所有 Pod，
但只有带有特定标签的 Pod 才会被添加到缓存中。

**关键代码** (`pkg/cache/informers.go`):

```go
func (c *Store) addPod(obj interface{}) {
    pod := obj.(*v1.Pod)
    modelName, ok := getModelNameFromPod(pod)
    modelClaims := utils.ModelClaimBindingsFromPod(pod)
    if !ok && len(modelClaims) == 0 {
        klog.V(4).InfoS("ignored pod without model label or annotation", "name", pod.Name)
        return  // Pod 被忽略！
    }
    // ...
}
```

**标签要求** (`pkg/constants/model.go`):

```go
ModelLabelName = "model.aibrix.ai/name"

func ModelNameFromMetadata(labels, annotations map[string]string) (string, bool) {
    if modelName := labels[ModelLabelName]; modelName != "" {
        return modelName, true
    }
    if modelName := annotations[ModelLabelName]; modelName != "" {
        return modelName, true
    }
    return "", false
}
```

**问题**: vLLM Pod 缺少 `model.aibrix.ai/name` 标签，导致不被缓存发现。

---

## 解决方案

### 1. 更新 vLLM Deployment

在 Pod 模板中添加必需标签：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-qwen35-4b
  namespace: default
spec:
  template:
    metadata:
      labels:
        app: vllm
        model: qwen3.5-4b
        aibrix.io/model: qwen3.5-4b
        model.aibrix.ai/name: qwen3.5-4b  # 添加此标签！
```

### 2. 重新部署 vLLM

```bash
kubectl apply -f deploy/manifests/vllm-deployment.yaml
```

### 3. 验证 Pod 标签

```bash
$ kubectl get pods -l app=vllm --show-labels
NAME                              READY   STATUS    LABELS
vllm-qwen35-4b-6c6fddf4d6-j682z   1/1     Running   aibrix.io/model=qwen3.5-4b,app=vllm,model.aibrix.ai/name=qwen3.5-4b,model=qwen3.5-4b
```

### 4. 验证缓存发现

查看 controller-manager 日志，应该能看到 Pod 被发现：

```bash
kubectl logs -n aibrix-system deployment/aibrix-controller-manager --tail=20
```

---

## 额外问题：ModelAdapter 名称

### 问题

创建 ModelAdapter 时，名称 `qwen3.5-4b` 包含点号（`.`），导致 Service 创建失败：

```
Service "qwen3.5-4b" is invalid: metadata.name: Invalid value: "qwen3.5-4b": 
a DNS-1035 label must consist of lower case alphanumeric characters or '-', 
start with an alphabetic character, and end with an alphanumeric character
```

### 原因

Kubernetes Service 名称必须符合 DNS-1035 规范：
- 只能包含小写字母、数字和连字符
- 必须以字母开头
- 必须以字母或数字结尾
- 正则表达式：`[a-z]([-a-z0-9]*[a-z0-9])?`

### 解决方案

使用符合规范的名称：

```yaml
apiVersion: model.aibrix.ai/v1alpha1
kind: ModelAdapter
metadata:
  name: qwen35-4b  # 使用连字符而不是点号
  namespace: default
spec:
  baseModel: qwen3.5-4b
  # ...
```

---

## 关键发现

### ModelAdapter vs 基础模型

**重要**: ModelAdapter 是用于 **LoRA 适配器**的，不是用于基础模型！

- **基础模型**: 直接由 vLLM Pod 提供，不需要 ModelAdapter
- **LoRA 适配器**: 通过 ModelAdapter 动态加载到已运行的 vLLM 实例上

我们的部署场景是提供基础模型（Qwen3.5-4B），所以**不需要创建 ModelAdapter**。

### AIBrix 缓存架构

```
Controller Manager
    ↓
cache.InitWithOptions()
    ↓
KubernetesProvider.Watch()
    ↓
Pod Informer (监听所有 Pod)
    ↓
handleDiscoveryObject()
    ↓
store.addPod()
    ↓
检查 model.aibrix.ai/name 标签
    ↓
添加到缓存 (metaPods)
    ↓
调度器可以使用
```

---

## 验证步骤

1. **检查 Pod 标签**:
   ```bash
   kubectl get pods -l app=vllm --show-labels
   ```

2. **检查 controller-manager 日志**:
   ```bash
   kubectl logs -n aibrix-system deployment/aibrix-controller-manager --tail=50
   ```

3. **测试 vLLM API**:
   ```bash
   kubectl port-forward svc/vllm-service 8000:8000 -n default &
   curl http://localhost:8000/v1/models
   ```

4. **检查缓存指标** (如果有):
   ```bash
   kubectl exec -n aibrix-system deployment/aibrix-controller-manager -- \
     wget -qO- http://localhost:8080/metrics | grep pod
   ```

---

## 相关文件

- `pkg/cache/discovery/kubernetes.go`: Kubernetes 发现提供者
- `pkg/cache/informers.go`: Pod 缓存管理
- `pkg/cache/cache_init.go`: 缓存初始化
- `pkg/constants/model.go`: 标签常量定义
- `pkg/controller/modeladapter/modeladapter_controller.go`: ModelAdapter 控制器

---

## 总结

1. ✅ vLLM Pod 必须有 `model.aibrix.ai/name` 标签
2. ✅ ModelAdapter 名称必须符合 DNS-1035 规范
3. ✅ 基础模型不需要 ModelAdapter，直接由 vLLM 提供
4. ✅ AIBrix 缓存通过标签发现和管理 Pod
