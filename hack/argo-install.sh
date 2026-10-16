#!/usr/bin/env bash
# 把 ArgoCD 装进 kind 集群。
#
# 用官方 install.yaml（而不是 Helm chart）是有意的：
# 这个练习的目标之一，是让你看清 ArgoCD 到底由哪些组件组成、
# 它们各自要多少资源。Helm chart 会把这些细节藏起来。
set -euo pipefail

HACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/env.sh
source "$HACK_DIR/env.sh"

CLUSTER_CTX="kind-${CNLAB_CLUSTER}"
# 固定版本，而不是 stable —— 与 kind/kustomize 同样的理由：可复现。
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.5}"
MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "安装 ArgoCD ${ARGOCD_VERSION}"
kubectl --context "$CLUSTER_CTX" create namespace argocd --dry-run=client -o yaml \
  | kubectl --context "$CLUSTER_CTX" apply -f -

# 用 server-side apply：ArgoCD 的 CRD 很大，client-side apply 会撞上
# "metadata.annotations: Too long" 的注解体积上限。
kubectl --context "$CLUSTER_CTX" apply --server-side --force-conflicts \
  -n argocd -f "$MANIFEST_URL"

log "等待各组件就绪（本机 Docker 只分配了 4GB 内存，首次拉起可能需要几分钟）"
kubectl --context "$CLUSTER_CTX" -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl --context "$CLUSTER_CTX" -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl --context "$CLUSTER_CTX" -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s
kubectl --context "$CLUSTER_CTX" -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

log "ArgoCD 就绪"
kubectl --context "$CLUSTER_CTX" -n argocd get pods -o wide

cat <<'EOF'

下一步：
  make argo-password     # 取 admin 初始密码
  make argo-ui           # 打开 https://localhost:8443
  make argo-bootstrap    # 用 app-of-apps 接入 GitOps

EOF
