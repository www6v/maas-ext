#!/bin/bash
# 一键部署脚本 - AIBrix + vLLM + Qwen3.5-4B
# 在单机 Minikube 上部署完整的推理服务

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo "  AIBrix + vLLM + Qwen3.5-4B 一键部署"
echo "=========================================="
echo ""
echo "部署步骤:"
echo "  1. 设置 Minikube 集群（带 GPU 支持）"
echo "  2. 从 ModelScope 下载 Qwen3.5-4B 模型"
echo "  3. 启动 vLLM 推理服务"
echo "  4. 部署 AIBrix 控制面"
echo ""

read -p "是否继续？(y/N) " confirm
if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
    echo "取消部署"
    exit 0
fi

echo ""
echo "=== Step 1/4: 设置 Minikube 集群 ==="
${SCRIPT_DIR}/01-setup-minikube.sh

echo ""
echo "=== Step 2/4: 下载模型 ==="
${SCRIPT_DIR}/02-download-model.sh

echo ""
echo "=== Step 3/4: 启动 vLLM 服务 ==="
${SCRIPT_DIR}/03-start-vllm.sh

echo ""
echo "=== Step 4/4: 部署 AIBrix ==="
${SCRIPT_DIR}/04-deploy-aibrix.sh

echo ""
echo "=========================================="
echo "  ✓ 部署完成！"
echo "=========================================="
echo ""
echo "vLLM API 地址: http://localhost:8000"
echo ""
echo "测试命令:"
echo '  curl http://localhost:8000/v1/chat/completions \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '"'"'{"model": "qwen3.5-4b", "messages": [{"role": "user", "content": "你好"}]}'"'"''
echo ""
echo "查看状态: ${SCRIPT_DIR}/status.sh"
echo "停止 vLLM: ${SCRIPT_DIR}/stop-vllm.sh"
