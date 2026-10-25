# 03 · Rust 核心实现

Dynamo 的控制面（discovery、routing、KV indexing、DC relay）几乎全是 Rust 写的，通过 PyO3/maturin 暴露给 Python 后端。

## 3.1 `lib/kv-router/` — KV Router

### 3.1.1 `WorkerType` 枚举（核心类型）

**`lib/kv-router/src/worker_type.rs`** — 整个分离架构的**类型源头**：

```rust
pub enum WorkerType {
    Prefill,
    Decode,
    Encode,
    Aggregated,
}
```

- `as_str()` → `"prefill" | "decode" | "encode" | "aggregated"`（**wire format**，全小写）
- `default_selector_label()`：除 `Prefill` 外都映射到 `"decode"`（兼容历史 prefill/decode 池分裂的命名）
- `FromStr` / `Serialize` / `Deserialize`：**大小写不敏感**的解析

`lib/llm/src/worker_type.rs:9` 只是 re-export：
```rust
pub use dynamo_kv_router::worker_type::WorkerType;
```

### 3.1.2 Conditional Disagg 策略

**`lib/kv-router/src/conditional_disagg.rs`** 实现"是否跳过远程 prefill"的旁路判定：

```rust
pub enum Policy {
    IslBounding,       // 只看 token 数
    PrefillLoad,       // 只看 prefill 池负载
    IslOrLoad,         // 两者结合（默认）
}
```

默认阈值（见代码常量）：
- `effective_isl <= 2048 tokens`
- `ratio <= 0.7`（即新增 prefill 占整段 prompt 的 ≤70%）

满足条件时，Router 直接在 decode worker 上跑 prefill，省掉 NIXL 传输。

### 3.1.3 调度器层次

**`lib/kv-router/src/scheduling/`** 目录：

| 文件 | 角色 |
|---|---|
| `selector/` | `WorkerSelector` trait：`WorkerPicker`（挑选候选）+ `WorkerScorer`（打分）+ `WorkerFilter`（过滤） |
| `prefill_load.rs` | 跟踪每个 prefill worker 的待处理 token 数 |
| `policy/` | 内置默认策略（与 `lib/router-plugins/` 配合） |

**`lib/router-plugins/`** 提供**可插拔**的 filter/scorer/picker，包括 builtin 默认策略。

### 3.1.4 KV Indexer & Hints

- `lib/kv-router/src/indexer/` — KV cache 索引；
- `lib/kv-router/src/kv_hints.rs` — prefill 返回的 KV 元数据（`disaggregated_params` 的 Rust 侧对应）；
- `lib/kv-router/src/tracking_hash.rs` — block hash 跟踪；
- `lib/kv-hashing/` — block hash 算法。

## 3.2 `lib/llm/` — Runtime

### 3.2.1 Discovery

**`lib/llm/src/discovery/`**：

| 文件 | 作用 |
|---|---|
| `model_manager.rs` | 管理 model 注册 |
| `worker_set.rs` | 管理 worker 集合 |
| `worker_inventory.rs` | worker 库存（按类型、按 capacity 分组） |
| `kv_source_membership.rs` | KV source（= prefill pool）的成员关系 |
| `kv_source_watch.rs` | KV source watch（用于 router 自动发现） |
| `kv_state_agent.rs` | 跨 DC KV 状态协调的 agent |
| `router_policy.rs` | router 策略接口 |

### 3.2.2 KV DC Relay（多数据中心 KV 路由）

**`lib/llm/src/kv_dc_relay.rs` + `lib/llm/src/kv_dc_relay/`**：

- `actor/` — 主 actor；
- `discovery/` — relay 之间的发现；
- `host/` — 主机层；
- `identity/` — relay 身份；
- `load/` — 负载；
- `membership_watch/` — 成员关系 watch；
- `pool_registry/` — CKF pool 注册；
- `publication/` — 发布；
- `resolution/` — 解析；
- `serving_load/` — serving 负载；
- `topology/` — 拓扑；
- `wan/` — **gRPC 传输**（HTTP/2，plaintext，可选 mTLS sidecar）。

## 3.3 `lib/kvbm-*` — KV Block Manager 家族

KV cache 的**分层卸载**：GPU → CPU → SSD → 远端。

| crate | 作用 |
|---|---|
| `kvbm-engine` | 引擎层 |
| `kvbm-common` | 公共 |
| `kvbm-config` | 配置 |
| `kvbm-consolidator` | block consolidation |
| `kvbm-logical` | 逻辑层 |
| `kvbm-physical` | 物理层 |
| `kvbm-kernels` | 自定义 kernel |

## 3.4 `lib/runtime/` — 分布式 Runtime

- 组件模型（component）；
- discovery；
- transports：**NATS, ZMQ, HTTP, gRPC**；
- endpoint 路由。

## 3.5 `lib/bindings/python/` — PyO3/maturin

把上述 Rust 能力暴露给 Python：
- `dynamo.*` Python 包的底层；
- worker_type、kv_router、discovery 等核心类型的 Python 绑定。
