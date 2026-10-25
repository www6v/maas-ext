#!/bin/bash
# 构建 Dynamo vLLM 镜像（基于现有 vllm-local 镜像）
set -e

echo "=========================================="
echo "构建 Dynamo vLLM Runtime 镜像"
echo "=========================================="
echo ""

BASE_IMAGE="vllm-local:qwen3.5-4b"
TARGET_IMAGE="nvcr.io/nvidia/ai-dynamo/vllm-runtime:my-tag"
DYNAMO_ROOT="/home/wangwei/wei/workspacePy/maas/dynamo-main"

echo "基础镜像: $BASE_IMAGE"
echo "目标镜像: $TARGET_IMAGE"
echo ""

# 创建临时 Dockerfile
cat > /tmp/Dockerfile.dynamo-vllm <<'EOF'
FROM vllm-local:qwen3.5-4b

# 安装 Dynamo 依赖
RUN pip install --no-cache-dir \
    ai-dynamo-runtime==1.7.0 \
    ai-dynamo==1.7.0 \
    nixl \
    pyzmq \
    msgspec \
    kubernetes \
    prometheus_client

# 复制 dynamo 源码（用于 dynamo.vllm 模块）
COPY . /workspace/dynamo-source
WORKDIR /workspace/dynamo-source

# 安装 dynamo Python 包（editable mode）
RUN pip install --no-cache-dir -e . || true

# 设置环境变量
ENV PYTHONPATH=/workspace/dynamo-source/components/src:$PYTHONPATH
ENV DYNAMO_HOME=/workspace/dynamo-source

# 默认工作目录
WORKDIR /workspace

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD python -c "import dynamo; print('dynamo ok')" || exit 1

CMD ["bash"]
EOF

echo "构建镜像（这可能需要 10-20 分钟）..."
cd "$DYNAMO_ROOT"
docker build -t "$TARGET_IMAGE" -f /tmp/Dockerfile.dynamo-vllm . 2>&1 | tail -50

echo ""
echo "验证镜像..."
docker run --rm "$TARGET_IMAGE" python -c "import dynamo; print('Dynamo version:', dynamo.__version__)" 2>&1 | tail -5

echo ""
echo "✓ 镜像构建完成: $TARGET_IMAGE"
echo ""
echo "下一步: 加载到 minikube"
echo "  minikube image load $TARGET_IMAGE"
