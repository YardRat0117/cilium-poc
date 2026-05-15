#!/usr/bin/env bash
# Cilium POC - 端口转发脚本
# 用法: ./ui.sh              # 启动所有转发（前台阻塞，Ctrl+C 停止）
#       ./ui.sh hubble       # 只启动 Hubble UI
#       ./ui.sh grafana      # 只启动 Grafana
#       ./ui.sh prometheus   # 只启动 Prometheus
#       ./ui.sh bg           # 后台启动所有转发（需手动 kill）

set -euo pipefail

case "${1:-all}" in
  prometheus|p)
    echo "→ Prometheus UI: http://localhost:19091"
    kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 19091:9091
    ;;
  grafana|g)
    echo "→ Grafana: http://localhost:13000  (admin / admin)"
    kubectl port-forward -n monitoring svc/prometheus-stack-grafana 13000:80
    ;;
  hubble|hu)
    echo "→ Hubble UI: http://localhost:12000"
    kubectl port-forward -n kube-system svc/hubble-ui 12000:80
    ;;
  bg)
    echo "启动所有 UI 转发（后台）"
    kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 19091:9091 >/dev/null 2>&1 &
    kubectl port-forward -n monitoring svc/prometheus-stack-grafana 13000:80 >/dev/null 2>&1 &
    kubectl port-forward -n kube-system svc/hubble-ui 12000:80 >/dev/null 2>&1 &
    echo "PID: $! (使用 kill 停止)"
    ;;
  all|*)
    echo "启动所有 UI 转发（前台，按 Ctrl+C 停止）"
    echo "  Prometheus → http://localhost:19091"
    echo "  Grafana    → http://localhost:13000  (admin/admin)"
    echo "  Hubble UI  → http://localhost:12000"
    echo ""
    trap "exit" INT TERM
    kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 19091:9091 &
    PID1=$!
    kubectl port-forward -n monitoring svc/prometheus-stack-grafana 13000:80 &
    PID2=$!
    kubectl port-forward -n kube-system svc/hubble-ui 12000:80 &
    PID3=$!
    wait $PID1 $PID2 $PID3
    ;;
esac
