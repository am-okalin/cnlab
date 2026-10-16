# 04 · GitOps 与 ArgoCD：CI 该不该有 `kubectl apply`

这是本项目最想让人想清楚的一个问题。它表面上是"部署命令放在哪"，实际上问的是：

**集群的写权限，应该放在谁手里？**

`.github/workflows/ci.yml` 的第一个注释块就直接给了答案：

```yaml
# 这个工作流里没有 "deploy" 这一步，这是刻意的。
# ...
# 所以最后一个 job 叫 gitops —— 它做的是"提交一个新的期望状态"，
# 而不是"部署"。CD 不是这个文件里的某个 job，CD 是 ArgoCD 本身。
```

这篇文档解释这个选择背后的边界在哪里，以及一整套 GitOps 闭环是怎么搭起来、怎么被验证、又会怎么出错。

---

## 一、分水岭：凭证在哪里

两种模型的区别不在自动化程度，而在**集群凭证的存放位置**。

### push 式：CI 持有 kubeconfig

```
GitHub Actions ──(kubeconfig)──▶ API Server ──▶ 集群
```

CI 需要一个能写集群的凭证。这带来一串连锁后果：

| 后果 | 具体表现 |
|---|---|
| **凭证扩散** | kubeconfig 存在 CI secret 里。同仓库任何能改 workflow 的人，都可以加一步把 secret 打到日志里或者发到外部。fork PR 拿不到 secret，但协作者可以 |
| **轮换困难** | 集群重建、证书轮换后，要去**每一个**持有凭证的系统里同步更新。漏掉一个就是一次静默的部署失败 |
| **网络要求** | 集群 API Server 必须能被 CI runner 访问——要么公网可达（风险），要么 CI 接 VPN（复杂度） |
| **审计位置** | "谁在什么时候改了生产"这个问题的答案在 CI 的日志里，而 CI 日志有保留期 |
| **不知道最终状态** | CI 跑完就结束了它不知道有没有人随后手动改过集群。没有持续比对，就没有"漂移"这个概念 |

### pull 式：集群自己去拉

```
GitHub Actions ──(只写 git)──▶ git 仓库 ◀──(拉取)── ArgoCD (在集群内) ──▶ 集群
```

CI 只需要能写 git。集群凭证由 ArgoCD 在集群内使用，**从不离开集群**：

| 后果 | 具体表现 |
|---|---|
| **凭证不出集群** | 集群凭证给的是 ArgoCD 的 ServiceAccount，它天生就在集群里。攻击面从"CI 系统"收缩到"集群内部" |
| **轮换简单** | 轮换集群凭证不影响任何 CI 配置 |
| **网络要求反转** | 变成集群需要出网访问 git（通常比"CI 能访问生产 API Server"更容易接受） |
| **审计天然在 git** | 每次变更都是一次 commit，有作者、有时间、有 diff，且默认永久保留 |
| **持续比对** | ArgoCD 一直在跑，所以"集群和 git 不一致"是一个可以被观测、被报警的状态，而不是一个没人知道的事实 |

### 本项目如何落地

CI 的最后一个 job 叫 `gitops`，它做两件事：把镜像 tag 写进 `deploy/overlays/staging/kustomization.yaml`，然后 commit + push。它**没有**任何 `kubectl` 调用。

真正的"部署"由集群里的 ArgoCD 完成。这就是为什么 `make` 里同时存在两条看起来重复的路径：

```bash
make deploy-staging    # 手动 push 式。本地练习用，平时不该有人敲
make argo-bootstrap    # GitOps 入口。这才是正式路径
```

`deploy-staging` 保留下来是为了在 ArgoCD 还没装好时能验证清单本身没问题。它是一条**练习用**的旁路，不是交付路径。

---

## 二、app-of-apps：只有一次手动 `kubectl apply`

`gitops/bootstrap/root-app.yaml` 是整个体系的唯一入口。它是唯一一个需要人工 apply 的对象：

```bash
make argo-bootstrap
# 等价于 kubectl --context kind-cnlab apply -f gitops/bootstrap/root-app.yaml
```

它的特殊之处在 source 段：

```yaml
source:
  repoURL: https://github.com/am-okalin/cnlab.git
  targetRevision: main
  path: gitops/apps
  directory:
    # 递归扫描 gitops/apps/ 下的所有 YAML。
    # 于是"新增一个环境"= 往这个目录里加一个文件 + git push，
    # 不需要再碰集群 —— 这就是 GitOps 的杠杆所在。
    recurse: true

destination:
  server: https://kubernetes.default.svc
  # 子 Application 是 argocd 命名空间里的 CR，所以根应用的目的地就是 argocd。
  namespace: argocd
```

`recurse: true` 意味着 ArgoCD 会把 `gitops/apps/` 下的**每一个** YAML 都当成一个 Application 来同步。于是：

```
root-app (手动 apply 一次)
   │  扫描 gitops/apps/
   ├── cnlab-dev.yaml     → Application cnlab-dev      → 同步 deploy/overlays/dev
   └── cnlab-staging.yaml → Application cnlab-staging  → 同步 deploy/overlays/staging
```

**新增一个环境 = 加一个文件 + push。** 不需要 kubectl、不需要改 Makefile、不需要告诉任何人。这是 GitOps 相比"写一个部署脚本"最实在的差别：扩展方式从"改代码"变成了"加数据"。

实测（在一个跑着的集群上）：

```console
$ kubectl -n argocd get applications
NAME            SYNC STATUS   HEALTH STATUS   REVISION
cnlab-dev       Synced        Healthy         f24b9a4e80edcb80af918e8ca06524333ae11ccf
cnlab-root      Synced        Healthy         e1293b3a6611df8b4f513fda82603021dc4d5da6
cnlab-staging   Synced        Healthy         e1293b3a6611df8b4f513fda82603021dc4d5da6
```

三个 Application 里只有 `cnlab-root` 是人创建的，另外两个是它的产物。

### 那个 finalizer 不是装饰

```yaml
metadata:
  finalizers:
    - resources-finalizer.argocd.argoproj.io
```

去掉它，删除 root Application 时只会删掉 root 本身，下面两个子 Application 会变成孤儿——继续存在、继续同步、再也没有东西管它们。这是"删不干净"最常见的来源，而且在你**以为**已经清理干净的时候才暴露。

### `CreateNamespace=false`

```yaml
syncOptions:
  - CreateNamespace=false
```

因为这个项目的目标命名空间由 overlay 里的 `namespace.yaml` 显式管理。让 ArgoCD 也去创建同名 namespace 会造成两个 owner 争同一个对象：ArgoCD 创建的 namespace 不带 PSA 标签，而 overlay 里的带。**两个 owner**在 GitOps 里是个应该主动避免的状态。

---

## 三、`prune` 和 `selfHeal`：两个开关，各自的代价

这两个开关都在 `syncPolicy.automated` 下，语义完全不同：

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

| 开关 | 语义 | 方向 |
|---|---|---|
| `prune` | git 里删掉的资源，集群里也删掉 | 删除同步 |
| `selfHeal` | 集群里被手动改过的资源，改回 git 的样子 | 修改同步 |

### `prune` 是"声明式"的必要条件

没有 `prune`，ArgoCD 只会做加法：git 里新增资源会同步过去，但删掉一个资源文件，集群里的对象会**留着不动**。于是集群和 git 逐渐分叉，你无法再回答"集群里应该有什么"。所以 `prune: true` 是让 GitOps 真正成立的必要条件，不是可选项。

但它带来一个必须知道的危险，`root-app.yaml` 的注释专门标了警告：

```yaml
# ⚠️ 注意这个组合的威力：我们的 overlay 里包含 Namespace 资源，
# 而 Namespace 被删除时，里面的所有东西会跟着消失。
# 所以永远不要"顺手"把 overlay 里的 namespace.yaml 删掉再 push。
```

**具体会发生什么**：`deploy/overlays/dev/kustomization.yaml` 的 `resources` 里有 `namespace.yaml`。如果你觉得"命名空间早就建好了，这行多余"而删掉它并 push：

1. ArgoCD 渲染新版本，发现期望状态里没有 `Namespace/cnlab-dev`；
2. `prune: true` 生效，它删除 `Namespace/cnlab-dev`；
3. Kubernetes 删除 Namespace 时**级联删除其中所有对象**——Deployment、Service、ConfigMap、Pod，全部消失；
4. 然后 ArgoCD 继续同步剩下的资源，但它们的命名空间已经不存在了。

结果是一次看起来无害的"清理"，把整个环境的运行负载连根拔掉。`CreateNamespace=false` 让情况更糟：ArgoCD 不会帮你把命名空间建回来。这是"声明式的威力"的另一面——**在声明式系统里，删除一个文件是一次真实的破坏性操作**。

> 这条规则值得抄进任何用 Kustomize + ArgoCD 的项目：**包含 Namespace 资源的 overlay，不要手动删那个文件。** 要下线一个环境，应该删掉对应的 `Application`（或者让它指向一个空目录），而不是删 namespace.yaml。

### `selfHeal` 是"漂移检测"的实现

`selfHeal: true` 让 ArgoCD 持续把集群状态和 git 状态比对，发现不一致就改回来。它依赖的基础是：**ArgoCD 从来没有"部署完就不管"这个状态**，它一直在 reconcile。第五节有实测。

---

## 四、为什么 prod 的 Application 没有 `automated`

`gitops/examples/cnlab-prod.yaml` 和另外两个的差别就这一处：

```yaml
syncPolicy:
  # 这里是和 dev/staging 最重要的区别：没有 automated 段。
  #
  # 没有 automated 意味着 ArgoCD 仍然会持续比对 git 与集群状态，
  # 发现漂移就在 UI 上标成 OutOfSync —— 但它不会动手。
  # 上线这个动作必须由人（或受控的流水线）显式触发 sync。
```

先把一个常见误解拆掉：**没有 `automated` ≠ 不检测。** ArgoCD 照样持续比对，照样把差异标成 `OutOfSync`，只是不自动执行。你依然拥有完整的漂移可见性，失去的只有"自动执行"这一个动作。

为什么生产要这样：

- **自动同步 + prune 的组合，让一次错误的合并可以无声删掉生产资源。** 前面第三节的 Namespace 例子在生产上就是一次事故。dev 环境删掉命名空间，重跑一次 `make kind-up` 就回来了；生产不是。
- **人工确认不是官僚主义。** 它在"快"和"可挽回"之间做选择。日常几秒的部署延迟，换的是"没有任何一次变更可以在无人知晓的情况下生效"。

代价也要说清楚：`automated` 关掉之后，**回滚速度取决于人**。半夜出问题时，从"发现异常"到"有人点 sync"之间的时间就是故障时长。所以这个选择只在有 on-call 的情况下成立——否则自动同步反而是更小的恶。

### 折中选项

`cnlab-prod.yaml` 的注释给了第三条路：

```yaml
# 折中方案（可选）：保留 automated.selfHeal 但关掉 prune，
# 这样手动改动会被纠正，但删资源必须由人来做。
```

即：

```yaml
syncPolicy:
  automated:
    selfHeal: true
    # prune 不给 —— 保留"改动会被纠回"，去掉"删除自动执行"
```

这覆盖了最常见的漂移场景（有人上服务器 `kubectl edit`），同时把不可逆的删除动作留给人工。对大多数团队来说，这是比"全手动"更实用的默认值。

### 为什么它放在 `examples/` 而不是 `apps/`

`root-app.yaml` 的 `recurse: true` 会扫描 `gitops/apps/` 下的所有 YAML。所以把 `cnlab-prod.yaml` 放在 `gitops/apps/` 里就等于**自动启用了生产环境**。

这里有一个值得注意的设计手法：**用目录位置承载语义**。文件内容里没有一行写着"不要自动应用"，但"它在 `examples/` 而不是 `apps/`"这件事本身就是约束——而且这个约束由 root app 的扫描路径强制执行，不依赖任何人记住一条规则。启用它的方式是显式的一次操作：

```bash
kubectl --context kind-cnlab apply -f gitops/examples/cnlab-prod.yaml
```

---

## 五、漂移检测：手动改集群，几秒后被纠回

这是 GitOps 最直观的一次演示。在集群跑起来、ArgoCD 同步完成之后：

```bash
# 模拟"有人上服务器改配置"
kubectl --context kind-cnlab -n cnlab-dev scale deploy/cnlab --replicas=3

# 观察它被改回去
kubectl --context kind-cnlab -n cnlab-dev get deploy cnlab -w
```

实测结果是**约 4 秒**后被纠回 `replicas: 1`（git 里 dev 写的是 1）。

4 秒这个数字值得解释一下，因为它容易让人以为 ArgoCD 在"高频轮询 git"——并不是。两个不同的时间尺度要分开：

| 机制 | 节奏 | 负责什么 |
|---|---|---|
| 集群状态比对 | ArgoCD 通过 informer 感知集群对象变化，秒级 | 发现"集群被改了" |
| git 轮询 | 默认约 3 分钟一次 | 发现"git 被改了" |

`selfHeal` 要发现的是**集群侧**的改动，ArgoCD 对集群对象有 watch，所以反应是秒级——不需要等下一轮 git 轮询。反过来说，你在 git 里 push 一个新 tag 之后，**可能要等 3 分钟**才会被同步（见下一节）。

这个演示的结论比"ArgoCD 好用"更具体：**在 selfHeal 打开的环境里，手动修改集群是没有意义的操作。** 你在集群上的每一次 `kubectl edit` 都是在制造一个会被自动清理的临时状态。想改配置，唯一的入口是 git。这正是"git 是唯一事实来源"从口号变成机制的地方。

---

## 六、轮询节奏与强制刷新

默认约 3 分钟的 git 轮询在两种场景下都不够用：

- **等 CI 生效。** push 之后想立刻看到部署结果，干等 3 分钟很折磨。
- **回滚。** 出问题时 3 分钟的发现延迟直接算进故障时长，这是不可接受的。

手动强制刷新：

```bash
kubectl -n argocd annotate application cnlab-staging \
  argocd.argoproj.io/refresh=hard --overwrite
```

（`normal` 只会重新比对已有缓存，`hard` 会重新拉取 git。要立刻看到 git 的变化，用 `hard`。）

**但生产不应该靠这个。** 正确的做法是配 webhook：让 GitHub 在 push 时通知 ArgoCD，把轮询从"定时拉"变成"事件推"。

```
GitHub push ──webhook──▶ argocd-server /api/webhook ──▶ 立即刷新
```

这样"CI 提交 → 集群同步"的延迟从约 3 分钟降到秒级，而且不需要任何人有集群权限去敲 refresh。本练习环境没配 webhook（需要一个 GitHub 能访问到的 ArgoCD 地址），所以演示时用上面的 annotate；**把它当成临时手段，不要当成流程**。

---

## 七、不可变 tag：三方一致的可追溯链

这是整个链路收口的地方。集群里 staging 正在跑：

```console
$ kubectl -n cnlab-staging get deploy cnlab -o jsonpath='{.spec.template.spec.containers[0].image}'
ghcr.io/am-okalin/cnlab:sha-f24b9a4
```

这个 tag 是 CI 写进 git 的。`git log` 里对应的那次提交：

```console
$ git log --oneline -3
e1293b3 chore(gitops): staging -> sha-f24b9a4 [skip ci]
f24b9a4 fix(ci): 修掉清单校验失败，并让 GitOps 写入不可变 tag
7f6c64f fix(kind): 创建集群时不把宿主代理透传进节点
```

而应用运行时自报（从集群里实际取回）：

```console
$ curl -s http://127.0.0.1:18080/api/v1/version
{"app_env":"staging","build_time":"2026-10-16T05:35:16Z",
 "commit":"f24b9a4e80edcb80af918e8ca06524333ae11ccf",
 "go_version":"go1.25.14","version":"sha-f24b9a4"}
```

三方串起来了：

```
镜像 tag              git commit              运行时自报
sha-f24b9a4    ←→     f24b9a4e80…   ←→    version=sha-f24b9a4
                                          commit =f24b9a4e80…
```

**注意两个字段的粒度不同**，这一点容易被忽略：`version` 是 CI 计算的短 sha（`sha-${GITHUB_SHA::7}`），而 `commit` 是构建时注入的 `${{ github.sha }}`，即完整 40 位 sha。所以自报里 `version` 是 `sha-f24b9a4`，`commit` 是 `f24b9a4e80edcb80af918e8ca06524333ae11ccf`——它们指向同一个提交，只是一个是短 sha、一个是全 sha。

这条链回答了那个最关键的问题：**"线上跑的这个 Pod，到底是哪份代码？"** 从一个正在运行的 Pod 出发，你可以反向定位到镜像 tag、到 git commit、到那次 CI 运行的日志，全程不需要问任何人。

它的前提是 tag 不可变。所以才有下面这个坑。

### 真实踩坑：CI 把 `latest` 写进了 GitOps 仓库

第一次 CI 运行之后，`git log` 里出现的是：

```console
d072b69 chore(gitops): staging -> latest [skip ci]
```

从那次运行的日志能看到现场：

```console
$ kustomize edit set image "cnlab=ghcr.io/am-okalin/cnlab:latest"
--- 改动后的 images 段 ---
images:
- name: cnlab
  newName: ghcr.io/am-okalin/cnlab
  newTag: latest
```

**根因**不是手滑，而是一条不明显的优先级规则。当时的 workflow 用 `docker/metadata-action` 的 `version` 输出去更新期望状态，而 metadata-action 会按优先级从多个规则里**挑一个** tag 作为 `version` 输出。原来的配置（`git show ea73ba4:.github/workflows/ci.yml`）是：

```yaml
- name: 生成镜像标签与 OCI 元数据
  id: meta
  uses: docker/metadata-action@v6
  with:
    tags: |
      # main 分支 -> sha-<短 sha>。用不可变的提交号做 tag，
      # 才能回答"线上这个 Pod 到底是哪份代码"。
      type=sha,format=short,prefix=sha-
      # 打 v* tag 时 -> 直接用这个版本号
      type=ref,event=tag
      # main 分支额外打一个 latest（方便人类，生产别用它）
      type=raw,value=latest,enable={{is_default_branch}}
```

单看这段配置，意图完全正确：主 tag 是 `sha-<短 sha>`，再额外打一个 `latest` 方便人类。问题在于它被当作**两个不同的东西**用了——生成镜像标签时，多打一个 `latest` 是无害的；但 `version` 这个**输出**只能有一个值。运行日志里能看到 metadata-action 的优先级判定：

```console
type=raw,value=latest,enable={{is_default_branch}},priority=200
```

`type=raw` 的 `latest` 拿到了 200，高于 `type=sha` 的 `sha-xxx`。于是 `version` 输出的是 `latest`，然后被原样写进了 GitOps 仓库。**注释里明明写着"生产别用它"，而它恰恰就是被用到的那个。**

**后果有两层，第二层更严重：**

1. staging 跑的是 `:latest`，`kubectl describe` 看到的是一个无意义的 tag，"这个 Pod 是哪份代码"重新变成不可回答的问题。上面那条可追溯链直接断掉。
2. `:latest` 会被**下一次构建覆盖**。等到需要回滚时，`latest` 已经指向更新的代码了——**你没有任何 tag 可以退回**。不可变 tag 的价值在需要回滚的那一刻才兑现，而 `latest` 让回滚这个动作根本不存在。

**修法**是显式计算 tag，不再依赖 action 的优先级规则。现在 `ci.yml` 里这一步是：

```yaml
- name: 计算不可变 tag
  id: tag
  run: |
    set -euo pipefail
    if [[ "${GITHUB_REF_TYPE}" == "tag" ]]; then
      echo "value=${GITHUB_REF_NAME}" >> "$GITHUB_OUTPUT"
    else
      echo "value=sha-${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
    fi
```

代码旁边留了注释记录这次教训：

```yaml
# 自己算最直白，也不用去记 action 的优先级规则。
```

**真正的教训不只是"别用 latest"**，而是：**自动化的输出也必须被验证。** metadata-action 并没有出错，它按文档里的优先级正确工作了；出错的是"没有检查它输出的到底是什么"。CI 里任何下游会依赖的值，都值得像这样显式算一遍或者断言一次——尤其当它来自一个你不完全掌握规则的第三方 action 时。

---

## 八、从零重建整套 GitOps

在一台已经装好 Docker、Go、并且 `make tools` 跑过的机器上：

```bash
# ---- 1. 集群 ----
make kind-up
# 起一个本地 registry + kind 集群（1 控制面 + 1 工作节点）
# 单节点是因为本机 Docker Desktop 只分配了 4GB 内存：
# 控制面自身约 700MB，再叠两个 worker 和 ArgoCD 会直接 OOM。

# ---- 2. 镜像 ----
make image-push-local
# 构建并推送到 localhost:5001，供 dev overlay 使用

# ---- 3. 先验证清单本身没问题（此时还没装 ArgoCD）----
make render-dev
make validate

# ---- 4. 装 ArgoCD ----
make argo-install                 # 装 v3.5.5，约需几分钟
kubectl -n argocd get pods        # 期望 7 个 Pod 全部 Running

# ---- 5. 接入 GitOps（唯一的入口动作）----
make argo-bootstrap

# ---- 6. 确认闭环 ----
make argo-status                  # cnlab-root / cnlab-dev / cnlab-staging 都 Synced
kubectl -n cnlab-dev get pods     # 工作负载起来了

# ---- 7. 拿 UI（可选）----
make argo-password
make argo-ui                      # https://localhost:8443
```

ArgoCD 装完之后的 Pod 分布（实测）：

| 组件 | 数量 |
|---|---|
| argocd-application-controller | 1（StatefulSet） |
| argocd-server | 1 |
| argocd-repo-server | 1 |
| argocd-applicationset-controller | 1 |
| argocd-notifications-controller | 1 |
| argocd-dex-server | 1 |
| argocd-redis | 1 |
| **合计** | **7** |

`hack/argo-install.sh` 用官方 `install.yaml` 而不是 Helm chart 是有意的：

```bash
# 用官方 install.yaml（而不是 Helm chart）是有意的：
# 这个练习的目标之一，是让你看清 ArgoCD 到底由哪些组件组成、
# 它们各自要多少资源。Helm chart 会把这些细节藏起来。
```

在上表这 7 个组件里，`application-controller` 是真正做 reconcile 的那个（第五节的 4 秒纠回就是它干的），`repo-server` 负责渲染 Kustomize，`server` 只是 API/UI。装 Helm chart 的话，这些边界会被 values 和模板盖住。

还有一个细节：安装用的是 server-side apply。

```bash
kubectl --context "$CLUSTER_CTX" apply --server-side --force-conflicts \
  -n argocd -f "$MANIFEST_URL"
```

因为 ArgoCD 的 CRD 很大，client-side apply 会撞上 `metadata.annotations: Too long`——注解体积上限。同一个原因也让 `gitops/apps/*.yaml` 里都带了 `ServerSideApply=true`。

---

## 小结

| 问题 | 答案 |
|---|---|
| CI 该不该有 `kubectl apply`？ | 不该。CI 的职责到"提交期望状态"为止，CD 是集群内的 ArgoCD |
| 换了 pull 式，最大的收益是什么？ | 集群凭证从不离开集群；同时获得了持续漂移检测 |
| 新增一个环境要动什么？ | 往 `gitops/apps/` 加一个文件 + push（靠 `recurse: true`） |
| `prune: true` 最危险的操作是什么？ | 删掉 overlay 里的 `namespace.yaml` —— 会连整个命名空间一起删 |
| 生产为什么不要 `automated`？ | 一次错误合并可以无声删掉生产资源；折中是留 `selfHeal`、去掉 `prune` |
| 为什么 git push 后要等 3 分钟？ | 默认轮询节奏。生产应配 webhook，演示可用 `refresh=hard` 强制 |
| 不可变 tag 到底保证了什么？ | 从运行中的 Pod 能反向定位到 commit——**以及回滚时真的有 tag 可退** |
| `latest` 那次事故的教训？ | 自动化的输出也必须被验证，第三方 action 的输出尤其要显式核对 |
