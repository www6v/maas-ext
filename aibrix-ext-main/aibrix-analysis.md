# AIBrix 功能深度分析

> 本文档基于 AIBrix 源码（`aibrix/`）的深度分析，涵盖 API Gateway、模型路由、流量调度、多租户隔离、资源管理、模型统一接入、版本管理、灰度发布与流量切换等核心能力。

---

## 目录

1. [整体架构概览](#1-整体架构概览)
2. [API Gateway](#2-api-gateway)
3. [模型统一接入](#3-模型统一接入)
4. [模型路由](#4-模型路由)
5. [流量调度](#5-流量调度)
6. [多租户隔离](#6-多租户隔离)
7. [资源管理](#7-资源管理)
8. [版本管理](#8-版本管理)
9. [灰度发布与流量切换](#9-灰度发布与流量切换)
10. [关键文件索引](#10-关键文件索引)

---

## 1. 整体架构概览

AIBrix 是一个 **Kubernetes 原生的 LLM 推理基础设施平台**，其核心架构由以下层次组成：

```
                        ┌─────────────────────┐
                        │    Client (OpenAI    │
                        │   Compatible API)    │
                        └─────────┬───────────┘
                                  │
                        ┌─────────▼───────────┐
                        │   Envoy Gateway      │
                        │  (HTTP/2 终结, TLS)  │
                        └─────────┬───────────┘
                                  │ gRPC ext_proc
                        ┌─────────▼───────────┐
                        │  Gateway Plugin      │
                        │  ┌─────────────────┐ │
                        │  │ 认证 / 限流      │ │
                        │  │ 路由策略选择     │ │
                        │  │ Pod 选择         │ │
                        │  │ 响应处理 / 计量  │ │
                        │  └─────────────────┘ │
                        └─────────┬───────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              │                   │                   │
     ┌────────▼──────┐  ┌────────▼──────┐  ┌────────▼──────┐
     │  vLLM Pod 1   │  │  vLLM Pod 2   │  │  SGLang Pod   │
     │  (Model A)    │  │  (Model A)    │  │  (Model B)    │
     └───────────────┘  └───────────────┘  └───────────────┘
              │                   │                   │
     ┌────────▼───────────────────▼───────────────────▼────┐
     │                    Redis                             │
     │  (限流计数, Session Affinity, Prefix Cache 同步)    │
     └─────────────────────────────────────────────────────┘
              │
     ┌────────▼────────────────────────────────────────────┐
     │            Kubernetes Control Plane                  │
     │  ┌──────────────┐ ┌──────────────┐ ┌─────────────┐ │
     │  │ModelRouter   │ │ModelAdapter  │ │ModelClaim   │ │
     │  │Controller    │ │Controller    │ │Controller   │ │
     │  └──────────────┘ └──────────────┘ └─────────────┘ │
     └─────────────────────────────────────────────────────┘
```

### 核心组件

| 组件 | 路径 | 职责 |
|------|------|------|
| Gateway Plugin | `cmd/plugins/main.go` | Envoy ext_proc gRPC 插件，处理请求/响应的全生命周期 |
| RouterManager | `pkg/plugins/gateway/algorithms/router.go` | 路由策略注册中心，支持多策略加权组合 |
| ModelRouter Controller | `pkg/controller/modelrouter/` | 自动创建 HTTPRoute，实现模型到路由的映射 |
| ModelAdapter Controller | `pkg/controller/modeladapter/` | LoRA 适配器的生命周期管理 |
| ModelClaim Controller | `pkg/controller/modelclaim/` | 温池 GPU 上的动态模型激活 |
| Cache Layer | `pkg/cache/` | Pod 注册、运行请求计数、指标收集、KV 事件管理 |

---

## 2. API Gateway

### 2.1 架构设计

AIBrix 的 API Gateway 基于 **Envoy External Processing (ext_proc) gRPC 插件** 模式实现。

- **数据平面**: Envoy Gateway 处理 HTTP/2 终结、TLS、连接管理
- **控制平面**: Gateway Plugin 作为独立的 gRPC 服务运行，拦截并处理每个请求/响应阶段
- **二进制入口**: `cmd/plugins/main.go`
- **gRPC 端口**: 50052（Envoy ext_proc 流）
- **HTTP 端口**: 8080（`/metrics` 和 `/v1/models`）

### 2.2 请求处理管线

Gateway 实现了 4 阶段的请求处理管线：

```
RequestHeaders → RequestBody → ResponseHeaders → ResponseBody
```

#### 阶段 1: RequestHeaders (`gateway_req_headers.go`)

- **API Key 认证**: 如果设置了 `AIBRIX_AUTH_BEARER_TOKEN`，使用常数时间 SHA-256 比对验证 `Authorization: Bearer <token>`
- **用户身份解析**: 从 `user` 请求头提取用户标识，从 Redis 加载用户配额（RPM/TPM）
- **请求头提取**: `routing-strategy`、`x-aibrix-priority-tier`、`config-profile`、`x-session-id`、`traceparent`
- **OTel 追踪上下文传播**: 注入 OpenTelemetry 追踪头
- **HTTPRoute 验证**: 使用 `singleflight.Group` 合并并发验证请求，防止缓存过期时的雷群效应

#### 阶段 2: RequestBody (`gateway_req_body.go`)

- **请求体验证**: 使用轻量级结构体验证 JSON 体（避免 SDK 反射开销）
- **多部分解析**: 处理音频/视频端点的 `multipart/form-data`
- **模型名提取**: 从请求体的 `model` 字段读取
- **配置 Profile 解析**: 从 Pod 的 `model.aibrix.ai/config` 注解读取配置
- **路由策略推导**: 优先级: locked profile → header → profile → `ROUTING_ALGORITHM` 环境变量
- **Pod 选择**: 调用 `selectTargetPod()` 执行路由算法
- **引擎路径重写**: xdit 引擎路由 `/v1/images/generations` → `/generate`
- **优先级映射**: 将 `x-aibrix-priority-tier` 映射为 vLLM 的 `priority` 字段
- **Content-Length 修正**: 匹配重写后的 body 大小

#### 阶段 3: ResponseHeaders (`gateway_rsp_headers.go`)

- 设置路由诊断头（`routing-strategy`、`target-pod`、`target-pod-ip`）
- 当 `authoritativeRoutingPolicy` 启用时隐藏路由诊断信息
- 移除 `content-length`（当响应体将被重写时）

#### 阶段 4: ResponseBody (`gateway_rsp_body.go`)

- **流式 SSE 处理**: 重组跨 chunk 边界的 SSE 行，1MB 缓冲区上限
- **Token 计量**: 从最终 `data: {...}` chunk 中提取 token 使用量，使用零分配 `gjson` 扫描
- **指标发射**: TTFT、TPOT、路由时间、Prefill 时间、KV 传输时间、Decode 时间
- **错误归一化**: 将嵌套/扁平错误体转换为统一的 `{"error": {...}}` 信封

### 2.3 支持的 API 端点

| 路径 | 类型 | 说明 |
|------|------|------|
| `/v1/chat/completions` | 语言 | Chat 补全，支持流式 |
| `/v1/completions` | 语言 | 文本补全，支持流式 |
| `/v1/responses` | 语言 | OpenAI Responses API |
| `/v1/messages` | 语言 | Anthropic 兼容 |
| `/v1/embeddings` | 语言 | 向量嵌入 |
| `/v1/rerank` | 语言 | 重排序 |
| `/v1/classify` | 语言 | 分类 |
| `/v1/images/generations` | 非语言 | 图像生成 |
| `/v1/video/generations` | 非语言 | 视频生成（JSON） |
| `/v1/videos` | 非语言 | vLLM-Omni Videos API（multipart） |
| `/v1/audio/transcriptions` | 非语言 | 音频转录（multipart） |
| `/v1/audio/translations` | 非语言 | 音频翻译（multipart） |
| `/tokenize` | 非语言 | 分词 |
| `/generate`、`/generatevideo` | 引擎特定 | xdit 引擎原生端点 |

### 2.4 认证机制

- **API Key 认证** (`api_key_auth.go`): 基于 `AIBRIX_AUTH_BEARER_TOKEN` 环境变量的 Bearer Token 验证，使用常数时间 SHA-256 比对防止时序攻击
- **用户身份**: 通过 `user` HTTP 请求头标识调用者，用户配额（RPM/TPM）存储在 Redis
- **禁用认证**: `AIBRIX_DISABLE_RATE_LIMITING=true` 跳过用户查找和配额执行

### 2.5 异步视频任务系统

Gateway 为 vLLM-Omni Videos API 实现了异步任务注册表 (`async_job_registry.go`)：

- **创建**: POST `/v1/videos` — Gateway 生成公开任务 ID，替换后端内部 ID，在 Redis 中记录 Pod 亲和性
- **状态查询**: GET `/v1/videos/{id}` — 通过注册表路由回拥有 Pod
- **内容获取**: GET `/v1/videos/{id}/content` — 从拥有 Pod 流式传输
- **删除**: DELETE `/v1/videos/{id}` — 路由到拥有 Pod，清理注册表记录
- **列表**: GET `/v1/videos` — 直接从注册表提供，无需后端路由
- **用户隔离**: 任务按用户身份隔离

### 2.6 配置系统

#### 环境变量（70+ 个）

核心环境变量（完整列表见 `pkg/plugins/gateway/ENV_VARS.md`）：

| 变量 | 说明 |
|------|------|
| `ROUTING_ALGORITHM` | 默认路由算法 |
| `AIBRIX_DISABLE_RATE_LIMITING` | 禁用限流 |
| `AIBRIX_AUTH_BEARER_TOKEN` | API Key |
| `AIBRIX_STATESYNC_ENABLED` | 跨副本状态同步 |
| `AIBRIX_GRPC_MAX_MESSAGE_SIZE_BYTES` | gRPC 消息大小限制（默认 4MB） |
| `AIBRIX_PRIORITY_TIER_ENABLED` | 启用优先级转发 |
| `AIBRIX_HTTPROUTE_CACHE_TTL` | HTTPRoute 验证缓存 TTL（默认 30s） |

#### Model Config Profiles (`configprofiles/configprofiles.go`)

通过 `model.aibrix.ai/config` 注解实现每模型配置：

- 多个命名 Profile，通过 `config-profile` 请求头选择
- 每个 Profile 可配置：路由策略、RPS 限制、Inflight 上限、TTFT 阈值
- `routingConfig` 子对象：路由算法参数（负载均衡权重、前缀缓存因子、PD 阈值、VTC 设置等）
- `lockedRoutingStrategy`：模型级路由策略锁定
- `authoritativeRoutingPolicy`：隐藏客户端响应中的路由诊断信息
- 基于 `promptTokensGte`/`promptTokensLt`/`maxTokensGte`/`maxTokensLt` 范围的自动 Profile 选择

### 2.7 可观测性

- **Prometheus 指标**: 飞行中请求数、请求总数、模型飞行中仪表、Token 桶直方图、TTFT/TPOT/路由时间/Prefill 时间/KV 传输/Decode 时间分布桶、panic 计数、PD prefill 失败计数
- **OpenTelemetry 追踪**: 可配置的 span（请求头处理、Body 处理、Pod 选择、推理、首 chunk 时间、chunk 间隔）
- **结构化日志**: klog 带有请求级上下文（请求 ID、模型、目标 Pod、路由策略、时间、Token 计数）
- **Grafana 仪表板**: `AIBrix_Envoy_Gateway_Dashboard.json` 和 `AIBrix_Envoy_Gateway_Plugins_Dashboard.json`

### 2.8 优雅关闭

- 信号处理器捕获 SIGINT/SIGTERM
- 通过 `shutdownCh` 向所有飞行中的 ext_proc 流广播关闭信号
- 按顺序停止状态同步管理器、HTTP 服务器（5s 超时）、gRPC 服务器
- 解除阻塞的 `Recv()` 调用，避免空闲流阻止进程退出

---

## 3. 模型统一接入

### 3.1 统一入口设计

AIBrix 提供**统一推理网关**，所有模型的请求通过单个 Envoy 端点路由。客户端向同一 URL 发送请求，通过 JSON body 中的 `"model"` 字段指定目标模型（OpenAI 兼容 API）。

**模型名提取流程** (`pkg/plugins/gateway/util.go:182`, `validateRequestBody`)：
1. 根据路径类型分发（`/v1/chat/completions`、`/v1/completions`、`/v1/embeddings` 等 14+ 种路径）
2. 反序列化 body 提取 model 名称
3. 支持 `baseModel` 关联解析

### 3.2 Model Router Controller — 自动 HTTPRoute 创建

`pkg/controller/modelrouter/modelrouter_controller.go` 监听 4 种工作负载类型：

| 工作负载 | 触发方式 |
|---------|---------|
| `apps/v1.Deployment` | `addRouteFromDeployment` |
| `model.aibrix.ai/v1alpha1.ModelAdapter` | `addRouteFromModelAdapter` |
| `orchestration.aibrix.ai/v1alpha1.RayClusterFleet` | `addRouteFromRayClusterFleet` |
| `leaderworkerset.x-k8s.io/v1.LeaderWorkerSet` | `addRouteFromUnstructuredObj` |

**HTTPRoute 创建流程** (`createHTTPRoute`, line 243)：

1. 从 `model.aibrix.ai/name` 标签提取**模型名**（注解作为回退，支持含 `/` 的名称）
2. 在 `aibrix-system` 命名空间创建 Kubernetes Gateway API `HTTPRoute`（父级: `aibrix-eg`）
3. 匹配规则：`Header: model = <modelName>` + 14 种标准路径前缀
4. 路由到工作负载命名空间中的 Kubernetes Service
5. 创建 `ReferenceGrant` 实现跨命名空间路由

**模型名解析** (`constants.ModelNameFromMetadata()`)：标签优先，注解回退（支持含无效标签字符的名称）。

**自定义路由路径**: 通过注解 `model.aibrix.ai/model-router-custom-paths`（逗号分隔）添加。

### 3.3 Pod 发现机制

`pkg/cache/discovery/` 定义了 `Provider` 接口：

- **KubernetesProvider** (`kubernetes.go`): 使用 K8s Informer 监听 Pod 和 ModelAdapter
- **StaticProvider** (`static.go`): 从 YAML 加载端点（用于独立/Docker 模式）

Gateway 缓存 (`pkg/cache/cache_impl.go`) 维护按 `model → pod list` 键控的 `podRegistry`，随 Informer 事件重建。`utils.FilterRoutablePods` 过滤掉非 Running+Ready 或缺少 PodIP 的 Pod。

### 3.4 多端口/数据并行 Pod 支持

`utils.IsDataParallelPod` 检测服务多端口的 Pod（张量并行副本共享一个 Pod）。`least-request` 的 `apiServerRoute` 同时选择 Pod **和端口**，通过跟踪 `RealtimeNumRequestsRunning/<port>` 选择请求最少的 (pod, port) 对。

### 3.5 AI Gateway 集成

`samples/ai-gateway-integration/` 展示了与 Kubernetes Gateway API Inference Extension 的集成：

- `AIGatewayRoute` CR 匹配 `x-ai-eg-model` 请求头
- 路由到 `InferencePool` 后端（每模型一个）
- 每个后端有自己的 Endpoint Picker (EPP) 部署，运行评分插件（`queue-scorer`、`kv-cache-utilization-scorer`、`prefix-cache-scorer`）

---

## 4. 模型路由

### 4.1 路由架构概述

AIBrix 实现了精密的、可插拔的模型路由管线，路由决策发生在两个层级：

1. **Kubernetes 层** — `ModelRouter` Controller 监听 Deployment、`ModelAdapter` CR、`RayClusterFleet`，创建 per-model `HTTPRoute` 对象
2. **Gateway 层** — 请求到达 Envoy 附加的 Gateway 后，per-request `RouterManager.Select(...)` 选择具体的 **Pod**（对于数据并行 Pod，还包括端口）

### 4.2 核心请求流 (`gateway.go:707`)

```
resolve overrides → external label filter → inflight-per-replica filter →
  exclusive-strategy branch (pd / slo*) OR ApplyLoadImbalanceGate →
  RouterManager.Select(ctx) → router.Route(ctx, podList)
```

### 4.3 路由接口 (`pkg/types/router.go`)

| 接口 | 说明 |
|------|------|
| `Router.Route(ctx, readyPodList) (string, error)` | 核心路由合约 |
| `PodScorer` (`ScoreAll` + `Polarity`) | 批量软评分接口，混合中使用的每个策略必须实现 |
| `PostRouteUpdater.PostRouteUpdate` | 选择后的副作用钩子（如 session-affinity Redis pin） |
| `QueueRouter` | `Router` + `Len()`；SLO 队列包装 `Router` |
| `FallbackRouter` | 可链式回退（默认为 `random`） |

### 4.4 RouterManager — 工厂 + 缓存 (`algorithms/router.go`)

**核心数据结构**：

- `routerFactory` — `map[RoutingAlgorithm]RouterProviderFunc`，由各策略的 `init()` 在包加载时填充
- `multiRouterCache` — 按混合算法字符串缓存的复合路由器
- `unblendableLogged` — 无法自动混合的策略的日志记录

**Select 流程**：

1. 通过 `ParseMultiRouterConfig` 解析路由算法字符串（格式: `"prefix-cache:5,least-latency:1,least-request"`）
2. 调用 `appendLoadBalanceBlend` 静默组合 `load-balance`（以及多端口 Pod 的 `least-request`）
3. 通过 `getOrCreateMultiStrategyRouter` 构建 `multiStrategyRouter`（按算法字符串缓存，上限 `AIBRIX_ROUTER_MAX_CACHED_ALGORITHM_STRINGS=4096`）
4. 如果多策略组合失败，回退到传统的单策略 `RouterProviderFunc`

### 4.5 完整路由策略列表

#### 4.5.1 基础单指标评分器（均实现 `PodScorer`）

| 策略 | 算法字符串 | 文件 | 极性 | 指标 |
|------|-----------|------|------|------|
| 最少请求 | `least-request` | `least_request.go` | Least | 跨 Gateway 的实时运行请求计数（Redis 支持） |
| 最少 KV 缓存 | `least-kv-cache` | `least_kv_cache.go` | Least | GPU+CPU KV 缓存使用率 |
| 最少 GPU 缓存 | `least-gpu-cache` | `least_gpu_cache.go` | Least | GPU 缓存使用率 |
| 最少繁忙时间 | `least-busy-time` | `least_busy_time.go` | Least | GPU 繁忙时间比 |
| 最少延迟 | `least-latency` | `least_latency.go` | Least | 排队 + Prefill + Decode 延迟 |
| 最少利用率 | `least-utilization` | `least_util.go` | Least | 引擎利用率 |
| 吞吐量 | `throughput` | `throughput.go` | Least | 2·prompt_throughput + generation_throughput |
| 随机 | `random` | `random.go` | — | 均匀分布 |

#### 4.5.2 容量感知负载均衡

**`load-balance`** (`load_balance.go`)

评分公式（越低越好）：
```
score = (running + λ·queued) / capacity × (1 + α·(1 − kvFree)²)
```

- `running` = 跨 Gateway 实时运行请求计数（Redis 支持）
- `queued` = 引擎队列中等待的请求数
- `capacity` = EWMA 输出 Token 速率（**从硬件学习，非配置**）
- `kvFree` = 空闲 KV 缓存比例 [0,1]
- `α`（`kvPressureAlpha`，默认 2.0）= KV 压力惩罚强度
- 低于 `kvCriticalFree`（默认 10%）→ 评分 = +Inf（排除）

**关键设计决策**: capacity 是**观测值**（`RealtimeOutputTokenRateEWMA`），因此 B40/A100/H200 混合 GPU 池无需标签即可工作。

#### 4.5.3 缓存亲和路由

**`prefix-cache`** (`prefix_cache.go`)

1. 对 prompt 进行分词
2. 遍历 Gateway 的 `PrefixHashTable` 找到前缀覆盖最长的 Pod
3. 在匹配 Pod 中，选择运行请求数在均值 `σ` 标准差范围内的 Pod
4. 回退到 `least-request`

**`prefix-cache-preble`** (`prefix_cache_preble.go`)

在前缀缓存之上增加 Preble 成本模型：按 GPU 成本函数评分（可配置目标 GPU：A6000 或 V100）。

#### 4.5.4 会话亲和

**`session-affinity`** (`simple_session_affinity.go`)

- 通过 Redis 将 `x-aibrix-session-key` 固定到特定 Pod（1h 滑动 TTL）
- Redis 冷启动时使用一致性哈希（Rendezvous Hashing）作为本地回退
- 本地 LRU 缓存每 60s 与 Redis 同步
- **排除在自动混合之外**（二元评分无法与 load-balance 有用混合）

#### 4.5.5 Power-of-Two 选择

**`power-of-two`** (`power_of_two.go`)

均匀随机采样两个不同 Pod，路由到运行请求较少的那个。

#### 4.5.6 VTC（虚拟 Token 计数器）— 公平性感知

**`vtc-basic`** (`vtc/vtc_router.go` + `vtc_basic.go`)

- 结合**公平性项**（每用户 Token 使用量 vs 集群最小值）和**利用率项**（Pod 运行请求数 / `maxPodLoad`）
- 权重: `fairnessWeight`、`utilizationWeight`、`inputTokenWeight`、`outputTokenWeight`
- 支持 per-profile tracker 窗口

#### 4.5.7 负载感知 Pack/Pull 模式（SLO 内部）

**`least-load`** 和 **`least-load-pulling`** (`least_load.go`)

- Push 模式路由到最小利用率
- Pull 模式额外添加 Pod 的 `GetConsumption`，跳过超过容量的 Pod

**`pack-load`** (`pack_load.go`)

- 反向最少负载：路由到**负载最高**但仍有容量的 Pod（装箱）

#### 4.5.8 独占策略 — PD 和 SLO 系列

**`pd`** (Prefill-Decode 分离) — `pd_disaggregation.go`

- 通过 Pod 标签将 Pod 分为 prefill 和 decode 角色
- Prefill 评分策略: `prefix_cache`、`least_request`、`conductor`、`token_load`、`hybrid_cache_load`
- Decode 评分策略: `load_balancing`、`least_request`、`conductor`、`token_load`
- 支持 KV 传输后端: `shfs`（GPU/SHFS）、`nixl`（Neuron）、`mooncake`
- 支持推理引擎适配器: vLLM、SGLang、TensorRT-LLM
- Prompt 长度分桶 + 桶服务规划

**`slo` / `slo-pack-load` / `slo-least-load` / `slo-least-load-pulling`** (`slo.go`)

- 每个 `slo` 变体是 `SLOQueue` 上的 `QueueRouter`，配合不同后端路由器
- `ModelRouterFactory` 默认设置为 `NewSLORouter`

### 4.6 多策略混合与评分

**评分管线** (`multiStrategyRouter`, `router.go` line 345)：

1. **评分收集** — 每个子策略的 `ScoreAll` 返回每 Pod 原始评分
2. **Winsorization** — `winsorizeClip` 将超出 3 个 MAD 的异常值裁剪
3. **Min-Max 归一化** 到 [0,1]，极性感知（Least 或 Most）
4. **加权聚合** — `finalScore[pod] = Σ (normalizedScore × weightFraction)`
5. **确定性决胜** — 按 Pod 名称排序（升序），防止评分翻转
6. **Post-Route 钩子** — 扇出到每个实现 `PostRouteUpdater` 的策略

**自动混合** (`appendLoadBalanceBlend`, `router.go` line 288)：

- 静默扩展任何调用者提供的策略为复合策略，同时评分 load-balance 的容量感知 pending 时间
- 特殊情况：
  - `session-affinity` 和 `load-balance` 本身不自动混合
  - 独占策略（`pd`、`slo*`）不自动混合
  - 裸 `prefix-cache` 获得专用的 5:4 比例
  - 显式 `load-balance:0` 被尊重

### 4.7 热点检测门控

`ApplyLoadImbalanceGate`（在任何策略运行前由 Gateway 集中调用）：

- 当某 Pod 的运行请求数超过 `factor × (meanOfOthers+1)` 且 `max − min ≥ minGap` 时，缩小候选集
- 默认值: factor=2.0, minGap=8
- 对独占策略（PD、SLO）跳过

### 4.8 Per-Request 路由覆盖

`pkg/types/routing_knobs.go` 定义了 `RoutingOverrides`：

```
LoadBalance / PrefixCache / Preble / VTC / AutoBlend / PD
```

解析流程 (`profile_knobs.go` 的 `ResolveRoutingOverrides`)：

1. 启动时从 `AIBRIX_*` 环境变量安装进程默认值
2. 应用请求的 `RoutingConfig`（从模型配置 Profile 的 `routingConfig` JSON 解析）
3. 将解析后的结构体放在 `RoutingContext` 上，供整个请求路径使用

---

## 5. 流量调度

### 5.1 架构概览

AIBrix 的流量管理系统是一个深层次的分层系统，涵盖 6 个核心层面：

```
┌─────────────────────────────────────────────────┐
│ 1. Gateway 层: 限流、HTTPRoute 验证、Inflight  │
│    上限、热点门控                                 │
├─────────────────────────────────────────────────┤
│ 2. 路由选择: 可插拔策略系统、自动混合、          │
│    多策略加权评分、确定性决胜                      │
├─────────────────────────────────────────────────┤
│ 3. 队列管理: SLO 感知优先级、per-feature 子队列  │
│    延迟预算排序                                   │
├─────────────────────────────────────────────────┤
│ 4. 缓存感知路由: 前缀缓存索引、分布式 KV 事件   │
│    同步、缓存亲和评分                             │
├─────────────────────────────────────────────────┤
│ 5. 分离式推理: 完整的 Prefill-Decode 分离、      │
│    5 种 Prefill + 4 种 Decode 策略、桶流量整形   │
├─────────────────────────────────────────────────┤
│ 6. 公平性: VTC 每用户 Token 跟踪、滑动窗口隔离   │
└─────────────────────────────────────────────────┘
```

### 5.2 队列管理系统

#### Queue Router (`algorithms/queue_router.go`)

`queueRouter` 包装后端路由器和 `RouterQueue`：

- **入队**: 请求进入队列而非立即路由
- **Serve 协程**: 通过 `routeNext()` 循环持续排空队列
- **Peek → Route → Dequeue**: 原子化管线
- **Panic 恢复**: 每一步在 `routeNext()` 中用 defer/recover 运行；panic 使候选失败并丢弃，但不杀死 serve 协程
- **指标**: 队列等待时间桶、结果标签（routed/slo_failure/capacity_reached/error）、pending 深度仪表

#### SimpleQueue (`queue/simple_queue.go`)

无锁风格的 FIFO 队列，基于循环缓冲区动态扩展：

- 使用原子游标进行入队/出队
- 通过容量翻倍或打包（取决于利用率）扩展
- 初始容量 64，一次扩展最多 128 每子队列

#### SLO Queue (`queue/slo_queue.go`)

最精密的队列 — 实现 **SLO 感知的请求优先级排序**：

**架构**:
- 多个按请求特征签名键控的**子队列**（log₂-bucketed）
- 每个子队列是一个 `SimpleQueue`
- `sync.Pool` 回收子队列实例

**排序算法** (`rank()`, line 447)：
```
rank = elapsed_time + expected_service_time − SLO_target
```
正值 → 接近 SLO 违规；越高越紧急。

**SLO 优先级链**（首个配置的生效）：

1. **TPOT** (Time Per Output Token): target = TPOT × tokens + TTFT
2. **TTFT** (Time To First Token): target = 配置的 TTFT
3. **TPAT** (Time Per All Tokens): target = TPAT × (prompt + output tokens)
4. **E2E** (End-to-End latency): target = 配置的 E2E

**候选选择** (`Peek()`, line 178)：

1. 收集所有子队列的头部
2. 对每个部署 Profile 排序每个候选（最宽松的 Profile 优先）
3. 按紧急度排序（最高 rank 优先），按到达时间决胜
4. 按候选尝试路由，每个候选先尝试最宽松 Profile 的 Pod 集
5. 无 Profile 或无 SLO 信息时 FIFO 回退

### 5.3 前缀缓存路由与分布式 KV 缓存

#### 前缀哈希表 (`pkg/utils/prefixcacheindexer/hash.go`)

**Radix-tree 启发**的前缀缓存索引：

- 对输入文本分词（字符级或 tiktoken）
- 计算块哈希（xxhash，可配置种子）
- 映射 `block_hash → {model → {pod_key → last_access_time}}`
- LRU 淘汰：可配置块数（默认 200K）、块大小（默认 4 tokens）、淘汰时间（默认 20 min）
- 支持 Gateway 副本间的**增量同步**

#### KV 事件管理器 (`pkg/cache/kv_event_manager.go`, `pkg/kvevent/`)

- 跟踪哪些 KV 块存在于哪些 Pod
- 使前缀缓存路由做出全局知情决策
- 支持 ZMQ 传输实现高吞吐事件传递

#### KV 传输（PD 分离）

`pkg/plugins/gateway/algorithms/pd/transfer/` 支持 3 种 KV 传输后端：

- **SHFS**（默认）: GPU 基础 KV 缓存传输
- **NIXL**: Neuron 加速器
- **Mooncake**: Mooncake KV 传输后端

### 5.4 Prefill-Decode 分离路由

**`pd_disaggregation.go`** 实现**分离式 Prefill-Decode 推理**：

```
Request → [Prefill Pod 选择] → HTTP prefill 请求 → KV 传输 → [Decode Pod] → Response
```

#### Prefill 评分策略

| 策略 | 说明 |
|------|------|
| `prefix_cache` | 路由到 KV 缓存重叠最好的 Pod，按运行请求加权 |
| `least_request` | 纯运行请求计数 |
| `conductor` | 估计每 Pod 的 TTFT（队列 + 前缀 + prefill 时间） |
| `token_load` | Token 加权负载账本 |
| `hybrid_cache_load` | 按前缀缓存匹配折扣 Token 负载 |

#### Decode 评分策略

| 策略 | 说明 |
|------|------|
| `load_balancing` | `score = (wRun·normRunningReqs + wThru·normInverseThroughput) / normFreeGPU` |
| `least_request` | 最少活跃 decode 请求 |
| `conductor` | 最低 TBT（Token 间时间），带 GPU 缓存压力惩罚 |
| `token_load` | decode 账本收费的最少 prompt tokens |

#### 桶服务 (`pd/bucket_serving.go`)

实现 "BucketServe"（arXiv 2507.17120）的 Gateway 半侧：

- 维护 Gateway 路由的 prompt 长度的 **EWMA**
- **自适应拆分**重叠的 prompt 长度范围到不同 roleset 的波段
- 两种模式: `rps`（请求计数分位数）和 `throughput`（prompt token 分位数）
- 计划是**建议性**的 — 当分配的 roleset 负载高时回退到全覆盖集

#### 负载不均衡快速路径

- **Prefill**: max/min Pod 间最小 spread 16 个运行请求
- **Decode**: max/min Pod 间最小 spread 16 个运行请求或 2048 tok/s 吞吐量
- **Drain 速率比**: 如果最慢 decode Pod 的 drain 速率比 > 最快 Pod 的 1.5×，避开

### 5.5 SLO 感知路由

四种 SLO 系列算法：

| 算法 | 后端路由器 |
|------|-----------|
| `slo`（默认） | SLO 队列 + least-load-pulling |
| `slo-pack-load` | SLO 队列 + 装箱 |
| `slo-least-load` | SLO 队列 + least-load (push) |
| `slo-least-load-pulling` | SLO 队列 + least-load (pull) |

SLO 路由器将 `QueueRouter` 包装在 `SLOQueue` 上，配合 `FallbackRouter` 机制。无 SLO Profile 匹配时回退到 `least-request`。

### 5.6 Per-Request 配置覆盖系统

每个路由旋钮可通过模型配置 Profile 的 `routingConfig` 覆盖：

```json
{
  "loadBalance": { "imbalanceFactor": 3.0, "kvCriticalFree": 0.05 },
  "prefixCache": { "standardDeviationFactor": 2 },
  "autoBlend": { "loadBalanceWeight": 2, "prefixCacheWeight": 8 },
  "pd": { "prefillScorePolicy": "hybrid_cache_load", "decodeScorePolicy": "conductor" }
}
```

**解析链**: 环境变量默认值 → Profile 覆盖 → 请求时通过 `ResolveRoutingOverrides()` 解析。无效 Profile 值被丢弃并记录日志；环境变量默认值获胜。

---

## 6. 多租户隔离

### 6.1 隔离架构概述

AIBrix 通过**分层架构**实现多租户隔离，跨越 Envoy 基础 Gateway、Kubernetes 控制器和 Redis 缓存。没有单一的 "Tenant" CRD — 相反，租户性由四个松耦合机制组合而成：

1. 用户身份与每用户速率配额
2. 每模型资源配额（速率/Inflight/GPU）
3. 公平共享路由（VTC）仲裁跨用户的 GPU 时间
4. GPU 级共享通过 `ModelClaim` 运行时附件

### 6.2 身份与每用户配额（Gateway 层）

#### 用户模型 (`pkg/utils/users.go`)

- `User{Name, Rpm, Tpm}` 以 JSON 持久化在 Redis 中，键为 `aibrix-users/<name>`
- `GetUser`/`SetUser`/`DelUser`/`CheckUser` 管理记录
- 用户通过控制台 API 播种（`apps/console/api/handler/quota.go`）

#### 请求身份提取 (`gateway_req_headers.go`)

- `HandleRequestHeaders` 提取 `user` 请求头、`authorization` API key、`x-aibrix-routing-strategy`、`x-aibrix-priority-tier` 等
- `resolveUserForRequest` 在限流禁用时短路；否则调用 `utils.GetUser` 和 `checkLimits`

#### API Key 认证 (`api_key_auth.go`)

- Gateway 级 API key 与 `Authorization` 比对，不匹配返回 401

### 6.3 租户级速率限制

在 **`gateway_ratelimit.go`** 中实现，使用 Redis 支持的固定窗口限流器。

#### 两个独立限流器

- **`s.ratelimiter`** — 每用户 **RPM/TPM** 限流器，1 分钟窗口
- **`s.modelRateLimiter`** — 每模型 **RPS** 限流器，1 秒默认窗口
- 均由 Lua 脚本 `incrAndExpireScript` 支持 — 原子 INCRBY + PEXPIRE-NX

#### `checkLimits` 流程 (`gateway_ratelimit.go:32`)

1. 默认填充：用户 `Rpm==0` → `DefaultRPM`；`Tpm==0` → `Rpm * DefaultTPMMultiplier`
2. `checkRPM` → GET `user_RPM_CURRENT`，超限返回 `429 + HeaderErrorRPMExceeded`
3. `incrRPM` → 原子递增
4. `checkTPM` → 同模式
5. 超限时返回 `ErrorCodeRateLimitExceeded`

#### 每模型 RPS — `enforceModelRPS` (`gateway_ratelimit.go:121`)

- 读取 `routingCtx.ConfigProfile.RequestsPerSecond` 和 `RateWindowSeconds`
- 原子 `Incr(model_MODEL_RPS_CURRENT, 1, window)`；超限立即**退还**（`Incr(..., -1, ...)`）

### 6.4 副本 Inflight 强制（硬 Per-Pod 上限）

在 **`gateway_inflight.go`** 和 **`cache_running_requests.go`** 中实现。

#### 跨 Gateway 运行请求计数器

- 每个 Pod 有一个 Redis hash 在 `aibrix:rrq:<pod>`，**字段是 Gateway 实例 ID**
- 仅对**活跃** Gateway（`aibrix:rrq:gateways` ZSET 中 score ≥ cutoff 的成员）求和
- Gateway 身份用进程启动时间加盐，使同名重启不重新采用崩溃进程的 "live" 条目

#### 原子准入 — `runningRequestsAdmitScript` (`cache_running_requests.go:247`)

一次 Lua 往返：求和活跃字段 → 如果 `< limit`，应用 `HINCRBY +1`，在零处钳制，刷新 TTL。

#### `enforceReplicaInflight` (`gateway_inflight.go:60`)

- 在目标 Pod 选择后调用
- 如果 `routingCtx.ConfigProfile.RequestsInflight > 0`，调用 `cache.AdmitPodRunningRequest`
- 拒绝 → `429` + `ErrorCodeReplicaInflightExceeded`

#### 活跃性和卫生

- `initRunningRequestsLiveness` 启动 1s ticker，`ZADD` 本 Gateway ID + Redis 校正时钟时间戳
- 时钟偏移通过 `TIME` 在心跳管线中搭载校正
- `flushPendingRunningRequestsPrunes` 在长 `runningRequestsFieldPruneWindow`（= 10 min）后 HDEL 死字段

### 6.5 工作负载隔离通过 Model Config Profiles

#### `ModelConfigProfiles` 结构 (`configprofiles/configprofiles.go`)

- 来源: `model.aibrix.ai/config` 注解
- 每个 `ModelConfigProfile` 携带:
  - `routingStrategy`
  - `routingConfig`（JSON 传给策略）
  - `requestsPerSecond` — 聚合 RPS 上限
  - `requestsPerSecondPerReplica` — 每副本 RPS
  - `requestsInflight` — 每副本并发请求上限
  - `ttftThresholdS` — per-profile TTFT SLO
- Profile 可通过 `x-aibrix-config-profile` 请求头选择
- 支持基于 prompt/max-token 范围的 `auto` 自动选择

#### 隔离效果

- 单个模型可暴露多个 Profile（如 `free`、`pro`、`batch`），每个有不同的 RPS/Inflight 上限和路由策略
- 请求通过请求头分桶到 Profile
- 当 `AuthoritativeRoutingPolicy=true` 时，客户端提供的路由/外部过滤请求头被剥离

### 6.6 公平共享 GPU 调度 — VTC Router

#### 虚拟 Token 计数器概念

- 每用户滑动窗口的 Token 消耗（input + output × weight）
- `InMemorySlidingWindowTokenTracker`:
  - 每用户双向链表桶队列（O(1) 时间戳查找）
  - O(1) 跨所有用户的最小/最大 Token 跟踪
  - 可配置窗口（默认 5 分钟）

#### `BasicVTCRouter.Route` (`vtc_basic.go:128`)

对每个候选 Pod：

1. `adaptiveBucketSize = max(minTokens, (minTokens + maxTokens) / 2)` — 动态步长
2. `normalizedTokens = min(userTokens / adaptiveBucketSize, len(pods)-1)` — 用户消耗到 Pod 索引空间的钳制线性映射
3. `fairnessScore = |podIndex - normalizedTokens|` — 重用户推到更高索引 Pod
4. `utilizationScore = min(podLoad / maxPodLoad, 1.0)`
5. 组合评分: `fairnessWeight * fairnessScore + utilizationWeight * utilizationScore + randomFactor`

**多租户影响**: 重用户自然路由到 Pod 子集，轻用户路由到其他 Pod — **GPU 时间在没有硬配额的情况下公平共享**。

### 6.7 优先级调度 (`gateway_req_priority.go`)

- 请求头 `x-aibrix-priority-tier` 通过固定表映射:
  - `batch → priority 100`
  - `background → priority 1000`
  - 默认（无 tier）→ 0（引擎默认）
- `applyPriorityTier` 通过 `sjson` 重写 JSON body 注入 `priority`
- vLLM 语义: 更小 priority 值 = 先服务，更大值可抢占
- 通过 `ServerOptions.PriorityTier` 可选启用

### 6.8 隔离边界汇总

| 隔离层 | 机制 | 粒度 | 执行点 |
|--------|------|------|--------|
| 身份 | `user` 请求头 → Redis `aibrix-users/<name>` | 每用户 | Gateway (ext_proc) |
| 速率配额 (RPM/TPM) | 固定窗口 Redis 计数器 + Lua | 每用户 | Gateway |
| 速率配额 (RPS) | 固定窗口 Redis 计数器 | 每模型 | Gateway |
| 并发上限 | 原子准入 Lua 脚本 + 活跃感知 Gateway 求和 | 每 Pod（跨 Gateway） | Gateway + Redis |
| 公平共享 | VTC Token 跟踪器，自适应桶，组合公平性+利用率评分 | 每用户 → 每 Pod | Gateway 路由器 |
| 配置 Profile | `model.aibrix.ai/config` 注解，每请求可选择 | 每模型 × 每租户 Profile | Gateway |
| 优先级 | `x-aibrix-priority-tier` → body `priority` 重写 | 每请求 tier | Gateway → 引擎 |
| GPU 共享 | `ModelClaim` + 每 Claim 的 kvcached IPC 名称 | 每模型 per-GPU | 控制器 + 运行时 sidecar |
| 工作负载隔离 (PD) | Prefill/Decode 角色分离，失败快速中止 | 每请求 | Gateway PD 路由器 |
| SLO | `ModelGPUProfile` + `SLOQueue` 重排序 | 每模型 | 队列路由器 |
| GPU 缓存压力 | `least-gpu-cache`、`least-kv-cache` 评分器 | 每 Pod | Gateway 路由器 |
| 命名空间 | 标准 K8s（每模型 HTTPRoute、RBAC、Pod 选择器） | 每模型 / 每租户 | 控制平面 |

---

## 7. 资源管理

### 7.1 GPU 感知路由策略

#### `least-gpu-cache` (`least_gpu_cache.go`)

- 路由到 `GPUCacheUsagePerc` 指标最低的 Pod
- 实现 `PodScorer` 配合 `PolarityLeast`

#### 其他读取 GPU 指标的策略

- `least-kv-cache`、`least-load`、`least-util`、`least-busy-time`、`least-latency`、`pack-load`、`throughput`、`power-of-two`、`prefix-cache`、`slo-*` — 均消费 `pkg/metrics/` 的指标

### 7.2 GPU 共享通过 ModelClaim

**`ModelClaim` CRD** (`api/model/v1alpha1/modelclaim_types.go`) 是最明确的 GPU 共享原语。

#### Spec

```go
type ModelClaimSpec struct {
    ModelName    *string                       // 服务模型名（默认对象名）
    PodSelector  *metav1.LabelSelector         // 选择温 GPU 池 Pod
    ArtifactURL  string                        // 模型权重位置
    Engine       string                        // "vllm" 或 "sglang"
    Replicas     *int32                        // 总是 1（引擎槽位数）
    EngineConfig *ModelClaimEngineConfig       // CLI 标志如 --max-model-len
}
```

#### 放置策略 (`pkg/controller/modelclaim/placement.go`)

`selectPodForActivationWithState` 使用词典排序选择最低成本温 Pod：

1. **本地缓存的 Artifact** (`PodPlacementState.ArtifactCached`)
2. **已知快照**（实时运行时观察）
3. **已知内存 → 更高 HBMFreeBytes**
4. **已知快照 → 更低 KVUsedBytes，更低 ModelCount**
5. ** locality 成本**
6. **当前模型负载**
7. **Pod 名称**（确定性决胜）

**多 ModelClaim 共享一个 GPU**: `ipcNameFor(pm)` 为每个 Claim 的 `kvcached` 共享内存段生成唯一 `kvc_<sanitized>` 名称。

#### 生命周期

```
Pending → Scheduling → Loading → Activating → Active ↔ Sleeping → Failed
```

- `ScheduledPodsAnnotationKey` 记录绑定，在控制器重启后存活
- `ModelClaimFinalizer` 确保删除前解除激活和路由注销
- 不可路由的模型保持端口 0（`ModelClaimActivating`），防止 Gateway 路由到未就绪引擎

#### 睡眠/唤醒

模型可以被置于睡眠状态（`ModelClaimSleeping`），并由 Gateway 按需唤醒 (`pkg/plugins/gateway/modelclaim_wake.go`)。

### 7.3 ModelAdapter 调度

`pkg/controller/modeladapter/scheduling/` 管理 **LoRA 适配器放置**（独立于请求路由）：

| 策略 | 说明 |
|------|------|
| `random` | 随机 Pod 选择 |
| `leastAdapters` | 最少现有适配器的 Pod |
| `binPack` | 将适配器装入剩余空间最少的 Pod（首次适应递减） |
| `leastLatency` | 最低队列+推理时间 |
| `leastThroughput` | 最低吞吐量 |

### 7.4 排空控制器 (`pkg/controller/drain/drain.go`)

- 在滚动更新/替换期间的优雅 Pod 排空
- 可配置超时；通过注解标记 Pod 为排空中
- 发射 Kubernetes 事件（Started/Completed/Cancelled）

### 7.5 StormService 资源编排

`StormService` (`api/orchestration/v1alpha1/stormservice_types.go`) 是分布式推理服务的 Deployment-like 控制器：

- 管理 `RoleSet` 对象（类似 ReplicaSet）
- 支持 `RollingUpdate` 和 `InPlaceUpdate` 策略
- 跟踪 `currentRevision` 和 `updateRevision`
- `calculateReplicas()` 在 current 和 update revision 间分配期望副本数
- 报告 `status.currentReplicas`、`status.updatedReplicas`、`status.updatedReadyReplicas`

---

## 8. 版本管理

### 8.1 ModelAdapter CRD — LoRA / 热切换适配器

`api/model/v1alpha1/modeladapter_types.go` 定义 `ModelAdapter` CRD：

```go
type ModelAdapterSpec struct {
    BaseModel          *string                        // 扩展的基础模型
    PodSelector        *metav1.LabelSelector          // 哪些 Pod 可托管
    SchedulerName      string                         // "default" | "least-adapters" | ...
    ArtifactURL        string                         // huggingface://, s3://, gcs://, local path
    CredentialsSecretRef *corev1.LocalObjectReference // 下载认证
    Replicas           *int32                         // nil = 所有 Pod, 1 = 单 Pod
    AdditionalConfig   map[string]string              // rank, alpha, timeout...
}
```

**生命周期**: `Pending → Scheduled → Bound → ResourceCreated → Running → Failed → Unknown`

**4 步协调循环** (`modeladapter_controller.go`)：

1. `reconcileReplicas` — 确定哪些 Pod 应托管适配器
2. `reconcileLoading` — 调用 vLLM 运行时 API 在选定 Pod 上加载/卸载 LoRA
3. `reconcileService` — 为适配器创建 Kubernetes Service
4. `reconcileEndpointSlice` — 创建指向运行适配器 Pod 的 EndpointSlice

**多 LoRA 服务**: 单个基础模型部署（如 `qwen-coder-1-5b-instruct` with `--max-loras 4`）可同时托管多个 `ModelAdapter` CR。每个适配器获得自己的 Service 和 HTTPRoute，使其可通过自己的模型名寻址。

### 8.2 ModelClaim CRD — 温池动态模型激活

`api/model/v1alpha1/modelclaim_types.go` 定义 `ModelClaim` — 用于**温 GPU 池上的高密度模型服务**：

- 温 Deployment 的预热 GPU Pod（带 `pool.aibrix.ai/name` 和 `pool.aibrix.ai/enabled` 标签）
- 控制器选择 Pod → 告诉 aibrix-runtime sidecar 激活模型 → 注解 Pod
- Gateway 缓存读取这些注解使活跃模型可路由

### 8.3 基础模型 ↔ 适配器映射

`pkg/cache/informers.go:320-323` — `setModelBaseModelLocked()` 记录适配器→基础模型映射。Gateway 在 `gateway_req_body.go:88` 读取：

```go
if base, ok := s.cache.ModelBaseModel(model); ok {
    routingCtx.BaseModel = base
}
```

### 8.4 适配器注册流程

1. 用户创建 `ModelAdapter` CR，指定 `baseModel`、`podSelector`、`artifactURL`
2. 控制器找到匹配 Pod（必须有 `adapter.model.aibrix.ai/enabled: "true"`）
3. 调度器基于 `schedulerName` 选择目标 Pod
4. 控制器调用 **aibrix-runtime sidecar**（端口 8080）通过 HTTP API 加载 LoRA 适配器
5. 控制器为适配器创建 Service + EndpointSlice
6. 模型路由器控制器看到新 ModelAdapter 并创建 HTTPRoute

#### 适配器加载机制

控制器使用 `loraClient` (`pkg/controller/modeladapter/lora_client.go`) 调用 vLLM 兼容运行时 API：

- `PUT /v1/load_adapter` — 加载适配器
- `DELETE /v1/unload_adapter` — 卸载适配器
- `GET /v1/models` — 列出已加载模型

重试通过 Pod 注解跟踪（`adapter.model.aibrix.ai/retry-count`、`adapter.model.aibrix.ai/last-retry-time`）。最大 6 次重试，5 秒退避。

#### Finalizer 清理

控制器添加 finalizer `adapter.model.aibrix.ai/finalizer`，确保 CR 删除前从所有 Pod 卸载适配器。

---

## 9. 灰度发布与流量切换

### 9.1 当前状态

**AIBrix 目前未实现基于百分比的规范金丝雀/灰度流量分割**（HTTPRoute 中无加权 `BackendRef`，无显式流量百分比 CRD）。这通过对源码的全面搜索确认：在功能代码中没有 "canary"、"gray"、"traffic split"、"blue-green" 或 "mirror" 的引用。

### 9.2 通过 StormService 滚动更新的隐式金丝雀

最接近金丝雀发布的是 `StormService` 的 **ControllerRevision-based 滚动管理**：

```go
type StormServiceUpdateStrategy struct {
    Type           StormServiceUpdateStrategyType  // "RollingUpdate" | "InPlaceUpdate"
    MaxUnavailable *intstr.IntOrString
    MaxSurge       *intstr.IntOrString
}
```

- 跟踪 `currentRevision` 和 `updateRevision`（类似 Kubernetes Deployment）
- 执行扩缩/滚动: `calculateReplicas()` 在 current 和 update revision 间分配期望副本数
- 支持 `RollingUpdate` 和 `InPlaceUpdate` 策略
- 报告 `status.currentReplicas`、`status.updatedReplicas`、`status.updatedReadyReplicas`

这提供了**新模型版本的渐进式推出**，通过创建带有更新模板的新 RoleSet 同时保留旧 RoleSet。但这不是基于百分比的流量分割 — 而是滚动替换。

### 9.3 通过路由算法的隐式流量切换

模型版本间的流量"切换"通过以下方式隐式发生：

#### 标签基础模型身份

每个模型版本是具有自己 `model.aibrix.ai/name` 标签的独立 Deployment。客户端通过更改请求体中的 `"model"` 字段进行切换。

#### 动态 Pod 成员

Gateway 缓存 (`pkg/cache/informers.go`) 监听 Pod 并动态添加/移除模型路由表中的 Pod。当新版本的 Pod 就绪且旧 Pod 终止时，流量自动转移。

#### ModelAdapter 热切换

LoRA 适配器可在不重启基础模型的情况下在运行 Pod 上加载/卸载。创建新 `ModelAdapter` CR 将流量路由到新适配器；删除它则移除路由。

#### 多策略加权路由

`multiStrategyRouter` 支持用户指定的跨路由算法权重（如 `"prefix-cache:5,load-balance:4"`），但这些是 Pod 评分的算法权重，不是模型版本间的流量分割百分比。

### 9.4 当前如何实现金丝雀发布

基于架构，金丝雀发布可通过外部方式实现：

#### 方案 A: 双模型名流量分割

运行两个具有不同 `model.aibrix.ai/name` 值的 Deployment（如 `my-model-v1` 和 `my-model-v2`）。客户端/应用层通过向每个模型名发送不同百分比的请求来分割流量。

#### 方案 B: Kubernetes Gateway API 原生加权 BackendRef

使用 HTTPRoute 的原生加权 `BackendRef`（模型路由器控制器当前生成单后端路由，但 HTTPRoute 规范支持权重）。

#### 方案 C: StormService 滚动更新策略

使用 StormService 的滚动更新策略配合 `MaxUnavailable`/`MaxSurge` 控制版本转换的节奏。

### 9.5 流量切换机制总结

| 机制 | 类型 | 粒度 | 说明 |
|------|------|------|------|
| 模型名切换 | 客户端控制 | 请求级 | 更改 `"model"` 字段指向不同版本 |
| ModelAdapter 热切换 | 控制平面 | 适配器级 | 创建/删除 ModelAdapter CR |
| StormService 滚动 | 控制平面 | Pod 级 | `MaxUnavailable`/`MaxSurge` 控制节奏 |
| 配置 Profile 切换 | 请求头 | Profile 级 | 不同 `config-profile` 获得不同路由策略 |
| 动态 Pod 成员 | Informer | Pod 级 | Pod 就绪/终止自动更新路由表 |

---

## 10. 关键文件索引

### Gateway 核心

| 文件 | 职责 |
|------|------|
| `cmd/plugins/main.go` | Gateway 插件二进制入口 |
| `pkg/plugins/gateway/gateway.go` | 核心 Server 结构，Process() 循环，Pod 选择，HTTP 服务器 |
| `pkg/plugins/gateway/types.go` | 常量，请求头，错误码，路径 |
| `pkg/plugins/gateway/gateway_req_headers.go` | 请求头处理 |
| `pkg/plugins/gateway/gateway_req_body.go` | 请求体处理，Pod 选择，引擎路径重写 |
| `pkg/plugins/gateway/gateway_rsp_headers.go` | 响应头处理 |
| `pkg/plugins/gateway/gateway_rsp_body.go` | 响应体处理，SSE 流式，Token 计量 |
| `pkg/plugins/gateway/gateway_ratelimit.go` | RPM/TPM/模型 RPS 限流 |
| `pkg/plugins/gateway/gateway_inflight.go` | 每副本 Inflight 请求上限 |
| `pkg/plugins/gateway/gateway_req_priority.go` | 优先级转发 |
| `pkg/plugins/gateway/api_key_auth.go` | Bearer Token 认证 |
| `pkg/plugins/gateway/recovery.go` | Panic 恢复拦截器 |
| `pkg/plugins/gateway/async_job_registry.go` | 异步视频任务注册表 |
| `pkg/plugins/gateway/modelclaim_wake.go` | 睡眠模型唤醒 |
| `pkg/plugins/gateway/util.go` | 请求验证，Body 解析，错误构建 |

### 路由算法

| 文件 | 职责 |
|------|------|
| `pkg/plugins/gateway/algorithms/router.go` | RouterManager，多策略组合，自动混合，评分归一化 |
| `pkg/plugins/gateway/algorithms/model_router_factory.go` | 默认路由器工厂（SLO） |
| `pkg/plugins/gateway/algorithms/pd_disaggregation.go` | Prefill-Decode 分离路由 |
| `pkg/plugins/gateway/algorithms/prefix_cache.go` | 前缀缓存路由 |
| `pkg/plugins/gateway/algorithms/load_balance.go` | 容量感知负载均衡路由 |
| `pkg/plugins/gateway/algorithms/slo.go` | SLO 感知路由 |
| `pkg/plugins/gateway/algorithms/queue_router.go` | 队列路由 |
| `pkg/plugins/gateway/algorithms/vtc/` | VTC 虚拟 Token 计数器 |
| `pkg/plugins/gateway/algorithms/pd/` | PD 子模块（评分器、引擎适配器、传输后端、桶服务） |

### 队列管理

| 文件 | 职责 |
|------|------|
| `pkg/plugins/gateway/queue/simple_queue.go` | 简单 FIFO 队列 |
| `pkg/plugins/gateway/queue/slo_queue.go` | SLO 感知优先队列 |

### 配置与限流

| 文件 | 职责 |
|------|------|
| `pkg/plugins/gateway/configprofiles/configprofiles.go` | 模型配置 Profile 解析 |
| `pkg/plugins/gateway/ratelimiter/rate_limiter.go` | 限流器接口 |
| `pkg/plugins/gateway/ratelimiter/redis.go` | Redis 支持限流器 |

### 控制器

| 文件 | 职责 |
|------|------|
| `pkg/controller/modelrouter/modelrouter_controller.go` | 自动创建 HTTPRoute |
| `pkg/controller/modeladapter/modeladapter_controller.go` | 适配器生命周期管理 |
| `pkg/controller/modelclaim/modelclaim_controller.go` | 温池模型激活控制器 |
| `pkg/controller/modelclaim/placement.go` | Pod 放置策略 |
| `pkg/controller/stormservice/sync.go` | Revision-based 滚动管理 |
| `pkg/controller/drain/drain.go` | 优雅排空 |

### CRD 定义

| 文件 | 职责 |
|------|------|
| `api/model/v1alpha1/modeladapter_types.go` | ModelAdapter CRD |
| `api/model/v1alpha1/modelclaim_types.go` | ModelClaim CRD |
| `api/orchestration/v1alpha1/stormservice_types.go` | StormService CRD |

### 缓存与发现

| 文件 | 职责 |
|------|------|
| `pkg/cache/cache_impl.go` | Pod 注册表，运行计数，指标 |
| `pkg/cache/cache_running_requests.go` | 跨 Gateway 运行请求计数 |
| `pkg/cache/informers.go` | Pod/适配器→模型映射 |
| `pkg/cache/kv_event_manager.go` | KV 缓存事件管理 |
| `pkg/cache/discovery/kubernetes.go` | K8s Informer 发现 |
| `pkg/cache/discovery/static.go` | 静态端点发现 |

### 类型与工具

| 文件 | 职责 |
|------|------|
| `pkg/types/router.go` | 路由接口定义 |
| `pkg/types/router_context.go` | 路由上下文 |
| `pkg/types/routing_knobs.go` | 路由覆盖 |
| `pkg/types/routing_config.go` | 路由配置类型 |
| `pkg/utils/users.go` | 用户模型 |
| `pkg/utils/prefixcacheindexer/hash.go` | 前缀哈希表 |
| `pkg/utils/model_router.go` | HTTPRoute 命名 |
| `pkg/constants/model.go` | 标签/注解常量 |

### 配置与部署

| 文件 | 职责 |
|------|------|
| `config/gateway/gateway.yaml` | Envoy Gateway + ext_proc 配置 |
| `dist/chart/templates/gateway-plugin/envoy_extension_policy.yaml` | Envoy ext_proc 接线 |
| `dist/chart/templates/gateway-plugin/deployment.yaml` | Gateway 插件部署 |
| `build/container/Dockerfile.gateway` | 容器构建（CGO 启用，支持 ZMQ/KV 缓存） |

### 文档

| 文件 | 职责 |
|------|------|
| `pkg/plugins/gateway/ENV_VARS.md` | 完整环境变量参考（70+ 变量） |
| `docs/source/features/gateway-plugins.rst` | 用户面向 Gateway 文档 |
| `docs/source/production/gateway.rst` | 生产部署指南 |

---

> **分析日期**: 2026-09-29
> **数据来源**: AIBrix 源码 (`aibrix/`)
