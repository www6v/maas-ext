#!/bin/bash
# 安装 Docker 配置（数据目录迁移 + 代理 + NVIDIA runtime）

set -e

echo "=== 安装 Docker 配置 ==="

# 备份原配置
if [ -f /etc/docker/daemon.json ]; then
    sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
fi

# 安装 daemon.json
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sudo cp ${SCRIPT_DIR}/docker-daemon.json /etc/docker/daemon.json
echo "✓ 已更新 /etc/docker/daemon.json"

# 安装代理配置
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo cp ${SCRIPT_DIR}/docker-proxy.conf /etc/systemd/system/docker.service.d/proxy.conf
echo "✓ 已安装代理配置"

# 重新加载并重启 Docker
sudo systemctl daemon-reload
sudo systemctl restart docker
echo "✓ Docker 已重启"

# 验证
echo ""
echo "=== 验证配置 ==="
docker info | grep -E "Docker Root Dir|Storage Driver|Runtimes"
