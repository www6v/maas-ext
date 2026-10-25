# Issue #17030 分析与修复方案

## 问题概述

**Issue**: test(frontend): complete native argument-streaming qualification  
**关联 PR**: #16822 (feat(frontend): default to V2 parsers when available)

### 核心问题

PR #16822 将默认解析器从 V1 切换到 V2（当可用时），但暴露了原生参数流式传输的 qualification gaps：

- **30/32 个原生早期参数检查失败**
- **所有 32 个最终结果正确**
- 问题在于"早期参数传递"（early argument delivery）

## 技术背景

### 解析器架构

```
dynamo-parsers-v2 (外部 crate, v0.7.24)
    ↓
unified_parser.rs (适配器层)
    ↓
ChoiceState (流式状态管理)
    ↓
OpenAI 兼容的流式输出
```

### 测试结构

测试文件：`lib/llm/src/protocols/openai/chat_completions/unified_parser.rs`

1. **`eight_family_native_argument_progress_matrix`** (第 10025 行)
   - 被 `#[ignore]` 标记
   - 测试 8 个模型族的原生参数进度
   - 调用 `argument_progress_matrix(false)`

2. **`native_progress`** (第 10566 行，每个族一个)
   - 被 `#[ignore]` 标记
   - 测试早期参数传递
   - 调用 `family_native_progress_and_exact_arguments($family, true)`

3. **`complete_native_arguments`** (第 10561 行，每个族一个)
   - **未被忽略**
   - 测试完整参数正确性
   - 调用 `family_native_progress_and_exact_arguments($family, false)`

### 测试逻辑

```rust
async fn family_native_progress_and_exact_arguments(selected: &str, require_early: bool) {
    // 1. 创建解析器状态
    let mut state = ChoiceState::new(...);
    
    // 2. 推送部分输入（到 " END" 之前）
    let events = state.push(&input[..stop]);
    let early = state.choices_for(...);
    
    // 3. 如果 require_early=true，检查早期传递
    if require_early {
        // 检查是否能看到工具名称
        assert!(early.iter()...any(|c| c.function.name == "write_file"));
        // 检查是否能看到部分参数
        assert!(early.iter()...any(|c| c.function.arguments.contains("long content")));
    }
    
    // 4. 继续推送剩余输入并验证最终结果
    // ... 这部分总是通过的
}
```

## 根因分析

### Cargo.toml 注释线索

```toml
# Native count-before-string early streaming still needs a frontend-crates fix.
dynamo-parsers-v2 = { version = "=0.7.24" }
```

这表明：
1. `dynamo-parsers-v2` v0.7.24 可能不支持"count-before-string"的早期流式传输
2. 需要在前端 crates（`unified_parser.rs`）中修复

### 问题本质

**"count-before-string"场景**：
```json
{"count": 2, "content": "long content..."}
```

当解析器看到 `"count": 2` 时，它知道：
- 工具名称（如果已经解析到 `