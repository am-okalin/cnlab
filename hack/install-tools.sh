#!/usr/bin/env bash
# 把 kind / kustomize 按固定版本装进项目内的 bin/。
#
# 为什么不 brew：
#   本机 /opt/homebrew 属主不是当前用户，brew 无法链接；Homebrew 缓存目录
#   又被沙箱拒绝写入。brew 会以 exit 0 结束但什么都不装，非常容易误判。
#   装到项目内 bin/ 的好处是可复现（版本写在脚本里）、可随时删、不污染系统。
# 想彻底修好 brew：sudo chown -R "$(whoami)" /opt/homebrew
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
mkdir -p "$BIN"

KIND_VERSION="${KIND_VERSION:-v0.33.0}"
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-v5.8.3}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64 | amd64) ARCH=amd64 ;;
  arm64 | aarch64) ARCH=arm64 ;;
  *)
    echo "不支持的架构: $ARCH" >&2
    exit 1
    ;;
esac

echo "==> platform: ${OS}/${ARCH}"

if [[ ! -x "$BIN/kind" ]]; then
  echo "==> downloading kind ${KIND_VERSION}"
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" -o "$BIN/kind"
  chmod +x "$BIN/kind"
else
  echo "==> kind 已存在，跳过"
fi

if [[ ! -x "$BIN/kustomize" ]]; then
  echo "==> downloading kustomize ${KUSTOMIZE_VERSION}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_${OS}_${ARCH}.tar.gz" \
    -o "$tmp/kustomize.tar.gz"
  tar -xzf "$tmp/kustomize.tar.gz" -C "$tmp"
  mv "$tmp/kustomize" "$BIN/kustomize"
  chmod +x "$BIN/kustomize"
else
  echo "==> kustomize 已存在，跳过"
fi

echo
# golangci-lint 内部会自己通过 PATH 去调用 `go`，于是又会踩到 GOCACHE
# 被 goenv shim 覆写成只读路径的坑。在 bin/ 里放一个指向真实 SDK 的软链，
# 把 bin/ 放到 PATH 最前面就能绕开。切换 Go 版本后需重新跑本脚本。
#
# 注意：这一步在 CI 里是多余的（GitHub runner 上没有 goenv），所以
# 找不到时只提示、不失败。下面几处都刻意用 if 而不是 `A && B` 的写法，
# 因为 `[[ ... ]] && cmd` 单独成句时，条件为假会让整个语句非零，
# 在 set -e 下可能中断脚本。
echo "==> linking real go into bin/ (绕过 goenv shim 的 GOCACHE 覆写)"
sdk_root=""
if sdk_root="$(go env GOROOT 2>/dev/null)"; then :; else sdk_root=""; fi

if [[ -n "$sdk_root" && -x "${sdk_root}/bin/go" ]]; then
  ln -sf "${sdk_root}/bin/go" "$BIN/go"
  echo "    $BIN/go -> ${sdk_root}/bin/go"
else
  echo "    未找到真实 go（GOROOT=${sdk_root:-空}），跳过 —— 普通环境不需要这个软链"
fi

# golangci-lint 自己也是一个 goenv shim：goenv exec 会给它注入那个只读的
# GOCACHE，它再传给内部的 go，于是照样失败。同样软链真实二进制绕开。
lint_real="${sdk_root}/bin/golangci-lint"
if [[ -n "$sdk_root" && -x "$lint_real" ]]; then
  ln -sf "$lint_real" "$BIN/golangci-lint"
  echo "    $BIN/golangci-lint -> $lint_real"
else
  echo "    未找到 golangci-lint，跳过（CI 中由官方 action 提供）"
fi

echo
"$BIN/kind" version
"$BIN/kustomize" version
if [[ -x "$BIN/go" ]]; then
  "$BIN/go" version
fi
if [[ -x "$BIN/golangci-lint" ]]; then
  "$BIN/golangci-lint" --version
fi
echo
echo "工具已就绪: $BIN"
