# 03 · Kustomize 多环境：base 和 overlay 到底该怎么切

Kustomize 的 API 很小，小到半小时就能看完。真正难的不是语法，而是一个它不回答的问题：

**哪些东西属于 base，哪些东西必须留给 overlay？**

切错了不会报错。清单照样能渲染、照样能部署，代价会在几周后以"没人敢改这个文件"的形式出现。这篇文档给出一个可操作的判断标准，并用本项目的三套 overlay 把它落到地上。

---

## 一、一条判断标准

> **凡是会让你说出"我们环境不太一样"的东西，都不属于 base。**

这句话的好处是它检验的不是"技术上能不能抽象"，而是"这句话会不会被说出口"。

环境差异的表达方式只有两种：

- **显式列举** —— 差异集中写在 overlay 里，看着 overlay 就知道这个环境特殊在哪；
- **隐式累积** —— 差异散落在各处，需要 diff 整套清单才能看出来。

base 里每多放一个环境相关的字段，就把一份差异从第一种变成了第二种。

### 本项目据此排除了哪三样

`deploy/base/kustomization.yaml` 的注释直接把结论写在文件里：

```yaml
# 刻意不放进 base 的三样东西：
#   - namespace  → 环境相关
#   - replicas   → 环境相关
#   - image tag  → 环境相关
```

逐个说清楚"不放进去"到底避免了什么。

**namespace**：如果 base 写死 `namespace: cnlab-dev`，那么 staging 和 prod 的 overlay 都必须记得改掉它。忘改的后果不是报错，而是**把生产环境部署进了 dev 命名空间**——集群里一切正常，只是流量进不来。这类"部署成功但部署错了地方"的故障，排查成本远高于直接失败。

**replicas**：如果 base 写 `replicas: 3`，它就变成了所有人的默认值。新加一个环境时，如果作者没想到副本数这件事，他会静默继承 3。而 3 这个数字原本是 prod 的容量决策，不是一条通用规则。副本数的正确来源是"这个环境的容量和可用性要求"，只能由该环境自己声明。

**image tag**：这是三样里最关键的。tag 决定了"这个环境跑的是哪份代码"，而 dev 和 prod 对这件事的答案在语义上就是相反的（见第五节）。把它写进 base，等于让某个环境的发布节奏变成所有环境的默认节奏。

### 关于 base 里的 `replicas: 1`

这里有一个容易被忽略的细节。`deploy/base/deployment.yaml` 里**确实**有 `replicas: 1`：

```yaml
spec:
  # replicas 由 overlay 决定。base 里放一个"能跑起来的最小值"。
  replicas: 1
```

它和上面"replicas 不进 base"的说法不矛盾，但需要分清两件事：

| | 含义 | 谁来定 |
|---|---|---|
| base 的 `replicas: 1` | 让 base **自己**是一个合法、可独立部署的清单 | base |
| overlay 的 `replicas:` 转换器 | "这个环境要几个副本" | 每个 overlay |

三个 overlay 都**显式**写了副本数，没有一个依赖 base 的值：

```yaml
# deploy/overlays/dev/kustomization.yaml
replicas:
  - name: cnlab
    count: 1
```

所以真实副本数永远来自 overlay。base 里的 1 是"最小可运行值"，作用类似编程语言里的零值——让 base 单独拿出来也能渲染出一个能跑的东西，而不是一个缺字段的半成品。这个"base 自身必须完整"的性质，下一节还会再用一次。

---

## 二、base 自带一份能部署的 ConfigMap

`deploy/base/kustomization.yaml` 里有一个完整的 `configMapGenerator`：

```yaml
configMapGenerator:
  - name: cnlab-config
    literals:
      - APP_ENV=base
      - LOG_LEVEL=info
      - LOG_FORMAT=json
      - DRAIN_DELAY=5s
      - SHUTDOWN_TIMEOUT=15s
      - GREETING=hello
```

六个键，一份任何环境拿来都能启动的配置。overlay 不去重写它，而是用 `behavior: merge` **只覆盖变化的键**：

```yaml
# deploy/overlays/dev/kustomization.yaml
configMapGenerator:
  - name: cnlab-config
    behavior: merge
    literals:
      - APP_ENV=dev
      - LOG_LEVEL=debug
      - DRAIN_DELAY=3s
      - SHUTDOWN_TIMEOUT=10s
      - GREETING=hello-from-dev
```

dev 只写了 5 个键，base 有 6 个。缺失的那个是 `LOG_FORMAT`，它保持 base 的值。渲染出来可以验证：

```console
$ make render-dev | sed -n '/^data:/,/^---/p'
data:
  APP_ENV: dev
  DRAIN_DELAY: 3s
  GREETING: hello-from-dev
  LOG_FORMAT: json          # ← dev 没提，从 base 继承
  LOG_LEVEL: debug
  SHUTDOWN_TIMEOUT: 10s
```

### 对比：如果 overlay 从零重写一份

假设 dev 不用 `merge`，而是自己写一份完整的 `literals`。那么：

1. **diff 失去了信息量。** 你想知道"dev 的配置和默认值差在哪"，必须把两个文件的 literals 并排比一遍。而当 base 有 30 个键时，这个对比没人会做。
2. **base 新增键时不会自动生效。** 后来 base 加了 `FEATURE_X=false`，merge 写法会自动继承；重写写法不会——dev 里根本没有这个键，而 `envFrom` 拿不到它，应用只能用自己的默认值。两个默认值来源就此分叉。
3. **"改了什么"这件事在 git history 里消失。** merge 的 diff 只显示变动的键，review 时一眼能看出这次改了 `DRAIN_DELAY`；重写写法的 diff 是一整块。

`behavior: merge` 的写法让 overlay 文件本身就在回答"dev 到底改了什么"。

---

## 三、哈希后缀：改配置为什么会自动触发滚动更新

`deploy/base/kustomization.yaml` 里保留了默认行为：

```yaml
generatorOptions:
  # 保持默认（不关掉哈希后缀）。
  disableNameSuffixHash: false
```

于是渲染出的 ConfigMap 名字带一个内容哈希：

| 环境 | 渲染出的 ConfigMap 名字 |
|---|---|
| dev | `cnlab-config-h6k4tb279k` |
| staging | `cnlab-config-bd928fctk2` |
| prod | `cnlab-config-7gfchhhftc` |

这个名字不是装饰，它是**"改配置自动触发滚动更新"这条能力的全部来源**。链条是这样的：

```
literals 内容变化
      ↓
kustomize 重新计算哈希 → ConfigMap 名字变化
      ↓
Deployment 里 envFrom.configMapRef.name 被改写成新名字
      ↓
Pod 模板（spec.template）发生变化
      ↓
Deployment 的 template hash 变化 → 滚动更新被触发
      ↓
新 Pod 带着新配置启动
```

关键在于：**Pod 模板变了**。Kubernetes 判断"要不要滚动更新"看的就是 `spec.template`，而不是 ConfigMap 变了没有。ConfigMap 是独立对象，它自己被修改，Deployment 完全不知情。

### 设成 `disableNameSuffixHash: true` 会发生什么

我实际验证过这两种写法。改同一个键（`GREETING`），只切换哈希开关：

| 开关 | 改变 literals 后渲染出的名字 |
|---|---|
| `false`（默认） | `cnlab-config-chg5tc8dkt` ← 名字变了 |
| `true` | `cnlab-config` ← **名字没变** |

名字没变意味着 `envFrom.configMapRef.name` 也是原来的值，Pod 模板完全没动。后果分两步显现，而且都比较隐蔽：

- **部署当场不报错。** `kubectl apply` 会报告 ConfigMap 已更新、Deployment unchanged。一切看起来正常。
- **运行中的 Pod 用不到新配置。** `envFrom` 只在容器**启动时**把 ConfigMap 的值注入环境变量；它不会热更新。于是你改了配置、部署成功、Pod 是 Running，但里面的 `GREETING` 还是旧值。

这时唯一的补救是手动触发：

```bash
kubectl -n cnlab-dev rollout restart deploy/cnlab
```

也就是说，关掉哈希等于把"改配置"和"让配置生效"这两件事重新拆开，并且第二件事没有任何自动化。它还有个次生问题：名字不再唯一，你无法从 ConfigMap 的名字判断它是不是最新那份。

> **所以别在脚本里硬编码 ConfigMap 名字。** 上面三个环境的哈希各不相同，任何写死 `cnlab-config` 的脚本都会在某个环境上失效。要引用它就用 label selector。

---

## 四、images 转换器：dev 和 prod 只差一个 registry 前缀

base 里的镜像是**故意不完整**的：

```yaml
# deploy/base/deployment.yaml
# 会被 overlay 的 images 转换器覆盖（匹配的是镜像名 cnlab）。
# 故意留一个不完整的值，逼着 overlay 必须显式声明用哪个仓库哪个 tag。
image: cnlab:dev
```

`cnlab:dev` 是一个不太可能在真实环境里存在的地址。这个选择是有意的：如果 base 写一个看起来很合理的地址，overlay 忘了声明镜像时**不会报错**，只会悄悄用一个错的镜像——而"用错镜像"往往要到线上才被发现。写一个明显不可用的值，等于把遗漏变成一次显式的失败。

三个 overlay 各自声明：

```yaml
# dev —— 本机 kind 的本地仓库
images:
  - name: cnlab
    newName: localhost:5001/cnlab
    newTag: dev
```

```yaml
# prod —— 不可变版本号
images:
  - name: cnlab
    newName: ghcr.io/am-okalin/cnlab
    newTag: v0.1.0
```

注意 `localhost:5001/cnlab` 和 `ghcr.io/am-okalin/cnlab` 结构完全一致：都是 `<registry>/<name>`。这不是巧合，而是本地仓库存在的理由（见 `hack/kind-up.sh` 的注释）——它让本地环境走一条**和生产同样形状**的路径，而不是发明一套"本地特供"的镜像加载方式（比如 `kind load`）。如果本地用 `kind load`，那么"镜像地址"这件事在本地根本不经过 Kustomize，你就练不到它。

`images` 转换器还有一个身份：**它是 CI 与 CD 的交接点**。`.github/workflows/ci.yml` 的 `gitops` job 用这一条命令改写 staging：

```bash
kustomize edit set image "cnlab=ghcr.io/am-okalin/cnlab:sha-f24b9a4"
```

它改的正是 `deploy/overlays/staging/kustomization.yaml` 里的 `images` 段。CI 不需要理解 Deployment 长什么样，只需要会改这一个字段。

---

## 五、`namespace:` 为什么不污染 Namespace 资源

overlay 里写了：

```yaml
namespace: cnlab-dev
```

它会把这个值写到所有**命名空间级**资源的 `metadata.namespace` 上。而 overlay 自己的 `resources` 里**包含**一个 Namespace 资源：

```yaml
resources:
  - namespace.yaml
  - ../../base
```

那 `Namespace` 会不会被写上 `metadata.namespace: cnlab-dev`？不会：

```console
$ make render-dev | awk '/^kind: Namespace/,/^---/'
kind: Namespace
metadata:
  labels:
    app.kubernetes.io/environment: dev
    app.kubernetes.io/part-of: cnlab
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
  name: cnlab-dev
```

没有任何 `namespace:` 字段。渲染结果里出现的 4 处 `namespace: cnlab-dev`，分别落在 ServiceAccount、ConfigMap、Service、Deployment 上——全是命名空间级资源。

原因是 kustomize 内置了一份"哪些 kind 是集群级"的知识（Namespace、ClusterRole、CustomResourceDefinition、PersistentVolume……），对它们一律跳过 namespace 转换。这件事值得单独讲，因为它是一个**你不需要写、但必须知道存在**的保护：如果 kustomize 无脑往里写，你就得为 Namespace 资源单独开小灶（拆文件、加 patch），而漏掉这一步的报错信息（"cluster-scoped resource must not have a namespace"）并不会指向真正的原因。

顺带一个实际好处：因为 `namespace:` 是声明式的，**同一个集群里可以同时存在三套环境**，互不干扰。这也是本项目能让 ArgoCD 在一个 kind 集群里同时演示 dev 和 staging 的基础。

---

## 六、Pod Security Admission：清单写错时的兜底

三个环境的 `namespace.yaml` 都带同样的标签（以 dev 为例）：

```yaml
metadata:
  name: cnlab-dev
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
```

这是集群层面的**准入兜底**。区别在于拦住的时机：

| 机制 | 何时起作用 | 拦不住什么 |
|---|---|---|
| 清单里写对 `securityContext` | 你写的时候 | 后来有人删掉了这一行 |
| PSA `enforce: restricted` | Pod 被创建时 | —— |

`restricted` 级别要求以非 root 运行、禁止提权、丢弃能力、设置 seccomp 等。关键在于它是**在 API Server 侧强制执行**的：即使有人把 `deploy/base/deployment.yaml` 里的 `securityContext` 整段删掉，Pod 也**起不来**，而不是悄悄以 root 运行。

这正是本项目 `make zero-downtime` 演示的第一步——故意提交一个不安全的 Pod，看它被 PSA 拒绝。如果没有 PSA 这一层，那个 Pod 会正常启动，而"它其实是 root"这件事不会有任何人告诉你。

一个容易误解的点：PSA 校验的是 **Pod 对象**，不是 Deployment。所以它报错时会表现成"Deployment 创建成功，但 ReplicaSet 生不出 Pod"，事件里才有 PSA 的拒绝信息。排查时如果只看 Deployment 会看不到原因，要用 `kubectl -n cnlab-dev get events` 或看 ReplicaSet。

---

## 七、渲染而不部署：为什么部署前必须先看渲染结果

Makefile 提供了三个"只读"目标：

```bash
make render-dev    # kustomize build deploy/overlays/dev
make diff-dev      # kustomize build deploy/overlays/dev | kubectl diff -f - || true
make validate      # 对 dev/staging/prod 逐个做服务端 dry-run
```

`deploy-dev` 和 `render-dev` 的区别只有一个管道符，但信息量差很多：

```bash
# 你看到的（最终结果）
make render-dev

# 你部署的（也是最终结果，只是直接喂给了集群）
kustomize build deploy/overlays/dev | kubectl apply -f -
```

**你写的 YAML 和集群收到的 YAML 不是同一份东西。** 前者是 base + overlay + patch + 各种转换器的输入，后者是它们的输出。在这个项目里，输出和输入至少有四处不同：namespace 被注入、副本数被改写、镜像地址被替换、ConfigMap 名字被加上哈希。

### 一个真实会踩到的静默失败

`deploy/overlays/dev/patch-dev.yaml` 是一段 strategic merge patch，它靠 **container 名字**定位要改哪个容器：

```yaml
spec:
  template:
    spec:
      containers:
        - name: cnlab
          imagePullPolicy: Always
```

如果这个名字拼错（`cnlab` → `cnlabb`），kustomize **不会报错**。它把 patch 当成"要新增一个容器"，于是渲染出的 Deployment 里有两个容器：

```console
$ kustomize build deploy/overlays/dev | grep -c '^        - '
2                        # 本来应该是 1
$ echo $?
0                        # 退出码是 0，一切"成功"
```

### 三层防线，各拦一类错

这个例子恰好能说明 Makefile 里那三个目标不是重复劳动。我用这个拼错的 patch 实测了三层：

| 层 | 命令 | 结果 | 拦住了吗 |
|---|---|---|---|
| 渲染 | `kustomize build` | 退出码 0，静默产出 2 个容器 | ✗ |
| Schema 校验 | `kubeconform -strict` | `Valid: 5, Invalid: 0` | ✗ |
| 服务端 dry-run | `kubectl apply --dry-run=server` | `spec.template.spec.containers[0].image: Required value` | ✓ |

kubeconform 没拦住，是因为 Kubernetes 的 OpenAPI schema **没有**把 `container.image` 标成必需字段（这条约束在 API Server 的校验逻辑里，不在 schema 里）。这不是 kubeconform 的缺陷，而是它的能力边界：它只保证"字段名合法、层级正确、apiVersion 存在"。

于是部署前的工作流是三层逐级收紧：

```
kustomize build        → 能渲染吗？（合并逻辑对不对）
kubeconform -strict    → 字段合法吗？（名字、层级、apiVersion）
kubectl --dry-run=server → 集群真的会接受吗？（准入、默认值、约束）
```

`make validate` 走的是第三层，也是唯一能覆盖 `make diff-dev` 之前那道关的一层。**跳过渲染直接部署，等于放弃了前两层能给你的全部信息。**

---

## 八、三个环境的实际差异

以下是 `kustomize build` 的渲染结果（kustomize v5.8.3）：

| 项 | dev | staging | prod |
|---|---|---|---|
| 资源数 | 5 | 5 | 6 |
| namespace | `cnlab-dev` | `cnlab-staging` | `cnlab-prod` |
| 镜像 | `localhost:5001/cnlab:dev` | `ghcr.io/am-okalin/cnlab:sha-f24b9a4` | `ghcr.io/am-okalin/cnlab:v0.1.0` |
| tag 性质 | 可变 | 不可变 | 不可变 |
| `imagePullPolicy` | `Always` | `IfNotPresent` | `IfNotPresent` |
| replicas | 1 | 2 | 3 |
| `DRAIN_DELAY` | 3s | 5s | 10s |
| `terminationGracePeriodSeconds` | 30 | 30 | 45 |
| PDB | — | — | `minAvailable: 2` |
| 反亲和 | — | — | `preferred` |
| ConfigMap | `cnlab-config-h6k4tb279k` | `cnlab-config-bd928fctk2` | `cnlab-config-7gfchhhftc` |

两点值得单独说明。

**`imagePullPolicy` 为什么 dev 是 `Always`。** 因为 dev 用的是**可变** tag（`:dev`），每次推送都覆盖同一个 tag。而 `imagePullPolicy` 的默认值是 `IfNotPresent`，节点上已经有 `cnlab:dev` 这个 tag 了，containerd 就认为不需要再拉。于是出现那个极具误导性的现象：**推了新镜像、rollout 也成功了、看到的却还是旧行为**。staging 和 prod 用不可变 tag，不存在这个问题，所以用 `IfNotPresent`（省一次拉取，也避免 tag 被覆盖导致的意外）。

**两个时间参数必须成对调整。** `terminationGracePeriodSeconds` 是 kubelet 给容器的退出预算，`DRAIN_DELAY` 是应用收到 SIGTERM 后主动等的窗口。prod 把 drain 调到 10s，退出预算就必须跟着涨到 45s。如果只改一个：

```
终止宽限期 ≥ DRAIN_DELAY + 最长请求耗时 + 余量
```

不满足这个不等式时，kubelet 会在应用还在收尾时直接 SIGKILL。**现象非常隐蔽**：日志里看不到"已优雅退出"那一行，并且偶发 502——而 502 是间歇性的，很容易被归因成网络抖动。base 的注释把这个不等式写在了 `terminationGracePeriodSeconds` 旁边，就是为了让改任一个数字的人都看到另一个。

---

## 九、Kustomize 还是 Helm

两者不是替代关系，解决的问题不同。

| | Kustomize | Helm |
|---|---|---|
| 核心模型 | 叠加（base + overlay + patch） | 模板（模板 + values 求值） |
| 输出 | YAML 进、YAML 出 | 模板求值后的 YAML |
| 条件与循环 | 没有；复杂逻辑会退化成大量 overlay | 有（`if` / `range` / `include`） |
| 依赖管理 | 无（可用 remote base 引用） | 有（chart 依赖、版本仓库） |
| 发布状态 | 无"发布"概念，只有期望状态 | 有 release 记录，支持 `helm rollback` |
| diff 可读性 | 高：任何改动都是 YAML 的叠加 | 低：先要理解模板分支才能读懂结果 |
| 适合场景 | **同一套应用往多个环境部署** | **把一个组件分发给很多团队** |

本项目的选择是 Kustomize，理由不是"Helm 不好"，而是练习的对象不同：

1. **要练的是"多环境"，不是"分发组件"。** 三个 overlay 是同一套 base 的三种取值，这正是叠加模型的主场。用 Helm 做这件事会变成三份 values.yaml，而 values 的合并规则（尤其 nested map 与 list）本身就是新的认知负担。
2. **GitOps 要求"git 里的东西就是集群里的东西"。** Kustomize 是纯叠加，渲染结果和源文件之间有直接的对应关系，review 时看到的就是将要发生的事。模板求值多了一层"需要先在心里执行一遍模板"，这在 review 阶段是实打实的成本。
3. **CI 的交接点足够简单。** `kustomize edit set image` 只改一个字段，不需要理解任何模板结构。

**什么时候该换 Helm**：要把这个服务打包成 chart 给别人装、需要 `helm rollback` 的发布记录、或者 values 的条件分支能显著减少重复时。ArgoCD 两者都原生支持，换过去不需要动 GitOps 那一层。

---

## 小结

| 问题 | 判断依据 |
|---|---|
| 这个字段放 base 还是 overlay？ | 你会不会说出"我们环境不太一样" |
| overlay 该 merge 还是重写？ | merge：diff 才有信息量，base 新增键才能自动继承 |
| 改了配置为什么没生效？ | 看 ConfigMap 名字有没有变（哈希后缀是否被关掉） |
| 为什么本地和生产只差一个地址？ | `images` 转换器 + 结构一致的 registry 前缀 |
| 为什么 `namespace:` 没写进 Namespace？ | 集群级资源被跳过，这是特性不是巧合 |
| 部署前该看什么？ | 先 `kustomize build`，再 `kubeconform`，再 `--dry-run=server` |
