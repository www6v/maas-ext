# AIBrix 部署故障排除指南

本文档记录了在 AIBrix 集群部署过程中遇到的所有问题及其解决方案。

---

## 目录

1. [网络与镜像拉取问题](#1-网络与镜像拉取问题)
2. [Docker 配置问题](#2-docker-配置问题)
3. [Minikube 集群问题](#3-minikube-集群问题)
4. [GPU 相关问题](#4-gpu-相关问题)
5. [vLLM 部署问题](#5-vllm-部署问题)
6. [AIBrix 组件问题](#6-aibrix-组件问题)

---

## 1. 网络与镜像拉取问题

### 1.1 Docker Hub 无法访问

**问题描述：**
```
Error response from daemon: Get "https://registry-1.docker.io/v2/": EOF
```

**原因：**
中国大陆无法直接访问 Docker Hub 官方镜像仓库。

**解决方案：**

#### 方案 A：使用中国镜像源（推荐）

配置 Docker daemon 使用中国镜像源：

```json
{
    "data-root": "/data/docker",
    "storage-driver": "overlay2",
    "registry-mirrors": [
        "https://docker.m.daocloud.io",
        "https://dockerhub.azk8s.cn"
    ]
}
```

保存为 `/etc/docker/daemon.json`，然后重启 Docker：
```bash
sudo systemctl restart docker
```

#### 方案 B：使用 skopeo 工具下载镜像

当 Docker pull 失败时，可以使用 skopeo 工具手动下载镜像：

```bash
# 安装 skopeo
sudo apt-get install skopeo

# 下载镜像到 tar 文件
skopeo copy \
  docker://docker.m.daocloud.io/library/python:3.11-slim-bookworm \
  docker-archive:/tmp/python311-slim.tar:python:3.11-slim-bookworm

# 加载到 Docker
docker load -i /tmp/python311-slim.tar
```

**验证：**
```bash
docker images | grep python
```

---

### 1.2 中国镜像源不稳定

**问题描述：**
```
error pulling image configuration: download failed after attempts=6: EOF
```

**原因：**
部分中国镜像源不稳定，大镜像下载容易中断。

**解决方案：**

使用多个镜像源并配置 insecure-registries：

```json
{
    "data-root": "/data/docker",
    "storage-driver": "overlay2",
    "registry-mirrors": [
        "https://docker.m.daocloud.io",
        "https://dockerhub.azk8s.cn"
    ],
    "insecure-registries": [
        "docker.m.daocloud.io",
        "docker.1panel.live",
        "hub.rat.dev"
    ]
}
```

**测试镜像源连通性：**
```bash
# 测试镜像源
curl -s -o /dev/null -w "%{http_code}" https://docker.m.daocloud.io/v2/
# 应该返回 401（需要认证）或 200
```

---

### 1.3 代理配置问题

**问题描述：**
```
curl: (35) error:0A000126:SSL routines::unexpected eof while reading
```

**原因：**
代理服务器（如 Clash）配置不当或 TLS 握手失败。

**解决方案：**

#### 检查代理状态
```bash
# 检查代理是否运行
ss -tlnp | grep 7897

# 测试代理连通性
curl -x http://127.0.0.1:7897 -v --connect-timeout 5 https://registry-1.docker.io/v2/
```

#### 配置 Docker 使用代理

创建 `/etc/systemd/system/docker.service.d/http-proxy.conf`：
```ini
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7897"
Environment="HTTPS_PROXY=http://127.0.0.1:7897"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
```

然后重启 Docker：
```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```

#### 验证代理配置
```bash
docker info | grep -i proxy
```

---

## 2. Docker 配置问题

### 2.1 Docker 数据目录迁移

**问题描述：**
需要将 Docker 数据目录从默认的 `/var/lib/docker` 迁移到 `/data/docker`。

**解决方案：**

```bash
# 1. 停止 Docker 服务
sudo systemctl stop docker

# 2. 迁移现有数据（可选）
sudo rsync -avz /var/lib/docker/ /data/docker/

# 3. 配置 Docker daemon
# 在 /etc/docker/daemon.json 中添加：
# "data-root": "/data/docker"

# 4. 重启 Docker
sudo systemctl start docker

# 5. 验证
docker info | grep "Docker Root Dir"
```

**注意事项：**
- 确保 `/data` 分区有足够的空间（建议至少 100GB）
- 迁移前备份重要数据
- 检查磁盘权限

---

### 2.2 Docker API 版本不兼容

**问题描述：**
```
client version 1.41 is too old. Minimum supported API version is 1.44
```

**原因：**
skopeo 或其他工具使用的 Docker API 版本过旧。

**解决方案：**

升级 Docker 到最新版本（20.10+）。

---

## 3. Minikube 集群问题

### 3.1 Minikube 启动失败（GPU 标志错误）

**问题描述：**
```
X 因 MK_USAGE 错误而退出：The gpus flag can only be used with the docker driver and docker container-runtime
```

**原因：**
GPU 支持需要使用 Docker 容器运行时，不能使用 containerd。

**解决方案：**

使用正确的启动参数：

```bash
# 正确的方式（使用 docker 运行时）
minikube start \
    --driver=docker \
    --container-runtime=docker \
    --gpus=all \
    --cpus=8 \
    --memory=16g \
    --disk-size=50g

# 错误的方式（containerd 不支持 --gpus 标志）
minikube start \
    --driver=docker \
    --container-runtime=containerd \
    --gpus=all  # 这会失败
```

---

### 3.2 Minikube 预加载镜像下载缓慢

**问题描述：**
Minikube 启动时下载预加载镜像非常缓慢（几 KB/s）。

**原因：**
从 GitHub 下载预加载镜像，国内网络访问 GitHub 不稳定。

**解决方案：**

#### 方案 A：使用已缓存的镜像

```bash
# 查看已缓存的镜像
ls -lh ~/.minikube/cache/preloaded-tarball/

# 使用已缓存的版本
minikube start --kubernetes-version=v1.28.0
```

#### 方案 B：手动下载预加载镜像

```bash
# 下载预加载镜像（使用代理）
export https_proxy=http://127.0.0.1:7897
wget -O ~/.minikube/cache/preloaded-tarball/preloaded-images-k8s-v18-v1.28.0-docker-overlay2-amd64.tar.lz4 \
  https://github.com/kubernetes-sigs/minikube-preloads/releases/download/v18/preloaded-images-k8s-v18-v1.28.0-docker-overlay2-amd64.tar.lz4
```

#### 方案 C：跳过预加载

```bash
minikube start --preload=false
```

---

### 3.3 Minikube 集群状态异常

**问题描述：**
```
minikube
type: Control Plane
host: Stopped
kubelet: Stopped
apiserver: Stopped
```

**解决方案：**

```bash
# 启动 Minikube
minikube start

# 如果启动失败，删除并重建
minikube delete
minikube start --driver=docker --container-runtime=docker --gpus=all

# 检查状态
minikube status

# 查看日志
minikube logs
```

---

## 4. GPU 相关问题

### 4.1 NVIDIA Device Plugin 启动失败

**问题描述：**
```
Detected non-NVML platform: could not load NVML library: libnvidia-ml.so.1: cannot open shared object file: No such file or directory
Incompatible platform detected
```

**原因：**
Minikube 容器无法访问宿主机的 NVIDIA 驱动。

**解决方案：**

#### 确保使用 Docker 运行时并启用 GPU

```bash
# 1. 删除现有集群
minikube delete

# 2. 使用 docker 运行时重新启动
minikube start \
    --driver=docker \
    --container-runtime=docker \
    --gpus=all \
    --cpus=8 \
    --memory=16g

# 3. 验证 GPU 可用
kubectl describe node minikube | grep -A 5 "Capacity:" | grep nvidia
```

#### 安装 NVIDIA Container Toolkit

```bash
# 添加 NVIDIA 仓库
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list

# 安装
sudo apt-get update
sudo apt-get install -y nvidia-docker2

# 重启 Docker
sudo systemctl restart docker
```

---

### 4.2 Pod 无法调度到 GPU 节点

**问题描述：**
```
0/1 nodes are available: 1 Insufficient nvidia.com/gpu
```

**原因：**
NVIDIA Device Plugin 未正确部署或 GPU 资源未被识别。

**解决方案：**

```bash
# 1. 部署 NVIDIA Device Plugin
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.1/deployments/static/nvidia-device-plugin.yml

# 2. 等待 Pod 就绪
kubectl wait --for=condition=ready pod -l app=nvidia-device-plugin -n kube-system --timeout=300s

# 3. 检查 GPU 资源
kubectl describe node minikube | grep -A 10 "Capacity:" | grep nvidia

# 4. 如果仍不可用，重启 Device Plugin
kubectl delete pod -n kube-system -l app=nvidia-device-plugin
```

**本地部署 NVIDIA Device Plugin：**

如果无法从 GitHub 下载，可以使用本地 manifest（见 `deploy/manifests/nvidia-device-plugin.yaml`）。

---

## 5. vLLM 部署问题

### 5.1 vLLM 镜像构建失败

**问题描述：**
```
ERROR: Could not find a version that satisfies the requirement vllm==0.28.0
```

**原因：**
PyPI 源访问不稳定或版本不存在。

**解决方案：**

使用清华镜像源构建 Dockerfile：

```dockerfile
FROM nvidia/cuda:12.1.1-base-ubuntu22.04

# 使用中国 Ubuntu 镜像
RUN sed -i 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list

# 安装 Python 3.11
RUN apt-get update && apt-get install -y \
    software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y python3.11 python3.11-dev python3.11-venv

# 使用清华 PyPI 镜像
RUN python3.11 -m pip install --upgrade pip \
    -i https://pypi.tuna.tsinghua.edu.cn/simple

# 安装 vLLM
RUN python3.11 -m pip install --no-cache-dir \
    -i https://pypi.tuna.tsinghua.edu.cn/simple \
    --extra-index-url https://download.pytorch.org/whl/cu121 \
    torch torchvision torchaudio \
    vllm==0.28.0
```

**构建命令：**
```bash
docker build -f Dockerfile.vllm -t vllm-local:qwen3.5-4b .
```

---

### 5.2 vLLM Pod 启动失败

**问题描述：**
```
CrashLoopBackOff
Error: CUDA out of memory
```

**原因：**
GPU 显存不足或模型路径配置错误。

**解决方案：**

#### 调整 GPU 显存使用率

```yaml
spec:
  containers:
  - name: vllm
    args:
    - "--model"
    - "/models/Qwen--Qwen3.5-4B"
    - "--gpu-memory-utilization"
    - "0.90"
    - "--max-model-len"
    - "8192"
```

#### 检查模型路径

```bash
# 确保模型文件存在
ls -lh /data/models/models/Qwen--Qwen3.5-4B/

# 检查 Pod 日志
kubectl logs <pod-name> | tail -50

# 进入 Pod 检查
kubectl exec -it <pod-name> -- ls -lh /models/
```

---

### 5.3 vLLM 镜像导入 Minikube 失败

**问题描述：**
```
Error response from daemon: Get "https://registry-1.docker.io/v2/": EOF
```

**原因：**
Minikube 内部 Docker daemon 无法访问外部镜像仓库。

**解决方案：**

手动导入镜像到 Minikube：

```bash
# 1. 保存镜像到 tar
docker save vllm-local:qwen3.5-4b -o /tmp/vllm-image.tar

# 2. 导入到 Minikube
docker load < /tmp/vllm-image.tar

# 或者使用 minikube 命令
minikube image load vllm-local:qwen3.5-4b

# 3. 验证镜像存在
eval $(minikube docker-env)
docker images | grep vllm-local
```

**在 Deployment 中使用本地镜像：**
```yaml
spec:
  containers:
  - name: vllm
    image: vllm-local:qwen3.5-4b
    imagePullPolicy: IfNotPresent
```

---

## 6. AIBrix 组件问题

### 6.1 Controller Manager 启动失败

**问题描述：**
```
Error: failed to create manager: unable to find leader election namespace
```

**原因：**
AIBrix controller-manager 需要正确的 RBAC 配置和命名空间。

**解决方案：**

```bash
# 1. 创建命名空间
kubectl create namespace aibrix-system

# 2. 应用 RBAC 配置
kubectl apply -f deploy/manifests/aibrix-controller-manager.yaml

# 3. 检查 Pod 状态
kubectl get pods -n aibrix-system

# 4. 查看日志
kubectl logs -n aibrix-system -l control-plane=controller-manager
```

---

### 6.2 Gateway Plugin 无法连接 vLLM

**问题描述：**
```
Error: connection refused to vllm-service:8000
```

**原因：**
vLLM Service 未正确配置或 Pod 未就绪。

**解决方案：**

```bash
# 1. 检查 vLLM Pod 状态
kubectl get pods -l app=vllm

# 2. 检查 Service
kubectl get svc vllm-service
kubectl describe svc vllm-service

# 3. 测试连通性
kubectl run test --rm -it --image=busybox -- wget -qO- http://vllm-service:8000/health

# 4. 检查 vLLM 日志
kubectl logs -l app=vllm | tail -50
```

**确保 Service 配置正确：**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: vllm-service
spec:
  selector:
    app: vllm
  ports:
  - port: 8000
    targetPort: 8000
```

---

## 7. 常用诊断命令

### 7.1 集群状态检查

```bash
# 检查所有 Pod
kubectl get pods --all-namespaces

# 检查节点状态
kubectl get nodes
kubectl describe node minikube

# 检查事件
kubectl get events --sort-by='.metadata.creationTimestamp' | tail -20

# 检查日志
kubectl logs <pod-name> -n <namespace>
kubectl logs -l app=<label> --tail=100
```

### 7.2 网络诊断

```bash
# 测试 DNS 解析
kubectl run test-dns --rm -it --image=busybox -- nslookup kubernetes.default

# 测试 Service 连通性
kubectl run test-curl --rm -it --image=curlimages/curl -- curl -v http://vllm-service:8000/health

# 检查端口转发
kubectl port-forward svc/vllm-service 8000:8000
curl http://localhost:8000/health
```

### 7.3 GPU 诊断

```bash
# 检查 GPU 资源
kubectl describe node minikube | grep -A 10 "Capacity:" | grep nvidia

# 检查 Device Plugin
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds

# 进入 Pod 检查 GPU
kubectl exec -it <pod-name> -- nvidia-smi
```

### 7.4 存储诊断

```bash
# 检查 PV/PVC
kubectl get pv,pvc

# 检查 HostPath 挂载
kubectl describe pod <pod-name> | grep -A 5 "Mounts:"

# 进入 Pod 检查文件
kubectl exec -it <pod-name> -- ls -lh /models/
```

---

## 8. 快速故障排除清单

### 部署前检查

- Docker 服务运行正常
- Docker 数据目录配置正确
- NVIDIA 驱动正常
- NVIDIA Container Toolkit 已安装
- Minikube 已安装
- kubectl 已安装
- 模型文件已下载

### 部署后验证

- Minikube 集群运行
- GPU 资源可用
- NVIDIA Device Plugin 运行
- vLLM Pod 运行
- vLLM Service 可访问
- AIBrix Controller Manager 运行

---

## 9. 联系支持

如果以上方案都无法解决问题，请收集以下信息：

```bash
# 集群信息
minikube status
kubectl cluster-info
kubectl get nodes -o yaml

# Pod 状态
kubectl get pods --all-namespaces -o yaml

# 日志
minikube logs
kubectl logs -n aibrix-system -l control-plane=controller-manager
kubectl logs -l app=vllm

# 系统信息
nvidia-smi
docker info
```

---

## 附录：参考资源

- [Minikube 官方文档](https://minikube.sigs.k8s.io/docs/)
- [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)
- [vLLM 官方文档](https://docs.vllm.ai/)
- [AIBrix 项目](https://github.com/aibrix/aibrix)

---

**最后更新：** 2026-09-30  
**维护者：** AIBrix 部署团队

## 问题 14: vLLM Pod CrashLoopBackOff - HostPath 挂载冲突

**问题描述**:
vLLM Pod 启动失败，错误信息：
```
Error: failed to start container "vllm": Error response from daemon: 
error while creating mount source path '/models': mkdir /models: file exists
```

**根本原因**:
`minikube mount` 使用 9p 协议挂载 `/models` 目录，但 Docker daemon 在创建 Pod 容器时尝试在宿主机（Minikube 容器）上创建 `/models` 目录，与 9p 挂载点冲突。

**解决方案**:
1. 卸载所有 9p 挂载：
   ```bash
   docker exec minikube umount -f /models
   docker exec minikube umount -f /data/models
   docker exec minikube umount -f /var/data/models
   ```

2. 使用 `docker cp` 将模型文件直接复制到 Minikube 容器的 overlay 文件系统：
   ```bash
   docker exec minikube mkdir -p /root/models
   docker cp /data/models/models/Qwen--Qwen3.5-4B minikube:/root/models/Qwen--Qwen3.5-4B
   ```

3. 更新 deployment 的 hostPath 指向 `/root/models`：
   ```yaml
   volumes:
   - name: model-storage
     hostPath:
       path: /root/models
       type: Directory
   ```

## 问题 15: FlashInfer JIT 编译失败 - 缺少 nvcc

**问题描述**:
vLLM 启动时 FlashInfer 采样模块 JIT 编译失败：
```
/bin/sh: 1: /usr/local/cuda/bin/nvcc: not found
```

**根本原因**:
Docker 镜像基于 `nvidia/cuda:12.1.1-base`，只包含 CUDA runtime，不包含 CUDA toolkit（nvcc 编译器）。

**解决方案**:
在现有镜像上安装 CUDA toolkit：
```bash
docker run --name vllm-fix -dit --entrypoint bash vllm-local:qwen3.5-4b
docker exec vllm-fix bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cuda-nvcc-12-1 cuda-cudart-dev-12-1
"
docker commit vllm-fix vllm-local:qwen3.5-4b
docker rm -f vllm-fix
```

重新导入到 Minikube：
```bash
docker save vllm-local:qwen3.5-4b | (eval $(minikube docker-env) && docker load)
```

## 问题 16: FlashInfer JIT 编译失败 - 缺少 ninja

**问题描述**:
安装 nvcc 后，FlashInfer JIT 编译仍然失败：
```
FileNotFoundError: [Errno 2] No such file or directory: 'ninja'
```

**根本原因**:
FlashInfer 使用 ninja 构建系统编译 CUDA 代码，但容器中没有安装 ninja。

**解决方案**:
通过 pip 安装 ninja（已包含在 Python 包中）：
```bash
docker exec vllm-fix bash -c "python3.11 -m pip install ninja"
```

确保 deployment 的 PATH 包含 `/usr/local/bin`：
```yaml
env:
- name: PATH
  value: "/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin"
```

## 问题 17: FlashInfer JIT 编译失败 - 缺少 curand.h

**问题描述**:
安装 ninja 后，FlashInfer JIT 编译失败：
```
fatal error: curand.h: No such file or directory
```

**根本原因**:
CUDA 开发库头文件（curand, cublas, cusparse 等）未安装。

**解决方案**:
安装完整的 CUDA 开发库：
```bash
docker exec vllm-fix bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq cuda-libraries-dev-12-1
"
docker commit vllm-fix vllm-local:qwen3.5-4b
```

验证头文件已安装：
```bash
ls /usr/local/cuda/include/curand.h
ls /usr/local/cuda/include/cublas.h
ls /usr/local/cuda/include/cusparse.h
```

## 问题 18: vLLM Pod 因 Liveness Probe 失败而重启

**问题描述**:
vLLM Pod 在启动过程中反复重启，状态为 `Error` 或 `CrashLoopBackOff`。

**根本原因**:
vLLM 首次启动需要较长时间（5-8 分钟）进行：
1. 模型加载（~4秒）
2. torch.compile 编译（~31秒）
3. 初始预热（~91秒）
4. CUDA graph 捕获（~9秒）
5. FlashInfer JIT 编译（首次启动时）

默认的 liveness probe `initialDelaySeconds: 120` 太短，导致在启动完成前就被杀死。

**解决方案**:
增加 probe 的初始延迟和失败阈值：
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 600  # 10分钟
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 5

readinessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 120
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 60
```

## 问题 19: vLLM 容器启动失败 - 错误的 Entrypoint

**问题描述**:
使用 `docker commit` 后，容器启动失败：
```
bash: --model: invalid option
```

**根本原因**:
`docker commit` 时，容器的 entrypoint 被设置为 `bash`，而不是原来的 vLLM 启动命令。

**解决方案**:
在 deployment 中显式指定 command：
```yaml
containers:
- name: vllm
  image: vllm-local:qwen3.5-4b
  command: ["python3.11"]
  args:
  - "-m"
  - "vllm.entrypoints.openai.api_server"
  - "--model"
  - "/models/Qwen--Qwen3.5-4B/snapshots/master"
  # ... 其他参数
```

## 最终解决方案总结

### 完整的 Docker 镜像修复步骤

```bash
# 1. 启动临时容器
docker run --name vllm-fix -dit --entrypoint bash vllm-local:qwen3.5-4b

# 2. 安装 CUDA toolkit 和开发库
docker exec vllm-fix bash -c "
export DEBIAN_FRONTEND=noninteractive
sed -i 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list
sed -i 's|http://security.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list
apt-get update -qq
apt-get install -y -qq \
  cuda-nvcc-12-1 \
  cuda-cudart-dev-12-1 \
  cuda-libraries-dev-12-1 \
  build-essential
"

# 3. 验证安装
docker exec vllm-fix bash -c "
/usr/local/cuda/bin/nvcc --version
ls /usr/local/cuda/include/curand.h
ls /usr/local/cuda/include/cublas.h
which ninja
ninja --version
"

# 4. 提交新镜像
docker commit vllm-fix vllm-local:qwen3.5-4b
docker rm -f vllm-fix

# 5. 导入到 Minikube
docker save vllm-local:qwen3.5-4b | (eval $(minikube docker-env) && docker load)
```

### 模型文件部署

```bash
# 在 Minikube 容器中创建模型目录
docker exec minikube mkdir -p /root/models

# 复制模型文件到 Minikube
docker cp /data/models/models/Qwen--Qwen3.5-4B minikube:/root/models/Qwen--Qwen3.5-4B

# 验证
docker exec minikube ls -la /root/models/Qwen--Qwen3.5-4B/
```

### Deployment 配置

关键配置：
- `command: ["python3.11"]` - 显式指定 Python 解释器
- `PATH: "/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin"` - 包含 nvcc 和 ninja
- `hostPath.path: /root/models` - 指向复制的模型文件
- `livenessProbe.initialDelaySeconds: 600` - 10分钟启动时间
- `readinessProbe.failureThreshold: 60` - 允许长时间启动

### 验证服务

```bash
# 检查 Pod 状态
kubectl get pods -l app=vllm

# 查看日志
kubectl logs -l app=vllm --tail=50

# 测试健康检查
kubectl exec -it $(kubectl get pods -l app=vllm -o name | head -1) -- \
  curl -s http://localhost:8000/health

# 测试模型列表
kubectl exec -it $(kubectl get pods -l app=vllm -o name | head -1) -- \
  curl -s http://localhost:8000/v1/models

# 测试推理
kubectl exec -it $(kubectl get pods -l app=vllm -o name | head -1) -- \
  curl -s http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.5-4b",
    "prompt": "Hello, my name is",
    "max_tokens": 50,
    "temperature": 0.7
  }'
```

### 性能指标

- 模型加载时间: ~4秒
- torch.compile 时间: ~31秒
- 初始预热时间: ~91秒
- CUDA graph 捕获: ~9秒（86个图）
- KV cache 大小: 10.17 GiB（234,589 tokens）
- 最大并发: 28.64x（8192 tokens/请求）
- GPU 内存使用: 8.91 GiB (权重) + 2.13 GiB (激活) + 0.5 GiB (CUDA graphs) + 10.17 GiB (KV cache)
- 总 GPU 内存: 21.71 GiB / 23.56 GiB (92%)


## 问题 20: Docker 拉取镜像失败 - 代理配置冲突

**问题描述**:
Docker 拉取镜像失败，错误信息：
```
Error response from daemon: Get "https://registry-1.docker.io/v2/": 
proxyconnect tcp: dial tcp 127.0.0.1:7897: connect: connection refused
```

即使配置了中国镜像源（docker.m.daocloud.io），也会失败。

**根本原因**:
Docker daemon 配置了 HTTP 代理（`/etc/systemd/system/docker.service.d/proxy.conf`），但代理服务（Clash）未运行。代理配置优先于镜像源配置，导致所有请求都尝试通过不可用的代理转发。

**解决方案**:

1. **临时移除代理配置**:
```bash
# 备份代理配置
sudo mv /etc/systemd/system/docker.service.d/proxy.conf \
        /etc/systemd/system/docker.service.d/proxy.conf.bak

# 重新加载并重启 Docker
sudo systemctl daemon-reload
sudo systemctl restart docker
```

2. **注释代理配置（推荐）**:
编辑 `/etc/systemd/system/docker.service.d/proxy.conf`：
```ini
[Service]
# 代理配置 - 仅在 Clash 或其他代理运行时启用
# 取消注释下面的行以启用代理
# Environment="HTTP_PROXY=http://127.0.0.1:7897/"
# Environment="HTTPS_PROXY=http://127.0.0.1:7897/"
# Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
```

然后重新加载：
```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```

3. **验证镜像拉取**:
```bash
# 测试拉取基础镜像
docker pull python:3.11-slim-bookworm
docker pull golang:1.21-bookworm
docker pull ubuntu:22.04
```

**预防措施**:
- 在不使用代理时，保持代理配置注释状态
- 需要代理时，手动取消注释并重启 Docker
- 创建脚本快速切换代理状态：

```bash
#!/bin/bash
# toggle-docker-proxy.sh
if grep -q "^# Environment=\"HTTP_PROXY" /etc/systemd/system/docker.service.d/proxy.conf; then
    echo "启用 Docker 代理..."
    sudo sed -i 's/^# Environment/Environment/' /etc/systemd/system/docker.service.d/proxy.conf
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    echo "代理已启用"
else
    echo "禁用 Docker 代理..."
    sudo sed -i 's/^Environment/# Environment/' /etc/systemd/system/docker.service.d/proxy.conf
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    echo "代理已禁用"
fi
```

**注意事项**:
- Docker 重启后，Minikube 也会停止，需要重新启动：`minikube start`
- Minikube 重启后，vLLM Pod 需要几分钟重新加载模型
- 中国镜像源（docker.m.daocloud.io）在代理禁用后可正常使用

## 问题 21: Minikube 重启后 Pod 状态异常

**问题描述**:
Docker 重启或 Minikube 重启后，Pod 出现各种异常状态：
- `UnexpectedAdmissionError`
- `ContainerCreating` 长时间不启动
- GPU 资源不可用

**解决方案**:

1. **等待集群稳定**（1-2 分钟）:
```bash
kubectl get pods -A -w
```

2. **删除异常 Pod**（Deployment 会自动重建）:
```bash
kubectl delete pod <pod-name> --force
```

3. **检查 GPU 资源**:
```bash
kubectl describe node minikube | grep -A 5 "Allocated resources"
```

4. **重新部署 NVIDIA Device Plugin**（如果需要）:
```bash
kubectl apply -f deploy/manifests/nvidia-device-plugin.yaml
```

5. **验证 vLLM 服务**:
```bash
# 等待 Pod 变为 1/1 Running
kubectl get pods -l app=vllm

# 测试 API
kubectl exec -it $(kubectl get pods -l app=vllm -o name | head -1) -- \
  curl -s http://localhost:8000/health
```

**预期恢复时间**:
- Minikube 启动：~15秒
- 系统 Pod 稳定：~1-2分钟
- vLLM Pod 启动：~5-8分钟（首次），~2-3分钟（后续）
- 总恢复时间：~10分钟
