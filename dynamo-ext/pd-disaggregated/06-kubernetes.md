# 06 · Kubernetes / Operator

Dynamo 的 K8s 部署通过 **DynamoGraphDeployment (DGD)** CRD 描述。PD 分离在 operator 层是一等公民。

## 6.1 CRD：`DynamoGraphDeployment`

### 6.1.1 v1beta1（当前）

**`deploy/operator/api/v1beta1/common.go:32-43`** 把 prefill/decode 提升为**一等 `ComponentType`**：

```go
// +kubebuilder:validation:Enum=frontend;worker;prefill;decode;planner;epp;lpx
type ComponentType string

const (
    ComponentTypeFrontend ComponentType = "frontend"
    ComponentTypeWorker   ComponentType = "worker"       // 聚合模式
    ComponentTypePrefill  ComponentType = "prefill"      // ← 一等公民
    ComponentTypeDecode   ComponentType = "decode"       // ← 一等公民
    ComponentTypePlanner  ComponentType = "planner"
    ComponentTypeEPP      ComponentType = "epp"          // Endpoint Picker (上游 K8s API)
    ComponentTypeLPX      ComponentType = "lpx"
)
```

Pod label：`nvidia.com/dynamo-component-type` 暴露 role，EPP 可以直接过滤。

### 6.1.2 v1alpha1（legacy）

用 `subComponentType`（自由字符串）作为变通：
- `componentType: worker` + `subComponentType: "prefill"`
- `componentType: worker` + `subComponentType: "decode"`

转换代码在 `deploy/operator/api/v1alpha1/shared_spec_conversion.go:406-431`，把 `subComponentType` 提升为 v1beta1 的 `ComponentType`。

### 6.1.3 典型 DGD 示例（v1beta1）

`examples/backends/vllm/deploy/disagg.yaml`：

```yaml
apiVersion: nvidia.com/v1beta1
kind: DynamoGraphDeployment
metadata:
  name: qwen3-32b-disagg
spec:
  backendFramework: vllm
  components:
  - name: Frontend
    type: frontend
    replicas: 1
    podTemplate:
      spec:
        containers:
        - name: main
          args: [--router-mode, kv, --http-port, "8000"]

  - name: prefill
    type: prefill                    # ← 一等公民
    replicas: 3
    podTemplate:
      spec:
        containers:
        - name: main
          args:
          - --model
          - Qwen/Qwen3-32B
          - --disaggregation-mode
          - prefill
          - --kv-transfer-config
          - '{"kv_connector":"NixlConnector","kv_role":"kv_producer"}'
          env:
          - name: VLLM_NIXL_SIDE_CHANNEL_PORT
            value: "55581"

  - name: decode
    type: decode                     # ← 一等公民
    replicas: 4
    podTemplate:
      spec:
        containers:
        - name: main
          args:
          - --model
          - Qwen/Qwen3-32B
          - --disaggregation-mode
          - decode
          - --kv-transfer-config
          - '{"kv_connector":"NixlConnector","kv_role":"kv_consumer"}'
          env:
          - name: VLLM_NIXL_SIDE_CHANNEL_PORT
            value: "55582"
```

## 6.2 DisaggregatedSet 工作负载 Provider

Dynamo operator 实现了一个完整的 **DisaggregatedSet** reconciler 家族，对接**上游 Kubernetes 的 `DisaggregatedSet` API**（`sigs.k8s.io/lws/api/disaggregatedset/v1`）。

### 6.2.1 关键文件

| 文件 | 角色 |
|---|---|
| `deploy/operator/internal/controller/dgd_disaggregatedset_program.go` | **顶层 program**：`disaggregatedSetProgram.Reconcile()` 编排共享资源、rollout、workloads、scaling adapters |
| `dgd_disaggregatedset_selection.go` | **选择逻辑**：用 `sigs.k8s.io/lws/api/disaggregatedset/v1`；准入条件 = ≥2 个多节点 worker role 且 type ∈ {prefill, decode} |
| `dgd_disaggregatedset_workloads_factory.go` | 构造 `DisaggregatedSet` 对象 |
| `dgd_disaggregatedset_workload_renderer.go` | 把每个 prefill/decode component 渲染成 role |
| `dgd_disaggregatedset_workloads_reconciler.go` | workload reconcile |
| `dgd_disaggregatedset_resource_reconciler.go` | 共享资源 reconcile |
| `dgd_disaggregatedset_stable_resources_reconciler.go` | 稳定资源 |
| `dgd_disaggregatedset_auxiliary_dcd_reconciler.go` | 辅助 DCD |
| `dgd_disaggregatedset_readiness_resolver.go` | readiness 解析 |
| `dgd_disaggregatedset_restart_progress_resolver.go` | restart/progress 解析 |
| `dgd_disaggregatedset_ownership.go` | owner reference |
| `dgd_disaggregatedset_watch_setup.go` | watch 配置 |

### 6.2.2 Feature Gate

通过 annotation 启用：
```yaml
metadata:
  annotations:
    nvidia.com/enable-disaggregatedset: "true"
```

常量：`deploy/operator/internal/consts/` 下的 `KubeAnnotationEnableDisaggregatedSet`。

Workload provider 常量：`WorkloadProviderDisaggregatedSet`。

## 6.3 Helm Charts

**`deploy/helm/charts/`**：

| Chart | 内容 |
|---|---|
| `platform/` | 平台 chart，含 operator (`components/operator/`)、CRDs、RBAC |
| `power-agent/` | 独立的 power-aware agent chart |

安装示例：
```bash
helm install dynamo-platform deploy/helm/charts/platform/
kubectl apply -f examples/backends/vllm/deploy/disagg.yaml
```

## 6.4 Kustomize 组件

**`recipes/kustomize/components/`**：

| 组件 | 说明 |
|---|---|
| `disagg-workers/` | 后端中性的分离 worker 组件（`PrefillWorker` + `DecodeWorker` 服务键），含子组件：`aws-efa`, `nebius-ib`, `nscale-ib`, `rdma-defaults`, `gke-roce` |
| `vllm-disagg/` | vLLM 专用 overlay：`aws-efa`, `nebius-ib`, `nixl-default` |

**`recipes/templates/kustomize/components/*/disagg/patch-dgd.yaml`**：JSON-6902 补丁，把普通 DGD patch 成 disagg DGD。子目录：
- `cache-binding/`
- `placement/`
- `network-interface/`
- `scheduling/`
- `registry-credentials/`
- `provider-networking/`

## 6.5 K8s 部署 Checklist

按 `docs/fern/pages/kubernetes/disaggregated-serving/overview.md` 的部署要求：

| 项 | 要求 |
|---|---|
| **ETCD** | 必须，用于 Dynamo coordination |
| **NATS** | 必须，用于 worker 注册/discovery |
| **sharedMemory.size** | 每个 worker pod 至少 **16Gi**（NIXL 用 `/dev/shm` 暂存传输元数据） |
| **RDMA (多节点)** | InfiniBand 或 RoCE；需要对应 device plugin |
| **NVLink (单节点)** | 自动使用 CUDA IPC |
| **model 对齐** | prefill 和 decode 必须用**同一个** `--model`（KV cache 格式必须兼容） |
| **日志验证** | 看到 `NIXL INFO Backend UCX was instantiated` 表示 RDMA 起来 |

## 6.6 EPP（Endpoint Picker）

`ComponentTypeEPP = "epp"` 对接上游的 [Endpoint Picker](https://github.com/kubernetes-sigs/gateway-api-inference-extension) 项目，让 K8s Gateway API 能感知 Dynamo 的 worker 拓扑做 L7 路由。

## 6.7 Grove（拓扑感知 gang scheduling）

[Grove](https://github.com/ai-dynamo/grove) 是 sibling 仓库，做**拓扑感知的 gang scheduling** —— 把 prefill/decode worker 调到**物理邻近**的 GPU 组，最小化 KV 传输延迟。与 DGD 配合使用。
