# 08 · 关键文件与文档索引

阅读地图：先看哪些文件，再看哪些文件。

## 8.1 必读文档（概念层）

| 文档 | 内容 |
|---|---|
| `docs/fern/pages/developer-guide/knowledge-base/concepts/system-architecture/disaggregated-serving.md` | **canonical 架构文档**：三段式执行、后端元数据、xPyD、性能 |
| `docs/fern/pages/kubernetes/disaggregated-serving/overview.md` | K8s 部署 walkthrough |
| `docs/fern/pages/developer-guide/knowledge-base/modular-components/router/disaggregated-serving.md` | PrefillRouter 激活规则、请求流、注册代码 |
| `docs/fern/pages/cli/disaggregated-serving/overview.mdx` | CLI 视角的分离部署 |

## 8.2 必读文档（进阶）

| 文档 | 内容 |
|---|---|
| `docs/fern/pages/developer-guide/knowledge-base/concepts/system-architecture/architecture.md` | 整体系统架构 |
| `docs/fern/pages/developer-guide/knowledge-base/modular-components/router/router-guide.md` | Router 通用指南 |
| `docs/fern/pages/developer-guide/knowledge-base/modular-components/router/topology-aware-kv-transfer.md` | 拓扑感知 KV 传输 |
| `docs/fern/pages/developer-guide/knowledge-base/modular-components/router/multi-dc-kv-routing.md` | 跨 DC KV 路由 |
| `docs/fern/pages/developer-guide/knowledge-base/modular-components/router/configuration-and-tuning.md` | Router 调优 |
| `docs/fern/pages/developer-guide/knowledge-base/modular-components/backends/sglang/disaggregation.md` | SGLang 分离特定 |
| `docs/fern/pages/kubernetes/disaggregated-serving/sizing-with-aiconfigurator.mdx` | 用 AIconfigurator  sizing |
| `docs/fern/pages/kubernetes/kv-cache-offloading/overview.mdx` | KV cache 卸载 |

## 8.3 KV-aware 路由文档

| 文档 | 内容 |
|---|---|
| `docs/fern/pages/kubernetes/kv-aware-routing/gateway-api.mdx` | Gateway API 集成 |
| `docs/fern/pages/kubernetes/kv-aware-routing/standalone-router.md` | 独立 router 部署 |
| `docs/fern/pages/kubernetes/kv-aware-routing/kv-dc-relay.md` | DC relay |
| `docs/fern/pages/kubernetes/kv-aware-routing/dynamo-frontend.md` | Frontend 集成 |
| `docs/fern/pages/kubernetes/kv-aware-routing/vanilla-vllm-onramp.mdx` | 原生 vLLM 接入 |

## 8.4 核心 Rust 文件

| 文件 | 内容 |
|---|---|
| `lib/kv-router/src/worker_type.rs` | **`WorkerType` 枚举**（canonical） |
| `lib/kv-router/src/conditional_disagg.rs` | 旁路策略 |
| `lib/kv-router/src/scheduling/selector/` | worker 选择器（Picker / Scorer / Filter） |
| `lib/kv-router/src/scheduling/prefill_load.rs` | prefill 负载跟踪 |
| `lib/kv-router/src/kv_hints.rs` | KV 元数据 |
| `lib/kv-router/src/indexer/` | KV indexer |
| `lib/kv-router/src/tracking_hash.rs` | block hash |
| `lib/kv-hashing/` | hash 算法 |
| `lib/llm/src/worker_type.rs` | re-export |
| `lib/llm/src/discovery/` | model/worker discovery |
| `lib/llm/src/kv_router.rs` | KV router 集成 |
| `lib/llm/src/kv.rs` | KV 接口 |
| `lib/llm/src/kv_dc_relay.rs` + `lib/llm/src/kv_dc_relay/` | 多 DC relay |
| `lib/runtime/` | 分布式 runtime |
| `lib/router-plugins/` | 可插拔 filter/scorer/picker |
| `lib/kvbm-*/` | KV Block Manager 家族 |
| `lib/bindings/python/` | PyO3 绑定 |

## 8.5 核心 Python 文件

### 8.5.1 公共

| 文件 | 内容 |
|---|---|
| `components/src/dynamo/common/constants.py` | `DisaggregationMode` enum |

### 8.5.2 Frontend / Router

| 文件 | 内容 |
|---|---|
| `components/src/dynamo/frontend/main.py` | HTTP frontend，自动 PrefillRouter |
| `components/src/dynamo/frontend/prepost.py` | 前后处理，`kv_transfer_params` 注入 |
| `components/src/dynamo/router/` | standalone Python router |
| `components/src/dynamo/kv_dc_relay/` | multi-DC KV relay CLI |
| `components/src/dynamo/kv_state_agent/` | KV state agent |

### 8.5.3 vLLM 后端

| 文件 | 内容 |
|---|---|
| `components/src/dynamo/vllm/backend_args.py` | `--disaggregation-mode` flag |
| `components/src/dynamo/vllm/args.py` | 模式校验 |
| `components/src/dynamo/vllm/main.py` | worker 注册 |
| `components/src/dynamo/vllm/handlers.py` | 旁路注解、deferred abort |
| `components/src/dynamo/vllm/pd_connector.py` | **`PdConnector`** |
| `components/src/dynamo/vllm/kv_connector_protocols.py` | 各 connector 协议 |
| `components/src/dynamo/vllm/publisher.py` | KV events |
| `components/src/dynamo/vllm/sidecar.py` | sidecar |
| `components/src/dynamo/vllm/nixl_telemetry.py` | NIXL telemetry |

### 8.5.4 SGLang 后端

| 文件 | 内容 |
|---|---|
| `components/src/dynamo/sglang/_disagg.py` | **分离核心辅助** |
| `components/src/dynamo/sglang/backend_args.py` | CLI flag |
| `components/src/dynamo/sglang/args.py` | 多模态映射 |
| `components/src/dynamo/sglang/init_llm.py` | `init_prefill` / `init_decode` |
| `components/src/dynamo/sglang/request_handlers/llm/prefill_handler.py` | prefill handler |
| `components/src/dynamo/sglang/request_handlers/llm/decode_handler.py` | decode handler |
| `components/src/dynamo/sglang/publisher.py` | KV events |

### 8.5.5 TRT-LLM 后端

| 文件 | 内容 |
|---|---|
| `components/src/dynamo/trtllm/backend_args.py` | CLI flag |
| `components/src/dynamo/trtllm/main.py` | drain callback |
| `components/src/dynamo/trtllm/args.py` | component 命名 |

## 8.6 Operator / K8s

| 文件 | 内容 |
|---|---|
| `deploy/operator/api/v1beta1/common.go:32-43` | **`ComponentType` enum**（prefill/decode 一等公民） |
| `deploy/operator/api/v1alpha1/dynamocomponentdeployment_types.go:87` | legacy `SubComponentType` |
| `deploy/operator/api/v1alpha1/shared_spec_conversion.go:406-431` | v1alpha1 → v1beta1 转换 |
| `deploy/operator/internal/controller/dgd_disaggregatedset_*.go` | **DisaggregatedSet reconciler 全家** |
| `deploy/operator/internal/controller/dgd_disaggregatedset_selection.go` | 用上游 `sigs.k8s.io/lws/api/disaggregatedset/v1` |
| `deploy/operator/internal/consts/` | feature gate、workload provider 常量 |
| `deploy/helm/charts/platform/` | Helm chart |
| `recipes/kustomize/components/disagg-workers/` | Kustomize 组件 |

## 8.7 启动脚本与部署 YAML

| 路径 | 内容 |
|---|---|
| `examples/backends/vllm/launch/disagg*.sh` | vLLM CLI 启动 |
| `examples/backends/sglang/launch/disagg*.sh` | SGLang CLI 启动 |
| `examples/backends/trtllm/launch/disagg*.sh` | TRT-LLM CLI 启动 |
| `examples/backends/vllm/deploy/disagg*.yaml` | vLLM K8s DGD |
| `examples/backends/sglang/deploy/disagg*.yaml` | SGLang K8s DGD |
| `examples/backends/trtllm/deploy/disagg*.yaml` | TRT-LLM K8s DGD |
| `examples/backends/mocker/deploy/disagg.yaml` | Mock backend 测试用 |

## 8.8 Recipes

`recipes/<model>/<backend>/disagg-*/` — 见 [07-recipes.md](./07-recipes.md) 完整列表。

## 8.9 兄弟仓库（Ecosystem）

| 仓库 | 作用 |
|---|---|
| [NIXL](https://github.com/ai-dynamo/nixl) | KV cache 传输（RDMA/NVLink） |
| [AIPerf](https://github.com/ai-dynamo/aiperf) | 性能基准测试 |
| [AISimulate](https://pypi.org/project/aisimulate/) | 离线行为预测 |
| [ModelExpress](https://github.com/ai-dynamo/modelexpress) | 权重流式传输（走 NIXL） |
| [Grove](https://github.com/ai-dynamo/grove) | 拓扑感知 gang scheduling operator |

## 8.10 推荐学习路径

```
1. 概念层
   └─ 01-overview.md + 02-architecture.md
   └─ docs/.../disaggregated-serving.md (canonical)

2. 数据流
   └─ 05-kv-transfer.md
   └─ docs/.../router/disaggregated-serving.md

3. 看一个最简例子
   └─ examples/backends/vllm/launch/disagg.sh
   └─ examples/backends/vllm/deploy/disagg.yaml

4. 看后端代码
   └─ components/src/dynamo/vllm/pd_connector.py
   └─ components/src/dynamo/vllm/kv_connector_protocols.py

5. 看 Rust 控制面
   └─ lib/kv-router/src/worker_type.rs
   └─ lib/kv-router/src/conditional_disagg.rs

6. 看 Operator
   └─ deploy/operator/api/v1beta1/common.go
   └─ deploy/operator/internal/controller/dgd_disaggregatedset_*.go

7. 看生产 recipe
   └─ recipes/qwen3-32b/vllm/disagg-kv-router/
   └─ recipes/deepseek-r1/vllm/disagg/
```
