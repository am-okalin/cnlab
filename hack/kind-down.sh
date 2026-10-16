#!/usr/bin/env bash
# 拆掉本地练习环境。
#   ./hack/kind-down.sh         只删集群，保留镜像仓库（镜像不用重推）
#   ./hack/kind-down.sh --all   连镜像仓库一起删
set -euo pipefail

HACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/env.sh
source "$HACK_DIR/env.sh"

KIND="${CNLAB_ROOT}/bin/kind"
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if "$KIND" get clusters 2>/dev/null | grep -qx "${CNLAB_CLUSTER}"; then
  log "删除 kind 集群 ${CNLAB_CLUSTER}"
  "$KIND" delete cluster --name "${CNLAB_CLUSTER}"
else
  log "集群 ${CNLAB_CLUSTER} 不存在，跳过"
fi

if [[ "${1:-}" == "--all" ]]; then
  if docker inspect "${CNLAB_REGISTRY_NAME}" >/dev/null 2>&1; then
    log "删除本地镜像仓库 ${CNLAB_REGISTRY_NAME}"
    docker rm -f "${CNLAB_REGISTRY_NAME}" >/dev/null
  else
    log "镜像仓库 ${CNLAB_REGISTRY_NAME} 不存在，跳过"
  fi
  if docker network inspect kind >/dev/null 2>&1; then
    log "提醒：Docker 网络 kind 仍存在（可能有其他 kind 集群在用），未自动删除"
  fi
fi

log "完成"
