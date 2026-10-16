# cnlab 顶层 Makefile。
#
# 设计原则：Makefile 只做「命令编排」，不重复实现逻辑。
# 所有需要环境准备的目标，都先 source hack/env.sh —— 本机的三处环境坑
# （brew 不可用、goenv 覆写 GOCACHE、buildx 配置目录不可写）集中在那里处理。
# 集群和镜像的复杂步骤则各自放进 hack/*.sh，Makefile 只负责调用。

SHELL := /usr/bin/env bash

# 每个 recipe 的前缀：先加载环境，再执行命令。
RUN := source $(CURDIR)/hack/env.sh &&

# --- 与 hack/env.sh 保持一致的常量 ---
CLUSTER       := cnlab
CLUSTER_CTX   := kind-cnlab
REGISTRY_NAME := kind-registry
REGISTRY_PORT := 5001
LOCAL_IMAGE   := localhost:$(REGISTRY_PORT)/cnlab
GHCR_IMAGE    := ghcr.io/am-okalin/cnlab

VERSION    ?= dev
COMMIT     := $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

LDFLAGS := -s -w \
  -X main.version=$(VERSION) \
  -X main.commit=$(COMMIT) \
  -X main.buildTime=$(BUILD_TIME)

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
.PHONY: help
help: ## 显示所有可用目标
	@echo "cnlab —— 云原生交付链路练习"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "第一次使用： make tools && make kind-up && make image-push-local && make deploy-dev"

# ---------------------------------------------------------------------------
# 工具链
# ---------------------------------------------------------------------------
.PHONY: tools
tools: ## 下载 kind / kustomize 到 bin/（不依赖 brew）
	@./hack/install-tools.sh

# ---------------------------------------------------------------------------
# 本地开发
# ---------------------------------------------------------------------------
# 注意：这里刻意不写 `gofmt -l .`，而是只检查 git 跟踪的 .go 文件。
#
# 原因是本机的 Go 缓存被放在项目内的 .cache/ 下（见 hack/env.sh），
# 而 gofmt 会无差别递归整个目录树 —— 于是 .cache/gomodcache 里成千上万个
# 第三方库和 Go 工具链自身的源文件都会被当成待检查对象。后果有两个：
# 既慢得离谱，又会刷出一屏"未格式化"的误报（工具链的测试数据本来就是
# 故意不合法的 Go 源码）。
#
# go 工具链自己会忽略以 . 开头的目录，所以 `go vet ./...` / `go test ./...`
# 不受影响；受影响的只有 gofmt 这种自己遍历文件系统的工具。
GOSOURCES := $(shell git ls-files '*.go')

.PHONY: fmt
fmt: ## 格式化代码
	@$(RUN) gofmt -w $(GOSOURCES)

.PHONY: fmt-check
fmt-check: ## 检查格式（CI 用，不修改文件）
	@$(RUN) unformatted="$$(gofmt -l $(GOSOURCES))"; \
	  if [ -n "$$unformatted" ]; then \
	    echo "以下文件未格式化，请执行 make fmt："; echo "$$unformatted"; exit 1; \
	  fi; \
	  echo "格式检查通过"

.PHONY: vet
vet: ## go vet
	@$(RUN) go vet ./...

.PHONY: lint
lint: ## golangci-lint
	@$(RUN) golangci-lint run ./...

.PHONY: test
test: ## 跑测试（带 -race）
	@$(RUN) go test -race -count=1 ./...

.PHONY: cover
cover: ## 跑测试并输出覆盖率
	@$(RUN) go test -count=1 -coverprofile=.cache/cover.out ./... \
	  && go tool cover -func=.cache/cover.out | tail -1

.PHONY: build
build: ## 编译二进制到 bin/cnlab
	@$(RUN) go build -trimpath -ldflags "$(LDFLAGS)" -o bin/cnlab .
	@ls -lh bin/cnlab

.PHONY: run
run: ## 本机直接运行（默认 8080 端口）
	@$(RUN) go run .

.PHONY: check
check: fmt-check vet lint test ## 一次跑完所有本地质量门

# ---------------------------------------------------------------------------
# 镜像
# ---------------------------------------------------------------------------
.PHONY: image
image: ## 构建镜像到本地 docker（cnlab:$(VERSION)）
	@./hack/image.sh build

.PHONY: image-push-local
image-push-local: ## 构建并推送到 kind 的本地仓库
	@./hack/image.sh push-local

.PHONY: image-multiarch
image-multiarch: ## 构建 amd64+arm64 多架构镜像为 OCI tar（验证 CI 的构建路径）
	@./hack/image.sh multiarch

# ---------------------------------------------------------------------------
# 集群
# ---------------------------------------------------------------------------
.PHONY: kind-up
kind-up: ## 创建本地 kind 集群 + 本地镜像仓库
	@./hack/kind-up.sh

.PHONY: kind-down
kind-down: ## 删除 kind 集群（保留镜像仓库）
	@./hack/kind-down.sh

.PHONY: kind-nuke
kind-nuke: ## 删除 kind 集群和镜像仓库
	@./hack/kind-down.sh --all

# ---------------------------------------------------------------------------
# 部署（Kustomize）
# ---------------------------------------------------------------------------
.PHONY: render-dev
render-dev: ## 渲染 dev 清单（不部署）
	@$(RUN) kustomize build deploy/overlays/dev

.PHONY: diff-dev
diff-dev: ## 显示 dev 环境与集群当前状态的差异
	@$(RUN) kustomize build deploy/overlays/dev | kubectl --context $(CLUSTER_CTX) diff -f - || true

.PHONY: deploy-dev
deploy-dev: ## 部署 dev 环境
	@$(RUN) kustomize build deploy/overlays/dev | kubectl --context $(CLUSTER_CTX) apply -f -

.PHONY: deploy-staging
deploy-staging: ## 部署 staging 环境
	@$(RUN) kustomize build deploy/overlays/staging | kubectl --context $(CLUSTER_CTX) apply -f -

.PHONY: undeploy-dev
undeploy-dev: ## 删除 dev 环境
	@$(RUN) kustomize build deploy/overlays/dev | kubectl --context $(CLUSTER_CTX) delete -f - --ignore-not-found

.PHONY: validate
validate: ## 用集群校验全部 overlay：命名空间已存在的走服务端 dry-run（含准入），否则明确降级
	@source $(CURDIR)/hack/env.sh; \
	set -e; \
	for dir in deploy/overlays/*/; do \
	  name="$$(basename "$$dir")"; \
	  printf -- "--- %-10s " "$$name"; \
	  if kustomize build "$$dir" | kubectl --context $(CLUSTER_CTX) apply --dry-run=server -f - >/dev/null 2>&1; then \
	    echo "OK  (server-side：含 Pod Security Admission 等准入校验)"; \
	  elif kustomize build "$$dir" | kubectl --context $(CLUSTER_CTX) apply --dry-run=client -f - >/dev/null 2>&1; then \
	    echo "OK  (client-side：目标命名空间尚未创建，跳过准入校验)"; \
	  else \
	    echo "FAILED"; \
	    kustomize build "$$dir" | kubectl --context $(CLUSTER_CTX) apply --dry-run=client -f - 2>&1 | sed 's/^/      /'; \
	    exit 1; \
	  fi; \
	done

# ---------------------------------------------------------------------------
# 观察
# ---------------------------------------------------------------------------
.PHONY: status
status: ## 查看 dev 环境状态
	@kubectl --context $(CLUSTER_CTX) -n cnlab-dev get deploy,po,svc,cm -o wide

.PHONY: logs
logs: ## 跟踪 dev 环境日志
	@kubectl --context $(CLUSTER_CTX) -n cnlab-dev logs -l app.kubernetes.io/name=cnlab --tail=50 -f

.PHONY: smoke
smoke: ## 通过 Service 打通一次请求（port-forward + curl）
	@echo ">>> 在后台建立 port-forward 8080 -> svc/cnlab:80"
	@kubectl --context $(CLUSTER_CTX) -n cnlab-dev port-forward svc/cnlab 8080:80 >/dev/null 2>&1 & \
	  PF_PID=$$!; \
	  sleep 2; \
	  echo "--- /healthz ---"; curl -s http://127.0.0.1:8080/healthz; echo; \
	  echo "--- /readyz ---";  curl -s http://127.0.0.1:8080/readyz;  echo; \
	  echo "--- /api/v1/version ---"; curl -s http://127.0.0.1:8080/api/v1/version; echo; \
	  echo "--- /api/v1/greet ---";   curl -s "http://127.0.0.1:8080/api/v1/greet?name=cnlab"; echo; \
	  kill $$PF_PID 2>/dev/null || true

.PHONY: rollout-restart
rollout-restart: ## 重启 dev 的 Pod。推了新镜像之后必须做这一步，原因见 README 的内循环说明
	@kubectl --context $(CLUSTER_CTX) -n cnlab-dev rollout restart deploy/cnlab
	@kubectl --context $(CLUSTER_CTX) -n cnlab-dev rollout status deploy/cnlab --timeout=180s

.PHONY: zero-downtime
zero-downtime: ## 验证滚动更新期间零中断（含 PSA 拒绝不安全 Pod 的演示）
	@./hack/zero-downtime-demo.sh

# ---------------------------------------------------------------------------
# ArgoCD / GitOps
# ---------------------------------------------------------------------------
.PHONY: argo-install
argo-install: ## 安装 ArgoCD 到 kind 集群
	@./hack/argo-install.sh

.PHONY: argo-password
argo-password: ## 打印 ArgoCD admin 初始密码
	@kubectl --context $(CLUSTER_CTX) -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argo-ui
argo-ui: ## 端口转发 ArgoCD UI 到 https://localhost:8443
	@echo ">>> https://localhost:8443  (用户 admin，密码见 make argo-password)"
	@kubectl --context $(CLUSTER_CTX) -n argocd port-forward svc/argocd-server 8443:443

.PHONY: argo-bootstrap
argo-bootstrap: ## 应用 app-of-apps 根 Application（GitOps 入口）
	@kubectl --context $(CLUSTER_CTX) apply -f gitops/bootstrap/root-app.yaml

.PHONY: argo-status
argo-status: ## 查看 ArgoCD 应用同步状态
	@kubectl --context $(CLUSTER_CTX) -n argocd get applications -o wide
