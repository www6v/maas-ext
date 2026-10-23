#!/bin/bash
# 停止 vLLM 服务

PID_FILE="/tmp/vllm-qwen3.5-4b.pid"

if [ -f "${PID_FILE}" ]; then
    PID=$(cat ${PID_FILE})
    if kill -0 ${PID} 2>/dev/null; then
        echo "停止 vLLM 服务 (PID: ${PID})..."
        kill ${PID}
        sleep 3
        if kill -0 ${PID} 2>/dev/null; then
            echo "强制停止..."
            kill -9 ${PID}
        fi
        echo "✓ vLLM 服务已停止"
    else
        echo "vLLM 进程不存在"
    fi
    rm -f ${PID_FILE}
else
    echo "PID 文件不存在，尝试查找进程..."
    PIDS=$(ps aux | grep "vllm.entrypoints" | grep -v grep | awk '{print $2}')
    if [ -n "${PIDS}" ]; then
        echo "找到 vLLM 进程: ${PIDS}"
        kill ${PIDS}
        echo "✓ 已发送停止信号"
    else
        echo "未找到 vLLM 进程"
    fi
fi
