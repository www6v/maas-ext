#!/bin/bash
# 从 ModelScope 下载 Qwen3.5-4B 模型
# 注意：HuggingFace 在国内无法访问，使用 ModelScope 镜像

set -e

MODEL_DIR="/data/models"
MODEL_ID="Qwen/Qwen3.5-4B"

echo "=== 创建模型目录 ==="
sudo mkdir -p ${MODEL_DIR}
sudo chown -R ${USER}:${USER} ${MODEL_DIR}

echo "=== 检查 modelscope 是否已安装 ==="
if ! python3 -c "import modelscope" 2>/dev/null; then
    echo "安装 modelscope..."
    python3 -m pip install modelscope -i https://pypi.tuna.tsinghua.edu.cn/simple
fi

echo "=== 下载模型 ${MODEL_ID} ==="
python3 << PYEOF
from modelscope import snapshot_download
import os

os.environ['MODELSCOPE_CACHE'] = '${MODEL_DIR}'

model_dir = snapshot_download(
    '${MODEL_ID}',
    cache_dir='${MODEL_DIR}',
    revision='master'
)

print(f"✓ 模型下载到: {model_dir}")
PYEOF

echo "=== 验证模型文件 ==="
ls -lh ${MODEL_DIR}/models/Qwen--Qwen3.5-4B/snapshots/master/
du -sh ${MODEL_DIR}/models/Qwen--Qwen3.5-4B/

echo "✓ 模型下载完成！"
