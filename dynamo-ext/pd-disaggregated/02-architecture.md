# 02 · 架构与数据流

## 2.1 整体拓扑

```
                 ┌────────────────────────┐
   HTTP/JSON     │       Frontend         │
   OpenAI API ──▶│  (HTTP + Tokenizer +   │
                 │      KV Router)        │
                 └───────────┬────────────┘
                             │  auto-promotes to
                             ▼
                 ┌────────────────────────┐
                 │    PrefillRouter       │  ← 仅当同一 namespace 下
                 │ (内部，frontend 里)    │    同时发现 Prefill+Decode
                 └──────┬─────────┬───────┘    服务时自动激活
                        │         │
            ┌───────────┘         └───────────┐
            ▼                                 ▼
   ┌────────────────┐               ┌────────────────┐
   │  Prefill Pool  │   NIXL KV     │   Decode Pool  │
   │  (GPU, TP=a)   │ ────────────▶ │  (GPU, TP=b)   │
   └────────────────┘   (direct,    └────────┬───────┘
                        non-blocking)        │
                                             ▼
                                    Stream tokens back
                                    through Frontend → Client
```

## 2.2 关键组件

| 组件 | 位置 | 作用 |
|---|---|---|
| **Frontend** | `components/src/dynamo/frontend/` | HTTP 入口，tokenizer，post-processing |
| **PrefillRouter** | `lib/kv-router/` + frontend 内部 | 选 prefill worker、选 decode worker、注入 handoff 元数据 |
| **Prefill Worker** | vllm/sglang/trtllm 模块 | 跑 prefill，发布 KV events，返回 `disaggregated_params` |
| **Decode Worker** | vllm/sglang/trtllm 模块 | 跑 decode，通过 NIXL 拉 KV cache，流式生成 token |
| **Discovery Service** | NATS + etcd | worker 注册、model card、KV 容量发布 |
| **NIXL** | 兄弟仓库 `ai-dynamo/nixl` | GPU-direct KV cache 传输 |
| **KV Indexer** | `lib/kv-router/src/indexer/` | 跟踪每个 worker 上的 KV cache 内容，支持 KV-aware 路由 |

## 2.3 PrefillRouter 的自动激活

`docs/fern/pages/developer-guide/knowledge-base/modular-components/router/disaggregated-serving.md` 中描述的规则：

> 当同一 namespace 下注册了一个 `WorkerType.Decode` 和一个 `WorkerType.Prefill` 服务（model name 相同），frontend 会**自动**创建一个内部 `PrefillRouter`。

激活后：
- **关闭 active block tracking**（`track_active_blocks=false`），因为 block 信息改由 NIXL 侧 channel 传输；
- Router 位于预处理和 decode 路由之间；
- 返回选定 decode worker 的 handoff 元数据；
- 激活期间若还没准备好，返回 HTTP 503。

## 2.4 完整请求链路

```
Client ─▶ Frontend ─▶ PrefillRouter
    │
    │ 1. 选 prefill worker
    │    (KV-aware routing based on cache overlap scores
    │     or 简单 load balance)
    ▼
    [Prefill Worker]
    │
    │ 2. 跑 prefill，产出 KV cache
    │ 3. 返回 disaggregated_params
    │    (后端特定的传输元数据，见 05 节)
    │ 4. 同时把 block 事件发到 KV Indexer
    ▼
    PrefillRouter
    │
    │ 5. 选 decode worker
    │    (若启用了 topology-aware KV transfer，
    │     会从选定 prefill worker 的拓扑元数据
    │     推导出 decode 的 RoutingConstraints)
    │ 6. 把 prefill 的返回注入到 decode 请求里
    ▼
    [Decode Worker]
    │
    │ 7. 用传输元数据，与 prefill 协调 NIXL KV 传输
    │    (prefill VRAM → decode VRAM，direct, non-blocking)
    │ 8. 跑 decode，流式生成 token
    ▼
    Frontend ─▶ Client (SSE stream)
```

## 2.5 KV-aware routing

PrefillRouter 不只做负载均衡，它还能做 **KV-aware routing**：

- **cache overlap score**：如果用户的前一轮对话已经命中了某 prefill worker 上的 KV cache（prompt prefix 复用），优先路由到那个 worker，省去重复 prefill；
- **prefill load**：跟踪每个 prefill worker 的待处理 prefill token 数，避开高负载 worker；
- **topology-aware decode**：选 decode worker 时考虑它和选定 prefill worker 之间的**物理拓扑**（同 NVLink domain？同 IB switch？），最小化 KV 传输延迟。

实现位于：
- `lib/kv-router/src/scheduling/selector/` — worker 选择器
- `lib/kv-router/src/scheduling/prefill_load.rs` — prefill 负载跟踪
- `lib/llm/src/kv_dc_relay/` — 跨数据中心拓扑

## 2.6 条件性分离（Conditional Disagg）

`lib/kv-router/src/conditional_disagg.rs` 实现了一个**旁路策略**：

> 对每个请求，Router 可以决定**跳过远程 prefill**，直接在选定的 decode worker 本地跑 prefill。

判断条件（默认阈值）：
- 净新增 ISL ≤ **2048 tokens**，**且**
- 净新增 ISL ≤ prompt 的 **70%**

这种小 prompt 走本地 prefill，省掉一次 NIXL 传输，反而更快。

策略变体：
- `IslBoundingPolicy` — 只看 token 数；
- `PrefillLoadPolicy` — 看 prefill 池负载；
- `IslOrLoadPolicy` — 两者结合。

## 2.7 多数据中心扩展

当 deployment 跨多个数据中心，Dynamo 提供 **KV DC Relay**：

```
DC-A                       DC-B
┌──────────┐               ┌──────────┐
│ Prefill  │               │  Decode  │
│ Worker   │               │  Worker  │
└────┬─────┘               └─────┬────┘
     │                           │
     ▼                           ▼
  KV DC Relay ───── gRPC ─────▶ KV DC Relay
  (CKF pool)     (mTLS opt)    (CKF pool)
```

- `lib/llm/src/kv_dc_relay/` — Rust 实现
- `components/src/dynamo/kv_dc_relay/` — Python CLI wrapper
- `components/src/dynamo/kv_state_agent/` — 跨 DC 的 KV 状态协调
- 传输：**gRPC (HTTP/2, plaintext, 可选 mTLS sidecar)**

详见 `docs/fern/pages/developer-guide/knowledge-base/modular-components/router/multi-dc-kv-routing.md`。
