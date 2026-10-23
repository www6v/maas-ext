# Dynamo 架构深度解析

> 基于官方文档（Architecture / Knowledge Base Overview）+ 架构图 + 本地代码库 `dynamo-main/` 的综合分析
>
> 版本：**dev / v1.6.0** · 生成日期：2026-10-23

---

## 1. 定位与设计哲学

Dynamo 是 NVIDIA 的**数据中心级分布式推理运行时**，面向需要高吞吐、低延迟、高可靠的生成式 AI 系统。

### 核心定位

> *"Dynamo is the orchestration layer **above** inference engines — it doesn't replace SGLang, TensorRT-LLM, or vLLM, it turns them into a coordinated multi-node inference system."*

Dynamo **不是**推理引擎，而是推理引擎**之上的编排层**。它将 GPU 集群组合成一个协同推理系统。

### 五大设计目标

| # | 目标 | 含义 |
|---|------|------|
| 1 | **延迟稳定性** | TTFT 和 ITL 在突发流量下保持可预测 |
| 2 | **GPU 效率** | 分离 prefill/decode，独立伸缩 |
| 3 | **计算复用** | KV-aware routing 最小化 KV 重复计算 |
| 4 | **运维韧性** | worker 崩溃被视为常态而非异常 |
| 5 | **部署可移植** | 支持 Kubernetes 和非 K8s 两种模式 |

### 解决的行业痛点

| 痛点 | Dynamo 对策 |
|------|-------------|
| Prefill/decode 不均衡导致 GPU 利用不足 | Disaggregated serving |
| KV 重复计算浪费算力 | KV-aware routing（2× 更快推理） |
| 长上下文超出 HBM 容量 | Multi-tier KVBM (GPU→CPU→SSD→远端) |
| 静态配置无法应对动态需求 | SLA-driven Planner autoscaling |
| 现实中的故障场景 | 飞行中容错 + 优雅关闭 + 请求迁移 |

---

## 2. 三平面架构

Dynamo 的核心架构由**三个协作平面**构成：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  ┌──────────────────┐       ┌────────────────────┐                      │
│  │   Request Plane  │       │   Control Plane    │                      │
│  │   (请求平面)      │       │   (控制平面)        │                      │
│  │                  │       │                    │                      │
│  │  Client          │       │  Planner           │                      │
│  │    │             │       │    │               │                      │
│  │    ▼             │       │    ▼               │                      │
│  │  Frontend ───────┼──────▶│  Dynamo Operator   │                      │
│  │    │             │       │    │               │                      │
│  │    ▼             │       │    ▼               │                      │
│  │  Router          │       │  Dynamo Graph      │                      │
│  │    │             │       │    │               │                      │
│  │    ▼             │       │    ▼               │                      │
│  │  Prefill Workers │       │  Grove             │                      │
│  │    │             │       │    │               │                      │
│  │    ▼             │       │    ▼               │                      │
│  │  Decode Workers  │       │  Model Express     │                      │
│  └────────┬─────────┘       └─────────┬──────────┘                      │
│           │                           │                                  │
│           └───────────┬───────────────┘                                  │
│                       │                                                  │
│  ┌────────────────────▼──────────────────────────────────────────────┐  │
│  │              Storage & Events Plane (存储与事件平面)                 │  │
│  │                                                                     │  │
│  │  KVBM ──── NIXL ──── Local SSD / NFS / Remote Storage              │  │
│  │  KV Events  Backend offloading connectors                           │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                         │
─────────────────────────────────────────────────────────────────────────
```

### 2.1 Request Plane（请求平面）

**职责**：请求/响应执行路径，关注低延迟 token 生成。

| 组件 | 作用 |
|------|------|
| **Frontend** | API gateway，暴露 OpenAI HTTP 和 KServe gRPC 端点，处理请求预处理（chat template、tokenize）和响应格式化 |
| **Router** | KV-aware 路由 + 负载均衡，选择 prefill/decode worker |
| **Prefill Workers** | 对输入 token 执行 prefill 计算，生成 KV cache |
| **Decode Workers** | 使用 KV cache 生成输出 token |

**特征**：
- Frontend 运行在端口 `8000`
- 路由支持两种模式：Dynamo-native Router 和 Gateway API (GAIE)
- Prefill 和 Decode 可独立伸缩（disaggregated serving）

### 2.2 Control Plane（控制平面）

**职责**：期望状态管理，关注伸缩和放置。

| 组件 | 作用 |
|------|------|
| **Planner** | SLA 驱动的自动伸缩器，消费运行时指标，计算 prefill/decode 目标 |
| **Dynamo Operator** | K8s operator，从 CRD reconcile 资源（Go 实现） |
| **Dynamo Graph** | DGD (DynamoGraphDeployment) 拓扑描述 |
| **Grove** | Topology-aware gang scheduling，NVL72 跨 rack/NUMA 放置 |
| **Model Express** | 可选的模型管理端点（权重流式传输） |
| **Discovery** | 服务发现（etcd / Kubernetes / 内存 / 文件） |

### 2.3 Storage & Events Plane（存储与事件平面）

**职责**：缓存状态可见性，关注 KV 复用和故障恢复。

| 组件 | 作用 |
|------|------|
| **KVBM** (KV Block Manager) | 多层 KV 缓存管理：G1(HBM) → G2(DRAM) → G3(NVMe) → G4(S3) |
| **NIXL** | 高性能 GPU-to-GPU / 跨存储传输（NVLink / InfiniBand / PCIe） |
| **KV Events** | 发布缓存生命周期转换事件 |
| **Backend offloading connectors** | 跨层移动 KV blocks |
| **Local SSD / NFS / Remote** | 物理存储后端 |

---

## 3. 通信平面（Communication Planes）

Dynamo 的运行时通过**三个独立的通信平面**连接各组件：

### 3.1 Discovery Plane（发现平面）

Worker 启动时注册 endpoint，客户端 watch 成员变化。

| 部署模式 | 发现后端 | 配置 |
|---------|---------|------|
| K8s + Dynamo Operator | `DynamoWorkerMetadata` + `EndpointSlice` | `DYN_DISCOVERY_BACKEND=kubernetes` |
| 本地/裸金属 | etcd（默认） | `DYN_DISCOVERY_BACKEND=etcd`, `ETCD_ENDPOINTS` |
| 开发 | 内存/文件 | — |

Etcd 使用 lease 机制移除 stale endpoints。

### 3.2 Request Plane（请求平面）

承载 RPC 流量，`DYN_REQUEST_PLANE` 选择传输：

| 传输 | 特征 |
|------|------|
| `tcp`（默认） | 直接池化连接 |
| `nats` | 代理化请求传输 |

`DYN_REQUEST_PLANE_CODEC` 选择 `msgpack` 或 `json`。

### 3.3 Event Plane（事件平面）

承载 KV cache 更新、遥测、异步信号。`DYN_EVENT_PLANE` 选择：

| 传输 | 特征 |
|------|------|
| `zmq`（默认） | 通过 discovery plane 发现 publisher |
| `nats` | 使用 namespace/component scope 的 subject |

三个平面**相互独立**。可用 `--no-router-kv-events` 关闭 KV 事件路由。

---

## 4. 端到端请求流（Disaggregated 模式）

这是 Dynamo 最核心的请求路径，共 9 个步骤：

```
Client
  │ S1: HTTP request (OpenAI API)
  ▼
Frontend (port 8000)
  │ S2: 预处理 (chat template, tokenize, 验证)
  ▼
PrefillRouter
  │ S3: 选择 Prefill Worker (KV-aware 路由)
  ▼
Prefill Worker
  │ S4: 执行 prefill 计算 → 生成 KV cache
  │ S5: 返回 disaggregated_params (transfer metadata)
  ▼
PrefillRouter
  │ S6: 注入 transfer metadata → 选择 Decode Worker
  ▼
Decode Worker ←─ S7: NIXL GPU-to-GPU KV transfer ←─ Prefill KV Cache
  │ S8: 使用 KV cache 生成 token
  ▼
Frontend ← S9: stream tokens
  ▼
Client (detokenize → 响应)

同时:
  KV Events → 更新 cache 可见性
  Backend offloading → 按需 offload/recall KV blocks
```

### 关键实现细节

| 细节 | 说明 |
|------|------|
| **KV 转移** | 通过 NIXL 直接 GPU-to-GPU，无需共享存储 |
| **Transfer metadata** | 在 `disaggregated_params` 中交换 |
| **非阻塞转移** | GPU 前向计算与 KV 转移并行 |
| **Backend 协调** | SGLang（bootstrap connections）、TRTLLM（opaque state）、vLLM（block IDs） |
| **Worker 抑制** | 路由失败后临时抑制失败 worker（`DYN_RUNTIME_INHIBITED_DURATION_SECS`，默认 5s） |

---

## 5. KV Block Manager (KVBM) 深度

KVBM 是 Dynamo 的存储核心，采用**四层分级缓存**架构：

| 层级 | 代号 | 介质 | 延迟 | 容量 | 用途 |
|------|------|------|------|------|------|
| **G1** | — | HBM (GPU VRAM) | 纳秒 | 最小 (~80GB) | 活跃 attention 计算 |
| **G2** | — | Pinned DRAM (CPU) | 微秒 | 中等 | RDMA 传输暂存 + G3/G4 晋升 |
| **G3** | — | NVMe SSD | 毫秒 | 较大 | 热 blocks 持久化 |
| **G4** | — | S3 / MinIO | 最高 | 无限 | 冷/归档 blocks |

### KVBM Rust 实现

代码在 `lib/kvbm-*` 下，拆为 7 个独立 crate：

```
lib/kvbm-common/       # 公共接口: BlockId, LogicalLayoutHandle, SequenceHash
lib/kvbm-config/       # 配置层
lib/kvbm-consolidator/ # 合并器
lib/kvbm-engine/       # 引擎层: G1/G2/G3/G4 分层 + leader 选举 + object store
lib/kvbm-kernels/      # CUDA kernels
lib/kvbm-logical/      # 逻辑层 (KV block 管理)
lib/kvbm-physical/     # 物理层 (实际存储)
```

KVBM 引擎核心代码（`lib/kvbm-engine/src/lib.rs`）：
```rust
/// GPU/device tier — HBM KV cache. Fastest access, smallest capacity.
pub struct G1;
/// CPU/host tier — pinned DRAM cache. Microsecond-latency staging area.
pub struct G2;
/// Disk tier — NVMe/SSD cache. Millisecond-latency persistent storage.
pub struct G3;
/// Object store tier — S3/MinIO. Highest latency but unlimited capacity.
pub struct G4;
```

---

## 6. KV-Aware Router

Router 是 Dynamo 的核心智能组件，代码在 `lib/kv-router/`。

### 核心能力

```rust
// lib/kv-router/src/lib.rs
//! KV Router - Radix tree data structures for LLM KV cache routing.
//!
//! This crate provides the core radix tree implementation and protocols for
//! efficient KV cache lookup and routing in distributed LLM inference systems.

mod active_set;
pub mod conditional_disagg;   // 条件式 disaggregation
pub mod identity;             // worker 身份
pub mod indexer;              // KV 索引
pub mod kv_hints;             // KV hints
pub mod plugins;              // 可插拔路由策略
pub mod protocols;            // 协议
pub mod recovery;             // 恢复
pub mod scheduling;           // 调度
pub mod sequences;            // 序列管理
```

### 路由策略

| 策略 | 原理 |
|------|------|
| **KV-aware routing** | 基于 cache overlap score + 负载选择 worker，3× 更快 TTFT |
| **Load balancing** | 基于 worker 负载的负载均衡 |
| **Random** | 随机选择（基线） |
| **Custom plugins** | 6 个 Rust 示例插件：soft-pin-repin, simple-filter-score-pick, catalog, disagg-filter-score-pick, EPP, simple-stacked-score-pick |

### 性能数据（100K requests, R1 Distilled Llama 70B FP8, 2×H100）

| 指标 | KV-Aware vs Random |
|------|-------------------|
| TTFT | **3× 更快** |
| Avg request latency | **2× 更快** |

---

## 7. Planner — SLA 驱动的自动伸缩

Planner 是控制平面的核心，代码在 `components/src/dynamo/planner/`。

### 三个控制循环

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   Serving Loop (服务循环)                                         │
│   Frontend → Router → Prefill → Decode → 维持低延迟执行            │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Planning Loop (规划循环)                                        │
│   Runtime metrics → Planner → 计算 prefill/decode 目标            │
│   → Connector → 应用到运行时资源                                    │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Resilience Loop (韧性循环)                                       │
│   Health check → 发现 stale endpoints → 优雅关闭 → 负载剥离        │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Planner 目录结构

```
components/src/dynamo/planner/
├── config/          # 配置
├── connectors/      # 连接 runtime 资源的适配器
├── control_api.py   # 控制 API
├── core/            # 核心算法
├── environment/     # 环境抽象
├── errors.py        # 错误处理
├── monitoring/      # 监控
└── examples/        # 示例
```

---

## 8. Distributed Runtime — Rust 核心

`lib/runtime/` 是 Dynamo 的 Rust 运行时，提供 discovery、endpoint registration、request transport、lifecycle management。

### 层次模型

```
DistributedRuntime            # 持有连接、后台任务、cancellation
  └── Namespace               # 隔离一个逻辑部署或模型组
        └── Component         # 执行相同角色的 worker 组
              └── Endpoint    # 暴露网络服务 (generate, clear_kv_blocks, load_metrics)
```

客户端通过 `namespace.component.endpoint` 路径解析 endpoint，支持 random / round-robin / direct dispatch 三种选择策略。

### Runtime 模块（`lib/runtime/src/lib.rs`）

```rust
pub mod component;           // 组件抽象
pub mod compute;             // 计算
pub mod config;              // 配置 (RuntimeConfig)
pub mod discovery;           // 服务发现
pub mod engine;              // 引擎抽象
pub mod engine_routes;       // 引擎路由
pub mod error;               // 错误处理
pub mod health_check;        // 健康检查
pub mod local_endpoint_registry;  // 本地 endpoint 注册
pub mod logging;             // 日志
pub mod metadata_registry;   // 元数据注册
pub mod metrics;             // 指标
pub mod namespace;           // 命名空间
pub mod nvtx;                // NVTX 追踪
```

### Discovery 实现

```
lib/runtime/src/discovery/
├── mod.rs              # 主模块
├── kube/               # Kubernetes 发现
├── kube.rs
├── kv_store.rs         # KV store 发现
├── metadata.rs         # 元数据
├── mock.rs             # Mock 发现
├── registration.rs     # 注册
└── utils.rs
```

---

## 9. Fault Tolerance（容错）

Dynamo 的容错哲学：**"This model assumes failures are routine, not exceptional."**

| 层级 | 机制 | 实际效果 |
|------|------|---------|
| **请求** | 迁移、取消 | 飞行中工作可继续或终止 |
| **Worker** | 健康检查、优雅关闭 | 失败 worker 安全停止接收新流量 |
| **系统** | 请求拒绝 / 负载剥离 | 防止过载传播 |
| **基础设施** | Discovery lease 到期 | 移除 stale membership，流量重路由 |

### 容错流程

1. Health check 检测 unhealthy worker
2. Discovery liveness 移除 stale endpoints
3. Graceful shutdown 排空 in-flight 工作
4. Load shedding 防止级联崩溃

---

## 10. Kubernetes 原生实现

### DGD — DynamoGraphDeployment

DGD 是 Dynamo 在 K8s 上的核心 CRD，描述一组协同工作的 Dynamo 节点。

```
deploy/operator/                 # Go K8s operator (Kubebuilder)
├── api/                         # CRD API (DGD, DynamoWorkerMetadata...)
├── internal/
── cmd/main.go                  # Operator 入口
── cmd/crd-apply/               # CRD 应用工具
├── cmd/dgd-apply-overrides/     # DGD 覆盖工具
├── config/                      # Kustomize 配置
├── hack/
├── samples/
└── go.mod / Makefile / PROJECT
```

### Grove — Topology-Aware Scheduling

Grove 提供 topology-aware gang scheduling（NVL72）：
- Worker groups 建模为 `PodCliqueSet` 和 `PodClique`
- 独立 prefill/decode 弹性通过 `PodCliqueScalingGroup`

### Gateway API (GAIE)

两种路由暴露方式：

| 方式 | 描述 |
|------|------|
| **Dynamo-native** | Frontend + Router 选择 worker，基于 KV-aware scoring |
| **Gateway API (GAIE)** | K8s Gateway API Inference Extension，调用 Dynamo Endpoint Picker Plugin |

GAIE 代码在 `deploy/inference-gateway/`：
```
deploy/inference-gateway/
├── ext-proc/          # Rust 外部处理器 (workspace member)
└── sidecar/           # Rust sidecar (workspace member)
```

---

## 11. Backend 集成

Dynamo 支持两种 backend 模式：

### 11.1 Integrated Backend（集成模式）

Dynamo worker 和推理引擎在同一进程中运行。

### 11.2 Sidecar Backend（实验性）

标准推理引擎 + CPU-only Dynamo sidecar 并排运行。

```
lib/sidecar/
├── common/            # 公共代码
├── testkit/           # 测试工具
├── vllm/              # vLLM sidecar
├── sglang/            # SGLang sidecar
└── trtllm/            # TensorRT-LLM sidecar
```

### 后端适配代码

```
components/src/dynamo/
├── vllm/              # vLLM 后端适配
├── sglang/            # SGLang 后端适配
├── trtllm/            # TensorRT-LLM 后端适配
├── triton/            # Triton 后端适配
└── mocker/            # Mock 引擎（测试用）
```

### 后端版本

| Backend | 版本 |
|---------|------|
| vLLM | 0.31.0 |
| SGLang | 0.5.22 |
| TensorRT-LLM | 1.4.0rc0 |

---

## 12. 代码库映射

| 架构概念 | 代码位置 | 语言 |
|---------|---------|------|
| **Frontend** | `components/src/dynamo/frontend/` | Python |
| **Router** | `components/src/dynamo/router/` + `lib/kv-router/` | Python + Rust |
| **Planner** | `components/src/dynamo/planner/` | Python |
| **KVBM** | `lib/kvbm-{common,config,consolidator,engine,kernels,logical,physical}/` | Rust |
| **NIXL transfer** | `lib/memory/` + backend-specific | Rust |
| **DistributedRuntime** | `lib/runtime/` | Rust |
| **Discovery** | `lib/runtime/src/discovery/` | Rust |
| **Operator** | `deploy/operator/` | Go |
| **GAIE** | `deploy/inference-gateway/` | Rust |
| **Grove** | `deploy/helm/charts/platform/` | K8s CRD |
| **Model Express** | Rust crate (dynamo-llm features) | Rust |
| **Planner Gym** | `gyms/planner-gym/` | Python |

---

## 13. 请求路由拓扑

### 13.1 Dynamo-native Routing

```
Client → Frontend → Router → Prefill Worker → Decode Worker → Frontend → Client
                          │
                          └─ KV-aware scoring / load balancing
```

### 13.2 Gateway API (GAIE) Routing

```
Client → K8s Gateway → Dynamo EPP Plugin → Worker Selection
```

---

## 14. 性能优化亮点

### 14.1 KV-Aware Routing

```
Routing with cache overlap + load signals reduces prefill recomputation
and improves latency. — Baseten achieved 2× faster inference.
```

### 14.2 NIXL Data Transfer

NIXL 优化跨 worker 传输，支持异构内存：
- NVLink（GPU-to-GPU 直连）
- InfiniBand / UCX（跨节点）
- PCIe（同节点跨 GPU）

### 14.3 Model Express

GPU-to-GPU 权重流式传输：
- DeepSeek-V3 on H200: **7× 更快模型启动**

---

## 15. Agent 驱动的运维系统

Dynamo 内置完整的 AI agent 运维系统：

```
user-interviewer        → 收集需求，生成 workload contract + baseline DGD
     ↓
recipe-deployer         → 部署 DGD + OpenAI 兼容 smoke test
     ↓
perf-analyzer           → AIPerf 基准测试（configure → run → analyze）
     ↓
hypothesis-generator    → 生成优化假设 + challenger DGD
     ↓
hypothesis-challenger   → 对抗评审
```

### 核心原则

| 原则 | 含义 |
|------|------|
| **one-variable** | 每次只改一个变量 |
| **evidence-before-spend** | 先有证据再花 GPU 时间 |
| **implausible-speedup** | 可疑加速必须调查 |

### Agent 知识库

```
agent-docs/
├── guides/           # deployment, knob-tuning, model-sizing, optimization, rate-matching
├── references/       # definitions, reference-repos
└── rules/            # execution, benchmarking, optimization, verification
```

---

## 16. 测试与质量保障

### 三层测试

| 层级 | 工具 | 硬件 |
|------|------|------|
| **Rust 单元/集成** | `cargo test`, `clippy`, `cargo-deny` | CPU |
| **Python 单元/集成** | `pytest`（丰富 markers） | CPU |
| **E2E** | 真实引擎 + GPU | GPU |

### Quality Gates

```
cargo fmt → clippy → cargo-deny → cargo machete → cargo doc
ruff → mypy → basedpyright → isort → codespell
pre-commit → DCO → copyright check → CodeRabbit → CODEOWNERS
```

---

## 17. 技术栈总结

| 层面 | 技术 |
|------|------|
| **核心运行时** | Rust 2024 (toolchain 1.96.1), tokio 1.54, axum 0.8, hyper 1.7, tonic 0.13/0.14 |
| **服务发现** | async-nats 0.49, etcd-client 0.17, Kubernetes client 2.0 |
| **GPU/CUDA** | cudarc 0.19, nixl[cu13] 1.4/1.5, cupy-cuda13x |
| **扩展层** | Python ≥3.11, PyO3/maturin, aiohttp, msgspec, transformers, kubernetes |
| **K8s 部署** | Go operator (Kubebuilder), Helm charts, Gateway API |
| **可观测** | opentelemetry 0.31, prometheus_client 0.23, Grafana dashboards |
| **序列化** | serde/serde_json, msgspec, msgpack |
| **文档** | Fern (hosted), Sphinx + MyST (offline) |
| **仿真** | aisimulate 0.13.0-dev |

---

## 18. 致谢

Dynamo 的设计借鉴了以下项目的工作：

> vLLM, SGLang, DistServe, Mooncake, AIBrix, BentoML

---

*本报告由 Claude Opus 5 自动生成，基于：*
- *NVIDIA Dynamo 官方文档：Architecture + Knowledge Base Overview*
- *架构示意图：dynamo-architecture.svg*
- *本地代码库：`/home/wangwei/wei/workspacePy/maas/dynamo-main/`*
