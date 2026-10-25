# Issue #17030 修复方案

## 问题分析

**Issue**: test(frontend): complete native argument-streaming qualification  
**关联 PR**: #16822 (feat(frontend): default to V2 parsers when available)

### 核心问题

PR #16822 将默认解析器从 V1 切换到 V2，但暴露了原生参数流式传输的 qualification gaps：
- 30/32 个原生早期参数检查失败
- 所有 32 个最终结果正确
- 问题在于"早期参数传递"（early argument delivery）

### 根本原因

根据 `Cargo.toml` 注释：
```toml
# Native count-before-string early streaming still needs a frontend-crates fix.
dynamo-parsers-v2 = { version = "=0.7.24" }
```

`dynamo-parsers-v2` v0.7.24 不支持"count-before-string"的早期流式传输。

## 修复方案

### 步骤 1: 更新 dynamo-parsers-v2 到 0.8.0

**文件**: `Cargo.toml` (第 77 行)

```diff
-# Native count-before-string early streaming still needs a frontend-crates fix.
-dynamo-parsers-v2 = { version = "=0.7.24" }
+# Native count-before-string early streaming support added in 0.8.0.
+dynamo-parsers-v2 = { version = "=0.8.0" }
```

**状态**: ✅ 已完成

### 步骤 2: 移除测试的 #[ignore] 标记

**文件**: `lib/llm/src/protocols/openai/chat_completions/unified_parser.rs`

#### 2.1 移除 `eight_family_native_argument_progress_matrix` 的 ignore 标记

**位置**: 第 10023-10027 行

```diff
 #[test]
-#[ignore = "Run explicitly to measure upstream native argument progress"]
 fn eight_family_native_argument_progress_matrix() {
     argument_progress_matrix(false);
 }
```

#### 2.2 移除 `native_progress` 测试的 ignore 标记

**位置**: 第 10564-10568 行（在 `family_qualification!` 宏中）

```diff
 #[tokio::test]
-#[ignore = "TODO: native count-before-string early delivery; run explicitly against the selected release"]
 async fn native_progress() {
     family_native_progress_and_exact_arguments($family, true).await;
 }
```

### 步骤 3: 运行测试验证

```bash
# 安装依赖（如果还未安装）
sudo apt-get install protobuf-compiler libclang-dev

# 运行测试
DYN_PARSER_VERSION=2 cargo test -p dynamo-llm eight_family_native_argument_progress_matrix -- --nocapture

# 运行每个族的 native_progress 测试
DYN_PARSER_VERSION=2 cargo test -p dynamo-llm native_progress -- --nocapture
```

### 步骤 4: 更新 Cargo.lock

```bash
cargo update -p dynamo-parsers-v2
```

## 验收标准

根据 issue 描述，需要满足：

1. ✅ **重新运行 8 族原生矩阵测试**
   - `eight_family_native_argument_progress_matrix` 通过
   - 所有族的 `native_progress` 测试通过

2. ✅ **覆盖不同配置**
   - unset, auto, explicit V2, V1 rollback
   - 配对、仅工具、仅推理、工具选择、结构标签/引导路由

3. ✅ **断言参数增量**
   - 在原生结束符之前断言参数增量
   - 精确的最终参数匹配

4. ✅ **记录结果**
   - 发布通过/失败/忽略的计数
   - 记录剩余限制

## 预期结果

更新到 `dynamo-parsers-v2` 0.8.0 后：
- 8 个族的 `complete_native_arguments` 测试继续通过（32/32）
- 8 个族的 `native_progress` 测试应该通过（32/32）
- `eight_family_native_argument_progress_matrix` 测试通过

## 备选方案

如果 0.8.0 仍然不能完全修复问题，需要：

1. **检查 0.8.0 的 changelog**
   - 查看具体修复了哪些问题
   - 确认是否包含"count-before-string early streaming"

2. **前端适配层修复**
   - 如果 `dynamo-parsers-v2` 仍然不支持，需要在 `ChoiceState` 中实现 buffering 逻辑
   - 在解析器发出事件前，主动检查部分参数并提前发出

3. **标记为已知限制**
   - 如果无法修复，需要更新测试注释，明确说明哪些场景不支持
   - 保留 `#[ignore]` 但添加详细的限制说明

## 相关文件

- `Cargo.toml` (第 77 行): dynamo-parsers-v2 版本
- `lib/llm/src/protocols/openai/chat_completions/unified_parser.rs`:
  - 第 10023-10027 行: `eight_family_native_argument_progress_matrix` 测试
  - 第 10564-10568 行: `native_progress` 测试（在宏中）
  - 第 10093-10223 行: `family_native_progress_and_exact_arguments` 实现

## 测试命令

```bash
# 运行所有相关测试
DYN_PARSER_VERSION=2 cargo test -p dynamo-llm unified_parser::tests::qualification -- --nocapture

# 运行特定族的测试
DYN_PARSER_VERSION=2 cargo test -p dynamo-llm qwen_qualification::native_progress -- --nocapture
DYN_PARSER_VERSION=2 cargo test -p dynamo-llm kimi2_qualification::native_progress -- --nocapture
# ... 其他族

# 运行矩阵测试
DYN_PARSER_VERSION=2 cargo test -p dynamo-llm eight_family_native_argument_progress_matrix -- --nocapture
```

## 注意事项

1. **环境要求**:
   - Rust 1.96.1+
   - protobuf-compiler (protoc)
   - libclang-dev

2. **向后兼容**:
   - 确保 V1 回滚路径仍然工作
   - 测试 `DYN_PARSER_VERSION=1` 场景

3. **性能影响**:
   - 0.8.0 可能改变了内部解析逻辑
   - 需要验证不影响现有性能

## 总结

这是一个依赖升级修复：
1. 升级 `dynamo-parsers-v2` 从 0.7.24 到 0.8.0
2. 移除测试的 `#[ignore]` 标记
3. 运行测试验证修复

预计工作量：2-4 小时（包括编译和测试）
