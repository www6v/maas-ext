# Dynamo Issue 分析报告

生成时间：2026-10-25（已修正）

## 摘要

本报告分析了 11 个 Dynamo 项目 issue，评估每个 issue 是否可以在本地 GPU 环境修复，并按照难度从易到难排序。

### 分类统计

| 分类 | 数量 | Issue 编号 |
|------|------|-----------|
| ✅ 可在本地 GPU 修复 | 3 | #16877, #17029, #16781, #16738 |
| ⚠️ 可在本地修复（无需 GPU） | 3 | #17188, #17030, #16958 |
| ❌ 需要特殊环境 | 3 | #17248, #16895, #17251 |
| 🚫 不修复 | 1 | #17106 |

---

## 正确的 Issue 对应关系

| Issue | 标题 |
|-------|------|
| #17251 | GMS V1: restore weights from a ModelExpress peer, with one GPU-confined process per rank |
| #17248 | [BUG]: vllm-runtime 1.6.0 deadlocks on warm restart of expert-parallel MoE workers |
| #17188 | chore(container): align planner Python bases and remove ensurepip workaround |
| #17106 | Update bundled dependencies and image bases |
| #17030 | test(frontend): complete native argument-streaming qualification |
| #17029 | fix(frontend): preserve suppressed Hermes/Qwen3 batch text |
| #16958 | ci: reevaluate stale PR issue-link checks at the release cut |
| #16895 | fix(operator): verify replacement inference before retiring the last old worker |
| #16877 | [BUG]: Frontend performance reports infinite tail latency from finite histogram samples |
| #16781 | [BUG]: Gemma 4 with thinking off leaks empty channel markers after tool result |
| #16738 | [BUG]: MiniMax M3 required tool choice can return text with explicit thinking |

---

## 按难度排序（从易到难）

### 1. ⭐ #17188 - chore(container): align planner Python bases and remove ensurepip workaround

**难度等级**: ⭐ (简单)  
**本地 GPU 修复**: ✅ 不需要 GPU  
**预估工时**: 2-4 小时

#### 问题描述
Planner 构建环境使用 Python 3.13.17，但运行环境基于 NGC Python 3.13.16，导致需要临时的 `ensurepip` 复制操作。

#### 修复方案
- 更新运行时基础镜像至 Python 3.13.17+
- 移除 `ensurepip` 复制的 workaround
- 在 amd64 和 arm64 架构上验证虚拟环境创建

#### 技术要点
- **组件**: Dockerfile / 容器基础设施
- **技能要求**: Docker、容器构建
- **相关 PR**: #17108

#### 本地修复可行性
✅ 完全可以在本地修复，无需 GPU，只需 Docker 环境

---

### 2. ⭐⭐ #16877 - [BUG]: Frontend performance reports infinite tail latency from finite histogram samples

**难度等级**: ⭐⭐ (较简单)  
**本地 GPU 修复**: ✅ 不需要 GPU  
**预估工时**: 2-3 小时

#### 问题描述
前端性能报告的 Prometheus 解析器错误地插值到 `+Inf` 直方图桶，导致有限的延迟分布产生无限的 p95/p99 值。

#### 修复方案
- 修改 `benchmarks/frontend/scripts/analysis/parsing_util.py` 中的 `parse_prometheus_text()` 函数
- 当选定的分位数落在无界桶时，返回最高有限桶边界
- 匹配 Prometheus `histogram_quantile` 的行为

#### 技术要点
- **组件**: Python 分析脚本
- **文件**: `benchmarks/frontend/scripts/analysis/parsing_util.py`
- **根因**: 线性插值逻辑扩展到 `+Inf` 桶而非限制在最高有限边界

#### 本地修复可行性
✅ 完全可以在本地修复，纯 Python 代码修改，无需 GPU 或后端服务

---

### 3. ⭐⭐ #17106 - Update bundled dependencies and image bases

**难度等级**: ⭐⭐ (较简单)  
**本地 GPU 修复**: ✅ 不需要 GPU  
**预估工时**: 4-8 小时

#### 问题描述
需要更新 OS CA 包、Go、Rust TLS 依赖、certifi、pip、uv 和 rustup 到当前维护版本。

#### 修复方案
- 更新所有列出的依赖到最新稳定版本
- 重建 wheels 和容器镜像
- 验证捆绑的 NATS/etcd 二进制使用更新的 Go 工具链
- 验证证书链处理

#### 技术要点
- **组件**: OS CA 包、Go 工具链、Rust TLS 依赖、Python 包
- **二进制**: NATS 和 etcd
- **操作**: 重建 wheels 和容器镜像；验证证书链
- **相关 PR**: #17108

#### 本地修复可行性
✅ 可以在本地修复，需要 Docker 和各种语言工具链，无需 GPU

---

### 4. ⭐⭐ #17030 - test(frontend): complete native argument-streaming qualification

**难度等级**: ⭐⭐ (较简单)  
**本地 GPU 修复**: ✅ 不需要 GPU  
**预估工时**: 4-6 小时

#### 问题描述
在解析器默认更改后，原生参数流式传输的测试不完整。`unified_parser.rs` 中有 30/32 个原生早期参数检查测试失败并被忽略。

#### 修复方案
- 重新运行矩阵测试
- 分类库行为与适配器行为
- 在各种路由（工具调用、推理等）中断言完成前的参数增量
- 覆盖未设置、自动、显式 V2 和 V1 回滚

#### 技术要点
- **文件**: `lib/llm/src/protocols/openai/chat_completions/unified_parser.rs`
- **失败测试**: `eight_family_native_argument_progress_matrix`, `native_progress`
- **上下文**: 跟踪 PR #16822 的 P2 后续工作

#### 本地修复可行性
✅ 可以在本地修复，纯 Rust 测试完善，无需 GPU

---

### 5. ⭐⭐ #16958 - ci: reevaluate stale PR issue-link checks at the release cut

**难度等级**: ⭐⭐ (较简单)  
**本地 GPU 修复**: ⚠️ 不需要 GPU，需要 CI 环境  
**预估工时**: 4-6 小时

#### 问题描述
在创建发布分支后，没有链接 issue 的 PR 的检查状态应该变红但保持绿色，因为 GitHub 拒绝重新运行超过 30 天的旧工作流。

#### 修复方案
- 在发布 cut 期间使用现有验证器实施新鲜评估
- 强制对每个针对 main 的开放、非草稿 PR 进行新的验证运行
- 添加回归测试覆盖链接缺失的 PR（45 天前的检查）

#### 技术要点
- **触发器**: 发布 cut 流程
- **目标**: 针对 `main` 的开放、非草稿 PR
- **逻辑变更**: cut 作业必须强制新的验证运行，无论之前的检查年龄
- **前置条件**: 在 `release/1.7.0` 分支 cut 之前完成

#### 本地修复可行性
⚠️ 不需要 GPU，但需要 GitHub Actions CI 环境来完整测试

---

### 6. ⭐⭐⭐ #17029 - fix(frontend): preserve suppressed Hermes/Qwen3 batch text

**难度等级**: ⭐⭐⭐ (中等)  
**本地 GPU 修复**: ✅ 需要 GPU 测试  
**预估工时**: 6-10 小时

#### 问题描述
Hermes/Qwen3 批处理聚合在工具调用被抑制时丢失字面量工具调用文本。当配置 `hermes` 工具解析器和 `qwen3` 推理解析器且禁用工具调用解析时，仅包含字面量 Hermes 文本的响应导致空的批处理内容。

#### 修复方案
- 当工具调用解析被禁用时保留字面量文本
- 分离解析器对身份与解码器激活
- 覆盖未设置/自动/显式 V1/V2 行为
- 在保留回归中用独立期望值替换选择派生的期望值

#### 技术要点
- **受影响组件**: 前端 (`dynamo.frontend`, `dynamo-run`)、工具调用解析、批处理聚合
- **涉及解析器**: Hermes（工具解析器）、Qwen3（推理解析器）
- **根因**: 保留的 Hermes 解析器提取调用并替换正常内容，然后抑制删除提取的调用
- **上下文**: PR #16822 的 P2 后续工作

#### 本地修复可行性
✅ 可以在本地 GPU 修复，需要运行 Hermes/Qwen3 模型验证修复

---

### 7. ⭐⭐⭐ #16781 - [BUG]: Gemma 4 with thinking off leaks empty channel markers after tool result

**难度等级**: ⭐⭐⭐ (中等)  
**本地 GPU 修复**: ✅ 需要 GPU 测试  
**预估工时**: 6-10 小时

#### 问题描述
使用 Gemma 4 模型且 `enable_thinking=false` 时，系统在工具响应后立即在助手内容中包含原始通道标记（`<|channel>thought\n<channel|>`）。

#### 修复方案
**选项 A（窄范围）**: 保留当前 gating 逻辑但实现特定过滤器，在推理禁用时删除前导空思考通道  
**选项 B（匹配 vLLM）**: 始终执行 Gemma 4 推理解析器，无论 `enable_thinking` 标志

#### 技术要点
- **受影响组件**: Rust 前端、`dynamo-llm`、chat templates
- **根因**: Jinja chat 模板逻辑在 `add_generation_prompt` 为 true 且上一条消息是 `tool_response` 时跳过预填充思考通道
- **配置**: 使用 `--dyn-reasoning-parser gemma4` 和 `enable_thinking=false` 时发生
- **影响**: 语音代理会将标记朗读出来

#### 本地修复可行性
✅ 可以在本地 GPU 修复，需要运行 Gemma 4 模型验证工具调用往返

---

### 8. ⭐⭐⭐ #16738 - [BUG]: MiniMax M3 required tool choice can return text with explicit thinking

**难度等级**: ⭐⭐⭐ (中等)  
**本地 GPU 修复**: ✅ 需要 GPU 测试  
**预估工时**: 6-10 小时

#### 问题描述
当启用显式思考（`thinking: true`）时，MiniMax M3 模型忽略 `tool_choice: "required"`。如果用户明确指示模型不要调用函数，模型返回标准文本内容而非强制执行工具调用或返回错误。

#### 修复方案
- 修改 `normalize_minimax_m3_thinking_mode` 函数
- 在约束输出期间不保留显式客户端思考
- 确保模型执行工具调用或返回清晰错误
- 添加回归测试覆盖对抗性请求

#### 技术要点
- **组件**: `dynamo-llm`, vLLM 后端
- **触发条件**: `tool_choice: "required"` + 非空工具列表 + `chat_template_kwargs: {"thinking": true}`
- **预期行为**: 模型必须执行工具调用或返回错误
- **观察行为**: 模型返回纯文本（如 "hello"），忽略强制工具约束

#### 本地修复可行性
✅ 可以在本地 GPU 修复，需要运行 MiniMax M3 模型验证

---

### 9. ⭐⭐⭐⭐ #17248 - [BUG]: vllm-runtime 1.6.0 deadlocks on warm restart of expert-parallel MoE workers

**难度等级**: ⭐⭐⭐⭐ (难)  
**本地 GPU 修复**: ⚠️ 需要多 GPU 环境  
**预估工时**: 10-16 小时

#### 问题描述
`vllm-runtime:1.6.0` 镜像（搭载 vLLM 0.31.0）在存在 FlashInfer autotune 缓存时，导致专家并行（EP）和数据并行（DP）Mixture-of-Experts（MoE）工作者在热重启时无限挂起。

#### 根因分析
在 vLLM 0.31 中，`flashinfer_autotune()` 让 rank 0 读取单个共享缓存文件并广播。但是，FlashInfer 按张量/专家并行 rank 键控 MoE 缓存条目。因此，只有 rank 0 获得缓存命中并跳过分析，而其他 rank 尝试分析并永远阻塞在 rank 0 从未加入的 `all_reduce` 集合上。

#### 修复方案
- 按 rank 持久化 autotune 缓存文件（例如 `autotune_configs_dp0_rank{0,1}.json`）
- 确保所有 rank 在跳过分析前验证其特定的缓存条目
- **注意**: 已在 vLLM 0.32 中修复（PR #57635），需要回移植到 1.6.x 版本

#### 技术要点
- **受影响镜像**: `nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.6.0`
- **受影响组件**: `vllm/model_executor/warmup/kernel_warmup.py`
- **影响**: 使用持久化 `VLLM_CACHE_ROOT` 且 EP 或 DP > 1 的部署会在重启后崩溃循环或挂起

#### 本地修复可行性
⚠️ 需要至少 2 个 GPU 来测试 EP/DP 场景，单 GPU 无法完整验证

#### 临时解决方案
1. 每次启动前删除 `$VLLM_CACHE_ROOT/flashinfer_autotune_cache`
2. 禁用自动调优：`--kernel-config '{"enable_flashinfer_autotune": false}'`

---

### 10. ⭐⭐⭐⭐ #16895 - fix(operator): verify replacement inference before retiring the last old worker

**难度等级**: ⭐⭐⭐⭐ (难)  
**本地 GPU 修复**: ❌ 需要 Kubernetes 环境  
**预估工时**: 12-20 小时

#### 问题描述
在替换 Pod 变为 "Ready" 后立即退役最后一个旧工作 Pod 会导致临时服务中断。Kubernetes 就绪状态不保证前端已更新其路由表以包含新工作者。

#### 复现时间线（UTC, 2026-10-20）
- 10:58:45: 替换 Pod 变为 Ready
- 10:58:46.425: 前端发现快照移除旧实例并添加新实例
- 10:58:46.425955: "Removed worker set from model", remaining_sets=0
- 10:58:46.468227: "chat endpoints disabled"
- 10:58:47-48: 客户端收到 HTTP 404 响应
- 10:58:48.207999: "Committed discovered model group"
- 10:58:48.208065: "chat endpoints enabled"

#### 修复方案
- 实现有界最小推理检查
- 使用现有的 `nvext.backend_instance_id` 和 `extra_fields: ["worker_id"]`
- 在允许副本缩小之前确认每个就绪前端已完成至少一个归因于替换工作者的推理请求
- 缺少归因和失败的探测必须阻止缩小

#### 技术要点
- **组件**: Kubernetes operator、dynamo-deploy 二进制、Python 前端
- **根因**: Kubernetes Pod 就绪与前端服务发现更新之间的竞态条件
- **范围**: 专门针对托管 Kubernetes 发现的 text-generation 滚动更新
- **相关**: #13622, #15558

#### 本地修复可行性
❌ 需要 Kubernetes 集群环境，不适合本地单 GPU 修复

---

### 11. ⭐⭐⭐⭐⭐ #17251 - GMS V1: restore weights from a ModelExpress peer, with one GPU-confined process per rank

**难度等级**: ⭐⭐⭐⭐⭐ (非常难)  
**本地 GPU 修复**: ❌ 需要多 GPU + RDMA 环境  
**预估工时**: 40-80 小时

#### 问题描述
解决 GMS V1 快照恢复的性能瓶颈。当前从存储重新填充 GPU 权重很慢。该提案支持通过 RDMA 从现有对等体使用 ModelExpress 恢复权重，而不是磁盘 I/O。

#### 修复方案
- 为 V1 加载器实现 `mx` 传输后端通过 RDMA 填充分配
- 引入 `v1.snapshot.mx_source` 配置发布已提交的分配
- 分配必须变为 `gpuDirectRDMACapable` 用于 NIXL 注册
- 实现进程隔离：每个 GPU 一个进程，按 PCI 总线顺序
- 使用 `no_new_privs` 和 Landlock 限制访问 `/dev/nvidia<minor>`

#### 技术要点
- **组件**: V1 loader、ModelExpress、NIXL、GMS sidecar、supervisor
- **新后端**: V1 加载器的 `mx` 传输后端通过 RDMA 填充分配
- **内存**: 分配必须支持 GPU Direct RDMA
- **进程隔离**: PCI 总线顺序的一个进程一个 GPU；限制访问特定设备
- **验收标准**: 恢复的引擎必须匹配捕获前输出；rank 无法访问其他 rank 的 GPU、套接字或进程

#### 本地修复可行性
❌ 需要多个 GPU、RDMA 支持、深入的系统级知识，不适合本地修复

---

## 推荐修复顺序

### 第一阶段：快速胜利（无需 GPU）
1. **#17188** - 容器 Python 版本对齐 (2-4h)
2. **#16877** - Prometheus 解析修复 (2-3h)
3. **#17030** - 完善测试 (4-6h)

### 第二阶段：本地 GPU 修复（需要单 GPU）
4. **#17029** - Hermes/Qwen3 批处理修复 (6-10h)
5. **#16781** - Gemma 4 通道标记修复 (6-10h)
6. **#16738** - MiniMax M3 工具调用修复 (6-10h)

### 第三阶段：需要特殊环境
7. **#16958** - CI 检查修复（需要 CI 环境）(4-6h)
8. **#17248** - vLLM 死锁修复（需要 2+ GPU）(10-16h)
9. **#16895** - K8s operator 修复（需要 K8s 集群）(12-20h)
10. **#17251** - GMS V1 RDMA 恢复（需要多 GPU + RDMA）(40-80h)

### 🚫 不修复
- **#17106** - Update bundled dependencies and image bases

---

## 本地 GPU 可修复 Issue 详细指南

### 可以在本地 GPU 修复的 Issue（4 个）

#### 1. #16877 - Prometheus 解析修复（不需要 GPU）
**最简单的修复，纯 Python**

```bash
# 定位文件
cd benchmarks/frontend/scripts/analysis/
# 修改 parsing_util.py 中的 parse_prometheus_text() 函数
# 当分位数落在 +Inf 桶时，返回最高有限桶边界
```

#### 2. #17029 - Hermes/Qwen3 批处理修复
**需要 GPU 运行相关模型**

```bash
# 测试配置
--tool-parser hermes --reasoning-parser qwen3 --disable-tool-call-parsing
# 验证包含字面量 Hermes 文本的响应正确保留内容
```

#### 3. #16781 - Gemma 4 通道标记修复
**需要 GPU 运行 Gemma 4 模型**

```bash
# 测试配置
--dyn-reasoning-parser gemma4 --enable-thinking false
# 执行工具调用往返，验证不泄漏空通道标记
```

#### 4. #16738 - MiniMax M3 工具调用修复
**需要 GPU 运行 MiniMax M3 模型**

```bash
# 测试场景
tool_choice: "required"
chat_template_kwargs: {"thinking": true}
# 验证模型强制执行工具调用或返回错误
```

---

## 总结

### 可在本地 GPU 修复的 Issue
- **#16877** - Prometheus 解析（无需 GPU）⭐⭐
- **#17029** - Hermes/Qwen3 批处理 ⭐⭐⭐
- **#16781** - Gemma 4 通道标记 ⭐⭐⭐
- **#16738** - MiniMax M3 工具调用 ⭐⭐⭐

### 可在本地修复但无需 GPU 的 Issue
- **#17188** - 容器配置 ⭐
- **#17030** - 测试完善 ⭐⭐
- **#16958** - CI 检查 ⭐⭐

### 需要特殊环境的 Issue
- **#17248** - vLLM 死锁（需 2+ GPU）⭐⭐⭐⭐
- **#16895** - K8s operator（需 K8s 集群）⭐⭐⭐⭐
- **#17251** - RDMA 恢复（需多 GPU + RDMA）⭐⭐⭐⭐⭐

### 🚫 不修复
- **#17106** - Update bundled dependencies and image bases

---

## 工时估算

| 分类 | Issue 数量 | 总工时 |
|------|-----------|--------|
| 本地可修复（7 个） | 7 | 24-41 小时 |
| 需要特殊环境（3 个） | 3 | 62-116 小时 |
| **待修复 10 个 issue** | **10** | **86-157 小时** |

**推荐优先处理**: #17188（容器配置）→ #16877（Prometheus 解析）→ #17030（测试完善）→ #17029（Hermes/Qwen3 批处理）
