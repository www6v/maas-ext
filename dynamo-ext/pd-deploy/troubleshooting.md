# 问题诊断指南

## 已解决的问题

### 1. FlashInfer 类型注解错误

**错误**:
```
TypeError: type 'array.array' is not subscriptable
```

**原因**: FlashInfer 0.6.16.post3 使用了 `array.array[int]` 类型注解，这在 Python 3.10/3.11 中不支持。

**解决**: 使用 Python 3.12，完美兼容。

### 2. TVM FFI C++ 编译错误

**错误**:
```
error: namespace "std" has no member "memcmp"
error: namespace "std" has no member "memcpy"
```

**原因**: TVM FFI 的 `string.h` 文件缺少 `#include <cstring>`。

**解决**: 设置环境变量 `TORCH_COMPILE_DISABLE=1` 禁用编译。

### 3. curand 头文件缺失

**错误**:
```
fatal error: curand_kernel.h: No such file or directory
```

**原因**: 基础 CUDA 镜像不包含 curand 开发头文件。

**解决**: 使用 Dockerfile.py312-curand 构建镜像，添加 curand 头文件。

### 4. nvcc 编译器缺失

**错误**:
```
/bin/sh: 1: /usr/local/cuda/bin/nvcc: not found
```

**原因**: 基础 CUDA 镜像（base）不包含 nvcc。

**解决**: 使用 CUDA devel 镜像或在基础镜像上安装 cuda-nvcc-12-1。

### 5. GPU 显存不足

**错误**:
```
ValueError: Free memory on device cuda:0 (3.85/23.56 GiB) < desired (0.15, 3.53 GiB)
```

**原因**: vGPU time-slicing 不共享显存，两个 workers 无法同时运行。

**解决**: 使用双物理 GPU 或 MIG。

### 6. 磁盘空间不足

**错误**:
```
GUEST_PROVISION_NOSPACE: write /tmp/build.*.tar: no space left on device
```

**原因**: minikube 虚拟机磁盘空间不足。

**解决**:
```bash
# 清理 Docker 资源
minikube ssh
docker system prune -af --volumes
docker image prune -af
exit
```

### 7. 模型下载失败

**错误**:
```
HFValidationError: Repo id must be in the form 'repo_name' or 'namespace/repo_name'
```

**原因**: vLLM 尝试从 HuggingFace 下载模型，但路径是本地路径。

**解决**: 设置环境变量 `HF_HUB_OFFLINE=1` 和 `TRANSFORMERS_OFFLINE=1`。

### 8. etcd 连接失败

**错误**:
```
Unable to create lease. Check etcd server status at http://localhost:2379
```

**原因**: Workers 尝试连接 localhost:2379，但 etcd 在另一个 pod 中。

**解决**: 设置环境变量 `ETCD_ENDPOINTS=http://etcd:2379`。

---

## 当前问题

### CUDA devel 镜像拉取缓慢

**状态**: 拉取中（已运行 1 小时+）

**原因**: 镜像较大（约 5-10GB），网络速度限制。

**解决**: 耐心等待，或使用代理加速。

### minikube 磁盘空间不足

**状态**: 100% 满

**原因**: 多次镜像构建和测试耗尽了空间。

**解决**: 清理 Docker 资源和临时文件。

---

## 最佳实践

### 1. 磁盘空间管理
- 构建前检查可用空间（至少需要 3x 镜像大小）
- 定期清理 Docker 资源
- 使用 `docker system prune` 清理无用镜像

### 2. Python 版本选择
- 使用 Python 3.12 运行 Dynamo + vLLM
- 避免使用 Python 3.10/3.11（FlashInfer 兼容性问题）

### 3. vGPU 配置
- 单卡不适合 PD 分离（显存限制）
- 生产环境使用双物理 GPU 或 MIG
- 开发测试可以使用 vGPU time-slicing

### 4. 镜像构建
- 使用多阶段构建减少镜像大小
- 预下载大文件（如模型）到本地
- 使用 hostPath 挂载模型目录

---

## 参考资源

- [Dynamo 官方文档](https://docs.nvidia.com/dynamo/)
- [vLLM 文档](https://docs.vllm.ai/)
- [FlashInfer 文档](https://flashinfer.ai/)
- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/)
