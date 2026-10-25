# 05 · KV Cache 传输机制

KV cache 传输是 PD 分离的核心数据平面。Dynamo 通过 **NIXL**（NVIDIA Inference Xfer Library）实现 GPU-direct、非阻塞的 KV cache 传输。

## 5.1 NIXL 概览

**NIXL**（[ai-dynamo/nixl](https://github.com/ai-dynamo/nixl)）是专门为推理场景设计的高吞吐数据传输库，自动选择最优底层 transport：

| 部署形态 | NIXL 选用 transport | 物理通道 |
|---|---|---|
| **单节点**（同 NVLink domain） | **CUDA IPC** | NVLink |
| **多节点 Mellanox/NVIDIA 网卡** | **UCX** | InfiniBand 或 RoCE |
| **无 RDMA** | **TCP fallback** | 以太网（性能差，不推荐） |

**关键特征**：
- **GPU-direct**：prefill VRAM → decode VRAM，不经过 host；
- **非阻塞**：传输过程中 GPU 可以继续服务其他请求；
- **元数据走 `/dev/shm`**：K8s 部署必须配 `sharedMemory.size: 16Gi`；
- **日志确认**：部署后看 `NIXL INFO Backend UCX was instantiated` 表示 RDMA 通道起来。

## 5.2 后端特定的传输元数据

三种后端用**不同的元数据格式**让 decode 端知道去哪里拉 KV cache。来自 `docs/fern/pages/developer-guide/knowledge-base/concepts/system-architecture/disaggregated-serving.md`：

| Backend | Metadata | Execution Mode | 说明 |
|---|---|---|---|
| **SGLang** | `bootstrap_info` = `(host, port, room_id)` | **Async** | prefill 作 background task，decode 立即开始 |
| **vLLM** | `kv_transfer_params`（block IDs + 连接信息） | **Sync** | decode 等 prefill 完成 |
| **TRT-LLM** | `opaque_state`（序列化内部元数据） | **Sync** | decode 等 prefill 完成 |

### 5.2.1 vLLM：pull-based NIXL

```
1. Prefill Worker:
   - 跑 prefill，产出 KV blocks
   - 返回 kv_transfer_params = {block_ids, remote_worker_host, remote_worker_port, ...}

2. PrefillRouter:
   - 把 kv_transfer_params 注入到 decode 请求里

3. Decode Worker:
   - 收到 kv_transfer_params
   - 通过 NIXL 连接 prefill worker 的 side channel
   - 拉取指定 block 的 KV cache
   - 跑 decode
```

**关键环境变量**：
- `VLLM_NIXL_SIDE_CHANNEL_PORT`：每个 worker 必须**唯一**，用于 NIXL 控制通道。

### 5.2.2 SGLang：bootstrap RDMA

```
1. Prefill Worker (启动时):
   - compute_bootstrap_address() 解析 (host, port)
   - 把 bootstrap endpoint 发布到 discovery
   - warmup_prefill_engine() 跑一次 disagg warmup

2. Prefill Worker (运行时):
   - 跑 prefill，产出 KV cache
   - 返回 bootstrap_info = (host, port, room_id)

3. Decode Worker:
   - 收到 bootstrap_info
   - 通过 RDMA 连到 prefill 的 bootstrap 端口
   - 立即开始 decode（prefill 在 background 完成传输）
```

**关键 CLI**：
- `--disaggregation-bootstrap-port 30001`

### 5.2.3 TRT-LLM：opaque state

```
1. Prefill Worker:
   - 跑 prefill
   - 序列化内部状态为 opaque_state (bytes)
   - 返回给 router

2. Decode Worker:
   - 收到 opaque_state
   - 反序列化，知道怎么拿 KV cache
   - 跑 decode
```

**关键约束**：
- Prefill 必须先 **drain** 才能 shutdown（`main.py:47-139`）；
- 否则 decode 端正在 RDMA 读，会被强行中断。

## 5.3 替代传输后端

除了 NIXL，Dynamo 还支持几种替代 KV 传输机制：

### 5.3.1 Mooncake (TokenSpeed)

- **push-based**：`transfer_id` 提前分配，bootstrap address 预先发布；
- 实验性，位于 `examples/backends/tokenspeed/`；
- 协议：`MooncakeConnectorProtocol`。

### 5.3.2 LMCache MP

- **cache-mediated**：KV 写到**共享 cache pool**，按 token hash 索引；
- decode 端按 hash 查，不需要 per-request 参数跨 PD 边界；
- 协议：`LMCacheMPConnectorProtocol`；
- 启动脚本：`examples/backends/vllm/launch/disagg_lmcache.sh`。

### 5.3.3 FlexKV

- 另一个 connector，通过 `PdConnector` 接入；
- 启动脚本：`examples/backends/vllm/launch/disagg_flexkv.sh`。

## 5.4 条件性旁路（Conditional Disagg）

`lib/kv-router/src/conditional_disagg.rs` 实现了一个**优化**：

> 对每个请求，Router 可以决定**跳过远程 prefill**，直接在选定的 decode worker 本地跑 prefill，省掉 NIXL 传输。

**默认阈值**：
- 净新增 ISL ≤ 2048 tokens
- **且** 净新增 ISL ≤ prompt 长度的 70%

满足任一条件则走本地 prefill。

**策略**：
- `IslBoundingPolicy` — 只看 token 数；
- `PrefillLoadPolicy` — 只看 prefill 池负载（当 prefill 池空闲时没必要走远程）；
- `IslOrLoadPolicy` — 两者结合（默认）。

**应用**：
- 用户请求里带上 `x-bypass-remote-prefill` 注解（见 `vllm/handlers.py`）可强制旁路；
- 短 prompt + 重 RAG 复用场景特别有效。

## 5.5 KV Events

Prefill worker 跑完 prefill 后，会把 block 信息发到 **KV Indexer**，让 Router 做 KV-aware 选择。

**协议**：ZMQ PUB/SUB

**vLLM 配置**：
```bash
--kv-events-config '{
    "publisher": "zmq",
    "topic": "kv-events",
    "endpoint": "tcp://*:20081",
    "enable_kv_cache_events": true
}'
```

**SGLang**：同样走 ZMQ，由 `publisher.py` + `sidecar.py` 发布。

## 5.6 拓扑感知 KV 传输

`docs/fern/pages/developer-guide/knowledge-base/modular-components/router/topology-aware-kv-transfer.md` 描述了一个**优化**：

> 当启用 topology-aware KV transfer 时，prefill router 会从**选定的 prefill worker 的拓扑元数据**推导出 decode worker 的 `RoutingConstraints`。

效果：优先选跟 prefill worker **物理邻近**（同 NVLink domain、同 IB switch、同机架）的 decode worker，最小化 KV 传输延迟。

## 5.7 KV Block Manager（分层卸载）

当 KV cache 超出 GPU VRAM，`lib/kvbm-*` 系列提供分层卸载：

```
GPU VRAM  ──▶  CPU DRAM  ──▶  SSD  ──▶  Remote
(kvbm-engine) (kvbm-logical) (kvbm-physical) (kvbm-consolidator)
```

- `kvbm-engine` — 引擎；
- `kvbm-common` — 公共；
- `kvbm-config` — 配置；
- `kvbm-consolidator` — block consolidation；
- `kvbm-logical` — 逻辑层；
- `kvbm-physical` — 物理层；
- `kvbm-kernels` — 自定义 CUDA kernel。

启动脚本：`examples/backends/vllm/launch/disagg_kvbm.sh`。
