# AIBrix 部署问题排查

本文档记录了部署 AIBrix 过程中遇到的所有问题及其解决方案。

---

## 问题 1: Gateway Plugins 镜像 glibc 兼容性错误

### 症状

```
/gateway-plugins: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.32' not found
/gateway-plugins: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found
```

### 原因

Gateway Plugins 二进制文件在较新的系统上编译，依赖高版本 glibc，但运行时镜像（Ubuntu 20.04）的 glibc 版本较低。

### 解决方案

使用静态链接编译，禁用 CGO：

```bash
cd /home/wangwei/wei/workspacePy/maas/aibrix
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -ldflags="-s -w" \
  -o /tmp/gateway-plugins \
  ./cmd/plugins

# 构建镜像
cd /tmp
cat > Dockerfile << 'DOCKERFILE'
FROM ubuntu:20.04
COPY gateway-plugins /gateway-plugins
RUN chmod +x /gateway-plugins
ENTRYPOINT ["/gateway-plugins"]
DOCKERFILE

eval $(minikube docker-env)
docker build -t aibrix/gateway-plugins:nightly .
```

### 相关文件

- `aibrix/cmd/plugins/main.go`
- `aibrix-ext/build/gateway-plugins/Dockerfile`

---

## 问题 2: Gateway API CRD 下载失败

### 症状

```
error: unable to read URL "https://github.com/kubernetes-sigs/gateway-api/...": 
server reported 404 Not Found
```

或下载超时。

### 原因

1. GitHub 在国内访问不稳定
2. 某些镜像站点不可用

### 解决方案

使用 ghproxy.net 镜像：

```bash
# 下载 Gateway API CRDs
for crd in gatewayclasses gateways httproutes referencegrants; do
  curl -fsSL "https://ghproxy.net/https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.1/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml" \
    -o "/tmp/gw-${crd}.yaml"
done

# 应用 CRDs
kubectl apply -f /tmp/gw-gatewayclasses.yaml
kubectl apply -f /tmp/gw-gateways.yaml
kubectl apply -f /tmp/gw-httproutes.yaml
kubectl apply -f /tmp/gw-referencegrants.yaml
```

### 验证

```bash
kubectl get crd | grep gateway.networking.k8s.io
# 应该看到 4 个 CRD
```

---

## 问题 3: Gateway Plugins RBAC 权限不足

### 症状

```
httproutes.gateway.networking.k8s.io "qwen3.5-4b-router" is forbidden: 
User "system:serviceaccount:aibrix-system:aibrix-gateway-plugins" cannot get resource "httproutes" 
in API group "gateway.networking.k8s.io"
```

### 原因

Gateway Plugins 的 ClusterRole 缺少 Gateway API 资源的访问权限。

### 解决方案

更新 ClusterRole：

```bash
kubectl patch clusterrole aibrix-gateway-plugins -p '{
  "rules": [
    {
      "apiGroups": [""],
      "resources": ["pods", "services", "endpoints"],
      "verbs": ["get", "list", "watch"]
    },
    {
      "apiGroups": ["model.aibrix.ai"],
      "resources": ["modeladapters"],
      "verbs": ["get", "list", "watch"]
    },
    {
      "apiGroups": ["gateway.networking.k8s.io"],
      "resources": ["httproutes", "gateways", "gatewayclasses"],
      "verbs": ["get", "list", "watch"]
    }
  ]
}'

# 重启 gateway-plugins 以应用新权限
kubectl rollout restart -n aibrix-system deployment/aibrix-gateway-plugins
```

### 验证

```bash
kubectl get clusterrole aibrix-gateway-plugins -o yaml | grep -A 30 "rules:"
```

---

## 问题 4: HTTPRoute 命名空间错误

### 症状

```
httproutes.gateway.networking.k8s.io "qwen3.5-4b-router" not found
```

即使 HTTPRoute 已创建。

### 原因

Gateway Plugins 在 `aibrix-system` 命名空间查找 HTTPRoute，但 HTTPRoute 被创建在 `default` 命名空间。

### 解决方案

在正确的命名空间创建 HTTPRoute：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: qwen3.5-4b-router
  namespace: aibrix-system  # 必须在 aibrix-system
  labels:
    model.aibrix.ai/name: qwen3.5-4b
spec:
  parentRefs:
    - name: aibrix-eg
      namespace: aibrix-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/completions
        - path:
            type: PathPrefix
            value: /v1/chat/completions
        # ... 其他路径
      backendRefs:
        - name: vllm-service
          namespace: default  # vLLM 在 default 命名空间
          port: 8000
```

---

## 问题 5: 跨命名空间引用被拒绝

### 症状

```
no healthy upstream
```

Envoy 无法连接到后端服务。

### 原因

HTTPRoute 在 `aibrix-system` 命名空间引用 `default` 命名空间的 `vllm-service`，需要 ReferenceGrant 授权。

### 解决方案

创建 ReferenceGrant：

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-aibrix-to-vllm
  namespace: default  # 在目标服务所在命名空间
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: aibrix-system  # 允许来自 aibrix-system 的引用
  to:
    - group: ""
      kind: Service
      name: vllm-service  # 目标服务名称
```

应用：

```bash
kubectl apply -f referencegrant.yaml
```

---

## 问题 6: Envoy ORIGINAL_DST 路由失败

### 症状

```
original_dst_load_balancer: No downstream connection or no original_dst.
no healthy upstream
```

### 原因

Envoy 使用 ORIGINAL_DST 集群类型，需要 gateway-plugins 通过 ExtProc 设置 `target-pod` 头部指定目标 Pod IP。但当前配置中 gateway-plugins 未正确设置该头部。

### 根本原因

Gateway Plugins 设计用于与完整的 Envoy Gateway 控制器配合，使用 xDS 动态配置。当前使用静态 Envoy 配置，无法完全集成 ExtProc 的 pod 选择逻辑。

### 临时解决方案

使用简化的 Envoy 配置，直接路由到 vllm-service，绕过 pod 级别的智能路由：

```yaml
clusters:
  - name: vllm_cluster
    connect_timeout: 5s
    type: STRICT_DNS  # 使用 DNS 而不是 ORIGINAL_DST
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: vllm_cluster
      endpoints:
        - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: vllm-service.default.svc.cluster.local
                    port_value: 8000
```

**影响**: 基本的负载均衡和路由功能正常，但高级功能（前缀缓存路由、会话亲和性）未完全启用。

### 长期解决方案

安装完整的 Envoy Gateway 控制器，启用 xDS 动态配置和 ExtProc 集成。

---

## 问题 7: ModelAdapter Service 名称无效

### 症状

```
Service "qwen3.5-4b" is invalid: metadata.name: Invalid value: "qwen3.5-4b": 
a DNS-1035 label must consist of lower case alphanumeric characters or '-', 
start with an alphabetic character, and end with an alphanumeric character
```

### 原因

模型名称 `qwen3.5-4b` 包含点号（.），不符合 Kubernetes DNS-1035 规范。

### 解决方案

1. 使用符合规范的 Deployment 名称：`vllm-qwen35-4b`
2. 保留模型名称标签：`model.aibrix.ai/name: qwen3.5-4b`
3. 手动创建 HTTPRoute 使用 `qwen3.5-4b-router` 名称

```yaml
# Deployment 名称使用连字符
metadata:
  name: vllm-qwen35-4b
  labels:
    model.aibrix.ai/name: qwen3.5-4b  # 模型名称可以包含点号
```

---

## 问题 8: Docker 镜像拉取失败

### 症状

```
Error response from daemon: Get "https://registry-1.docker.io/v2/": 
net/http: request canceled while waiting for unknown
```

### 原因

Docker Hub 在国内访问不稳定或被限制。

### 解决方案

配置 Docker 镜像加速器：

```json
// /etc/docker/daemon.json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerhub.azk8s.cn"
  ]
}
```

重启 Docker：

```bash
sudo systemctl restart docker
```

或使用完整镜像地址：

```bash
docker pull docker.m.daocloud.io/envoyproxy/envoy:v1.33.2
docker tag docker.m.daocloud.io/envoyproxy/envoy:v1.33.2 envoyproxy/envoy:v1.33.2
```

---

## 问题 9: Controller Manager 未创建 HTTPRoute

### 症状

vLLM Deployment 已创建，但 HTTPRoute 未自动生成。

### 原因

1. Controller Manager 的 modelrouter 控制器需要 Gateway 资源存在
2. Deployment 创建时 Gateway 尚未创建，未触发控制器

### 解决方案

1. 确保 Gateway 资源已创建：

```bash
kubectl apply -f gateway.yaml
```

2. 重启 vLLM Deployment 触发控制器：

```bash
kubectl rollout restart deployment/vllm-qwen35-4b -n default
```

3. 或手动创建 HTTPRoute（推荐，更可控）

---

## 调试命令

### 查看组件日志

```bash
# Controller Manager
kubectl logs -n aibrix-system deployment/aibrix-controller-manager --tail=100

# Gateway Plugins
kubectl logs -n aibrix-system deployment/aibrix-gateway-plugins --tail=100

# Envoy
kubectl logs -n aibrix-system deployment/aibrix-envoy --tail=100

# vLLM
kubectl logs -n default deployment/vllm-qwen35-4b --tail=100
```

### 检查 Gateway API 资源

```bash
# 查看所有 Gateway API 资源
kubectl get gatewayclass,gateway,httproute,referencegrant -A

# 查看 HTTPRoute 详情
kubectl describe httproute qwen3.5-4b-router -n aibrix-system

# 查看 Gateway 状态
kubectl describe gateway aibrix-eg -n aibrix-system
```

### 测试路由

```bash
# 测试 Envoy 网关
MINIKUBE_IP=$(minikube ip)
curl -v http://$MINIKUBE_IP:30080/v1/models

# 测试推理
curl http://$MINIKUBE_IP:30080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.5-4b","messages":[{"role":"user","content":"Hi"}]}'
```

### 检查 DNS 解析

```bash
# 从 Envoy Pod 检查 DNS
kubectl exec -n aibrix-system deployment/aibrix-envoy -- \
  cat /etc/resolv.conf

# 检查 Service 端点
kubectl get endpoints vllm-service -n default
```

---

## 性能优化建议

1. **调整 Gateway Plugins 缓存刷新间隔**

```yaml
env:
  - name: AIBRIX_POD_METRIC_REFRESH_INTERVAL_MS
    value: "50"  # 默认 50ms，可根据负载调整
```

2. **启用前缀缓存**

```yaml
env:
  - name: AIBRIX_PREFIX_CACHE_TOKENIZER_TYPE
    value: "character"
  - name: AIBRIX_PREFIX_CACHE_BLOCK_SIZE
    value: "128"
```

3. **调整 Envoy 超时**

```yaml
routes:
  - match:
      prefix: "/v1/"
    route:
      timeout: 600s  # 增加超时时间
```

---

## 参考资源

- [AIBrix GitHub Issues](https://github.com/vllm-project/aibrix/issues)
- [Gateway API 故障排查](https://gateway-api.sigs.k8s.io/guides/troubleshooting/)
- [Envoy 调试指南](https://www.envoyproxy.io/docs/envoy/latest/operations/admin)
