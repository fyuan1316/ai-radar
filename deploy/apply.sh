#!/usr/bin/env bash
# fy-runner 部署 / 更新 / 冒烟测试一站式脚本
# 用法:
#   ./apply.sh           # 创建 Secret + apply Deployment + 跟启动日志
#   ./apply.sh smoke     # 在已部署的 pod 里手动跑一次 oai-weekly 任务
#   ./apply.sh logs      # 看最新一次启动日志(follow)
#   ./apply.sh restart   # rollout restart 重新拉起(.env 改了之后用这个)
#   ./apply.sh down      # 卸载

set -euo pipefail

NS=alauda-developer-aimiddleware-yuanfang
NAME=fy-runner
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/../.env"
YAML="$DIR/$NAME.yaml"

require_env() {
  [ -f "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE not found"; exit 1; }
  for k in FEISHU_WEBHOOK GITHUB_REPO GITHUB_TOKEN; do
    grep -qE "^$k=" "$ENV_FILE" || { echo "FATAL: $k missing in $ENV_FILE"; exit 1; }
  done
}

cmd_up() {
  require_env

  echo "==> create/update secret ${NAME}-secrets from $ENV_FILE"
  kubectl create secret generic ${NAME}-secrets \
    -n "$NS" \
    --from-env-file="$ENV_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "==> apply deployment"
  kubectl apply -f "$YAML"

  echo "==> wait rollout"
  kubectl -n "$NS" rollout status deploy/$NAME --timeout=300s

  cmd_logs
}

cmd_logs() {
  local pod
  pod=$(kubectl -n "$NS" get pod -l app=$NAME -o jsonpath='{.items[0].metadata.name}')
  echo "==> follow logs of $pod (Ctrl-C 退出)"
  kubectl -n "$NS" logs -f "$pod" -c agent
}

cmd_smoke() {
  local pod task=${1:-oai-weekly}
  pod=$(kubectl -n "$NS" get pod -l app=$NAME -o jsonpath='{.items[0].metadata.name}')
  echo "==> run task '$task' inside $pod (as vscode user, claude 拒绝 root)"
  # kubectl exec 默认 root,必须显式 runuser 切到 vscode,否则 claude 拒绝 --dangerously-skip-permissions
  kubectl -n "$NS" exec "$pod" -c agent -- runuser -u vscode -- /work/bin/run-task.sh "$task"
}

cmd_restart() {
  echo "==> re-sync secret from $ENV_FILE"
  require_env
  kubectl create secret generic ${NAME}-secrets \
    -n "$NS" \
    --from-env-file="$ENV_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "==> rollout restart"
  kubectl -n "$NS" rollout restart deploy/$NAME
  kubectl -n "$NS" rollout status deploy/$NAME --timeout=300s
}

cmd_down() {
  echo "==> delete deployment + secret"
  kubectl -n "$NS" delete deploy/$NAME --ignore-not-found
  kubectl -n "$NS" delete secret ${NAME}-secrets --ignore-not-found
}

case "${1:-up}" in
  up)       cmd_up ;;
  logs)     cmd_logs ;;
  smoke)    cmd_smoke "${2:-oai-weekly}" ;;
  restart)  cmd_restart ;;
  down)     cmd_down ;;
  *) echo "usage: $0 [up|logs|smoke <task>|restart|down]"; exit 2 ;;
esac
