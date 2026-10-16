#!/usr/bin/env bash
# 拉起本地 K8s 练习环境：
#   1. 一个本地镜像仓库（registry:2）
#   2. 一个 kind 集群（1 控制面 + 1 工作节点）
#   3. 把两者接到同一个 Docker 网络，并发布仓库地址
#
# 幂等：重复执行不会重建已存在的东西。
set -euo pipefail

HACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/env.sh
source "$HACK_DIR/env.sh"

KIND="${CNLAB_ROOT}/bin/kind"
if [[ ! -x "$KIND" ]]; then
  echo "缺少 bin/kind，请先执行： ./hack/install-tools.sh" >&2
  exit 1
fi

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. 本地镜像仓库
# ---------------------------------------------------------------------------
# 为什么需要它，而不是用 kind load 直接把镜像灌进节点：
# 有了仓库，dev 环境的镜像地址就是 localhost:5001/cnlab，与生产的
# ghcr.io/am-okalin/cnlab 结构完全一致。于是 Kustomize overlay 只需要
# 改 registry 前缀和 tag —— 这正是"同一份清单、多环境部署"想教的东西。
# 用 kind load 的话，本地环境会走一条生产不存在的特殊路径。
if [[ "$(docker inspect -f '{{.State.Running}}' "${CNLAB_REGISTRY_NAME}" 2>/dev/null || true)" != "true" ]]; then
  log "启动本地镜像仓库 ${CNLAB_REGISTRY_NAME} (localhost:${CNLAB_REGISTRY_PORT})"
  docker run -d --restart=always \
    -p "127.0.0.1:${CNLAB_REGISTRY_PORT}:5000" \
    --network bridge \
    --name "${CNLAB_REGISTRY_NAME}" \
    registry:2
else
  log "本地镜像仓库 ${CNLAB_REGISTRY_NAME} 已在运行，跳过"
fi

# ---------------------------------------------------------------------------
# 2. kind 集群
# ---------------------------------------------------------------------------
if "$KIND" get clusters 2>/dev/null | grep -qx "${CNLAB_CLUSTER}"; then
  log "集群 ${CNLAB_CLUSTER} 已存在，跳过创建"
else
  log "创建 kind 集群 ${CNLAB_CLUSTER}（首次需 1-2 分钟拉取 node 镜像）"
  "$KIND" create cluster --config "${CNLAB_ROOT}/kind/cluster.yaml"
fi

# 无论集群是新建还是已存在，都重新导出一次 kubeconfig。
# 这样"集群在、kubeconfig 丢了"（上一次导出失败）能自愈，
# 也保证 KUBECONFIG 指向的那份始终是权威来源。
log "导出 kubeconfig -> ${KUBECONFIG}"
"$KIND" export kubeconfig --name "${CNLAB_CLUSTER}"

# ---------------------------------------------------------------------------
# 3. 把仓库接入 kind 网络
# ---------------------------------------------------------------------------
# 节点容器通过 Docker 内嵌 DNS 解析 kind-registry 这个名字，
# 前提是仓库容器与节点处在同一个 Docker 网络上。
if ! docker network inspect kind -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
  | grep -qw "${CNLAB_REGISTRY_NAME}"; then
  log "把 ${CNLAB_REGISTRY_NAME} 接入 kind 网络"
  docker network connect kind "${CNLAB_REGISTRY_NAME}"
else
  log "${CNLAB_REGISTRY_NAME} 已在 kind 网络上，跳过"
fi

# ---------------------------------------------------------------------------
# 4. 发布仓库地址（约定俗成的 ConfigMap，方便人和工具发现本地仓库）
# ---------------------------------------------------------------------------
log "写入 local-registry-hosting ConfigMap"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${CNLAB_REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

log "集群就绪"
kubectl --context "kind-${CNLAB_CLUSTER}" get nodes -o wide
