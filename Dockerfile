# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# 构建阶段
# ---------------------------------------------------------------------------
# 这里用 --platform=$BUILDPLATFORM：在 arm64 机器上构建 amd64 镜像时，
# 编译动作本身仍然跑在原生架构上（快），只有"产物"是目标架构。
# 如果没有这一行，buildx 会通过 QEMU 模拟整个 build 阶段，慢一个数量级。
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder

# buildx 会自动注入这两个参数，多架构交叉编译由此而来。
ARG TARGETOS
ARG TARGETARCH

# 构建信息通过 ldflags 注入，让 /api/v1/version 在运行时能自证身份。
# 这一点在 K8s 上很关键：你需要能回答"线上跑的这个 Pod 到底是哪个 commit"。
ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_TIME=unknown

WORKDIR /src

# 本项目零第三方依赖（连 go.sum 都没有），所以这里没有单独的"下载依赖"层。
# 一旦引入依赖，就要改成：
#   COPY go.mod go.sum ./
#   RUN --mount=type=cache,target=/go/pkg/mod go mod download
#   COPY . .
# 让依赖层独立缓存——依赖没变时，改代码不会触发重新下载。
COPY go.mod ./
COPY *.go ./

# CGO_ENABLED=0 是关键：产出静态链接的二进制，
# 才能放进 scratch / distroless-static 这种没有 libc 的基础镜像。
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -ldflags="-s -w \
        -X main.version=${VERSION} \
        -X main.commit=${COMMIT} \
        -X main.buildTime=${BUILD_TIME}" \
      -o /out/cnlab .

# ---------------------------------------------------------------------------
# 运行阶段
# ---------------------------------------------------------------------------
# distroless static 不是"更小的 alpine"，而是"没有攻击面"：
# 没有 shell、没有包管理器、没有 libc、没有 /bin。
# 代价是没法 docker exec 进去排查——用 kubectl debug 临时注入 busybox 即可。
FROM gcr.io/distroless/static-debian12:nonroot

ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_TIME=unknown

# OCI 标准标签。org.opencontainers.image.source 会告诉 GHCR
# 这个包属于哪个仓库，否则 Packages 页面上会出现一个无法关联的孤立镜像。
LABEL org.opencontainers.image.title="cnlab" \
      org.opencontainers.image.description="云原生交付链路练习：极简 Go 服务 + CI/CD + K8s" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://github.com/am-okalin/cnlab" \
      org.opencontainers.image.licenses="MIT"

COPY --from=builder /out/cnlab /cnlab

EXPOSE 8080

# distroless 的 :nonroot 变体自带 uid/gid 65532，不需要再 useradd。
# 配合 K8s 的 runAsNonRoot + readOnlyRootFilesystem，
# 容器既拿不到 root，也写不了自己的文件系统。
USER 65532:65532

# 必须是 exec 形式（JSON 数组）。
# 如果写成 shell 形式 `CMD /cnlab`，Docker 会包一层 /bin/sh，
# 而 PID 1 变成 sh —— SIGTERM 会被 sh 吞掉，优雅退出永远不触发，
# 结果就是每次滚动更新都要等满 terminationGracePeriodSeconds 才被 SIGKILL。
# distroless 里没有 shell，这个坑反而被结构性避开了。
ENTRYPOINT ["/cnlab"]
