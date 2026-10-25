# 07 · 示例与 Recipes

Dynamo 提供从"2-GPU 本地 demo"到"生产级 32-GPU Hopper recipe"的完整示例梯度。

## 7.1 CLI 启动脚本（`examples/backends/*/launch/`）

### 7.1.1 vLLM

| 脚本 | 场景 |
|---|---|
| `disagg.sh` | 2-GPU 基础分离（1 prefill + 1 decode） |
| `disagg_router.sh` | 用 standalone Python router 做显式路由 |
| `disagg_kvbm.sh` | 启用 KV Block Manager |
| `disagg_lmcache.sh` | 用 LMCache MP 替代 NIXL |
| `disagg_flexkv.sh` | 用 FlexKV connector |
| `disagg_multimodal_*.sh` | 多模态（vision）分离 |
| `disagg_omni_*.sh` | Omni（音视频）分离 |
| `disagg_tracing.sh` | 启用 OpenTelemetry tracing |

### 7.1.2 SGLang

| 脚本 | 场景 |
|---|---|
| `disagg.sh` | 基础分离 |
| `disagg_router.sh` | standalone router |
| `disagg_same_gpu.sh` | prefill 和 decode 在同一 GPU（debug 用） |
| `disagg_dp_attn.sh` | data-parallel attention |

### 7.1.3 TensorRT-LLM

| 脚本 | 场景 |
|---|---|
| `disagg.sh` | 基础分离 |
| `disagg_router.sh` | standalone router |
| `disagg_same_gpu.sh` | 同 GPU debug |
| `disagg_multimodal.sh` | 多模态 |
| `disagg_e_pd.sh` | encode + prefill + decode 三段（多模态） |

### 7.1.4 最简启动示例（vLLM，2 GPU）

```bash
# Terminal 1: NATS + ETCD (assumed running)

# Terminal 2: Prefill Worker
python -m dynamo.vllm \
    --model Qwen/Qwen3-32B \
    --disaggregation-mode prefill \
    --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_producer"}' \
    --kv-events-config '{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:20081","enable_kv_cache_events":true}'

# Terminal 3: Decode Worker
python -m dynamo.vllm \
    --model Qwen/Qwen3-32B \
    --disaggregation-mode decode \
    --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_consumer"}'

# Terminal 4: Frontend
python -m dynamo.frontend --router-mode kv --http-port 8000

# Terminal 5: Test
curl http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen3-32B","messages":[{"role":"user","content":"Hello!"}]}'
```

## 7.2 K8s DGD YAML（`examples/backends/*/deploy/`）

| 文件 | 内容 |
|---|---|
| `vllm/deploy/disagg.yaml` | 最干净的 v1beta1 参考 |
| `vllm/deploy/disagg_router.yaml` | 带 standalone router |
| `vllm/deploy/disagg_planner.yaml` | 带 planner（动态调 PD 比例） |
| `vllm/deploy/disagg_kvbm.yaml` | 启用 KVBM |
| `vllm/deploy/disagg_kvbm_tp2.yaml` | KVBM + TP=2 |
| `vllm/deploy/disagg_kvbm_2p2d.yaml` | 2 prefill + 2 decode 拓扑 |
| `vllm/deploy/disagg-multinode.yaml` | 多节点（RDMA） |
| `vllm/deploy/disagg_tracing.yaml` | 启用 tracing |
| `sglang/deploy/disagg.yaml` | SGLang 版 |
| `sglang/deploy/disagg-multinode.yaml` | SGLang 多节点 |
| `trtllm/deploy/disagg_router.yaml` | TRT-LLM + router |
| `trtllm/deploy/disagg-multinode.yaml` | TRT-LLM 多节点 |
| `mocker/deploy/disagg.yaml` | Mock backend（测拓扑用，不真正推理） |

## 7.3 Production Recipes（`recipes/`）

Recipes 是经过验证的、**硬件特定**的 DGD。所有 `disagg-*` 变体都是 PD 分离部署：

| Model | Backend | Recipe | Hardware |
|---|---|---|---|
| Qwen3-32B | vLLM | `qwen3-32b/vllm/disagg-kv-router/` | + KV router |
| Qwen3-32B-FP8 | vLLM | `qwen3-32b-fp8/vllm/disagg/` | |
| Qwen3-32B-FP8 | TRT-LLM | `qwen3-32b-fp8/trtllm/disagg/` | |
| Qwen3-VL-32B-FP8 | vLLM | `qwen3-vl-32b-fp8/vllm/hetero_hardware_disagg/` | 异构硬件 |
| Qwen3.5-122B | vLLM | `qwen3.5-122b/{nvfp4,fp8}/vllm/disagg-*/` | B200/H200 agentic |
| DeepSeek-R1 | vLLM | `deepseek-r1/vllm/disagg/` | 32× Hopper |
| DeepSeek-R1 | SGLang | `deepseek-r1/sglang/disagg-{8,16}gpu/` | |
| DeepSeek-R1 | TRT-LLM | `deepseek-r1/trtllm/disagg/wide_ep/gb200/` | GB200 |
| DeepSeek-V4-Pro | vLLM | `deepseek-v4/deepseek-v4-pro/vllm/disagg*/` | H200/B200/GB200 |
| DeepSeek-V4-Pro | SGLang | `deepseek-v4/deepseek-v4-pro/sglang/disagg-*/` | B200/GB200 |
| DeepSeek-V4-Flash | vLLM | `deepseek-v4/deepseek-v4-flash/vllm/disagg-*/` | |
| DeepSeek-V4.1-Flash | vLLM/SGLang | `deepseek-v4.1-flash/{vllm,sglang}/disagg-*/` | GB200/B200/H200 + RDMA/UCX kustomize |
| Nemotron-3.5-Lightning | vLLM | `nemotron-3.5-lightning/vllm/disagg-*/` | H100/H200/B200/GB200 (DFlash/DSpark) |
| Nemotron-3-Ultra | vLLM | `nemotron-3-ultra/vllm/disagg-*-agentic-*/` | H200/B200/GB200, 256K/1M ctx |
| Kimi-K2.5 | TRT-LLM | `kimi-k2.5/trtllm/disagg-eagle-kv-router/` | |
| Kimi-K3 | vLLM/SGLang | `kimi-k3/{vllm,sglang}/disagg-*/` | GB300 |
| Beam-1.0-501B | vLLM/SGLang | `beam-1.0-501b/{vllm,sglang}/disagg-*/` | H200/B200/B300/GB200/GB300 |
| GLM-5.3-Flash | vLLM/SGLang | `glm-5.3-flash/{vllm,sglang}/disagg-*/` | GB200/H200 |
| AX-K2 | vLLM | `ax-k2/vllm/disagg-{h200,b200-chat}/` | |
| Inkling | vLLM | `inkling/vllm/disagg-gb300-agentic/` | GB300 (with AWS RoCE variant) |
| Solar-Open2-250B | vLLM | `solar-open2-250b/vllm/disagg-b200-chat/` | |
| Muse-Spark-Open-816B | SGLang | `muse-spark-open-816b-a42b/sglang/disagg-*/` | GB200/GB300 |
| Qwen3.8-2.4T | SGLang | `qwen3.8-2.4t-a95b-fp8/sglang/disagg-*/` | GB200/GB300 |

## 7.4 Kustomize 模板

**`recipes/templates/`**：

- `sglang/disagg/deploy-v1alpha1.template.yaml` — SGLang disagg 模板（v1alpha1）；
- `sglang/disagg/deploy-v1beta1.template.yaml` — SGLang disagg 模板（v1beta1）；
- `kustomize/components/*/disagg/patch-dgd.yaml` — 各 kustomize 组件的 disagg 补丁。

## 7.5 Mock Backend

`examples/backends/mocker/` 提供**不真正推理**的 mock worker，专门用来：
- 测分离拓扑；
- 测 Router 行为；
- 测 Operator reconcile；
- 不需要 GPU。

## 7.6 选择 recipe 的建议

- **开发调试**：用 `examples/backends/<backend>/launch/disagg.sh`，2 GPU 起步；
- **单节点生产**：从 `examples/backends/<backend>/deploy/disagg.yaml` 起步改；
- **多节点 RDMA**：参考 `recipes/<model>/<backend>/disagg-*/` 里带 RDMA kustomize 的；
- **特定硬件**（B200/GB200/GB300）：直接找对应 recipe，硬件相关配置（如 NVLink domain、IB switch 拓扑）都调好了。
