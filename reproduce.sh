#!/usr/bin/env bash
# Cilium L4/L7 策略演示 + Hubble UI + Prometheus/Grafana 集成
# 用法: ./reproduce.sh
# 前置条件: docker, kind, kubectl, helm

set -euo pipefail
trap 'echo "❌ 出错行: $LINENO"; exit 1' ERR

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=============================================="
echo "  Cilium POC - L4/L7 策略 + 可观测性"
echo "=============================================="

# 1. 检查依赖
for cmd in docker kind kubectl helm; do
    if ! command -v $cmd &>/dev/null; then
        echo "❌ 缺少 $cmd，请安装后再试"
        exit 1
    fi
done

# 2. 创建 Kind 集群 (3节点)
echo ">>> 创建 Kind 集群 (3节点)"
kind delete cluster --name cilium-clus 2>/dev/null || true
kind create cluster --config "$ROOT_DIR/kind-cilium.yml" --name cilium-clus

# 3. 给节点打标签
echo ">>> 给节点打标签以便调度"
CONTROL_NODE=$(kubectl get nodes -o name | grep control-plane | head -1 | cut -d'/' -f2)
WORKER1=$(kubectl get nodes -o name | grep worker | head -1 | cut -d'/' -f2)
WORKER2=$(kubectl get nodes -o name | grep worker | tail -1 | cut -d'/' -f2)

# 为 worker1 打上 http-node 标签，为 worker2 打上 grpc-node 标签
kubectl label node $WORKER1 http-node=true --overwrite
kubectl label node $WORKER2 grpc-node=true --overwrite

echo "节点标签设置完成："
kubectl get nodes --show-labels | grep -E "NAME|http-node|grpc-node"

# 4. 构建自定义 grpcurl 镜像
echo ">>> 构建 my-grpcurl 镜像"
docker build -t my-grpcurl:latest -f "$ROOT_DIR/grpcurl.Dockerfile" .

# 5. 加载镜像到 Kind 所有节点
echo ">>> 加载镜像到 Kind 节点"
kind load docker-image my-grpcurl:latest --name cilium-clus

# 6. 安装 Cilium
echo ">>> 安装 Cilium 1.19.4 + Hubble + 指标"
helm repo add cilium https://helm.cilium.io --force-update
helm repo update
helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version 1.19.4 \
    --set cluster.name=kind-cilium-clus \
    --set ipam.mode=kubernetes \
    --set routingMode=tunnel \
    --set tunnelProtocol=vxlan \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set operator.replicas=1 \
    --set prometheus.enabled=true \
    --set prometheus.serviceMonitor.enabled=false \
    --set operator.prometheus.enabled=true \
    --set operator.prometheus.serviceMonitor.enabled=false \
    --set hubble.metrics.enableOpenMetrics=true \
    --set hubble.metrics.serviceMonitor.enabled=false \
    --wait --timeout 5m

# 7. 等待 Cilium 组件就绪
echo ">>> 等待 Cilium Agent DaemonSet 就绪"
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
kubectl -n kube-system rollout status deployment/hubble-relay --timeout=5m
kubectl -n kube-system rollout status deployment/hubble-ui --timeout=5m

# 8. 等待 CRD
echo ">>> 等待 CiliumNetworkPolicy CRD 出现"
for i in {1..30}; do
    if kubectl get crd ciliumnetworkpolicies.cilium.io &>/dev/null; then
        echo "CRD ciliumnetworkpolicies.cilium.io 已就绪"
        break
    fi
    sleep 2
done
kubectl wait --for=condition=established --timeout=1m crd/ciliumnetworkpolicies.cilium.io

# 9. 安装 Prometheus + Grafana (可选)
echo ">>> 安装 kube-prometheus-stack (可选)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --version 45.4.0 \
    --values "$ROOT_DIR/prometheus-stack-values.yml" \
    --wait --timeout 10m || echo "⚠️ Prometheus 安装失败，跳过"

kubectl wait --for=condition=established --timeout=1m crd/servicemonitors.monitoring.coreos.com 2>/dev/null || true

# 10. 升级 Cilium 开启 ServiceMonitor
echo ">>> 开启 Cilium ServiceMonitor"
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --version 1.19.4 \
    --reuse-values \
    --set prometheus.serviceMonitor.enabled=true \
    --set operator.prometheus.serviceMonitor.enabled=true \
    --set hubble.metrics.serviceMonitor.enabled=true \
    --wait --timeout 5m 2>/dev/null || echo "⚠️ ServiceMonitor 开启失败，可能 Prometheus 未安装"

# 11. 部署测试应用
echo ">>> 部署测试应用"
kubectl apply -f "$ROOT_DIR/apps/demo-app.yml"

# 12. 应用网络策略
echo ">>> 应用 L4 和 L7 网络策略"
kubectl apply -f "$ROOT_DIR/apps/policies.yml"

echo ""
echo "=============================================="
echo " ✅ 部署完成！"
echo "=============================================="
echo ""
echo "Pod 分布情况 (预期: client/grpc-client 在 control-plane, nginx/http-echo 在 worker1, grpc-server 在 worker2):"
kubectl get pods -o wide
echo ""
echo "手动导入 Grafana 仪表盘 21431"
echo ""
echo "启动端口转发（另开终端执行）:"
echo "  ./ui.sh              # 启动所有 UI 转发"
echo "  ./ui.sh hubble       # 只启动 Hubble UI"
echo "  ./ui.sh grafana      # 只启动 Grafana"
echo "  ./ui.sh prometheus   # 只启动 Prometheus"
echo ""
echo "访问地址（端口转发后）:"
echo "  Hubble UI:   http://localhost:12000"
echo "  Grafana:     http://localhost:13000  (admin/admin)"
echo "  Prometheus:  http://localhost:19091"
echo ""
echo "等待 30-60 秒让监控数据收集，即可在 Hubble UI 看到跨节点 gRPC 流量。"
