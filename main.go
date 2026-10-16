// cnlab 是一个刻意保持极简的 Go 服务。
//
// 这个文件里没有框架、没有分层、没有代码生成、没有第三方依赖——只有标准库。
// 因为本项目的重点不是"怎么写 Go"，而是"一个 Go 服务要被交付到 Kubernetes
// 上，需要在代码里预先留出哪些接缝"。把业务复杂度压到最低，交付链路上的
// 每个环节才会浮出水面。
//
// 它刻意实现了这些接缝：
//
//   - 12-factor 配置：全部来自环境变量，不读配置文件
//   - 探针语义：/healthz（存活）与 /readyz（就绪）严格区分，不是同一个东西
//   - 优雅退出：收到 SIGTERM 后先摘流量、再等在途请求跑完、最后退出
//   - 指标：/metrics 手写 Prometheus 文本格式，零依赖
//   - 结构化日志：log/slog，输出 JSON
//   - 构建信息：version/commit/buildTime 由 ldflags 注入，运行时可见
//
// 部署侧的一切（Dockerfile、kind、Kustomize、ArgoCD）都围绕这些接缝展开。
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// 由构建时 ldflags 注入：-X main.version=... 等。
var (
	version   = "dev"
	commit    = "none"
	buildTime = "unknown"
)

// ---------------------------------------------------------------- 配置

// config 全部来自环境变量。这是 12-factor 的第 3 条：配置存在环境里。
// 在 K8s 上，环境变量由 ConfigMap / Secret 注入，于是同一份镜像可以
// 不加修改地跑在 dev / staging / prod。
type config struct {
	AppEnv          string
	Port            int
	LogLevel        slog.Level
	LogFormat       string
	ShutdownTimeout time.Duration
	DrainDelay      time.Duration
	ReadyDelay      time.Duration
	EnableAdmin     bool
	Greeting        string
}

func loadConfig() (config, error) {
	c := config{
		AppEnv:          env("APP_ENV", "dev"),
		LogFormat:       env("LOG_FORMAT", "json"),
		ShutdownTimeout: envDuration("SHUTDOWN_TIMEOUT", 15*time.Second),
		DrainDelay:      envDuration("DRAIN_DELAY", 5*time.Second),
		ReadyDelay:      envDuration("READY_DELAY", 0),
		Greeting:        env("GREETING", "hello"),
	}

	port, err := strconv.Atoi(env("PORT", "8080"))
	if err != nil || port < 1 || port > 65535 {
		return c, fmt.Errorf("PORT 必须是 1-65535 的整数，收到 %q", os.Getenv("PORT"))
	}
	c.Port = port

	if err := c.LogLevel.UnmarshalText([]byte(env("LOG_LEVEL", "info"))); err != nil {
		return c, fmt.Errorf("LOG_LEVEL 无效: %w", err)
	}
	if c.LogFormat != "json" && c.LogFormat != "text" {
		return c, fmt.Errorf("LOG_FORMAT 只能是 json 或 text，收到 %q", c.LogFormat)
	}

	c.EnableAdmin, err = strconv.ParseBool(env("ENABLE_ADMIN", "false"))
	if err != nil {
		return c, fmt.Errorf("ENABLE_ADMIN 必须是布尔值: %w", err)
	}
	return c, nil
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

// envDuration 解析 "15s" / "2m" 这类 Go duration 字符串。
// 解析失败时直接 panic 更快——配置错误应该在启动瞬间暴露，
// 而不是等运行中才发现。K8s 上的 CrashLoopBackOff 就是在告诉你这件事。
func envDuration(key string, def time.Duration) time.Duration {
	raw, ok := os.LookupEnv(key)
	if !ok || raw == "" {
		return def
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		panic(fmt.Sprintf("%s 不是合法的 duration（如 15s、2m）: %v", key, err))
	}
	return d
}

// ---------------------------------------------------------------- 指标

// 手工实现的 Prometheus 客户端。真实项目会用
// github.com/prometheus/client_golang，这里故意手写一遍，是为了看清
// /metrics 到底是什么：一段约定格式的纯文本，没有任何魔法。
//
// 关键约束是"标签基数"。绝不能把原始 URL 路径当标签，否则
// /api/v1/greet?name=alice 和 ?name=bob 会各生成一条时间序列，内存会被打爆。
// 所以下面用的是 Go 1.22+ ServeMux 注册的路由模板（r.Pattern），
// 它天然是有限集合。
//
// 指标沿用包级变量，相当于 prometheus 的 DefaultRegisterer：
// 进程内只有一个指标注册表，这是符合直觉的。
var (
	httpRequests = newCounterVec()
	httpDuration = newHistogramVec()
	inFlight     atomic.Int64
	startTime    = time.Now()
)

type seriesKey struct {
	method string
	route  string
	status string
}

type counterVec struct {
	mu     sync.RWMutex
	series map[seriesKey]uint64
}

func newCounterVec() *counterVec {
	return &counterVec{series: make(map[seriesKey]uint64)}
}

func (c *counterVec) inc(k seriesKey) {
	c.mu.Lock()
	c.series[k]++
	c.mu.Unlock()
}

// 经典的 Prometheus 默认 buckets，够用且不需要调参。
var defaultBuckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

// histogram 的 counts 存的是"每个桶的增量"，不是累积值。
// Prometheus 的 le 桶语义是累积的，所以在渲染时再累加，
// 这样 observe 的热路径更短。
type histogram struct {
	buckets []float64
	counts  []uint64 // len(buckets)+1，最后一个是 +Inf
	sum     float64
	count   uint64
}

type histogramVec struct {
	mu     sync.RWMutex
	series map[seriesKey]*histogram
}

func newHistogramVec() *histogramVec {
	return &histogramVec{series: make(map[seriesKey]*histogram)}
}

func (h *histogramVec) observe(k seriesKey, v float64) {
	h.mu.Lock()
	hist, ok := h.series[k]
	if !ok {
		hist = &histogram{buckets: defaultBuckets, counts: make([]uint64, len(defaultBuckets)+1)}
		h.series[k] = hist
	}
	hist.sum += v
	hist.count++
	placed := false
	for i, ub := range hist.buckets {
		if v <= ub {
			hist.counts[i]++
			placed = true
			break
		}
	}
	if !placed {
		hist.counts[len(hist.buckets)]++
	}
	h.mu.Unlock()
}

// escapeLabel 按 Prometheus 文本格式转义标签值。
// 漏掉这一步，一个带引号或换行的参数就能让整个 /metrics 抓取失败。
func escapeLabel(s string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(s)
}

// fprintf 显式丢弃写入错误。
//
// 这里刻意不把错误往上抛：向 ResponseWriter 写指标时，出错通常只意味着
// 客户端已经断开，没有任何补救动作可做，真正的错误会由 http.Server 记录。
// 把"我知道这里会丢错误"写成显式的 `_, _ =`，比让 errcheck 闭嘴更诚实。
func fprintf(w io.Writer, format string, args ...any) {
	_, _ = fmt.Fprintf(w, format, args...)
}

// writeMetrics 先完整渲染到内存，再一次性写出。
// 这样客户端不会收到半截的 exposition 文本——Prometheus 遇到半截文本会
// 整个抓取失败，而不是只丢一条指标。
func (a *app) writeMetrics(w http.ResponseWriter) {
	var b strings.Builder

	fprintf(&b, "# HELP cnlab_build_info 构建信息，值恒为 1\n")
	fprintf(&b, "# TYPE cnlab_build_info gauge\n")
	fprintf(&b, "cnlab_build_info{version=%q,commit=%q,go_version=%q,app_env=%q,build_time=%q} 1\n",
		escapeLabel(version), escapeLabel(commit), escapeLabel(runtime.Version()),
		escapeLabel(a.cfg.AppEnv), escapeLabel(buildTime))

	fprintf(&b, "# HELP cnlab_ready 就绪状态：1 就绪，0 未就绪\n")
	fprintf(&b, "# TYPE cnlab_ready gauge\n")
	fprintf(&b, "cnlab_ready %d\n", boolToInt(a.ready.Load()))

	fprintf(&b, "# HELP cnlab_process_start_time_seconds 进程启动的 Unix 时间戳\n")
	fprintf(&b, "# TYPE cnlab_process_start_time_seconds gauge\n")
	fprintf(&b, "cnlab_process_start_time_seconds %d\n", startTime.Unix())

	fprintf(&b, "# HELP cnlab_process_uptime_seconds 进程运行时长\n")
	fprintf(&b, "# TYPE cnlab_process_uptime_seconds gauge\n")
	fprintf(&b, "cnlab_process_uptime_seconds %.3f\n", time.Since(startTime).Seconds())

	fprintf(&b, "# HELP go_goroutines 当前 goroutine 数\n")
	fprintf(&b, "# TYPE go_goroutines gauge\n")
	fprintf(&b, "go_goroutines %d\n", runtime.NumGoroutine())

	fprintf(&b, "# HELP cnlab_http_in_flight 正在处理中的 HTTP 请求数\n")
	fprintf(&b, "# TYPE cnlab_http_in_flight gauge\n")
	fprintf(&b, "cnlab_http_in_flight %d\n", inFlight.Load())

	fprintf(&b, "# HELP cnlab_http_requests_total HTTP 请求总数\n")
	fprintf(&b, "# TYPE cnlab_http_requests_total counter\n")
	httpRequests.mu.RLock()
	for _, k := range sortedKeys(httpRequests.series) {
		fprintf(&b, "cnlab_http_requests_total{method=%q,route=%q,status=%q} %d\n",
			escapeLabel(k.method), escapeLabel(k.route), escapeLabel(k.status), httpRequests.series[k])
	}
	httpRequests.mu.RUnlock()

	fprintf(&b, "# HELP cnlab_http_request_duration_seconds HTTP 请求耗时\n")
	fprintf(&b, "# TYPE cnlab_http_request_duration_seconds histogram\n")
	httpDuration.mu.RLock()
	for _, k := range sortedKeys(httpDuration.series) {
		h := httpDuration.series[k]
		lbl := fmt.Sprintf("method=%q,route=%q", escapeLabel(k.method), escapeLabel(k.route))
		cum := uint64(0)
		for i, ub := range h.buckets {
			cum += h.counts[i]
			fprintf(&b, "cnlab_http_request_duration_seconds_bucket{%s,le=%q} %d\n",
				lbl, strconv.FormatFloat(ub, 'g', -1, 64), cum)
		}
		cum += h.counts[len(h.buckets)]
		fprintf(&b, "cnlab_http_request_duration_seconds_bucket{%s,le=\"+Inf\"} %d\n", lbl, cum)
		fprintf(&b, "cnlab_http_request_duration_seconds_sum{%s} %g\n", lbl, h.sum)
		fprintf(&b, "cnlab_http_request_duration_seconds_count{%s} %d\n", lbl, h.count)
	}
	httpDuration.mu.RUnlock()

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	if _, err := io.WriteString(w, b.String()); err != nil {
		a.log.Debug("写出指标失败，客户端可能已断开", "error", err)
	}
}

// sortedKeys 让 /metrics 的输出顺序稳定，便于 diff 和测试。
func sortedKeys[V any](m map[seriesKey]V) []seriesKey {
	keys := make([]seriesKey, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].route != keys[j].route {
			return keys[i].route < keys[j].route
		}
		if keys[i].method != keys[j].method {
			return keys[i].method < keys[j].method
		}
		return keys[i].status < keys[j].status
	})
	return keys
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// ---------------------------------------------------------------- 应用

// app 持有随"一次运行"变化的生命周期状态。
// ready 刻意不是包级变量：就绪是每次运行的实例状态，
// 而不是进程级全局状态，测试里也因此不会互相污染。
type app struct {
	cfg   config
	log   *slog.Logger
	ready atomic.Bool
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// observe 把每个请求的"方法 / 路由模板 / 状态码 / 耗时"记进指标。
// 用 r.Pattern 而不是 r.URL.Path，是控制标签基数的关键。
func observe(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		inFlight.Add(1)
		defer inFlight.Add(-1)

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		// r.Pattern 是注册时的完整模式，形如 "GET /api/v1/greet"。
		// 方法已经由独立的 method 标签承载了，这里只保留路径部分，
		// 免得同一个维度被表达两次。
		route := r.Pattern
		switch route {
		case "":
			route = "unmatched"
		default:
			if _, path, ok := strings.Cut(route, " "); ok {
				route = path
			}
		}
		httpRequests.inc(seriesKey{r.Method, route, strconv.Itoa(rec.status)})
		httpDuration.observe(seriesKey{r.Method, route, ""}, time.Since(start).Seconds())
	})
}

// ---------------------------------------------------------------- 处理器

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

// healthz 是存活探针（livenessProbe）：只回答"进程还活着吗"。
//
// 它绝不能去检查数据库或下游依赖——那些东西挂了不代表本进程需要被重启。
// 如果存活探针检查依赖，依赖一抖动就会引发全部 Pod 连环重启，
// 把一次小故障放大成一次雪崩。这是最常见的探针误用。
func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "ok",
		"uptime": time.Since(startTime).Round(time.Millisecond).String(),
	})
}

// readyz 是就绪探针（readinessProbe）：回答"现在能给我导流量吗"。
//
// 它要在两个时刻返回失败：
//  1. 启动预热还没完成（READY_DELAY）
//  2. 收到 SIGTERM 之后、进程退出之前
//
// 第 2 点最容易被漏掉。Pod 被删除时，K8s 会同时做两件事：从 Service
// endpoints 摘除、给容器发 SIGTERM。这两件事是并发的，而 endpoints 的
// 传播需要时间。如果进程收到 SIGTERM 就立刻退出，那么在"已摘除但
// kube-proxy 还没生效"的窗口里，流量仍会打到这个已死的 Pod 上 → 502。
// 所以正确顺序是：先让 readyz 失败 → 等一个 DRAIN_DELAY → 再关闭监听器。
func (a *app) handleReadyz(w http.ResponseWriter, _ *http.Request) {
	if !a.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "not ready",
			"reason": "warming up or draining",
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (a *app) handleGreet(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		name = "world"
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"message": fmt.Sprintf("%s, %s!", a.cfg.Greeting, name),
		"app_env": a.cfg.AppEnv,
		"pod":     hostname(),
	})
}

// handleSlow 人为制造延迟，用来观察：
//   - 探针超时与 failureThreshold 的配合
//   - 滚动更新期间在途请求是否被优雅处理
//   - 优雅退出时 DRAIN_DELAY 到底在保护什么
func handleSlow(w http.ResponseWriter, r *http.Request) {
	raw := r.URL.Query().Get("d")
	if raw == "" {
		raw = "1s"
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "d 必须是 duration，如 2s / 500ms"})
		return
	}
	if d > 30*time.Second {
		d = 30 * time.Second
	}
	select {
	case <-time.After(d):
	case <-r.Context().Done():
		// 客户端（或 kube-proxy）断开时及时收手，别做无用功。
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"slept": d.String(), "pod": hostname()})
}

func (a *app) handleVersion(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"version":    version,
		"commit":     commit,
		"build_time": buildTime,
		"go_version": runtime.Version(),
		"app_env":    a.cfg.AppEnv,
	})
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return h
}

// ---------------------------------------------------------------- 装配

func (a *app) router(shutdown func()) http.Handler {
	mux := http.NewServeMux()

	// Go 1.22+ 的"方法 + 路径"模式。r.Pattern 会拿到注册时的模板，
	// 指标标签因此天然有界。
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /readyz", a.handleReadyz)
	mux.HandleFunc("GET /api/v1/greet", a.handleGreet)
	mux.HandleFunc("GET /api/v1/slow", handleSlow)
	mux.HandleFunc("GET /api/v1/version", a.handleVersion)
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, _ *http.Request) {
		a.writeMetrics(w)
	})

	// 管理端点默认关闭。它的意义是在本地演示优雅退出时不必去 kill 进程，
	// 但绝不该在生产打开。
	if a.cfg.EnableAdmin {
		mux.HandleFunc("POST /api/v1/admin/shutdown", func(w http.ResponseWriter, _ *http.Request) {
			writeJSON(w, http.StatusAccepted, map[string]string{"status": "shutting down"})
			go func() {
				time.Sleep(100 * time.Millisecond) // 让响应先发出去
				shutdown()
			}()
		})
	}

	return observe(mux)
}

// ---------------------------------------------------------------- 生命周期

// run 承载服务的完整生命周期，并接收一个已创建好的 listener。
//
// 为什么不让 run 自己 net.Listen：把"监听"这一步留给调用方，测试就能在
// :0 随机端口上驱动真实的服务生命周期（含优雅退出），也让"启动失败"
// 与"运行期失败"在调用点天然分开。这是 Go 社区很常见的可测性做法。
func run(ctx context.Context, c config, logger *slog.Logger, ln net.Listener) error {
	a := &app{cfg: c, log: logger}

	shutdownCh := make(chan struct{})
	var once sync.Once
	requestShutdown := func() { once.Do(func() { close(shutdownCh) }) }

	srv := &http.Server{
		Handler:           a.router(requestShutdown),
		ReadHeaderTimeout: 5 * time.Second,
		// IdleTimeout 别设太短，否则 keep-alive 连接被频繁重建，
		// 表现为周期性的延迟抖动。
		IdleTimeout: 60 * time.Second,
	}

	// 就绪是有意做晚的：容器起来、监听器开始 accept 之后才置 1。
	// READY_DELAY 用来演示 startupProbe —— 把它调到 20s，
	// 你会看到没有 startupProbe 时容器被 livenessProbe 反复杀掉。
	go func() {
		if c.ReadyDelay > 0 {
			logger.Info("等待预热完成", "ready_delay", c.ReadyDelay.String())
			select {
			case <-time.After(c.ReadyDelay):
			case <-ctx.Done():
				return
			}
		}
		a.ready.Store(true)
		logger.Info("已就绪，开始接收流量")
	}()

	errCh := make(chan error, 1)
	go func() {
		logger.Info("HTTP 服务启动",
			"addr", ln.Addr().String(),
			"app_env", c.AppEnv,
			"version", version,
			"commit", commit,
			"pid", os.Getpid(),
		)
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return fmt.Errorf("监听失败: %w", err)
	case <-ctx.Done():
		logger.Info("收到终止信号，开始优雅下线")
	case <-shutdownCh:
		logger.Info("收到管理端点下线请求，开始优雅下线")
	}

	// --- 优雅下线的三步，顺序不能换 ---

	// 1. 立刻让就绪探针失败，把自己从 Service endpoints 里摘出去。
	//    此时进程仍在正常服务，只是不再接收新流量。
	a.ready.Store(false)
	logger.Info("就绪探针已置为失败，等待流量摘除", "drain_delay", c.DrainDelay.String())

	// 2. 等摘除动作在集群内传播完成（kube-proxy/iptables/ipvs 更新需要时间）。
	//    这就是 DRAIN_DELAY 存在的唯一理由。设成 0，滚动更新时就会看到 502。
	drain := time.NewTimer(c.DrainDelay)
	defer drain.Stop()
	select {
	case <-drain.C:
	case <-time.After(c.ShutdownTimeout):
	}

	// 3. 关闭监听器，并等待在途请求自然结束。Shutdown 不会强杀连接，
	//    它会阻塞到所有活跃请求返回，或 context 超时。
	shutdownCtx, cancel := context.WithTimeout(context.Background(), c.ShutdownTimeout)
	defer cancel()

	begin := time.Now()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("优雅关闭超时，强制退出", "error", err, "in_flight", inFlight.Load())
		_ = srv.Close()
		return fmt.Errorf("优雅关闭超时: %w", err)
	}
	logger.Info("已优雅退出", "grace", time.Since(begin).Round(time.Millisecond).String())
	return nil
}

// main 只负责把退出码交给操作系统。
//
// 之所以拆成 main + realMain：gocritic 的 exitAfterDefer 会正确地指出，
// 在带 defer 的函数里调用 os.Exit 会让 defer 永远不执行——而这里的
// defer stop() 决定了信号处理能否干净收尾。返回 int 再统一 exit 更安全。
func main() {
	os.Exit(realMain())
}

func realMain() int {
	c, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "配置错误: %v\n", err)
		return 1
	}

	var handler slog.Handler
	opts := &slog.HandlerOptions{Level: c.LogLevel}
	if c.LogFormat == "text" {
		handler = slog.NewTextHandler(os.Stdout, opts)
	} else {
		handler = slog.NewJSONHandler(os.Stdout, opts)
	}
	logger := slog.New(handler)
	slog.SetDefault(logger)

	// 收到 SIGTERM / SIGINT 时取消这个 context。
	// K8s 删除 Pod 时发的就是 SIGTERM。
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	// 用 ListenConfig 而不是 net.Listen，是为了让 context 贯穿到监听阶段：
	// 启动过程中若被取消，监听动作也应该立刻放弃。
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", fmt.Sprintf(":%d", c.Port))
	if err != nil {
		logger.Error("无法监听端口", "port", c.Port, "error", err)
		return 1
	}

	if err := run(ctx, c, logger, ln); err != nil {
		logger.Error("服务异常退出", "error", err)
		return 1
	}
	return 0
}
