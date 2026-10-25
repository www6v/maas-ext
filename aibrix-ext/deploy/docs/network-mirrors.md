# 网络镜像配置指南

## 问题背景

在中国大陆环境中，Docker Hub 和 GitHub 的直接访问经常受到限制，导致：
- 无法拉取 Docker 基础镜像（python, golang, ubuntu 等）
- 无法 git clone GitHub 仓库
- 构建 Docker 镜像时失败

## 解决方案

### 1. Docker Hub 镜像加速

#### 配置中国镜像源

编辑 `/etc/docker/daemon.json`：

```json
{
  "data-root": "/data/docker",
  "storage-driver": "overlay2",
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerhub.azk8s.cn",
    "https://hub-mirror.c.163.com"
  ]
}
```

**重要**：如果之前配置了代理（HTTP_PROXY/HTTPS_PROXY），需要移除或确保代理可用。

#### 移除代理配置

如果 Docker 配置了不可用的代理，会导致所有拉取失败：

```bash
# 检查代理配置
cat /etc/systemd/system/docker.service.d/proxy.conf

# 备份并移除
sudo mv /etc/systemd/system/docker.service.d/proxy.conf \
        /etc/systemd/system/docker.service.d/proxy.conf.bak

# 重新加载并重启
sudo systemctl daemon-reload
sudo systemctl restart docker
```

#### 验证镜像拉取

```bash
# 测试拉取基础镜像
docker pull python:3.11-slim-bookworm
docker pull golang:1.21-bookworm
docker pull ubuntu:22.04
docker pull nvidia/cuda:12.1.1-base-ubuntu22.04
docker pull redis:7-alpine
```

#### 可用的中国镜像源

| 镜像源 | URL | 状态 |
|--------|-----|------|
| DaoCloud | `https://docker.m.daocloud.io` | ✅ 稳定 |
| Azure China | `https://dockerhub.azk8s.cn` | ✅ 可用 |
| 163 | `https://hub-mirror.c.163.com` | ⚠️ 偶尔慢 |
| 阿里云 | `https://<your-id>.mirror.aliyuncs.com` | ✅ 需注册 |

#### 显式使用镜像源

如果默认镜像源仍然慢，可以显式指定：

```bash
# 方式 1: 直接拉取镜像站的镜像
docker pull docker.m.daocloud.io/library/python:3.11-slim-bookworm
docker tag docker.m.daocloud.io/library/python:3.11-slim-bookworm python:3.11-slim-bookworm

# 方式 2: 在 Dockerfile 中使用
FROM docker.m.daocloud.io/library/python:3.11-slim-bookworm
```

### 2. GitHub 访问

#### 当前状态（2026-09-30）

| 访问方式 | 状态 | 说明 |
|---------|------|------|
| GitHub API | ✅ 可用 | `https://api.github.com` |
| GitHub Git Clone | ❌ 超时 | 直接 clone 被限制 |
| raw.githubusercontent.com | ⚠️ 部分可用 | HTTP 301 重定向 |

#### GitHub 镜像（测试结果）

| 镜像 | URL | 状态 |
|------|-----|------|
| ghproxy.com | `https://ghproxy.com/https://github.com/...` | ❌ 超时 |
| gitclone.com | `https://gitclone.com/github.com/...` | ❌ 502 错误 |
| hub.fastgit.xyz | `https://hub.fastgit.xyz/...` | ❌ 超时 |
| kkgithub.com | `https://kkgithub.com/...` | ❌ SSL 错误 |

**结论**：当前 GitHub 镜像大多不可用。

#### 替代方案

**方案 1: 使用本地已克隆的源码**

AIBrix 源码已克隆到本地：
```bash
/home/wangwei/wei/workspacePy/maas/aibrix/
```

直接从本地构建，无需再次 clone。

**方案 2: 使用 Gitee 镜像**

部分热门项目已同步到 Gitee：
```bash
# 检查 Gitee 是否有镜像
git clone https://gitee.com/<username>/aibrix.git
```

**方案 3: 配置 Git 代理**

如果有可用的代理服务器：
```bash
git config --global http.proxy http://127.0.0.1:7897
git config --global https.proxy http://127.0.0.1:7897
```

### 3. Python/Go 包管理

#### Python pip 使用清华镜像

```bash
# 临时使用
pip install <package> -i https://pypi.tuna.tsinghua.edu.cn/simple

# 永久配置
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

在 Dockerfile 中：
```dockerfile
RUN pip install --no-cache-dir \
    -i https://pypi.tuna.tsinghua.edu.cn/simple \
    torch torchvision torchaudio \
    vllm==0.28.0
```

#### Go 模块使用中国代理

```bash
# 设置环境变量
export GOPROXY=https://goproxy.cn,direct

# 或在 go.mod 中配置
# 不需要额外配置，GOPROXY 会自动生效
```

在 Dockerfile 中：
```dockerfile
ENV GOPROXY=https://goproxy.cn,direct
RUN go mod download
```

Go 模块缓存已存在：
```bash
~/go/pkg/mod/
```

### 4. AIBrix 构建流程

由于源码和依赖都已本地化，构建流程如下：

```bash
# 1. 进入 AIBrix 源码目录
cd /home/wangwei/wei/workspacePy/maas/aibrix

# 2. 构建 controller-manager（Go）
make build-manager
# 输出: bin/manager

# 3. 构建 Docker 镜像（使用本地基础镜像）
docker build -t aibrix/controller-manager:v0.7.0 \
  -f build/Dockerfile .

# 4. 构建 gateway-plugin（Go）
cd apps/gateway-plugin
go build -o ../../bin/gateway-plugin .

# 5. 构建 metadata-service（Python）
cd ../../python/metadata-service
poetry build
```

### 5. 网络问题排查

#### Docker 拉取失败

```bash
# 检查 Docker 日志
sudo journalctl -u docker -n 50 --no-pager

# 检查网络连接
curl -v https://docker.m.daocloud.io/v2/

# 检查 DNS
nslookup docker.m.daocloud.io

# 检查代理配置
env | grep -i proxy
docker info | grep -i proxy
```

#### Git Clone 超时

```bash
# 测试 GitHub 连通性
timeout 10 git ls-remote https://github.com/vllm-project/aibrix.git HEAD

# 检查 Git 配置
git config --global --list | grep proxy

# 使用 SSH 代替 HTTPS（如果有 SSH key）
git clone git@github.com:vllm-project/aibrix.git
```

#### pip 安装慢

```bash
# 测试镜像源连通性
curl -v https://pypi.tuna.tsinghua.edu.cn/simple/

# 切换镜像源
pip config set global.index-url https://pypi.org/simple
```

## 总结

### ✅ 已解决的问题

1. **Docker Hub 访问**: 通过配置中国镜像源（docker.m.daocloud.io）解决
2. **关键前提**: 移除不可用的代理配置（HTTP_PROXY/HTTPS_PROXY）
3. **Python 包**: 使用清华镜像（pypi.tuna.tsinghua.edu.cn）
4. **Go 模块**: 使用 goproxy.cn，且模块已缓存到本地
5. **GitHub 源码**: 已克隆到本地，无需再次 clone

### ⚠️ 仍需注意

1. **GitHub 直接访问**: 仍然不可用，但本地已有源码
2. **代理配置**: 如果有可用的代理（如 Clash），可以重新配置
3. **镜像源稳定性**: 中国镜像源可能偶尔不稳定，建议配置多个

### 📝 最佳实践

1. **优先使用本地资源**: 源码、模型文件、Go 模块缓存
2. **配置多个镜像源**: Docker、pip、Go 都配置备用源
3. **定期检查连通性**: 在构建前测试镜像源可用性
4. **避免代理冲突**: 确保代理配置与实际可用代理一致

## 参考链接

- [Docker 镜像加速](https://github.com/dongyubin/DockerHub)
- [清华 PyPI 镜像](https://mirrors.tuna.tsinghua.edu.cn/help/pypi/)
- [Go 模块代理](https://goproxy.cn/)
- [DaoCloud 镜像站](https://github.com/daocloud/docker-register)
