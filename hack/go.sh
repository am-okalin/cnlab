#!/usr/bin/env bash
# 直接运行 go 的小包装器，等价于：
#   source hack/env.sh && go "$@"
#
# 意义在于：即使不 source env.sh、不修改 PATH，也能跑对。
# 它会绕过 goenv shim —— shim 会把 GOCACHE 覆写成 GOROOT 下的只读路径，
# 导致 go 报出误导性的 "package net/http is not in std"。
set -euo pipefail

HACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/env.sh
source "$HACK_DIR/env.sh"

# env.sh 已把 bin/go（指向真实 SDK）放进 PATH 最前，这里再兜一层底：
# 万一 bin/go 还没被 install-tools.sh 创建，就回退到 shim。
sdk_root="$(go env GOROOT 2>/dev/null || true)"
real_go="${sdk_root}/bin/go"
if [[ ! -x "$real_go" ]]; then
  real_go="$(command -v go)"
fi

exec "$real_go" "$@"
