#!/bin/bash
# 测试 vLLM API

API_URL="${API_URL:-http://localhost:8000}"
MODEL_NAME="${MODEL_NAME:-qwen3.5-4b}"

echo "=== 测试 vLLM API ==="
echo "API URL: ${API_URL}"
echo "Model: ${MODEL_NAME}"
echo ""

# 健康检查
echo "1. 健康检查..."
if curl -s ${API_URL}/health > /dev/null 2>&1; then
    echo "   ✓ 服务健康"
else
    echo "   ✗ 服务不可用"
    exit 1
fi

# 模型列表
echo ""
echo "2. 模型列表..."
curl -s ${API_URL}/v1/models | python3 -m json.tool

# 简单推理测试
echo ""
echo "3. 推理测试..."
RESPONSE=$(curl -s ${API_URL}/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [
            {\"role\": \"user\", \"content\": \"你好，请用一句话介绍自己\"}
        ],
        \"max_tokens\": 100,
        \"temperature\": 0.7
    }")

echo "响应:"
echo "${RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    content = d['choices'][0]['message']['content']
    usage = d.get('usage', {})
    print(f'回复: {content}')
    print(f'Token 使用: prompt={usage.get(\"prompt_tokens\", \"?\")}, completion={usage.get(\"completion_tokens\", \"?\")}, total={usage.get(\"total_tokens\", \"?\")}')
except Exception as e:
    print(f'解析失败: {e}')
    print(sys.stdin.read() if hasattr(sys.stdin, 'read') else '')
"

echo ""
echo "✓ 测试完成"
