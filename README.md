# cnlab

**一个故意把应用写得很薄、把交付链路做得很厚的 Go 练习项目。**

Go 代码只有一个文件、只用标准库、零第三方依赖。省下来的全部复杂度，都放在了它被交付到 Kubernetes 的方式上：Dockerfile、kind、Kustomize 多环境、GitHub Actions、ArgoCD。

目标不是"做出一个能用的服务"，而是让下面这条链路里的每一环都**可解释、可验证、可复现**：

```
main.go ──▶ Dockerfile ──▶ 镜像仓库 ──▶ Kustomize overlay ──▶ kind/K8s ──▶ ArgoCD
                 ▲                                                        ▲
                 │                                                        │
           GitHub Actions ─────────────────────────────────────────────────┘
              (构建 + 推送)              (把新 tag 写回 git，ArgoCD 自己来拉)
```

## 为什么又起一个项目

前一个项目 [cn-starter](../cn-starter) 用的是 Kratos 布局：DDD 分层、wire 依赖注入、sqlc、buf/protobuf 代码生成。骨架很完整，但结果是——**想练的东西被业务脚手架淹没了**。

当 `internal/application`、`internal/domain`、`internal/infrastructure` 三层摆在那里时，你很难集中注意力去回答真正的问题：

- 为什么 liveness 和 readiness 必须是两个端点？
- 收到 SIGTERM 之后那几秒到底应该发生什么？
- `terminationGracePeriodSeconds` 和容器里的 drain 时间是什么关系？
- CI 到底该不该有 `kubectl apply` 这一步？
- `imagePullPolicy` 为什么能在本地把你坑一个小时？

cnlab 把这些问题单独拎出来，用最少的应用代码承载它们。**应用是载体，交付链路才是内容。**

## 交付链路里被刻意做出来的东西

| 环节 | 做了什么 | 为什么这么做 |
|---|---|---|
| 应用 | 单文件标准库，零依赖，静态二进制 | 让镜像 14MB、构建秒级，注意力不被依赖管理分散 |
| 探针 | `/healthz` 与 `/readyz` 语义严格分离 | 存活失败会重启、就绪失败只摘流量，混用会把小故障放大成雪崩 |
| 优雅下线 | SIGTERM → 探针失败 → 等 drain → 等在途请求结束 | 这是滚动更新零中断的全部秘密 |
| 指标 | 手写 Prometheus 文本格式 | 看清 `/metrics` 只是一段约定格式的文本，没有魔法 |
| 镜像 | 多阶段构建 → distroless static → 非 root | 没有 shell、没有 libc，攻击面接近于零 |
| 构建 | 多架构（amd64 + arm64）+ `--platform=$BUILDPLATFORM` | 交叉编译交给 Go，不装 QEMU，快一个数量级 |
| 清单 | Kustomize base + dev/staging/prod overlays | 环境差异被显式列举，而不是两套互相复制的 YAML |
| 集群 | kind + 本地 registry | 集群可随时销毁重建；本地镜像地址与生产结构一致 |
| CI | GitHub Actions：质量门 / 清单校验 / 多架构镜像 | **没有 `kubectl apply`** |
| CD | ArgoCD 从 git 拉期望状态 | 集群凭证从不离开集群；漂移会被自动纠回 |

## 快速开始

前置：Go 1.25+、Docker、`gh` CLI（可选，用于跑 CI）。

> **关于 Docker 内存**：本项目全部内容是在 Docker 只分配 **4GB** 内存的机器上跑通的
> （这也是集群只起 1 控制面 + 1 工作节点的原因）。如果你想练 `podAntiAffinity`、
> 拓扑分布这类需要多节点的话题，把 Docker 内存提到 8GB 以上，再把 `kind/cluster.yaml`
> 里的 worker 加成两个。

```bash
# 1. 装工具到项目内 bin/（不依赖 brew，版本写在脚本里）
make tools

# 2. 起本地集群：一个 registry + 一个 kind 集群（1 控制面 + 1 工作节点）
make kind-up

# 3. 构建镜像并推进本地仓库
make image-push-local

# 4. 部署 dev 环境
make deploy-dev

# 5. 打通一次请求
make smoke

# 6. 之后每次改完代码，重复第 3 步，并显式重启 Pod
make image-push-local && make rollout-restart
```

> **为什么第 6 步需要 `rollout-restart`？**（这是内循环最容易踩的一点）
>
> dev 用的 tag 是固定值 `:dev`，改代码不会改变 Deployment 里的任何字段：
> 镜像地址没变、ConfigMap 内容没变（哈希也没变）→ **Pod 模板完全一致 →
> `make deploy-dev` 是一次空操作**。新镜像安静地躺在本地仓库里，而 K8s
> 没有任何理由去替换 Pod。所以推完镜像必须显式 `rollout restart`。
>
> 注意这和"改 ConfigMap 会自动触发滚动更新"**恰好相反**——后者靠的是
> `configMapGenerator` 的哈希后缀改变了 Pod 模板。这两种行为的差别，
> 是理解"什么会让 Deployment 滚动"的最好入口。

想验证"滚动更新期间零中断"这个核心承诺：

```bash
make zero-downtime
```

它会先故意提交一个不安全的 Pod（被 Pod Security Admission 拒绝），再启动一个合规的压测 Pod 持续访问 Service，然后在压测进行中触发滚动更新，最后给出失败计数。期望结果是 `fail=0`，以及旧 Pod 完整的优雅下线日志。

### 走一遍完整的 GitOps 闭环

```bash
make argo-install      # 把 ArgoCD 装进 kind
make argo-password     # 取 admin 初始密码
make argo-ui           # https://localhost:8443
make argo-bootstrap    # 应用 app-of-apps 根 Application
make argo-status       # 看同步状态
```

之后：
1. 改一行 Go 代码，推到 `main`
2. GitHub Actions 跑质量门 → 构建多架构镜像推 GHCR → **把新 tag 写回 `deploy/overlays/staging`**
3. ArgoCD 发现 git 变了，自动同步到集群
4. **全程没有人执行过部署命令**

顺带可以体验漂移检测：

```bash
# 手动把副本数改掉（模拟"有人上服务器改配置"）
kubectl -n cnlab-dev scale deploy/cnlab --replicas=3

# 几秒后 ArgoCD 会把它改回去，因为 git 里写的是 1
kubectl -n cnlab-dev get deploy cnlab -w
```

## 目录结构

```
cnlab/
├── main.go                     # 整个应用。一个文件，只有标准库
├── main_test.go                # 含真实驱动完整生命周期（含优雅退出）的测试
├── Dockerfile                  # 多阶段 → distroless static → 非 root
├── Makefile                    # 命令编排层，逻辑都在 hack/ 里
├── .golangci.yml               # lint 规则
├── .github/workflows/ci.yml    # 质量门 / 清单校验 / 多架构镜像 / 期望状态更新
│
├── deploy/
│   ├── base/                   # 与环境无关的部分
│   └── overlays/
│       ├── dev/                # localhost:5001，可变 tag，1 副本
│       ├── staging/            # ghcr.io，CI 自动写入 tag，2 副本
│       └── prod/               # ghcr.io，不可变 tag，3 副本 + PDB + 反亲和
│
├── gitops/
│   ├── bootstrap/root-app.yaml # app-of-apps 唯一入口
│   ├── apps/                   # dev / staging 的 Application（自动同步）
│   └── examples/               # prod Application 模板（不自动同步）
│
├── kind/cluster.yaml           # 集群形状 + 本地仓库接线
├── hack/                       # 所有脚本：环境、集群、镜像、验收
└── docs/                       # 中文实操文档与踩坑记录
```

## 应用契约

应用代码不是重点，但它必须提供正确的"接缝"。这些是与部署侧的接口。

### 端点

| 方法 | 路径 | 语义 |
|---|---|---|
| GET | `/healthz` | **存活**。永远 200，只要进程还在。绝不检查下游依赖 |
| GET | `/readyz` | **就绪**。预热完成前、收到 SIGTERM 后返回 503 |
| GET | `/metrics` | Prometheus 文本格式指标 |
| GET | `/api/v1/greet?name=X` | 业务端点（回显 `GREETING` 和 Pod 名） |
| GET | `/api/v1/slow?d=2s` | 人为延迟。用来观察探针超时、滚动更新、drain 窗口 |
| GET | `/api/v1/version` | 版本 / commit / 构建时间 / Go 版本 |
| POST | `/api/v1/admin/shutdown` | 仅当 `ENABLE_ADMIN=true` 时注册，用于本地演示优雅退出 |

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `APP_ENV` | `dev` | 环境标识，会出现在日志和指标标签里 |
| `PORT` | `8080` | 监听端口 |
| `LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |
| `LOG_FORMAT` | `json` | `json` / `text` |
| `DRAIN_DELAY` | `5s` | 收到 SIGTERM 后、关闭监听器前的等待时间 |
| `SHUTDOWN_TIMEOUT` | `15s` | 等待在途请求结束的上限 |
| `READY_DELAY` | `0s` | 人为延迟就绪，用来制造"慢启动"。注意它只影响 `/readyz`，单独特意调大不会导致重启——见[练习 1.1](docs/07-动手练习.md) |
| `ENABLE_ADMIN` | `false` | 是否注册 `/api/v1/admin/shutdown`。生产必须保持 false |
| `GREETING` | `hello` | 业务用的可配置值，用来演示 ConfigMap 变更触发滚动更新 |

### 三个时间参数必须对齐

```
terminationGracePeriodSeconds  ≥  DRAIN_DELAY + 最长请求耗时 + 余量
```

| 环境 | DRAIN_DELAY | terminationGracePeriodSeconds |
|---|---|---|
| dev | 3s | 30s |
| staging | 5s | 30s |
| prod | 10s | 45s |

对不齐的后果很具体：kubelet 会在应用还在收尾时直接 SIGKILL。现象是日志里看不到「已优雅退出」那一行，并且偶发 502。

## 常用命令

```bash
make help                # 看全部目标

# 本地质量门
make check               # fmt-check + vet + lint + test
make cover               # 覆盖率

# 集群
make kind-up             # 起集群
make kind-down           # 删集群（保留镜像仓库）
make kind-nuke           # 全删

# 镜像
make image               # 只构建到本地 docker
make image-push-local    # 构建并推本地仓库
make image-multiarch     # 验证 amd64+arm64 构建路径

# 部署 / 观察
make render-dev          # 只看渲染结果，不部署
make diff-dev            # 看集群与期望状态的差异
make deploy-dev
make validate            # 用集群做服务端 dry-run 校验全部 overlay
make status / logs / smoke / zero-downtime

# GitOps
make argo-install / argo-password / argo-ui / argo-bootstrap / argo-status
```

## 文档

| 文档 | 内容 |
|---|---|
| [交付链路总览](docs/01-交付链路总览.md) | 一次代码变更从 `git push` 到集群生效的完整旅程 |
| [探针与优雅下线](docs/02-探针与优雅下线.md) | 三种探针的分工，以及 SIGTERM 之后的每一步 |
| [Kustomize 多环境](docs/03-Kustomize多环境.md) | base/overlay 到底该怎么切 |
| [GitOps 与 ArgoCD](docs/04-GitOps与ArgoCD.md) | push 式与 pull 式部署的分水岭、漂移检测 |
| [CI 流水线](docs/05-CI流水线.md) | 每个 job 在做什么，以及为什么没有 deploy 这一步 |
| [踩坑记录](docs/06-踩坑记录.md) | 本项目实际踩到的坑，含现象、根因、绕法 |
| [动手练习](docs/07-动手练习.md) | 按难度递增的练习清单 |

## 与本机环境有关的三处绕行

本项目在一台有特定限制的机器上开发完成，`hack/env.sh` 里集中处理了三件事。**它们不是 Go 或 Docker 的问题**，换台机器大概率不需要：

1. **brew 不可用** — `/opt/homebrew` 属主不是当前用户，brew 会以 exit 0 结束却什么都不装。所以 kind / kustomize 装进项目内 `bin/`，版本固定在 `hack/install-tools.sh` 里。
2. **goenv shim 覆写 `GOCACHE`** — shim 把 `GOCACHE` 指向 `$GOROOT/go-build-...`，而 GOROOT 不可写。后果是 go 报出极具误导性的 `package net/http is not in std`。`golangci-lint` 同样是 shim，会传递同样的错误值。
3. **宿主代理被透传进 kind 节点** — 节点容器里的 `127.0.0.1` 不是你的 Mac，导致 containerd 拉本地镜像时报 `proxyconnect tcp: dial tcp 127.0.0.1:10801: connect: connection refused`，表现为 `ImagePullBackOff`。

细节和完整现象见 [踩坑记录](docs/06-踩坑记录.md)。

## 已经验证过的结果

下面每一条都是在本机真实执行、看到实际输出的，不是"理论上可以"。全部可通过 `make` 目标复现。

| 验证项 | 命令 | 结果 |
|---|---|---|
| 代码格式 | `make fmt-check` | 通过（0.11s） |
| 静态检查 | `make vet` | 通过 |
| Lint | `make lint` | **0 issues**（golangci-lint v2.12.2） |
| 单元测试 | `make test` | 通过；`-race` 连跑 5 次稳定 |
| 覆盖率 | `make cover` | **77.8%** |
| 镜像构建 | `make image` | 成功，**14.1 MB** |
| 多架构构建 | `make image-multiarch` | linux/amd64 与 linux/arm64 均编译通过 |
| 容器优雅下线 | `docker stop` | **0.94s** 完成（DRAIN_DELAY=800ms）；在途 600ms 请求返回 200 |
| 清单渲染 | `make render-dev` | dev 5 / staging 5 / prod 6 个资源 |
| 清单 schema | `kubeconform -strict` | **16 个资源全部 Valid，0 Invalid** |
| 滚动更新零中断 | `make zero-downtime` | **60/60 请求成功，fail=0** |
| Pod Security | 提交一个 root Pod | 被 `restricted` 策略**拒绝** |
| CI 流水线 | GitHub Actions | 4 个 job 全绿（18s / 24s / 51s / 12s） |
| GitOps 自动同步 | 推送到 `main` | CI 写入 `sha-f24b9a4` → ArgoCD 自动同步到集群 |
| 漂移检测 | `kubectl scale --replicas=3` | ArgoCD **约 4 秒**自动纠回 1 副本 |

规模：`main.go` 624 行 + `main_test.go` 378 行，**零第三方依赖**（`go.mod` 里没有 `require` 块）。

其中 GitOps 闭环的三方一致性是最值得看的一条证据：

```
CI 写入期望状态的 tag       →  sha-f24b9a4
ArgoCD 同步到的 revision     →  e1293b3
集群里运行的镜像             →  ghcr.io/am-okalin/cnlab:sha-f24b9a4
应用自报的 /api/v1/version   →  version = sha-f24b9a4
                               commit  = f24b9a4e80edcb80af918e8ca06524333ae11ccf
```

注意两个字段的粒度不同：`version` 是 CI 计算的**短 sha**（`sha-${GITHUB_SHA::7}`），
而 `commit` 是构建时注入的 `${{ github.sha }}`，即**完整 40 位 sha**。两者指向同一个提交。

**镜像 tag ↔ git commit ↔ 运行时自报**三者对得上，才谈得上"线上跑的是哪份代码"可追溯。

## 已知边界

诚实地说明这个项目**没有**覆盖的东西，避免误以为它是一套生产模板：

- **单机集群**：本机 Docker 只分配了资源给一个 1 控制面 + 1 工作节点的集群。反亲和、拓扑分布用 `preferred` 而非 `required`，否则 Pod 会永远 Pending。要练这些，得把节点数加到 2 个 worker 以上。
- **没有可观测性栈**：`/metrics` 端点有了，但没有部署 Prometheus / Grafana / 日志聚合 / 链路追踪。
- **没有渐进式发布**：滚动更新是唯一策略，没有金丝雀、蓝绿、流量切分。
- **没有供应链安全**：没有镜像扫描、SBOM、签名、准入校验。
- **没有 Secret 管理**：只演示了 ConfigMap。真实项目需要 Sealed Secrets / External Secrets / SOPS 之类。
- **staging 与 prod 都指向 GHCR**，而本练习环境里它们未必能真的拉起来。dev 走本地仓库，是唯一保证可跑的路径。

这些都在 [动手练习](docs/07-动手练习.md) 里作为后续方向列出。

## License

[MIT](LICENSE)
