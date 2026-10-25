# NVIDIA Dynamo PD 分离（Disaggregated Serving）深度分析

> 基于 `dynamo-main` 源码（commit as-of 2026-10-24）与官方文档分析。
> 参考：
> - https://docs.nvidia.com/dynamo/dev/knowledge-base/concepts/system-architecture/disaggregated-serving
> - https://docs.nvidia.com/dynamo/dev/kubernetes/disaggregated-serving/overview

## 📖 文档索引

| # | 文档 | 内容 |
|---|---|---|
| 01 | [概念与动机](./01-overview.md) | 什么是 PD 分离、为什么要分离、性能权衡 |
| 02 | [架构与数据流](./02-architecture.md) | 三段式执行流程、PrefillRouter、请求链路 |
| 03 | [Rust 核心实现](./03-rust-core.md) | `lib/kv-router`、`lib/llm`、`WorkerType`、conditional disagg |
| 04 | [Python 后端实现](./04-python-backends.md) | vLLM / SGLang / TRT-LLM 三种后端的分离实现 |
| 05 | [KV Cache 传输机制](./05-kv-transfer.md) | NIXL、各后端的传输元数据、条件性旁路 |
| 06 | [Kubernetes / Operator](./06-kubernetes.md) | CRD v1beta1、DisaggregatedSet、Helm/Kustomize |
| 07 | [示例与 Recipes](./07-recipes.md) | 启动脚本、DGD YAML、recipes 目录 |
| 08 | [关键文件与文档索引](./08-reference.md) | 阅读地图 |

## 🎯 TL;DR

- **PD 分离** = 把 LLM 推理的 **Prefill**（处理 prompt、生成 KV cache）与 **Decode**（用 KV cache 自回归生成 token）两个阶段，拆到**独立的 worker 池**，分别扩缩容、独立调度。
- Dynamo 通过 **PrefillRouter** 自动把请求串到 `prefill → NIXL KV 传输 → decode → 流式响应` 这条链路上。
- **NIXL**（NVIDIA 的 KV cache 传输库）负责 GPU-direct 传输：单节点走 **CUDA IPC over NVLink**，多节点走 **UCX over RDMA (IB/RoCE)**。
- Operator 层：v1beta1 把 `prefill` / `decode` 提升为**一等 `ComponentType`**；可选对接上游 Kubernetes `DisaggregatedSet` API（`sigs.k8s.io/lws`）。
- 后端支持：**vLLM**（pull-based NIXL）、**SGLang**（push-like bootstrap RDMA）、**TRT-LLM**（opaque_state）、实验性 TokenSpeed（Mooncake）、LMCache MP、FlexKV。
- 支持**运行时 xPyD 重配**：prefill/decode 副本数可动态扩缩，Router 通过 discovery 自动感知。
