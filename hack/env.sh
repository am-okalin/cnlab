#!/usr/bin/env bash
# cnlab 的共享环境准备。用法： source hack/env.sh
#
# 本机有三个环境坑，集中在这里处理，避免每个脚本各修一遍：
#
#  1) brew 装不了东西
#     /opt/homebrew 属主不是当前用户，brew 会以 exit 0 结束却什么都不装
#     （非常容易误判成"装好了"）。所以 kind / kustomize 都装进项目内 bin/，
#     见 hack/install-tools.sh。
#
#  2) goenv shim 把 GOCACHE 覆写成只读路径
#     shim 会把 GOCACHE 指到 $GOROOT/go-build-<host>-<host>-cgo，而 GOROOT 在
#     受限沙箱下不可写。后果是 go 报出极具误导性的
#     "package net/http is not in std" —— 看起来像标准库没了，其实只是
#     构建缓存写不进去。golangci-lint 同样是 goenv shim，会被注入同样的值。
#     绕法：把 bin/ 里的真实 go 放到 PATH 最前面，缓存全部放进 .cache/。
#
#  3) buildx 要写 ~/.docker/buildx/activity，同样不可写
#     绕法：把 BUILDX_CONFIG 指到 .cache/buildx。
#
# 请注意：这些坑来自"受限沙箱 + goenv + 非用户属主的 homebrew"这套组合，
# 不是 Go 或 Docker 本身的问题。在普通终端里 go / docker 通常可以直接用。

CNLAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CNLAB_ROOT

CNLAB_CACHE="${CNLAB_CACHE:-${CNLAB_ROOT}/.cache}"
export CNLAB_CACHE

# 1) 项目内工具优先（bin/go、bin/golangci-lint 是绕过 goenv shim 的软链）
export PATH="${CNLAB_ROOT}/bin:${PATH}"

# 2) Go 的各类缓存全部落在工作区内
export GOCACHE="${CNLAB_CACHE}/gocache"
export GOTMPDIR="${CNLAB_CACHE}/gotmp"
export GOPATH="${CNLAB_CACHE}/gopath"
export GOMODCACHE="${CNLAB_CACHE}/gomodcache"
export GOLANGCI_LINT_CACHE="${CNLAB_CACHE}/golangci-lint"

# 3) buildx 的配置目录
export BUILDX_CONFIG="${CNLAB_CACHE}/buildx"

# 4) kubeconfig 也放进工作区
#    ~/.kube/config 在受限沙箱下不可写，kind 会因此失败，报出
#    "failed to lock config file: operation not permitted"。
#    而此时集群其实已经建好了，只是 kubeconfig 没写出来 —— 很容易误判成建集群失败。
#    放在项目内还有个额外好处：完全不污染你本机真实的 ~/.kube/config，
#    想清干净直接删 .cache/ 就行。
export KUBECONFIG="${CNLAB_KUBECONFIG:-${CNLAB_CACHE}/kubeconfig}"

# 5) 代理：把本地镜像仓库排除在外
#    宿主设了 http_proxy=http://127.0.0.1:10801，而 kind 会把这些代理变量
#    透传进节点容器。问题在于：节点容器里的 127.0.0.1 是它自己，不是你的 Mac。
#    于是 containerd 拉取本地仓库时会去连节点自己的 10801 端口，报出
#      proxyconnect tcp: dial tcp 127.0.0.1:10801: connect: connection refused
#    最终表现为 ImagePullBackOff。这个错误信息里完全看不到"代理"两个字，
#    从 kubelet 事件几乎不可能一眼定位。
#    kind 会自动往 NO_PROXY 里追加自己的网段，但不会加我们的仓库主机名，
#    所以必须在这里显式补上，并且要在【创建集群之前】生效——
#    代理变量是烘进节点容器的，集群建好之后改宿主的 NO_PROXY 没有用，
#    只能删掉重建（见 docs/踩坑记录）。
CNLAB_NO_PROXY="kind-registry,kind-registry:5000,localhost,127.0.0.1"
export NO_PROXY="${CNLAB_NO_PROXY}${NO_PROXY:+,${NO_PROXY}}"
export no_proxy="${CNLAB_NO_PROXY}${no_proxy:+,${no_proxy}}"

mkdir -p "$GOCACHE" "$GOTMPDIR" "$GOPATH" "$GOMODCACHE" \
  "$GOLANGCI_LINT_CACHE" "$BUILDX_CONFIG"

# --- 项目常量：脚本与 Makefile 共用，避免各处硬编码 ---
export CNLAB_CLUSTER="${CNLAB_CLUSTER:-cnlab}"
export CNLAB_REGISTRY_NAME="${CNLAB_REGISTRY_NAME:-kind-registry}"
export CNLAB_REGISTRY_PORT="${CNLAB_REGISTRY_PORT:-5001}"

# dev 环境用的本地镜像地址。注意它和下面的 GHCR 地址结构完全一致——
# 这正是本地仓库存在的意义：让 overlay 只需要改 registry 前缀和 tag。
export CNLAB_LOCAL_IMAGE="localhost:${CNLAB_REGISTRY_PORT}/cnlab"
export CNLAB_GHCR_IMAGE="ghcr.io/am-okalin/cnlab"

# 当前机器的架构，用于单架构构建
case "$(uname -m)" in
  x86_64 | amd64) CNLAB_HOST_ARCH=amd64 ;;
  arm64 | aarch64) CNLAB_HOST_ARCH=arm64 ;;
  *) CNLAB_HOST_ARCH="$(uname -m)" ;;
esac
export CNLAB_HOST_ARCH
