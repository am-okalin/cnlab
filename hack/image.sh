#!/usr/bin/env bash
# 镜像构建 / 推送。用法：
#
#   ./hack/image.sh build        构建本机架构镜像，装进本地 docker（cnlab:dev）
#   ./hack/image.sh push-local   构建并推送到 kind 的本地仓库
#   ./hack/image.sh multiarch    构建 amd64+arm64 多架构镜像为 OCI tar（只验证，不推送）
#
# 为什么 push-local 是"先 --load 再 docker push"，而不是 buildx 的 --push：
# buildx 用 docker-container 驱动时，推送动作发生在 BuildKit 容器内部，
# 那里的 localhost 不是你的 Mac，推不到 localhost:5001。
# 先落到本机 docker daemon 再 push，localhost 的语义才是对的。
# （CI 里推 ghcr.io 不需要这么做，直接 --push 即可。）
set -euo pipefail

HACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/env.sh
source "$HACK_DIR/env.sh"

ACTION="${1:-build}"

VERSION="${VERSION:-dev}"
COMMIT="${COMMIT:-$(git -C "$CNLAB_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)}"
BUILD_TIME="${BUILD_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

COMMON_ARGS=(
  --build-arg "VERSION=${VERSION}"
  --build-arg "COMMIT=${COMMIT}"
  --build-arg "BUILD_TIME=${BUILD_TIME}"
)

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

case "$ACTION" in
  build)
    log "构建 cnlab:${VERSION} (linux/${CNLAB_HOST_ARCH})"
    docker buildx build \
      --platform "linux/${CNLAB_HOST_ARCH}" \
      "${COMMON_ARGS[@]}" \
      -t "cnlab:${VERSION}" \
      --load \
      "$CNLAB_ROOT"
    docker images "cnlab:${VERSION}" --format '    {{.Repository}}:{{.Tag}}  {{.Size}}'
    ;;

  push-local)
    log "构建并推送到本地仓库 ${CNLAB_LOCAL_IMAGE}:${VERSION}"
    docker buildx build \
      --platform "linux/${CNLAB_HOST_ARCH}" \
      "${COMMON_ARGS[@]}" \
      -t "${CNLAB_LOCAL_IMAGE}:${VERSION}" \
      --load \
      "$CNLAB_ROOT"
    if ! docker inspect "${CNLAB_REGISTRY_NAME}" >/dev/null 2>&1; then
      echo "本地仓库 ${CNLAB_REGISTRY_NAME} 不存在，请先执行： ./hack/kind-up.sh" >&2
      exit 1
    fi
    docker push "${CNLAB_LOCAL_IMAGE}:${VERSION}"
    log "已推送。集群内可直接引用 ${CNLAB_LOCAL_IMAGE}:${VERSION}"
    ;;

  multiarch)
    OUT="${2:-/tmp/cnlab-multiarch.tar}"
    log "构建多架构镜像 (linux/amd64 + linux/arm64) -> ${OUT}"
    docker buildx build \
      --platform linux/amd64,linux/arm64 \
      "${COMMON_ARGS[@]}" \
      --output "type=oci,dest=${OUT}" \
      "$CNLAB_ROOT"
    ls -lh "$OUT"
    ;;

  *)
    echo "未知操作：${ACTION}（可用：build / push-local / multiarch）" >&2
    exit 1
    ;;
esac
