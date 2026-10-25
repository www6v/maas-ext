#!/bin/bash
# 启动 vLLM OpenAI 兼容 API 服务器
# 使用 Qwen3.5-4B 模型

set -e

MODEL_PATH="/data/models/models/Qwen--Qwen3.5-4B/snapshots/master"
LOG_FILE="/tmp/vllm-qwen3.5-4b.log"
PID_FILE="/tmp/vllm-qwen3.5-4b.pid"

# 参数配置
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.9}"
DTYPE="${DTYPE:-auto}"
MODEL_NAME="${MODEL_NAME:-qwen3.5-4b}"

echo "=== vLLM 启动配置 ==="
echo "模型路径: ${MODEL_PATH}"
echo "服务名称: ${MODEL_NAME}"
echo "监听地址: ${HOST}:${PORT}"
echo "GPU 内存利用率: ${GPU_MEM_UTIL}"
echo "数据类型: ${DTYPE}"
echo "日志文件: ${LOG_FILE}"
echo ""

# 检查模型是否存在
if [ ! -d "${MODEL_PATH}" ]; then
    echo "✗ 模型目录不存在: ${MODEL_PATH}"
    echo "请先运行 02-download-model.sh 下载模型"
    exit 1
fi

# 停止已有的 vLLM 进程
if [ -f "${PID_FILE}" ]; then
    OLD_PID=$(cat ${PID_FILE})
    if kill -0 ${OLD_PID} 2>/dev/null; then
        echo "=== 停止旧的 vLLM 进程 (PID: ${OLD_PID}) ==="
        kill ${OLD_PID}
        sleep 3
    fi
    rm -f ${PID_FILE}
fi

# 也检查端口占用
if ss -tlnp | grep -q ":${PORT} "; then
    echo "⚠ 端口 ${PORT} 已被占用，尝试清理..."
    fuser -k ${PORT}/tcp 2>/dev/null || true
    sleep 2
fi

echo "=== 启动 vLLM 服务 ==="
nohup python3.13 -m vllm.entrypoints.openai.api_server \
    --model ${MODEL_PATH} \
    --served-model-name ${MODEL_NAME} \
    --host ${HOST} \
    --port ${PORT} \
    --trust-remote-code \
    --dtype ${DTYPE} \
    --gpu-memory-utilization ${GPU_MEM_UTIL} \
    > ${LOG_FILE} 2>&1 &

VLLM_PID=$!
echo ${VLLM_PID} > ${PID_FILE}
echo "vLLM 启动中... PID: ${VLLM_PID}"

# 等待服务就绪
echo "=== 等待 vLLM 服务就绪 ==="
for i in $(seq 1 60); do
    # 检查进程是否还活着
    if ! kill -0 ${VLLM_PID} 2>/dev/null; then
        echo "✗ vLLM 进程已退出"
        echo "=== 错误日志 ==="
        tail -50 ${LOG_FILE}
        exit 1
    fi

    # 检查 API 是否就绪
    if curl -s http://localhost:${PORT}/health > /dev/null 2>&1; then
        echo "✓ vLLM 服务已就绪！"
        break
    fi

    sleep 2
    echo "  等待中... ($((i*2))s)"
done

# 最终检查
if ! curl -s http://localhost:${PORT}/health > /dev/null 2>&1; then
    echo "✗ vLLM 服务启动超时"
    echo "=== 最近日志 ==="
    tail -30 ${LOG_FILE}
    exit 1
fi

echo ""
echo "=== 测试 API ==="
echo "模型列表:"
curl -s http://localhost:${PORT}/v1/models | python3 -m json.tool

echo ""
echo "✓ vLLM 服务启动成功！"
echo ""
echo "使用示例:"
echo "  curl http://localhost:${PORT}/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\": \"${MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"你好\"}]}'"
echo ""
echo "停止服务: kill \$(cat ${PID_FILE})"
echo "查看日志: tail -f ${LOG_FILE}"
