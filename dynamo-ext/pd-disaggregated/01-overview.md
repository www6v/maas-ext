# 01 · 概念与动机

## 1.1 什么是 PD 分离

**PD 分离（Prefill-Decode Disaggregated Serving）** 是把 LLM 推理的两个阶段拆到**独立的 worker 池**来跑的部署形态。

| 阶段 | 工作内容 | 资源特征 | 瓶颈来源 |
|---|---|---|---|
| **Prefill** | 处理整段 prompt，生成初始 KV cache | 计算密集；batch 小、token 多 | prompt 长度、prompt reuse |
| **Decode** | 用 KV cache 自回归生成 token | 访存密集；并发高、KV 内存大 | 并发数、输出长度、活跃 KV 内存 |

在**聚合式（aggregated）**部署里，同一个 worker 既要打 prefill 又要打 decode，两种负载互相抢 GPU —— prefill 的大 chunk 会打断 decode 的 token 生成，造成 latency 抖动；decode 的长尾又会拖慢 prefill 的吞吐。

**分离式**把两者拆到不同 GPU 池：
- prefill 池专注打大 prompt，能吃满 GPU 算力；
- decode 池专注打自回归，KV cache 容量独立扩；
- 两个池的 TP/PP 可以**独立配置**（比如 decode 用 TP8、prefill 用 TP4）。

## 1.2 三段式执行流程

Dynamo 的分离执行被切成清晰的三步（参考 `docs/fern/pages/developer-guide/knowledge-base/concepts/system-architecture/disaggregated-serving.md`）：

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Prefill    │   NIXL  │    Decode    │
│    Engine    │ ──────▶ │    Engine    │
└──────────────┘  KV     └──────────────┘
   1. 算 prefill         3. 跑 decode
   2. 产出 KV cache      2. 收到 KV cache
```

1. **Prefill 计算**：prefill engine 处理 prompt，产出 KV cache；
2. **KV cache 传输**：prefill engine 把 KV cache 直接传给 decode engine（**NIXL，GPU-to-GPU，non-blocking**）；
3. **Decode 计算**：decode engine 用收到的 KV cache 跑自回归生成。

## 1.3 性能权衡

### 1.3.1 混合迭代 vs 分离

Dynamo 文档中有一段关键描述：

> "When an aggregated or decode engine combines chunked prefill and decode work in one forward iteration, the backend can launch separate attention work for context tokens and decode tokens."

**Token budget 控制 latency 干扰的形状**：
- **prefill chunk 大** → 打断 decode 的 forward 次数少，但每次打扰时间长；
- **prefill chunk 小** → 打断频繁，但每次打扰短。

分离式直接消除这种打扰 —— prefill 在另一块 GPU 上，decode 完全感知不到。

### 1.3.2 Prefill 饱和

> "Prefill is compute-intensive and becomes more efficient as the prompt supplies enough work to saturate the GPU."

独立的 prefill 池可以**用更小的 batch、跑更大的 token work unit**，把 GPU 算力打满。这对 RAG、长上下文、agentic 工作负载（大 prompt + 多轮）特别合算。

### 1.3.3 Decode 内存权衡

> "Decode engines divide GPU memory among model weights, activation and communication buffers, intermediate tensors, and KV cache."

- TP 切分 model state → 单卡 KV 空间变多，但通信开销上来；
- PP 切分 → pipeline bubble 会影响 decode 的步调；
- 分离后，decode 池可以独立选择 TP 大小，不必跟 prefill 妥协。

### 1.3.4 容量效应

| 并发 | 聚合 vs 分离 | 说明 |
|---|---|---|
| **低并发** | 聚合更优 | 分离的传输 + 池碎片化开销压不住收益 |
| **持续高并发** | 分离更优 | latency isolation 明显 |
| **KV 瓶颈** | 看场景 | 加 prefill 副本会**挤占总服务容量**，除非 latency 收益能补回来 |

## 1.4 xPyD：运行时可重配

Dynamo 的分离架构支持 **x prefill workers + y decode workers** 的运行时重配：

- **扩容**：worker 启动后向 discovery service 注册，发布 `RuntimeConfig`（含 KV 容量）；Router 自动发现；
- **缩容**：worker 排空（drain）活跃请求后从 discovery 注销；
- **Router 自动适应**：无需重启 frontend。

这让 PD 比例可以**跟着流量形态走** —— 白天 RAG 多就多扩 prefill，晚上对话多就多扩 decode。

## 1.5 什么时候**不**该用 PD 分离

- **短 prompt + 短输出**：prefill 几乎无成本，NIXL 传输反而拖慢；
- **低并发**：池碎片化会吃掉收益；
- **没有 RDMA/NVLink**：跨机走 TCP fallback 会慢到不如聚合；
- **模型本身 KV 需求小**：KV cache 传输量小，传输 overhead 占比相对更高。
