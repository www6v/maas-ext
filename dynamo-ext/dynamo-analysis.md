# Dynamo 项目深度分析

> 对 `/home/wangwei/wei/workspacePy/maas/dynamo-main/` 的完整结构与架构分析
>
> 生成日期：2026-10-23 · 对应版本：**v1.6.0**

---

## 1. 项目概述

**NVIDIA Dynamo** 是一个开源的、面向数据中心规模的**分布式 LLM 推理编排框架**。

> *"Dynamo is the orchestration layer above inference engines — it doesn't replace SGLang, TensorRT-LLM, or vLLM, it turns them into a coordinated multi-node inference system."*

核心定位：在推理引擎**之上**加一层编排，把 GPU 集群组合成一个协同推理系统。

| 维度 | 描述 |
|------|------|
| **Owner** | NVIDIA Inc. (`sw-dl-dynamo@nvidia.com`) |
| **License** | Apache-2.0 |
| **Home** | <https://github.com/ai-dynamo/dynamo> |
| **Docs** | <https://docs.nvidia.com/dynamo/> |
| **PyPI** | `ai-dynamo` |
| **版本** | Rust/Python 统一 `1.6.0` |
| **主要语言** | Rust（核心）、Python（扩展）、Go（K8s operator）、Bash、Jinja2 |
| **Rust 工具链** | `1.96.1`（`rust-toolchain.toml`），edition 2024 |
| **Python 版本** | `>=3.11`（支持 3.11 / 3.12 / 3.13） |
| **Copyright** | 2024–2026 NVIDIA CORPORATION & AFFILIATES |

### 1.1 关键性能结果

| 指标 | 场景 |
|------|------|
| **7×** GPU 吞吐 | DeepSeek R1 on GB200 NVL72 vs B200（InferenceX） |
| **7×** 模型启动速度 | ModelExpress weight streaming (DeepSeek-V3 on H200) |
| **2×** TTFT 加速 | KV-aware routing, Qwen3-Coder 480B (Baseten) |
| **80%** SLA 违规减少 | Planner autoscaling at 5% lower TCO (Alibaba APSARA 2025) |
| **750×** 吞吐提升 | DeepSeek-R1 on GB300 NVL72（InferenceXv2） |

### 1.2 核心能力

| 能力 | 作用 | 重要性 |
|------|------|--------|
| **Disaggregated Prefill/Decode** | 把 prefill 和 decode 拆分为独立伸缩的 GPU 池 | 最大化 GPU 利用率 |
| **KV-Aware Routing** | 基于 worker 负载 + KV cache 重叠路由请求 | 2× 更快 TTFT |
| **Multi-tier KVBM** | KV cache 多层卸载：GPU → CPU → SSD → 远端 | 扩展有效上下文长度 |
| **ModelExpress** | 通过 NIXL/NVLink GPU-to-GPU 流式传输权重 | 7× 更快冷启动 |
| **Planner** | SLA 驱动的自动伸缩器 + 工作负载画像 | 最低 TCO 达到延迟目标 |
| **Grove** | K8s topology-aware gang scheduling（NVL72） | 跨 rack/NUMA 放置 |
| **AISimulate** | 离线预测服务行为 + 搜索配置 | 无 GPU 集群找到强配置 |
| **Fault Tolerance** | Canary 健康检查 + 飞行中请求迁移 | worker 故障不丢请求 |

### 1.3 支持的推理后端

| 能力 | SGLang 0.5.22 | TensorRT-LLM 1.4.0rc0 | vLLM 0.31.0 |
|------|:------------:|:---------------------:|:-----------:|
| Disaggregated Serving | ✅ | ✅ | ✅ |
| KV-Aware Routing | ✅ | ✅ | ✅ |
| SLA-Based Planner | ✅ | ✅ | ✅ |
| KVBM | 🚧 | ✅ | ✅ |
| Multimodal | ✅ | ✅ | ✅ |
| Tool Calling | ✅ | ✅ | ✅ |

> **互斥**：`vllm` / `sglang` / `trtllm` 三个 optional extras 在 UV 中声明为冲突（incompatible NIXL / flashinfer / XHyper 需求），同一环境只能装一个。

---

## 2. 整体架构

Dynamo 刻意分层：**Rust 核心 + Python 扩展 + Kubernetes 部署层**。任何跨越这三层的改动都应被视为"非平凡"。

```
┌──────────────────────────────────────────────────────────────────┐
│                    Clients (OpenAI-compatible HTTP/gRPC)         │
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│   Frontend  (HTTP server, pre-processor, KV router, discovery)   │
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│   Router  (KV-aware, pluggable policies, Gateway EPP plugin)     │
└───────────────────────────┬──────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
┌───────▼────────┐  ┌───────▼────────┐  ┌───────▼────────┐
│  vLLM backend  │  │ SGLang backend │  │ TRT-LLM backend│ (+ sidecar 二进制)
└───────┬────────┘  └───────┬────────┘  └───────┬────────┘
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│  Planner (SLA autoscaler)  │  KVBM (多层 cache)                 │
│  Global Planner / Router   │  KV state agent, DC relay          │
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│ Rust runtime 核心:  dynamo-runtime, dynamo-llm, dynamo-memory,  │
│                     dynamo-kv-router, dynamo-tokens, …           │
│ 服务发现: etcd / NATS / file                                     │
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│ Kubernetes:  Helm charts, operator (Go), GAIE gateway plugin,    │
│              power-agent, observability                          │
└──────────────────────────────────────────────────────────────────┘
```

### 2.1 架构要点

- **Rust 核心** 承载热路径：runtime、LLM 引擎、路由、KVBM、内存、tokens
- **Python 层** (`components/src/dynamo/`) 包含 frontend、planner、router、profiler、per-backend 集成
- **PyO3/maturin 绑定**（`lib/bindings/python/` 和 `lib/bindings/c/`）桥接 Rust ↔ Python
- **Sidecar 二进制**（`lib/sidecar/{vllm,sglang,trtllm}/`）— Rust 进程，位于 Python 引擎旁，通过 gRPC 通信
- **Kubernetes operator**（`deploy/operator/`）— Go 服务，带独立 `go.mod`/`Makefile`/`PROJECT`
- **Gateway API Inference Extension (GAIE)**（`deploy/inference-gateway/`）— Rust ext-proc + sidecar

---

## 3. 顶层目录结构

```
dynamo-main/
├── lib/                  # Rust 核心 crate workspace (~25 crates)
├── components/           # Python 组件源码 (frontend, planner, backends...)
├── agents/               # 5 个 AI agent 角色定义 (user-interview → deploy 流水线)
├── agent-docs/           # Agent 知识库 (guides/references/rules)
├── skills/ → .agents/skills  # 31 个 Claude Code skills (符号链接)
├── recipes/              # 预配置模型部署配方 (40+ 模型)
├── examples/             # 示例：backends, router, RL, diffusers...
├── deploy/               # K8s operator、Helm charts、Inference Gateway
├── container/            # Dockerfile 模板 + 15 个渲染后的 Dockerfile
├── tests/                # Python 集成/E2E 测试
├── benchmarks/           # 各种基准测试工具
├── gyms/                 # Planner 训练 gym
├── docs/                 # Fern 文档站源码
├── scripts/              # 校验脚本 (skills, agents, DCO, recipes...)
├── dev/                  # 本地开发工具 (docker-compose, sanity_check.py)
├── Cargo.toml            # Rust workspace 根
├── pyproject.toml        # Python 包根 (ai-dynamo)
├── AGENTS.md / CLAUDE.md # Agent 指令（canonical = AGENTS.md）
├── .agents/              # canonical skills 存放地
├── .claude/              # Claude Code 配置 (skills → .agents/skills)
├── .codex/               # OpenAI Codex agent 定义 (5 个 .toml)
├── .ai/                  # AI 编码准则 (7 个指南)
├── .cargo/               # Rust 编译标志 (target-cpu, pcre2, swagger-ui)
├── .github/              # 63 个 workflows、22 个 composite actions
├── .devcontainer/        # Dev container (vllm/sglang/trtllm 三套)
└── README.md / README.zh-CN.md
```

### 3.1 目录职责表

| 目录 | 内容 |
|------|------|
| `lib/` | **Rust workspace crates** — 性能核心。~25 crates |
| `components/src/dynamo/` | **Python 组件** — frontend、planner、router、profiler、各 backend 适配 |
| `agents/` | **子 agent 角色合约** — 5 个角色，每个都有 `AGENTS.md` + `CLAUDE.md` |
| `agent-docs/` | **Agent 知识库** — guides/deployment, knob-tuning, model-sizing, optimization, rate-matching；references/；rules/execution, benchmarking, optimization, verification |
| `recipes/` | **生产级 K8s 部署 recipes** — 40+ 模型/框架组合，Kustomize manifests |
| `tests/` | **跨组件/E2E 测试** — serve, kvbm_integration, fault_tolerance, deploy, frontend, router, mm_router, lmcache, basic, benchmarks, wheels, gpu_memory_service, rl, metrics, parity, dependencies |
| `benchmarks/` | **基准工具** — router, frontend, mocker, multimodal, incluster, burstgpt_loadgen, nat_trace, request_trace, sin_load_generator, prefix_data_generator, cuda_custom_storage, omni；使用 AIPerf |
| `examples/` | **可运行示例** — backends, router (6 个 Rust workspace member 插件), deployments, rl, diffusers, global_planner, gpu-sharing, custom_backend, custom_encoder, chat_templates, power-aware-budget, nemotron_speech_cascaded_pipeline |
| `deploy/` | **K8s 部署层** — helm/charts/{platform, power-agent}, operator (Go), inference-gateway (Rust), observability, power-agent, pre-deployment, utils |
| `container/` | **容器构建** — Dockerfile.template + render.py (Jinja2) → 15 个具体 Dockerfile；deps/ 含 per-framework requirements |
| `docs/fern/` | **Fern 文档站** — pages/, components/, templates/, translations/ (i18n), scripts/ (含 griffe 静态 Python API 生成) |
| `gyms/planner-gym/` | Planner 训练/评估 gym（独立 Python 包） |
| `scripts/` | 校验脚本 — validate_skills/agent_instructions/recipe-kustomization, generate_kustomize_openapi, kustomize-matrix, dco_check, check_action_pins, protocol_compatibility |
| `dev/` | 本地开发 — docker-compose.yml, docker-observability.yml, nats-server.conf, sanity_check.py (161 KB) |
| `.devcontainer/` | Framework-specific dev containers (vllm/sglang/trtllm)，由 devcontainer.json.j2 生成 |

---

## 4. `lib/` — Rust 核心 Crate Workspace

`Cargo.toml` 定义了 **39 个 workspace members**（resolver `"3"`），主要在 `lib/` 下。

### 4.1 核心 Crates

| Crate | 路径 | 作用 |
|-------|------|------|
| `dynamo-runtime` | `lib/runtime` | 分布式运行时：component、discovery、metrics、config、health check、NVTX |
| `dynamo-llm` | `lib/llm` | LLM 库：block manager、admission gate、engines、CUDA、ZMQ fan-in、media (ffmpeg) |
| `dynamo-rl` | `lib/rl` | 强化学习 |
| `dynamo-kv-router` | `lib/kv-router` | KV-aware 路由器 |
| `dynamo-kv-hashing` | `lib/kv-hashing` | KV 哈希 |
| `dynamo-memory` | `lib/memory` | 内存抽象 |
| `dynamo-tokens` | `lib/tokens` | Tokenization |
| `dynamo-truthy` | `lib/truthy` | Truthy 工具 |
| `dynamo-data-gen` | `lib/data-gen` | 数据生成 |
| `dynamo-mocker` | `lib/mocker` | Mock 推理引擎（测试用） |
| `dynamo-bench` | `lib/bench` | 基准测试库 |
| `dynamo-backend-common` | `lib/backend-common` | 后端公共代码 |
| `dynamo-sidecar-{common,testkit,vllm,sglang,trtllm}` | `lib/sidecar/*` | Sidecar 进程 |

### 4.2 KVBM 拆分

KV Block Manager 拆为 6 个独立 crate：

```
lib/kvbm-common/       # 公共接口
lib/kvbm-config/       # 配置
lib/kvbm-consolidator/ # 合并器
lib/kvbm-engine/       # 引擎层
lib/kvbm-kernels/      # CUDA kernels
lib/kvbm-logical/      # 逻辑层
lib/kvbm-physical/     # 物理层
```

### 4.3 插件与绑定

| Crate | 作用 |
|-------|------|
| `lib/router-plugins/catalog` | 路由插件目录 |
| `lib/router-plugins/builtin` | 内置路由插件 |
| `lib/bindings/c` | C 绑定（cbindgen） |
| `lib/bindings/python/codegen` | Python codegen（PyO3/maturin） |

### 4.4 重要外部依赖（Rust）

| 依赖 | 版本 | 说明 |
|------|------|------|
| `dynamo-tokenizers` | `=3.1.1` | 已发布 crate |
| `dynamo-renderer` | `=8.0.3` | 已发布 |
| `dynamo-protocols` | `=8.2.0` | 已发布 |
| `dynamo-parsers` | `=10.0.7` | 已发布 |
| `dynamo-parsers-v2` | `=0.7.24` | 已发布 |
| `aisimulate-core` | `=0.13.0-dev...` | 来自 `ai-dynamo/aisimulate` |
| `tokio` | `1.54` | Async 运行时 |
| `axum` | `0.8.4` | HTTP 框架 |
| `hyper` | `1.7` | HTTP 底层 |
| `tonic` | `0.13`/`0.14` | gRPC |
| `prost` | `0.13` | Protobuf |
| `async-nats` | `0.49.1` | NATS 服务发现 |
| `etcd-client` | `0.17` | etcd 服务发现 (TLS) |
| `kube` | `2.0.1` | K8s client |
| `cudarc` | `0.19.8` | CUDA 绑定 |
| `nixl[cu13]` | `1.4.1`/`1.5.0` | KV transfer |
| `opentelemetry` | `0.31` | Traces/logs/OTLP |
| `quinn` | `0.11.12` | QUIC |
| `rustls` | `0.23` (ring) | TLS |

### 4.5 Rust 编译配置

`.cargo/config.toml` 关键设置：

```toml
[build]
rustflags = ["--cfg", "tokio_unstable"]     # tokio-console 需要

[target.x86_64-unknown-linux-gnu]
rustflags = ["-C", "target-cpu=x86-64-v3",   # Haswell+ (AVX-2)
             "-C", "force-frame-pointers=yes",
             "--cfg", "tokio_unstable"]

[target.aarch64-unknown-linux-gnu]
rustflags = ["-C", "target-cpu=neoverse-n1", # Graviton 2 / Ampere Altra+
             "-C", "force-frame-pointers=yes",
             "--cfg", "tokio_unstable"]

[env]
PCRE2_SYS_STATIC = "1"                       # 静态链接 pcre2
SWAGGER_UI_DOWNLOAD_URL = "v5.33.1.zip"      # 覆盖 Utoipa 默认
```

Release profile：`codegen-units = 1`, `lto = "thin"`。另有 `profiling` profile（继承 release + debug symbols，`--features nvtx`）。

---

## 5. Python 组件层

### 5.1 `components/src/dynamo/` 组件清单

| 组件 | 作用 |
|------|------|
| `frontend` | HTTP + tokenizer + KV router 前端 |
| `planner` | SLA 驱动的自动伸缩 planner |
| `global_planner` | 全局 planner |
| `global_router` | 全局路由器 |
| `router` | 路由组件 |
| `vllm` / `sglang` / `trtllm` / `triton` | 推理引擎 backend 适配 |
| `mocker` | Mock 引擎 |
| `kv_state_agent` | KV 状态代理 |
| `kv_dc_relay` | KV 数据中心中继 |
| `profiler` | 性能分析器 |
| `replay` | 流量重放 |
| `squeeze_evolve` | 压缩/演化 |
| `thunderagent_router` | ThunderAgent 路由 |
| `tokenspeed` | Token 速度工具 |
| `aisimulate` | AI 模拟（集成 aisimulate 包） |
| `artifacts` | 工件 |
| `experimental` | 实验性组件 |
| `common` | 公共工具 |

### 5.2 Python 包构建

- **构建后端**：Hatchling（`hatch_build.py` 自定义 hook）
- **版本注入**：`hatch_build.py` 向每个 component 写入 `_version.py`（格式 `<semver>+<short-git-sha>`）
- **PyO3/maturin** 绑定 Rust ↔ Python

### 5.3 Python 主要依赖

```toml
ai-dynamo-runtime==1.6.0
aisimulate==0.13.0.dev...
aiohttp>=3.14.3
transformers>=4.56.0
kubernetes>=32.0.1
prometheus_client>=0.23.1
msgspec>=0.19.0
redis>=6.2.0
zstandard>=0.23.0
pyzmq>=26.0.0
```

### 5.4 Optional Dependency Groups

| Extra | 主要依赖 |
|-------|---------|
| `trtllm` | `tensorrt-llm==1.4.0rc0`, `uvloop`, `mpmath<1.4` |
| `vllm` | `vllm[flashinfer,runai,otel]==0.31.0`, `nixl[cu13]==1.4.1`, `ray>=2.55.0`, `blake3`, `soundfile`, `librosa` |
| `sglang` | `sglang[diffusion]==0.5.22`, `cupy-cuda13x>=13.6.0` |
| `artifact-delivery` | `opendal==0.47.10` |

### 5.5 Entry Points

```toml
vllm.general_plugins → dynamo_nixl_telemetry
pytest11 → vllm/trtllm/triton/sglang backend-specific conftests
aisimulate.sweep_config_providers / runner_factories / config_adapters / output_adapters
```

---

## 6. `agents/` + `agent-docs/` — AI Agent 系统

### 6.1 五个协作 Agent

Dynamo 内置 5 个 AI agent，形成一条**从用户访谈到部署优化**的完整流水线：

```
┌─────────────────────┐
│  user-interviewer   │  synthesize-user-workload → 捕获 workload + baseline DGD
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│  recipe-deployer    │  deploy-dynamo-recipe → 部署 + OpenAI 兼容 smoke test
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│  perf-analyzer      │  configure/run/analyze-aiperf-benchmark
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│ hypothesis-generator│  consult-perf-knowledge → create-optimization-hypothesis
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│hypothesis-challenger│  perform-adversarial-review → 对抗评审
└─────────────────────┘
```

每个 agent 都有：
- `agents/<name>/AGENTS.md` + `CLAUDE.md` — Claude Code 指令
- `.codex/agents/<name>.toml` — OpenAI Codex 镜像定义

### 6.2 Agent 知识库 `agent-docs/`

```
agent-docs/
├── guides/
│   ├── deployment/        # 部署指南
│   ├── knob-tuning/       # 旋钮调优
│   ├── model-sizing/      # 模型规模
│   ├── optimization/      # 优化方法论
│   └── rate-matching/     # 速率匹配
├── references/
│   ├── definitions.md
│   └── reference-repos.md
└── rules/
    ├── README.md
    ├── execution/         # 执行不变量
    ├── benchmarking/      # 基准测试严谨性
    ├── optimization/      # 优化纪律
    └── verification/      # 验证规则
```

Rules 按 activity 条件加载，核心原则：
- **one-variable rule**：每次只改一个变量
- **evidence-before-spend**：先有证据再花 GPU 时间
- **implausible-speedup rule**：可疑加速必须调查

---

## 7. `skills/` — Claude Code Skills

`.agents/skills/` 是 canonical 位置（**31 个 skill**），`skills/` 与 `.claude/skills/` 是符号链接。

### 7.1 开发类 skills

| Skill | 作用 |
|-------|------|
| `debug-session` | 结构化 bug 调查（持久工作日志） |
| `dep-create` / `dep-status` / `dep-update` | Dynamo Enhancement Proposals（GitHub issues） |
| `dynamo-clone-hotpath-audit` | Rust 热路径 `.clone()` 审计 |
| `dynamo-docs` | Fern 文档维护 |
| `dynamo-frontend-benchmark` | 前端性能基准（mock workers） |
| `dynamo-kv-replay-parity` | KV replay 一致性校验 |
| `dynamo-agent-harness` | 通过 ACP 驱动 Claude/Codex/OpenCode |
| `dynamo-release-cherry-pick` | Release 分支 cherry-pick |
| `graham-code-review` | 严格的 Rust/systems review |
| `visual-review` | HTML 代码评审仪表板（图表 + 注解 diff） |
| `fern-components` / `fern-navigation` | Fern 文档组件/导航 |
| `repo-codeowners` | 评审人定位 |
| `pr-monitor` | CI 健康检查 + 失败根因 |
| `dynamo-issue-first` | Issue-first PR |
| `report-skillpack-issue` | 报告 skill 包本身的问题 |

### 7.2 部署/运维类 skills

| Skill | 作用 |
|-------|------|
| `synthesize-user-workload` | 用户访谈 → workload 合约 |
| `author-baseline-dgd` | 起草 baseline DGD |
| `consult-perf-knowledge` | 选优化方案 + 写推理记录 |
| `create-optimization-hypothesis` | 物化 challenger-ready DGD |
| `perform-adversarial-review` | 对抗评审 |
| `deploy-dynamo-recipe` | 部署 DGD + smoke test |
| `configure-aiperf-benchmark` / `run-aiperf-benchmark` / `analyze-aiperf-results` | AIPerf 完整链路 |
| `find-serving-recipe` | 走 recipe catalog |
| `dynamo-router-starter` | 启动/补丁 router modes |
| `dynamo-interconnect-check` | 校验 NIXL/UCX/NCCL |
| `troubleshoot-dynamo` | 故障排查 |

### 7.3 Skill 规范

- 目录名 = frontmatter `name`（kebab-case）
- `description` 第三人称，≤ 1024 字符
- 必须含 `license: Apache-2.0` 和 `metadata:` 块（`author` + `tags`）
- 由 `scripts/validate_skills.py` 校验（pre-commit hook `validate-skills`）
- NVSkills CI 也校验（maintainer 在 PR 上 `/nvskills-ci`）

---

## 8. `recipes/` — 模型部署配方

40+ 个生产级 Kustomize recipe：

| 系列 | 示例 |
|------|------|
| **DeepSeek** | `deepseek-r1`, `deepseek-v4`, `deepseek-v4.1-flash` |
| **Qwen** | `qwen3-{0.6b, 32b, 235b-a22b-fp8}`, `qwen3.5-122b`, `qwen3.6-{35b, 35b-a3b}` |
| **Nemotron** | `nemotron-3-{super, ultra, nano-omni}`, `nemotron-3.5-{lightning, super-vl-120b-a12b}` |
| **Kimi** | `kimi-k2.5`, `kimi-k2.6`, `kimi-k3` |
| **GLM** | `glm-5.2`, `glm-5.3`, `glm-5.3-flash`, `glm-5-nvfp4` |
| **MiniMax** | `minimax-m3`, `minimax-m3.1` |
| **其他** | `beam-1.0-501b`, `gpt-oss-120b`, `gemma4-31b`, `ax-k2`, `k-exaone-2.0`, `inkling`, `motif-3`, `muse-spark-open-816b-a42b` |

### 8.1 Recipe 特性

- **硬件覆盖**：Hopper (H100/H200)、Blackwell (B100/B200/GB200/GB300)、EFA 集群
- **量化支持**：FP8、NVFP4、MXFP4、AWQ、GGUF、BF16 KV、FP8 KV
- **部署模式**：聚合 / disaggregated
- **GAIE 支持**：部分 recipe 已接入 Gateway API Inference Extension
- **工具**：`recipes/templates/`（骨架）、`recipes/kustomize/`（公共 helpers）、`recipes/hf_hub_secret/`、`recipes/accuracy/`

---

## 9. `deploy/` — Kubernetes 部署

```
deploy/
├── operator/              # Go K8s operator (Kubebuilder)
│   ├── api/               # CRD API
│   ├── internal/
│   ├── cmd/               # main.go, crd-apply, dgd-apply-overrides
│   ├── config/            # Kustomize
│   ├── hack/
│   ├── samples/
│   ├── docs/
│   ├── go.mod / Makefile / PROJECT / Tiltfile / Dockerfile
│   └── AGENTS.md / CLAUDE.md
├── helm/charts/
│   ├── platform/          # Dynamo 平台 chart
│   └── power-agent/       # 功耗管理 chart
├── inference-gateway/
│   ├── ext-proc/          # Rust 外部处理器 (workspace member)
│   └── sidecar/           # Rust sidecar (workspace member)
├── observability/
│   ├── grafana-{dynamo,operator,planner,disagg}-dashboard-configmap.yaml
│   ├── dcgm-metrics-with-nvlink.csv
│   ├── setup-monitoring.sh / cleanup-monitoring.sh
│   ├── logging/
│   └── MONITORING_SETUP.md / README.md
├── power-agent/           # Python 功耗/热执行器 + Dockerfile + pytest
├── pre-deployment/        # NIXL/RDMA/UCX/NCCL 检查
└── utils/
```

### 9.1 DGD — 核心部署单元

`DynamoGraphDeployment` (DGD) 是 Dynamo 在 K8s 上的核心 CRD：
- 描述一组协同工作的 Dynamo 节点（router、workers、planner）
- 由 `deploy-dynamo-recipe` skill 部署
- 由 K8s operator reconcile
- 40+ recipes 每个都产出一个 baseline DGD

---

## 10. `container/` — 容器构建

### 10.1 模板系统

```
container/
├── Dockerfile.template    # Jinja2 模板
├── render.py              # 渲染器
├── templates/             # 15 个渲染后的 Dockerfile：
│   ├── dynamo_base.Dockerfile
│   ├── dynamo_runtime.Dockerfile
│   ├── frontend.Dockerfile
│   ├── planner.Dockerfile
│   ├── vllm_runtime.Dockerfile
│   ├── sglang_runtime.Dockerfile
│   ├── sglang_xpu_framework.Dockerfile
│   ├── trtllm_runtime.Dockerfile
│   ├── triton_runtime.Dockerfile
│   ├── aws.Dockerfile
│   ├── compliance.Dockerfile
│   ├── dev.Dockerfile
│   ├── local_dev.Dockerfile
│   ├── wheel_builder.Dockerfile
│   └── args.Dockerfile
├── deps/                  # Per-framework requirements
│   ├── requirements.{common,frontend,planner,vllm,sglang,trtllm,dev,test,benchmark,aisimulate}.txt
│   └── README.md
├── dev/                   # 开发用容器
├── compliance/            # 合规
├── launch_message/        # 启动消息
├── context.yaml
├── run.sh
├── use-sccache.sh
├── Dockerfile.docs
└── Dockerfile.test
```

### 10.2 Dev Containers

`.devcontainer/` 提供 3 套 dev container（`vllm/` / `sglang/` / `trtllm/`），由 `devcontainer.json.j2` 模板通过 `gen_devcontainer_json.py` 生成。`post-create.sh` 在容器创建时运行。

---

## 11. 测试体系

### 11.1 三层测试策略

| 层级 | 范围 | 硬件 | 典型时长 |
|------|------|------|---------|
| **Unit** | 单函数/类隔离 | CPU | 100ms–30s/test |
| **Integration** | 多组件 + `dynamo.mocker` + 真实 ETCD/NATS | CPU | 秒级/test, <30 min 全量 |
| **End-to-End** | 真实引擎 + 真实请求 | **GPU** | 分钟级/test, 小时级全量 |

**所有测试都在容器内运行。**

### 11.2 测试位置

| 类型 | 位置 |
|------|------|
| Rust 单元+集成 | `lib/<crate>/src/**` `#[cfg(test)]` + `lib/<crate>/tests/` + `benches/` |
| Python 单元+集成 | `components/src/dynamo/<component>/tests/` |
| 跨组件/E2E | `tests/`（根目录） |

### 11.3 `tests/` 子目录

```
tests/
├── basic/                 # 基础测试
├── frontend/              # 前端测试
├── deploy/                # 部署测试
├── fault_tolerance/       # 容错测试
├── kvbm_integration/      # KVBM 集成测试
├── lmcache/               # LMCache 测试
├── mm_router/             # 多模态 router 测试
├── parity/                # 一致性测试
├── metrics/               # 指标测试
├── gpu_memory_service/    # GPU 内存服务测试
├── benchmarks/            # 基准测试
├── dependencies/          # 依赖测试
├── conftest.py            # pytest 配置（阻止 vllm/sglang/triton shadow + 强制标记）
└── README.md              # 测试指南
```

### 11.4 pytest 配置

```toml
[tool.pytest.ini_options]
minversion = "8.0"
asyncio_mode = "auto"
xfail_strict = true
```

**庞大的 marker 分类法**：

| 类别 | 示例 markers |
|------|-------------|
| **Lifecycle** | `pre_merge`, `post_merge`, `nightly`, `weekly`, `release` |
| **Hardware** | `gpu_0/1/2/4/8`, `xpu_1/2`, `h100` |
| **Framework** | `vllm`, `sglang`, `trtllm`, `triton`, `lmcache`, `none`, `core` |
| **Category** | `router`, `planner`, `kvbm*`, `sidecar`, `mocker`, `multimodal`, `fault_tolerance`, `deploy`, `framework_only`, `framework_with_gaie/efa/kvcr`, `snapshot_restore`, `unified` |
| **Performance** | `slow`, `stress`, `performance`, `benchmark` |
| **Specialized** | `profiled_vram_gib`, `requested_vllm_kv_cache_bytes`, `requested_sglang_kv_tokens`, `engine_ports`, `custom_build`, `wheel_smoke`, `token_budget_parity` 等 |

根 `conftest.py` 通过 `REQUIRED_CATEGORIES` 强制默认 markers，并 patch `sys.path` 阻止 `dynamo.vllm`/`dynamo.sglang`/`dynamo.triton` 在子进程中 shadow 真实安装包。

### 11.5 基准测试

`benchmarks/` 是独立 Python 项目，作为 AIPerf 的负载生成器/trace 工具，集成到 agent 优化循环中。

### 11.6 Planner Gym

`gyms/planner-gym/` — 独立 Python 包，用于 planner 训练/评估。

### 11.7 Lint/Format/Quality 工具栈

| 工具 | 配置 |
|------|------|
| Rust format | `cargo fmt` |
| Rust lint | `clippy` |
| Rust 依赖卫生 | `cargo-deny`（`deny.toml`）、`cargo machete` |
| Rust doc | `cargo doc` |
| Python format/lint | **Ruff**（line 88，Black-compatible） |
| Python type check | **mypy** + **basedpyright** |
| Import 顺序 | **isort**（Black profile） |
| 拼写 | **codespell**（`dynmo→dynamo`, `dynemo→dynamo`） |
| Pre-commit | `.pre-commit-config.yaml` |
| License | 每个源文件 SPDX header |
| DCO | `dco.yml` + `DCO.md` + `scripts/dco_check.py` |
| Action pin | `scripts/check_action_pins.py` + `actionlint.yaml` |

---

## 12. `docs/` — Fern 文档站

基于 [Fern](https://buildwithfern.com/) 框架：

```
docs/fern/
├── docs.yml               # Fern 配置
│                            custom_domain: docs.nvidia.com/dynamo
├── fern.config.json
├── pages/                 # MDX 页面
│   ├── agent-skills/
│   ├── blog/
│   ├── cli/
│   ├── community/
│   ├── developer-guide/
│   ├── enterprise/
│   ├── home/
│   ├── kubernetes/
│   ├── recipes/
│   ├── reference/
│   └── use-cases/
├── components/            # MDX 组件
├── templates/
├── translations/          # zh-CN 翻译
├── scripts/               # 含 griffe 静态 Python API 生成
├── assets/                # 图片/CSS
├── AGENTS.md / CLAUDE.md
├── index.yml
├── main.css / custom.js
└── tests/
```

- 支持英文（默认）+ `zh-CN` 翻译
- 文档构建依赖隔离在 `[dependency-groups] docs`：Sphinx 8.1+, nvidia-sphinx-theme, MyST, nbsphinx, sphinxcontrib-mermaid/bibtex, griffe 2.1.0

---

## 13. 配置与元数据文件

| 文件 | 用途 |
|------|------|
| `Cargo.toml` | Rust workspace 根，39 members，resolver 3，pinned 外部依赖，`release`/`profiling` profiles |
| `Cargo.lock` | 锁定（275 KB） |
| `pyproject.toml` | Python 包、hatchling 构建、ruff/mypy/isort/codespell/pytest 配置、dependency-groups |
| `hatch_build.py` | 自定义 hatch hook，向每个 component 写入 `_version.py` |
| `rust-toolchain.toml` | Rust `1.96.1` |
| `deny.toml` | `cargo-deny` 配置：Linux targets only，宽松 license 白名单（MIT/Apache/BSD/ISC/Unicode/BSL/MPL/Zlib/CC0/...），显式 `ring` clarification，禁止 `native-tls`/`openssl-sys` |
| `codespell.txt` | 两个覆盖：`dynmo→dynamo`, `dynemo→dynamo` |
| `.coderabbit.yaml` | CodeRabbit 配置："chill" profile、no request changes、path-specific 指令指向 `.ai/*.md`、标记内部 Linear ticket refs (DIS/DYN/OPS/DEP-NNNN) |
| `.pre-commit-config.yaml` | 13 KB pre-commit hooks |
| `.clang-format` | C/C++/Objective-C 格式化 |
| `.coveragerc` | Coverage 配置 |
| `.gitattributes` / `.gitignore` / `.dockerignore` / `.lycheeignore` | SCM/Docker/link-checker 卫生 |
| `dynamo.code-workspace` | VS Code multi-root workspace |
| `CODEOWNERS` | 116 KB 路径级 ownership |
| `LICENSE` | Apache-2.0 |
| `SECURITY.md` / `DCO.md` / `CODE_OF_CONDUCT.md` / `CONTRIBUTING.md` / `CONTRIBUTORS.md` | 治理 |

---

## 14. AI/Agent 配置目录

### 14.1 `.agents/`

```
.agents/
└── skills/                # Canonical 31 个 skill 目录
```

### 14.2 `.claude/`

```
.claude/
└── skills → ../.agents/skills  (symlink)
```

### 14.3 `.codex/`

```
.codex/
├── AGENTS.md
├── CLAUDE.md
├── config.toml            # multi_agent = true, 5 个 agent 定义
├── assets/
└── agents/
    ├── user-interviewer.toml
    ├── recipe-deployer.toml
    ├── perf-analyzer.toml
    ├── hypothesis-generator.toml
    └── hypothesis-challenger.toml
```

`config.toml` 为每个 agent 提供描述和配置文件路径，镜像 `agents/` 目录以支持 OpenAI Codex harness。

### 14.4 `.ai/` — 编码准则（7 个）

| 文件 | 主题 |
|------|------|
| `python-guidelines.md` | Python 编码规范 |
| `pytest-guidelines.md` | Pytest 规范 |
| `bash-launch-guidelines.md` | Bash 启动脚本规范 |
| `ci-guidelines.md` | CI 规范 |
| `linear-ticket-refs.md` | Linear ticket 引用 |
| `test-model-size-guardrails.md` | 测试模型尺寸护栏 |
| `ais-perf-model-guidelines.md` | AIS 性能模型规范 |

这些被 `.coderabbit.yaml` path-specific 指令引用。

---

## 15. CI / GitHub

```
.github/
├── workflows/             # 63 个 workflows
│   ├── dynamo-pipeline    # 主流水线
│   ├── nightly-ci
│   ├── fern-docs
│   ├── copyright-checks
│   ├── codeql
│   ├── compliance-base-drift
│   ├── deepseek-v4 / kimi-k25 nightly  # 模型特定 nightly CI
│   └── release-branches
├── actions/               # 22 个 composite actions
├── ci/                    # 模型 CI 配置
│   ├── deepseek-v4-pro-{agg,disagg}
│   └── kimi-k25-{agg,disagg}
├── codeowners/            # CODEOWNERS 文件
├── ISSUE_TEMPLATE/
├── review-prompts/        # Frontend / Runtime review 提示
├── FILTERS.md / filters.yaml  # 路径过滤 CI
├── actionlint.yaml
├── allurerc.mjs           # Allure 报告
├── copy-pr-bot.yaml
├── dco.yml                # Developer Certificate of Origin
└── scripts/
```

---

## 16. `scripts/` — 校验工具

| 脚本 | 作用 |
|------|------|
| `validate_skills.py` | 校验 skill 目录结构/命名/frontmatter（pre-commit + NVSkills CI） |
| `validate_agent_instructions.py` | 校验 agent 指令文件（AGENTS.md/CLAUDE.md 配对） |
| `validate-recipe-kustomization.py` | 校验 recipe Kustomize 结构 |
| `check_action_pins.py` | 校验 GitHub Action 版本 pin |
| `dco_check.py` | DCO 检查 |
| `generate_kustomize_openapi.py` | 生成 Kustomize OpenAPI |
| `kustomize-matrix.py` | Kustomize 矩阵生成 |
| `protocol_compatibility/` | 协议兼容性检查（pinned tooling deps） |

---

## 17. `examples/` — 示例集合

| 目录 | 描述 |
|------|------|
| `backends/{vllm,sglang,trtllm,mocker,tokenspeed,sample}/` | Backend-specific 启动示例 |
| `router/custom-policy-example/` | **6 个 Rust workspace member**：`soft-pin-repin`, `simple-filter-score-pick`, `catalog`, `disagg-filter-score-pick`, `epp` (Gateway API EPP), `simple-stacked-score-pick`；加 `policy-class-queues.yaml` |
| `deployments/` | 多组件部署示例 |
| `rl/` | 强化学习工作流 |
| `diffusers/` | Diffusion 模型（图片/视频） |
| `global_planner/` / `gpu-sharing/` | 跨节点规划 + GPU 共享 |
| `custom_backend/` / `custom_encoder/` | 自定义后端/编码器接入 |
| `chat_templates/` | Chat template 示例 |
| `power-aware-budget/` | 功耗/热感知调度 |
| `nemotron_speech_cascaded_pipeline/` | Nemotron 语音流水线 |
| `common/` | 共享工具 |

---

## 18. 开发工作流要点

| 项 | 说明 |
|----|------|
| **AGENTS.md 是 canonical** | `CLAUDE.md` 必须只含 `@AGENTS.md`，不写独立指令 |
| **Skills 编辑** | 只能编辑 `.agents/skills/`，`skills/` 与 `.claude/skills/` 是 symlink |
| **Pre-commit** | 包含 `validate-skills`、`codespell`、`clang-format` 等 |
| **容器优先** | 所有测试都在容器内运行 |
| **DCO** | 每个 commit 需 Developer Certificate of Origin |
| **DEP 流程** | 重大变更需走 Dynamo Enhancement Proposal (GitHub issue) |
| **Review prompts** | Frontend/runtime 改动有专门的 `.github/review-prompts/` |
| **Agent harness** | 区分 single-shot / interactive / goal-mode；禁止在 narrated intent 上 parking turn |
| **协议字段** | 修改请求/响应字段前必读 `docs/fern/.../protocol_field_handling.md` |

---

## 19. 项目规模速览

| 维度 | 数量 |
|------|------|
| Rust crates (workspace members) | 39 |
| Python 组件 | 20+ |
| Claude skills | 31 |
| AI agents | 5 (流水线) + 5 (Codex mirror) |
| 模型 recipes | 40+ |
| 文档翻译 | en + zh-CN |
| Container Dockerfiles | 15 |
| Dev containers | 3 (vllm/sglang/trtllm) |
| 推理后端 | 3 (vLLM, SGLang, TensorRT-LLM) |
| Benchmark 工具 | 12 |
| AI 编码准则 | 7 |
| GitHub workflows | 63 |
| GitHub composite actions | 22 |
| CODEOWNERS 大小 | 116 KB |

---

## 20. 关键依赖关系图

```
ai-dynamo (Python wheel)
  ├── ai-dynamo-runtime (PyO3/maturin 绑定)
  │     └── dynamo-runtime / dynamo-llm / dynamo-kv-router / ... (Rust crates)
  ├── transformers
  ├── kubernetes
  ├── redis / pyzmq / aiohttp
  └── [optional, 互斥] vllm / sglang / tensorrt-llm

deploy/operator (Go)
  └── K8s API, CRDs (DGD — DynamoGraphDeployment)

deploy/inference-gateway/ (Rust)
  ├── ext-proc (外部处理器)
  └── sidecar

docs (Fern)
  └── MDX pages + templates + zh-CN translations

agent pipeline (Claude/Codex/OpenCode)
  ├── user-interviewer → synthesize-user-workload
  ├── recipe-deployer → deploy-dynamo-recipe
  ├── perf-analyzer → AIPerf
  ├── hypothesis-generator → create-optimization-hypothesis
  └── hypothesis-challenger → perform-adversarial-review
```

---

## 21. 小结

Dynamo 是一个**工业级、生产就绪**的分布式推理编排框架，具有：

1. **清晰分层**：Rust 核心 + Python 扩展 + Go operator，边界明确
2. **丰富的 AI 辅助**：31 个 skills + 5 个 agent + 7 个编码准则 + Codex mirror，对 AI 辅助开发极度友好
3. **完整的部署栈**：从 recipe → DGD → Helm → operator → observability 一条龙
4. **成熟的测试体系**：三层测试（Rust/Python/E2E），容器内运行，GPU 资源敏感，丰富 pytest markers
5. **多引擎支持**：vLLM / SGLang / TensorRT-LLM 三大后端统一接口
6. **社区驱动**：Apache-2.0、DCO、DEP 流程、公开 calendar/meetup
7. **Agent 驱动的优化循环**：user-interview → deploy → benchmark → hypothesize → challenge 自动化

项目代码量大（39 Rust crates + 20+ Python 组件 + 40+ recipes），但组织有序、文档齐全、AI 原生，是一个值得深入研究的**大规模分布式系统 + AI-native 工程**范例。

---

*本报告由 Claude Opus 5 自动生成，基于对 `/home/wangwei/wei/workspacePy/maas/dynamo-main/` 的目录结构、README、CLAUDE.md、AGENTS.md、Cargo.toml、pyproject.toml、conftest.py、.cargo/config.toml 等关键文件的静态分析。*
