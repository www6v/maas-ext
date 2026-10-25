#!/bin/bash
echo "========================================="
echo "  AIBrix 集群状态"
echo "========================================="
echo ""

echo "--- 主机服务 ---"
echo "Redis:            $(redis-cli ping 2>/dev/null || echo 'NOT RUNNING')"
echo "metadata-service: $(curl -s --max-time 2 http://localhost:8090/healthz 2>/dev/null || echo 'NOT RUNNING')"
echo "gateway-plugin:   $(ps aux | grep -v grep | grep -c 'gateway-plugin') process(es)"
echo "vLLM:             $(curl -s --max-time 2 http://localhost:8000/v1/models 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin)["data"]; print(d[0]["id"] if d else "no models")' 2>/dev/null || echo 'NOT RUNNING')"
echo ""

echo "--- Minikube ---"
echo "Minikube: $(minikube status --format='{{.Host}} {{.Kubelet}} {{.APIServer}}' 2>/dev/null || echo 'NOT RUNNING')"
echo ""

echo "--- K8s Pods (aibrix-system) ---"
kubectl get pods -n aibrix-system -o wide 2>/dev/null || echo "kubectl not available"
echo ""

echo "--- K8s Services (aibrix-system) ---"
kubectl get svc -n aibrix-system 2>/dev/null || echo "kubectl not available"
echo ""

echo "--- K8s Endpoints (aibrix-system) ---"
kubectl get endpoints -n aibrix-system 2>/dev/null || echo "kubectl not available"
echo ""

echo "--- K8s CRDs ---"
kubectl get crd 2>/dev/null | grep aibrix || echo "No AIBrix CRDs found"
echo ""

echo "--- GPU ---"
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo "nvidia-smi not available"
echo ""

echo "--- 端口监听 ---"
ss -tlnp 2>/dev/null | grep -E "6379|8090|50052|8080|8000|9443" | awk '{print $4, $6}' || echo "ss not available"
