# syntax=docker/dockerfile:1.4
# 最小化 Dynamo vLLM Runtime 镜像
FROM python:3.11-slim

# 使用代理
ARG HTTP_PROXY=http://127.0.0.1:7897
ARG HTTPS_PROXY=http://127.0.0.1:7897
ENV HTTP_PROXY=$HTTP_PROXY
ENV HTTPS_PROXY=$HTTPS_PROXY
ENV HOSTNAME_SOURCES="none"

# 安装系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# 升级 pip
RUN pip install --upgrade pip setuptools wheel

# 安装 vLLM (CPU-only 版本用于测试)
RUN pip install --no-cache-dir vllm==0.6.3

# 安装 Dynamo
RUN pip install --no-cache-dir \
    ai-dynamo-runtime \
    ai-dynamo \
    nixl \
    pyzmq \
    msgspec \
    kubernetes \
    prometheus_client

# 安装 HuggingFace 工具
RUN pip install --no-cache-dir huggingface_hub

# 创建工作目录
WORKDIR /workspace

# 验证安装
RUN python -c "import vllm; print('vLLM:', vllm.__version__)" && \
    python -c "import dynamo; print('Dynamo:', dynamo.__version__)" && \
    echo "✓ All modules installed"

# 默认命令
CMD ["bash"]
