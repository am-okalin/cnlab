#!/usr/bin/env bash
# 验证并演示「滚动更新期间零中断」。
#
# 为什么用集群内的 Pod 施压，而不是本机 curl：
#   kubectl port-forward svc/cnlab 会把连接固定到"当时选中"的某一个 Pod 上。
#   滚动更新替换掉那个 Pod 时 port-forward 必然断开——这样测出来的"失败"
#   是测试方法的产物，不是服务的问题。
#   只有走 Service（由 kube-proxy 按 endpoints 转发）才算真正验证了
#   就绪探针 → endpoints 摘除 → 优雅下线 这一整条链路。
#
# 顺带演示 Pod Security Admission：
#   先故意提交一个不安全的 Pod 看它被拒绝，再提交合规的压测 Pod。
set -euo pipefail

HACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/env.sh
source "$HACK_DIR/env.sh"

CTX="kind-${CNLAB_CLUSTER}"
NS="cnlab-dev"
LOADGEN="cnlab-loadgen"
IMG="localhost:${CNLAB_REGISTRY_PORT}/alpine:3.20"
SVC_URL="http://cnlab.${NS}.svc.cluster.local"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

cleanup() {
  kubectl --context "$CTX" -n "$NS" delete pod "$LOADGEN" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$CTX" -n "$NS" delete pod psa-canary --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
log "0. 准备压测镜像"
# ---------------------------------------------------------------------------
if ! curl -sf "http://127.0.0.1:${CNLAB_REGISTRY_PORT}/v2/alpine/tags/list" | grep -q '3.20'; then
  docker tag alpine:3.20 "$IMG"
  docker push "$IMG" >/dev/null
  echo "  已推送 $IMG"
else
  echo "  $IMG 已在本地仓库"
fi

# ---------------------------------------------------------------------------
log "1. 先试一个不安全的 Pod（预期被 Pod Security Admission 拒绝）"
# ---------------------------------------------------------------------------
# cnlab-dev 命名空间打了 pod-security.kubernetes.io/enforce: restricted，
# 所以这个"以 root 运行、不丢 capabilities"的 Pod 根本进不来。
# 这就是为什么清单里写 securityContext 不是形式主义——它是被强制执行的。
if kubectl --context "$CTX" -n "$NS" run psa-canary \
  --image="$IMG" --restart=Never --dry-run=server >/dev/null 2>/tmp/psa-reject.txt; then
  echo "  ⚠ 未被拒绝（该命名空间可能没开启 restricted 强制）"
else
  sed -n 's/.*\(violates PodSecurity[^"]*\).*/  被拒绝：\1/p' /tmp/psa-reject.txt | head -3
  grep -q 'violates PodSecurity' /tmp/psa-reject.txt || head -3 /tmp/psa-reject.txt | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
log "2. 启动合规的压测 Pod，持续访问 Service"
# ---------------------------------------------------------------------------
MANIFEST="$(sed "s|__IMAGE__|${IMG}|" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: cnlab-loadgen
  labels:
    app: cnlab-loadgen
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: loadgen
      image: __IMAGE__
      command: ["sh", "-c"]
      args:
        - |
          SVC_URL="http://cnlab.cnlab-dev.svc.cluster.local"
          ok=0; fail=0; total=0
          while [ $total -lt 60 ]; do
            if [ $((total % 3)) -eq 0 ]; then
              url="$SVC_URL/api/v1/slow?d=300ms"
            else
              url="$SVC_URL/api/v1/greet?name=loadgen"
            fi
            total=$((total + 1))
            if wget -q -O /dev/null --timeout=5 "$url"; then
              ok=$((ok + 1))
            else
              fail=$((fail + 1))
              echo "FAILED request #$total"
            fi
          done
          echo "RESULT total=$total ok=$ok fail=$fail"
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
YAML
)"
echo "$MANIFEST" | kubectl --context "$CTX" -n "$NS" apply -f -
kubectl --context "$CTX" -n "$NS" wait --for=condition=Ready pod/"$LOADGEN" --timeout=60s

echo "  等待压测跑起来…"
sleep 3

# ---------------------------------------------------------------------------
log "3. 在压测进行中触发滚动更新"
# ---------------------------------------------------------------------------
# rollout restart 会给 Pod 模板打一个时间戳注解，从而触发一次滚动更新。
# 这是最接近"发布新版本"的本地等效操作。
OLD_POD="$(kubectl --context "$CTX" -n "$NS" get pod -l app.kubernetes.io/name=cnlab -o jsonpath='{.items[0].metadata.name}')"
echo "  将被替换的 Pod: ${OLD_POD}"

# 先把旧 Pod 的日志流式抓到文件里。
# 为什么要提前抓：Pod 一旦删除，kubectl logs 就再也读不到了，
# 而"已优雅退出"这最后一行恰恰出现在 Pod 即将消失的时刻。
OLD_LOG="$(mktemp)"
kubectl --context "$CTX" -n "$NS" logs -f "$OLD_POD" >"$OLD_LOG" 2>&1 &
LOG_PID=$!
sleep 1

kubectl --context "$CTX" -n "$NS" rollout restart deploy/cnlab

echo "  等待滚动更新完成…"
kubectl --context "$CTX" -n "$NS" rollout status deploy/cnlab --timeout=180s

echo "  等待旧 Pod（${OLD_POD}）完成优雅下线并消失…"
kubectl --context "$CTX" -n "$NS" wait --for=delete pod/"$OLD_POD" --timeout=120s >/dev/null 2>&1 || true
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true

echo "  等待压测跑完…"
for _ in $(seq 1 60); do
  phase="$(kubectl --context "$CTX" -n "$NS" get pod "$LOADGEN" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
  sleep 1
done

# ---------------------------------------------------------------------------
log "4. 结果"
# ---------------------------------------------------------------------------
echo "--- 压测输出 ---"
kubectl --context "$CTX" -n "$NS" logs "$LOADGEN" | sed 's/^/  /'

echo
echo "--- 被替换 Pod 的完整优雅下线日志 ---"
grep -E '终止信号|摘除|优雅退出|就绪' "$OLD_LOG" | sed 's/^/  /' || echo "  （未捕获到，请检查）"
rm -f "$OLD_LOG"

echo
echo "--- 当前 Pod ---"
kubectl --context "$CTX" -n "$NS" get pod -l app.kubernetes.io/name=cnlab -o wide | sed 's/^/  /'
