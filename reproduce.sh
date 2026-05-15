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

# 2. 创建无 CNI 的 Kind 集群
echo ">>> 创建 Kind 集群"
kind delete cluster --name cilium-clus 2>/dev/null || true
kind create cluster --config "$ROOT_DIR/kind-cilium.yml"

# 3. 安装 Cilium
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

# 4. 等待 Cilium Agent 就绪
echo ">>> 等待 Cilium Agent DaemonSet 就绪"
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m
kubectl -n kube-system rollout status deployment/hubble-relay --timeout=5m
kubectl -n kube-system rollout status deployment/hubble-ui --timeout=5m

# 5. 等待 CiliumNetworkPolicy CRD 出现
echo ">>> 等待 CiliumNetworkPolicy CRD 出现"
for i in {1..30}; do
    if kubectl get crd ciliumnetworkpolicies.cilium.io &>/dev/null; then
        echo "CRD ciliumnetworkpolicies.cilium.io 已就绪"
        break
    fi
    sleep 2
done
kubectl wait --for=condition=established --timeout=1m crd/ciliumnetworkpolicies.cilium.io

# 6. 安装 Prometheus + Grafana
echo ">>> 安装 kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --version 45.4.0 \
    --values "$ROOT_DIR/prometheus-stack-values.yml" \
    --wait --timeout 10m

# 等待 ServiceMonitor CRD 完全注册
kubectl wait --for=condition=established --timeout=1m crd/servicemonitors.monitoring.coreos.com

# 7. 升级 Cilium 开启 ServiceMonitor
echo ">>> 开启 Cilium ServiceMonitor"
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --version 1.19.4 \
    --reuse-values \
    --set prometheus.serviceMonitor.enabled=true \
    --set operator.prometheus.serviceMonitor.enabled=true \
    --set hubble.metrics.serviceMonitor.enabled=true \
    --wait --timeout 5m

# 8. 部署测试应用
echo ">>> 部署测试应用 (nginx-l4, http-echo-l7, client)"
kubectl apply -f "$ROOT_DIR/apps/demo-app.yml"

# 9. 应用网络策略
echo ">>> 应用 L4 和 L7 网络策略"
kubectl apply -f "$ROOT_DIR/apps/policies.yml"

echo ""
echo "=============================================="
echo " ✅ 部署完成！"
echo "=============================================="
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
echo "等待 30-60 秒让监控数据收集，即可在 Hubble UI 看到 L7 策略拒绝 POST 请求。"
