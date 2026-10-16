package main

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// 测试一律使用禁用 keep-alive 的客户端。
//
// 原因是一个真实的坑：net/http 的 Server.Shutdown 在关闭连接时，对处于
// StateNew 状态（TCP 已 accept，但还没读到任何请求字节）的连接，要等到
// 它"闲置"满 5 秒才肯关闭（net/http Issue 22682）。连接池复用很容易
// 制造出这种"连上了但没发请求"的连接，于是优雅退出的耗时会无规律地在
// 0s 与 5s 之间跳动——一个让本项目测试偶发失败的幽灵。
//
// 关掉 keep-alive 后，每个请求一条连接、用完即关，Shutdown 的行为就可预测了。
//
// 注意：这个问题在生产里同样存在。kubelet 的探针每次都会新建 TCP 连接，
// 所以 terminationGracePeriodSeconds 必须留出余量，否则 Pod 会被 SIGKILL。
var testClient = &http.Client{
	Transport: &http.Transport{DisableKeepAlives: true},
	Timeout:   10 * time.Second,
}

// response 是测试用的响应快照。
// 刻意不让 *http.Response 逃逸出 helper —— 响应体在 helper 内部就被读完并
// 关闭了，调用方拿不到"忘了 Close"的机会（bodyclose 也就能守住这条约束）。
type response struct {
	status int
	header http.Header
	body   string
}

func testApp() *app {
	return &app{
		cfg: config{AppEnv: "test", Greeting: "hi"},
		log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

func do(t *testing.T, method, url string) response {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), method, url, nil)
	if err != nil {
		t.Fatalf("构造请求失败: %v", err)
	}
	resp, err := testClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s 失败: %v", method, url, err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读取响应体失败: %v", err)
	}
	return response{status: resp.StatusCode, header: resp.Header, body: string(body)}
}

func doGet(t *testing.T, url string) response  { return do(t, http.MethodGet, url) }
func doPost(t *testing.T, url string) response { return do(t, http.MethodPost, url) }

// 存活探针必须无条件成功：它一旦失败，kubelet 会重启容器。
func TestHealthzAlwaysOK(t *testing.T) {
	srv := httptest.NewServer(testApp().router(func() {}))
	defer srv.Close()

	got := doGet(t, srv.URL+"/healthz")
	if got.status != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200", got.status)
	}
	if !strings.Contains(got.body, `"ok"`) {
		t.Errorf("响应体不含 ok: %s", got.body)
	}
}

// 就绪探针必须能"先失败后成功"，这是它区别于存活探针的全部意义。
func TestReadyzGating(t *testing.T) {
	a := testApp()
	srv := httptest.NewServer(a.router(func() {}))
	defer srv.Close()

	if got := doGet(t, srv.URL+"/readyz"); got.status != http.StatusServiceUnavailable {
		t.Fatalf("未就绪时状态码 = %d, 期望 503", got.status)
	}

	a.ready.Store(true)

	if got := doGet(t, srv.URL+"/readyz"); got.status != http.StatusOK {
		t.Fatalf("就绪后状态码 = %d, 期望 200", got.status)
	}
}

func TestGreetUsesEnvAndQuery(t *testing.T) {
	srv := httptest.NewServer(testApp().router(func() {}))
	defer srv.Close()

	got := doGet(t, srv.URL+"/api/v1/greet?name=cnlab")
	if !strings.Contains(got.body, "hi, cnlab!") {
		t.Errorf("响应体 = %s, 期望包含 %q", got.body, "hi, cnlab!")
	}
	if !strings.Contains(got.body, `"app_env":"test"`) {
		t.Errorf("响应体应回显 app_env: %s", got.body)
	}

	got = doGet(t, srv.URL+"/api/v1/greet")
	if !strings.Contains(got.body, "hi, world!") {
		t.Errorf("缺省 name 应回落到 world: %s", got.body)
	}
}

// 非法参数应该是 400，而不是 500——输入错误不是服务端故障。
func TestSlowRejectsBadDuration(t *testing.T) {
	srv := httptest.NewServer(testApp().router(func() {}))
	defer srv.Close()

	if got := doGet(t, srv.URL+"/api/v1/slow?d=abc"); got.status != http.StatusBadRequest {
		t.Fatalf("状态码 = %d, 期望 400", got.status)
	}
}

// 管理端点默认必须关闭：这是"安全默认值"，不是可选项。
func TestAdminShutdownDisabledByDefault(t *testing.T) {
	srv := httptest.NewServer(testApp().router(func() {}))
	defer srv.Close()

	if got := doPost(t, srv.URL+"/api/v1/admin/shutdown"); got.status != http.StatusNotFound {
		t.Fatalf("状态码 = %d, 期望 404（默认不注册该路由）", got.status)
	}
}

// 指标输出的格式与基数约束。基数这条尤其重要：
// 同一个路由配不同查询参数，只能产生一条时间序列。
func TestMetricsExposition(t *testing.T) {
	srv := httptest.NewServer(testApp().router(func() {}))
	defer srv.Close()

	for _, n := range []string{"alice", "bob", "carol"} {
		if got := doGet(t, srv.URL+"/api/v1/greet?name="+n); got.status != http.StatusOK {
			t.Fatal("预热请求失败")
		}
	}

	got := doGet(t, srv.URL+"/metrics")
	if got.status != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200", got.status)
	}
	if ct := got.header.Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Errorf("Content-Type = %q, 期望 text/plain", ct)
	}

	for _, want := range []string{
		"# TYPE cnlab_http_requests_total counter",
		"# TYPE cnlab_http_request_duration_seconds histogram",
		`cnlab_http_requests_total{method="GET",route="/api/v1/greet",status="200"}`,
		`cnlab_http_request_duration_seconds_bucket{method="GET",route="/api/v1/greet",le="+Inf"}`,
		"cnlab_ready ",
		"cnlab_build_info{",
		"go_goroutines ",
	} {
		if !strings.Contains(got.body, want) {
			t.Errorf("指标输出缺少 %q", want)
		}
	}

	// 基数约束：3 个不同 name 只应产生 1 条 greet 序列。
	greetSeries := strings.Count(got.body, `cnlab_http_requests_total{method="GET",route="/api/v1/greet"`)
	if greetSeries != 1 {
		t.Errorf("greet 路由产生了 %d 条序列, 期望 1（标签基数泄漏）", greetSeries)
	}

	if !strings.Contains(got.body, `le="+Inf"`) {
		t.Error("直方图缺少 +Inf 桶，Prometheus 会拒绝该指标")
	}
}

func TestEscapeLabel(t *testing.T) {
	got := escapeLabel(`he said "hi"` + "\n" + `back\slash`)
	want := `he said \"hi\"` + `\n` + `back\\slash`
	if got != want {
		t.Errorf("escapeLabel = %q, 期望 %q", got, want)
	}
}

func TestLoadConfigDefaultsAndOverrides(t *testing.T) {
	clearEnv := func(t *testing.T) {
		t.Helper()
		for _, k := range []string{
			"APP_ENV", "PORT", "LOG_LEVEL", "LOG_FORMAT",
			"SHUTDOWN_TIMEOUT", "DRAIN_DELAY", "READY_DELAY", "ENABLE_ADMIN", "GREETING",
		} {
			t.Setenv(k, "")
		}
	}

	t.Run("默认值", func(t *testing.T) {
		clearEnv(t)
		c, err := loadConfig()
		if err != nil {
			t.Fatalf("loadConfig 失败: %v", err)
		}
		if c.Port != 8080 || c.AppEnv != "dev" || c.LogFormat != "json" {
			t.Errorf("默认值不符: %+v", c)
		}
		if c.DrainDelay != 5*time.Second || c.ShutdownTimeout != 15*time.Second {
			t.Errorf("默认时长不符: %+v", c)
		}
		if c.EnableAdmin {
			t.Error("ENABLE_ADMIN 默认必须是 false")
		}
		if c.LogLevel != slog.LevelInfo {
			t.Errorf("默认日志级别 = %v, 期望 info", c.LogLevel)
		}
	})

	t.Run("环境变量覆盖", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("APP_ENV", "prod")
		t.Setenv("PORT", "9000")
		t.Setenv("LOG_LEVEL", "debug")
		t.Setenv("LOG_FORMAT", "text")
		t.Setenv("DRAIN_DELAY", "250ms")
		t.Setenv("ENABLE_ADMIN", "true")
		c, err := loadConfig()
		if err != nil {
			t.Fatalf("loadConfig 失败: %v", err)
		}
		if c.AppEnv != "prod" || c.Port != 9000 || c.LogFormat != "text" || !c.EnableAdmin {
			t.Errorf("覆盖值不符: %+v", c)
		}
		if c.DrainDelay != 250*time.Millisecond {
			t.Errorf("DRAIN_DELAY = %v, 期望 250ms", c.DrainDelay)
		}
		if c.LogLevel != slog.LevelDebug {
			t.Errorf("日志级别 = %v, 期望 debug", c.LogLevel)
		}
	})

	// 配置错误必须在启动瞬间失败，而不是运行到一半才炸。
	t.Run("非法值在启动时失败", func(t *testing.T) {
		cases := map[string]map[string]string{
			"端口越界":   {"PORT": "70000"},
			"端口非数字":  {"PORT": "abc"},
			"日志级别非法": {"LOG_LEVEL": "verbose"},
			"日志格式非法": {"LOG_FORMAT": "xml"},
			"布尔值非法":  {"ENABLE_ADMIN": "yes-please"},
		}
		for name, envs := range cases {
			t.Run(name, func(t *testing.T) {
				clearEnv(t)
				for k, v := range envs {
					t.Setenv(k, v)
				}
				if _, err := loadConfig(); err == nil {
					t.Fatal("期望返回错误，实际通过了")
				}
			})
		}
	})
}

// 这是整个测试里最有价值的一个：它驱动真实的服务生命周期，
// 验证"在途请求不会被优雅退出打断"。K8s 滚动更新时，这条保证决定了
// 用户会不会看到 502。
func TestGracefulShutdownDrainsInFlight(t *testing.T) {
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}
	base := "http://" + ln.Addr().String()

	cfg := config{
		AppEnv:          "test",
		DrainDelay:      800 * time.Millisecond,
		ShutdownTimeout: 5 * time.Second,
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan error, 1)
	go func() { done <- run(ctx, cfg, logger, ln) }()

	waitReady(t, base)

	// 发起一个耗时 200ms 的在途请求。这里刻意用 test 自己的 context：
	// 它不会因为下面的 cancel() 而中断，我们正要看它在停机过程中能否跑完。
	type result struct {
		code int
		err  error
	}
	slow := make(chan result, 1)
	go func() {
		req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, base+"/api/v1/slow?d=200ms", nil)
		if err != nil {
			slow <- result{err: err}
			return
		}
		resp, err := testClient.Do(req)
		if err != nil {
			slow <- result{err: err}
			return
		}
		defer func() { _ = resp.Body.Close() }()
		_, _ = io.Copy(io.Discard, resp.Body)
		slow <- result{code: resp.StatusCode}
	}()

	// 确认请求已经进入服务端，再触发下线。
	time.Sleep(50 * time.Millisecond)
	start := time.Now()
	cancel()

	// 优雅期内（DRAIN_DELAY=800ms），就绪探针必须已经变成 503，
	// 这样 kube-proxy 才会停止向本 Pod 转发新流量。
	time.Sleep(150 * time.Millisecond)
	if got := doGet(t, base+"/readyz"); got.status != http.StatusServiceUnavailable {
		t.Errorf("优雅期内 /readyz 状态码 = %d, 期望 503（body=%s）", got.status, got.body)
	}

	// 在途请求必须完整返回 200，不能被强杀。
	select {
	case r := <-slow:
		if r.err != nil {
			t.Fatalf("在途请求被中断: %v", r.err)
		}
		if r.code != http.StatusOK {
			t.Errorf("在途请求状态码 = %d, 期望 200", r.code)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("在途请求一直没有返回")
	}

	// run 应该在 DrainDelay 走完后干净退出。
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run 返回错误: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("run 没有在预期时间内退出")
	}

	// 退出总耗时应该约为 DRAIN_DELAY，而不是被 StateNew 连接的 5s 兜底
	// 拖住。这条断言是上面 testClient 注释里那个坑的回归护栏。
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Errorf("优雅退出耗时 %v，远超 DRAIN_DELAY（预期约 0.8s）", elapsed.Round(time.Millisecond))
	}
}

func waitReady(t *testing.T, base string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, base+"/readyz", nil)
		if err == nil {
			resp, err := testClient.Do(req)
			if err == nil {
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
				if resp.StatusCode == http.StatusOK {
					return
				}
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("服务在 5s 内没有就绪")
}
