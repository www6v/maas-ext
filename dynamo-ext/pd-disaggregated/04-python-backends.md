# 04 · Python 后端实现

Dynamo 支持三种主流 LLM 后端：**vLLM**、**SGLang**、**TensorRT-LLM**，每种都有自己的 PD 分离实现。公共部分（`DisaggregationMode` 枚举）放在 `components/src/dynamo/common/constants.py`。

## 4.1 公共类型

**`components/src/dynamo/common/constants.py`**：

```python
class DisaggregationMode(Enum):
    AGGREGATED = "agg"
    PREFILL    = "prefill"
    DECODE     = "decode"
    ENCODE     = "encode"       # 多模态 encode 阶段
```

vLLM 还扩展支持 `"pd"` 作为聚合 + 传输的混合模式。

## 4.2 vLLM 后端（`components/src/dynamo/vllm/`）

### 4.2.1 关键文件

| 文件 | 作用 |
|---|---|
| `constants.py` | re-export `DisaggregationMode` |
| `common/constants.py` | 实际枚举定义 |
| `backend_args.py:124-130` | `--disaggregation-mode` CLI flag |
| `args.py:269-330` | 模式校验：prefill 必须显式给 `--kv-transfer-config` |
| `pd_connector.py` | **`PdConnector`**（核心） |
| `kv_connector_protocols.py` | 各 connector 的 PD 协调策略 |
| `main.py:909-1053` | worker 注册，发布 `worker_type` |
| `handlers.py` | 旁路注解、deferred abort 逻辑 |
| `publisher.py` / `sidecar.py` / `nixl_telemetry.py` | KV events + NIXL telemetry |

### 4.2.2 `PdConnector`

`pd_connector.py` 实现了一个 **`MultiConnector` 包装器**：

```
PdConnector
├── connector 1:  offload/onboard connector
│                 (DynamoConnector (KVBM) | LMCacheConnectorV1 | FlexKVConnectorV1)
└── connector 2:  NixlConnector   ← 真正做 decode 端 pull
```

**严格两个 connector**：
- 第一个：负责 KV offload/onboard（可以是 KVBM、LMCache、FlexKV）；
- 第二个：NIXL，decode 端通过它**拉**KV cache。

### 4.2.3 KV Connector 协议

`kv_connector_protocols.py` 定义了每种 connector 的 PD 协调策略：

| Protocol | 模式 | 行为 |
|---|---|---|
| **`NixlConnectorProtocol`** | **pull-based** | decode 从 prefill 响应中读 block 位置；prefill 端设 `do_remote_decode=True`；prefill 的 `kv_transfer_params` 透传给 decode |
| **`MooncakeConnectorProtocol`** | **push-based** | `transfer_id` 提前分配，bootstrap address 预先发布 |
| **`LMCacheMPConnectorProtocol`** | **cache-mediated** | KV 写到共享 cache pool；decode 按 token hash 查；无 per-request 参数跨 PD 边界 |

Registry：
```python
KV_CONNECTOR_PROTOCOLS = {
    "NixlConnector",
    "NeuronNixlConnector",
    "MooncakeConnector",
    "LMCacheMPConnector",
}
MULTI_CONNECTOR_WRAPPERS = ("MultiConnector", "PdConnector")
```

### 4.2.4 关键 CLI flag

```bash
--disaggregation-mode {agg|prefill|decode|encode|pd}
--kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_producer|kv_consumer"}'
--kv-events-config '{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:20081","enable_kv_cache_events":true}'

# 环境变量
VLLM_NIXL_SIDE_CHANNEL_PORT=<unique per worker>
```

### 4.2.5 旁路注解

`handlers.py` 定义了：
```python
BYPASS_REMOTE_PREFILL_ANNOTATION = "x-bypass-remote-prefill"
```

配合 `lib/kv-router/src/conditional_disagg.rs` 的旁路策略使用。

## 4.3 SGLang 后端（`components/src/dynamo/sglang/`）

### 4.3.1 关键文件

| 文件 | 作用 |
|---|---|
| `_disagg.py` | **核心分离辅助函数** |
| `backend_args.py:225-240` | `--disaggregation-mode` |
| `args.py:462-480` | `_normalize_multimodal_disaggregation_args()` 把 `--dedicated-mm-encoder` 映射到 sglang 的 `disaggregation-mode` |
| `init_llm.py` | `init_prefill()` / `init_decode()` 入口 |
| `request_handlers/llm/prefill_handler.py` | `PrefillWorkerHandler`：先 yield bootstrap info，再 consume |
| `request_handlers/llm/decode_handler.py` | `DecodeWorkerHandler`：聚合 + 分离 decode |
| `publisher.py` / `nixl_telemetry.py` / `sidecar.py` | metrics + KV events via ZMQ |

### 4.3.2 `_disagg.py` 关键函数

```python
compute_bootstrap_address()       # 解析 (host, port)，prefill 在 init 时广播给 decode peers
get_sglang_worker_group_id()      # 归一化 dist_init_addr 用于多节点发现
warmup_prefill_engine()           # 每个 DP rank 跑一个 disagg 请求，用 FAKE_BOOTSTRAP_HOST
                                  #   提前付 JIT / CUDA graph 成本，避免首请求慢
validate_disagg_parallel_sampling()  # 拒绝 n > 1（disagg 模式只支持 n=1）
```

### 4.3.3 SGLang 协议特点

SGLang 走的是 **`bootstrap_info = (host, port, room_id)`**：
- prefill 启动时把自己的 bootstrap endpoint 发布到 discovery；
- decode 接到请求后，**立即**开始跑（prefill 可作为 background task 并行）；
- KV 传输通过 RDMA bootstrap 进行。

### 4.3.4 关键 CLI flag

```bash
--disaggregation-mode {agg|pd|prefill|decode|encode}
--disaggregation-transfer-backend nixl
--disaggregation-bootstrap-port 30001
--prefill-round-robin-balance
--chunked-prefill-size 4096
```

## 4.4 TensorRT-LLM 后端（`components/src/dynamo/trtllm/`）

### 4.4.1 关键文件

| 文件 | 作用 |
|---|---|
| `backend_args.py:519, 551-564` | `disaggregation_mode: DisaggregationMode` 字段 + 解析；**拒绝旧 alias `prefill_and_decode`** |
| `main.py:47-139` | prefill worker 安装 **drain callback**，保证 shutdown 不打断 decode 端 NIXL-RDMA 读 |
| `args.py:219-225` | component 命名：prefill → `"prefill"`，decode → `"decode"`，encode → `"encode"` |

### 4.4.2 TRT-LLM 协议特点

- 传输元数据：**`opaque_state`** = 序列化的 TRT-LLM 内部状态；
- **同步模式**：decode 等 prefill 完成才开始；
- 关闭顺序敏感：prefill 必须先 drain，否则 decode 端的 RDMA 读会断。

### 4.4.3 关键 CLI flag

```bash
--disaggregation-mode {agg|prefill|decode|encode}
```

## 4.5 Frontend（`components/src/dynamo/frontend/`）

| 文件 | 作用 |
|---|---|
| `main.py` | 启动 HTTP frontend；自动创建 PrefillRouter |
| `prepost.py` | 请求前/后处理；注入 `kv_transfer_params` |

**自动 PrefillRouter 触发条件**（来自 `main.py`）：
- 同 namespace；
- 同 model name；
- 同时存在 `WorkerType.Prefill` 和 `WorkerType.Decode` 服务。

## 4.6 Standalone Python Router

`components/src/dynamo/router/` 提供独立的 Python 路由进程，`disagg_router.sh` 启动脚本用它来做显式的 prefill/decode 池路由（高级场景）。

## 4.7 后端对比总结

| 维度 | vLLM | SGLang | TRT-LLM |
|---|---|---|---|
| **传输元数据** | `kv_transfer_params`（block IDs + 连接信息） | `bootstrap_info (host, port, room_id)` | `opaque_state`（序列化内部状态） |
| **同步/异步** | 同步：decode 等 prefill 完成 | **异步**：prefill 作 background task | 同步：decode 等 prefill 完成 |
| **Connector** | `PdConnector`（`MultiConnector` 包装 `NixlConnector`） | 原生 sglang 集成 | 原生 TRT-LLM 集成 |
| **KV event publisher** | ZMQ | ZMQ | ZMQ |
| **关闭顺序要求** | 一般 | 一般 | **严格**：prefill 必须先 drain |
