# HAMi diff 雷达 2026-11-24

## 摘要
- 当日只有 HAMi 主仓有 3 个新提交(#3509 / #3494 / #3431),HAMi-core、volcano-vgpu、ascend-device-plugin、WebUI 四个仓库零新提交。严格信号无命中:没有 API/CRD 改动,没有 proposal/design 改动,Release 仍停在 v2.11.0。
- 主线是调度器进程的**优雅退出**(#3509):`start()` 改为接收由 SIGINT/SIGTERM 触发的 `ctx`,四个 HTTP 服务(extender、cluster、metrics、pprof)的 `serve()` 在 ctx 取消后改走 `server.Shutdown`(超时写死 5s),由 `sync.WaitGroup` 统一排空。排空前先调 `sher.Stop()`,防止正在重试节点锁的 Bind 在排空末尾又抢到锁。`Scheduler.Stop()` 用 `sync.Once` 做了幂等。收到信号返回 nil、服务出错返回 error,容器状态因此能区分 Completed 和失败。
- 设备 cordon 注解解析收敛到 `common.CordonedDevices`(#3431):nvidia 后端删掉了自己那份 `DeviceCordonAnnotation` 常量和 `cordonedDevices()` 副本,注解键 `hami.io/device-cordon` 不变。新注释明确写出只有 nvidia 和 amd 两家后端执行该注解,其他厂商后端会忽略它。另有 #3494 补了一个 e2e 用例:为已删除 Pod 算出的注解 patch 不得落到同名新 Pod 上。

## 当日重要改变
- 无。逐条核对:
  - `[弃用/移除]`:3 个提交标题都不含 deprecate/remove/drop。#3431 删除的是 Go 导出常量 `nvidia.DeviceCordonAnnotation` 和包内私有函数,不是 CRD 字段或 flag,注解键也没变,因此不算命中。但 import 了 `pkg/device/nvidia` 这个常量的下游代码会编译失败,见下文。
  - `[API/CRD变更]`:helper 的路径探测返回"无 API/CRD 路径命中"。
  - `[架构方向]` 和 `[新能力]`:没有 docs/proposals、没有 /design/,也没有新增或删除顶层 package。唯一新增文件是 `test/e2e/pod/test_patch_identity.go`,落在已有的 e2e 目录。
  - `[版本跨档]`:v2.11.0 没变。

## Project-HAMi/HAMi: 7e92d065 -> 508995fa
- 比较: 7e92d065eca7f9248bc908aa160adad775d337a8 -> 508995fa | ahead=3 | files=10 | Release: v2.11.0(未变)
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/7e92d065eca7f9248bc908aa160adad775d337a8...508995fae6d47115765b964baedf87485a5a05d0
- 实质提交:
  - `feat(scheduler): shut down gracefully on SIGTERM` — https://github.com/Project-HAMi/HAMi/pull/3509 (cc7b310e)
  - `test(e2e): check a pod annotation patch cannot reach a recreated pod` — https://github.com/Project-HAMi/HAMi/pull/3494 (96ffda19)
  - `consolidate device-cordon annotation parsing onto common.CordonedDevices` — https://github.com/Project-HAMi/HAMi/pull/3431 (508995fa)
- helper 节选中 `cmd/scheduler/main.go` 被截断,已用 compare API 补拉该文件的完整 patch,并取 HEAD 下的 `pkg/device/common/common.go` 全文核对。下文 main.go 的结论覆盖全部 hunk。

### AI 总结重点(源码 diff 为据)
- **调度器入口从"阻塞到任一服务出错"改为"阻塞到收到信号或任一服务出错,然后统一关停"**(`cmd/scheduler/main.go`,#3509)。`RunE` 里用 `signal.NotifyContext(..., SIGINT, SIGTERM)` 构造 ctx 传给 `start(ctx)`。**改动前**的 `start()` 末尾直接 `return <-errCh`,SIGTERM 到来时进程被 runtime 默认处理直接杀掉,在途的 extender `filter`/`bind` 请求会被截断。**改动后**用 `select` 同时等 `ctx.Done()` 和 `errCh`:信号路径记一条 "Received termination signal" 并返回 `nil`;出错路径返回 `runErr`。代码注释写明这样做是为了让容器在真实故障时以非零码退出,而不是显示 Completed。
  <details><summary>代码依据 cmd/scheduler/main.go</summary>

  ```diff
  -			return start()
  +			ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
  +			defer stop()
  +			return start(ctx)
  ...
  -	return <-errCh
  +	// A signal is a normal shutdown, an error is not: return it so main exits
  +	// non-zero and the container reports the failure instead of Completed.
  +	var runErr error
  +	select {
  +	case <-ctx.Done():
  +		klog.InfoS("Received termination signal, shutting down")
  +	case runErr = <-errCh:
  +	}
  +	// Stop the scheduler before draining, so a Bind still retrying a node lock
  +	// gives up instead of taking one near the end of the drain.
  +	sher.Stop()
  +	cancel()
  +	wg.Wait()
  +	return runErr
  ```
  </details>
- **关停顺序是"先停调度器内核,再排空 HTTP"**,针对的是节点锁泄漏。`sher.Stop()` 关闭 `stopCh`,在 `cancel()` 和 `wg.Wait()` 之前执行。按注释的说法,这样还在重试节点锁的 Bind 会放弃,而不是在排空末尾拿到一把锁后进程退出。HAMi 的节点锁是写在 Node 注解上的,进程退出时持有的锁要等过期才能释放。另外,`start()` 启动阶段新开了一个 goroutine,在 `<-ctx.Done()` 后调 `s.Stop()`,原因是 `sher.Start()` 等 informer 缓存同步时看的是 `stopCh` 而不是 ctx;`Start()` 返回后又加了一次 `ctx.Err()` 检查,在启动期收到信号就直接返回 nil。
  <details><summary>代码依据 cmd/scheduler/main.go</summary>

  ```diff
  +	ctx, cancel := context.WithCancel(ctx)
  +	defer cancel()
  +
   	sher = scheduler.NewScheduler()
  +	// Start waits for the informer caches on the scheduler's stop channel, not
  +	// on ctx, so stop the scheduler as soon as ctx is canceled.
  +	go func(s *scheduler.Scheduler) {
  +		<-ctx.Done()
  +		s.Stop()
  +	}(sher)
   	go sher.RegisterFromNodeAnnotations()
   	go sher.WatchAllocateTimeouts()
   	err = sher.Start()
   	if err != nil {
   		return err
   	}
   	defer sher.Stop()
  +	if ctx.Err() != nil {
  +		return nil
  +	}
  ```
  </details>
- **`Scheduler.Stop()` 改为幂等**(`pkg/scheduler/scheduler.go`)。新流程里 `Stop()` 最多会被调用三次:信号 goroutine 一次、排空前显式一次、`defer` 一次。原来裸 `close(s.stopCh)` 第二次调用就会 panic,所以新增了 `stopOnce sync.Once` 字段。单测 `TestSchedulerStopIsIdempotent` 连调两次,断言 `stopCh` 已关闭且没有 panic。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
   	stopCh       chan struct{}
  +	stopOnce     sync.Once
   	nodeNotify   chan struct{}
  ...
  +// Stop stops the scheduler's informers and background loops. It is safe to
  +// call more than once.
   func (s *Scheduler) Stop() {
  -	close(s.stopCh)
  +	s.stopOnce.Do(func() {
  +		close(s.stopCh)
  +	})
   }
  ```
  </details>
- **`serve()` 增加 ctx 参数,ctx 取消时走 `http.Server.Shutdown`,超时 5 秒写死**。改动前 `serve` 直接返回 `server.Serve/ServeTLS` 的结果。改动后 Serve 放进 goroutine,`select` 等 serve 出错或 ctx 取消;取消时以 `context.WithTimeout(context.Background(), 5*time.Second)` 调 `Shutdown`:不再接新连接,等在途请求完成。超时后返回 error 并打 `Server shutdown failed` 日志。新单测 `TestServeWaitsForInFlightRequests` 用一个阻塞的 handler 验证 cancel 后在途请求仍能拿到响应。四个服务各有独立的 5s 窗口,但它们并行排空,所以总时长约等于最慢的那一个。5s 没有做成 flag。
  <details><summary>代码依据 cmd/scheduler/main.go</summary>

  ```diff
  -func serve(listener net.Listener, handler http.Handler, tlsCfg *tls.Config) error {
  +func serve(ctx context.Context, listener net.Listener, handler http.Handler, tlsCfg *tls.Config) error {
  ...
  +	// Graceful shutdown on context cancellation
  +	select {
  +	case err := <-serveErr:
  +		return err
  +	case <-ctx.Done():
  +	}
  +	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
  +	defer cancel()
  +	if err := server.Shutdown(shutdown); err != nil {
  +		klog.ErrorS(err, "Server shutdown failed", "address", listener.Addr())
  +		return err
  +	}
  +	return nil
   }
  ```
  </details>
- **metrics 和 pprof 服务纳入同一个 WaitGroup,并修了一处启动期泄漏**(`cmd/scheduler/metrics.go`、`main.go`)。`startMetricsServer` 和 `startProfilingServer` 的签名都加了 `(ctx, wg *sync.WaitGroup, ...)`,裸 `go func()` 换成 `wg.Go(...)`。另一个变化是 serve 返回 nil(正常关停)时不再往 `errCh` 写,原来是无条件写入。如果 metrics 已经起来而 pprof 绑定端口失败,会先 `cancel(); wg.Wait()` 停掉 metrics 再返回错误;改动前这条路径会留下一个仍在服务的 metrics goroutine。
  <details><summary>代码依据 cmd/scheduler/metrics.go / main.go</summary>

  ```diff
  -	go func() {
  -		errCh <- fmt.Errorf("metrics server error: %w", initMetrics(listener, metricsProvider, legacyMetrics))
  -	}()
  +	wg.Go(func() {
  +		if err := initMetrics(ctx, listener, metricsProvider, legacyMetrics); err != nil {
  +			errCh <- fmt.Errorf("metrics server error: %w", err)
  +		}
  +	})
  ...
   	profilingListener, err := startProfilingServer(ctx, &wg, enableProfiling, profilingBindAddress, errCh)
   	if err != nil {
  +		// The metrics server is already running; stop it before returning.
  +		cancel()
  +		wg.Wait()
   		return err
   	}
  ```
  </details>
- **cordon 注解解析去重:nvidia 后端改用 `common.CordonedDevices`,并删除了导出常量 `nvidia.DeviceCordonAnnotation`**(`pkg/device/nvidia/device.go` +4/-28,#3431)。删除内容是 nvidia 包里的常量 `DeviceCordonAnnotation = "hami.io/device-cordon"` 和私有函数 `cordonedDevices(nodeInfo)`。`Fit()` 改为在 `nodeInfo`、`nodeInfo.Node` 都非 nil 时调用 `common.CordonedDevices(nodeInfo.Node.Annotations)`;否则 `cordoned` 是 nil map,对 nil map 查找返回零值,效果与原来的"空集合"一致。行为差异只有一点:原实现先 `strings.TrimSpace(raw) == ""` 提前返回,新实现直接 Split 再跳过空项,两者结果等价。注解键在 `pkg/device/common` 中仍是 `hami.io/device-cordon`,线上注解不受影响。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  -	DeviceCordonAnnotation = "hami.io/device-cordon"
  ...
  -func cordonedDevices(nodeInfo *device.NodeInfo) map[string]struct{} {
  -	cordoned := make(map[string]struct{})
  -	if nodeInfo == nil || nodeInfo.Node == nil {
  -		return cordoned
  -	}
  -	raw, ok := nodeInfo.Node.Annotations[DeviceCordonAnnotation]
  ...
  -	cordoned := cordonedDevices(nodeInfo)
  +	var cordoned map[string]struct{}
  +	if nodeInfo != nil && nodeInfo.Node != nil {
  +		cordoned = common.CordonedDevices(nodeInfo.Node.Annotations)
  +	}
  ```
  </details>
- **新注释把 cordon 的适用范围和生效语义写明了**(`pkg/device/common/common.go`)。注释原文:只有调用 `CordonedDevices` 的后端会执行该注解,目前是 nvidia 和 amd,其他厂商后端不检查。与 NVIDIA 的 `FilterDeviceToRegister` 相比,后者在 device plugin 启动时就把设备排除在注册之外;前者在调度器的节点缓存观察到注解变化后生效,不需要重启 device plugin。用 GitHub code search 核对,`CordonedDevices` 在 HEAD 只被 `pkg/device/amd/device.go` 和 `pkg/device/nvidia/device.go` 引用,与注释一致。也就是说,昇腾、寒武纪、海光、天数等后端目前写了 `hami.io/device-cordon` 也不会生效。
  <details><summary>代码依据 pkg/device/common/common.go</summary>

  ```diff
  -// DeviceCordonAnnotation is a node annotation holding a comma-separated list of
  -// device UUIDs that must not receive new pods.
  +// DeviceCordonAnnotation is a node annotation holding a comma-separated list
  +// of device UUIDs that a backend's Fit should treat as unavailable for new
  +// pods, without affecting pods already running on those devices. It's a
  +// live, per-GPU equivalent of `kubectl cordon`, but it's only enforced by
  +// backends that call CordonedDevices (currently nvidia and amd) — other
  +// vendor backends don't check it. ...
   const DeviceCordonAnnotation = "hami.io/device-cordon"
  ```
  </details>
- **e2e 测试锁定"注解 patch 只能落到计算它时的那个 Pod 上"**(新增 `test/e2e/pod/test_patch_identity.go`,#3494)。文件头注释说明:`util.PatchPodAnnotations` 按名字定位 Pod,但在 patch body 里钉住了 UID,而这个约束只有 API server 会执行,单测验证不了。用例流程:创建 Pod,删除后用同名重建并断言 UID 不同;用旧对象调 `PatchPodAnnotations`,断言返回 error 且新 Pod 上没有该注解;再用新对象 patch,断言成功。测试 Pod 设置了一个不存在的 `SchedulerName`,让它保持未调度,因此不依赖 GPU 节点。这对应的是 bind 阶段 `identity` 失败原因背后的不变量:调度器写进注解的设备分配不能错写到同名新 Pod 上。
  <details><summary>代码依据 test/e2e/pod/test_patch_identity.go</summary>

  ```diff
  +// util.PatchPodAnnotations addresses a pod by name and pins the UID it was
  +// computed for in the patch body. Only the API server enforces that pin, so the
  +// unit tests can check the body but not that a patch computed for a deleted pod
  +// fails instead of landing on a pod that later took the same name.
  ...
  +		ginkgo.By("Patching with the deleted pod's identity")
  +		err = util.PatchPodAnnotations(stale, map[string]string{annotation: "stale"})
  +		gomega.Expect(err).To(gomega.HaveOccurred(), "a patch computed for the deleted pod was accepted")
  ```
  </details>

### 后续发展方向 [AI]
- **HAMi 调度器正在补齐"可滚动升级"所需的进程生命周期语义,与上期的 SLI 工作是同一条可运维性主线。** 上期 #3505 让失败序列从 0 起算,本期 #3509 让 SIGTERM 不再截断在途的 bind 和 filter,#3494 用 e2e 钉住 Pod 身份不变量。三者合起来针对的是同一个场景:调度器重启或升级期间,分配既不能丢,也不能写错对象。值得注意的是排空顺序先 `sher.Stop()` 再 `wg.Wait()`,说明维护者把节点锁注解在退出时残留视为主要风险,而不是 HTTP 请求被截断。**证据边界**:diff 只覆盖 `cmd/scheduler` 与 `pkg/scheduler.Stop`,没有改动 leader election(`leaderManager`)的退出路径,也没有改 Helm chart 的 `terminationGracePeriodSeconds`。所以"leader 是否在退出时主动释放 lease"以及"5s 排空窗口与 Pod 宽限期是否匹配"这两点,本期代码无法回答。
- **cordon 是 HAMi 走向"设备级运维原语"的雏形,目前只在 nvidia 和 amd 两家后端生效。** 把解析函数收敛到 `common`,并在注释里写明"其他后端不检查",说明下一步大概率是把 `CordonedDevices` 接入其余后端的 `Fit()`;届时 `CardCordoned` 这个失败原因会出现在昇腾、寒武纪等厂商的过滤结果里。可以用"`CordonedDevices` 的引用数是否增加"作为跟踪指标。**证据边界**:只确认了 HEAD 的 code search 引用分布,没有查是否已有对应的 open PR 或 issue。另外,#3431 删除导出常量是一次 Go API 层面的不兼容变更:外部代码若 import `pkg/device/nvidia.DeviceCordonAnnotation`,需要改为 `pkg/device/common.DeviceCordonAnnotation`。
- **对我们产品的启示**:(1)如果我们在 HAMi 上二次开发,或作为上游集成方 vendor 了 `pkg/device/nvidia`,要注意上面这个常量迁移。(2)在多厂商集群里依赖 `hami.io/device-cordon` 做故障卡隔离,目前只对 NVIDIA 和 AMD 有效;昇腾 vNPU 场景需要自己补,或继续走 device plugin 侧过滤。我们的运维文档和告警自愈流程不能默认它对所有厂商都生效。(3)HAMi 调度器的优雅退出窗口写死为 5s,远小于 K8s 默认的 30s 宽限期,通常够用。但如果我们在 extender 链路上叠加了慢 webhook 或长时间的节点锁重试,需要评估 5s 内能否排空。这一项属于"软切分调度控制面",与 DRA 原生路径无关。

## 本期无实质改动(折叠)
<details><summary>4 个仓零新提交</summary>

- `Project-HAMi/HAMi-core`:HEAD 仍为 `4314e0a7`,无新提交(与 2026-11-23 锚点一致)。
- `Project-HAMi/volcano-vgpu-device-plugin`:HEAD 仍为 `5357e807`,无新提交;Release 仍为 `volcano-vgpu-device-plugin-1.13.0`。
- `Project-HAMi/ascend-device-plugin`:HEAD 仍为 `9325759b`,无新提交;Release 仍为 `ascend-device-plugin-0.2.2`。
- `Project-HAMi/HAMi-WebUI`:HEAD 仍为 `19a0f955`,无新提交;Release 仍为 `v1.3.0`。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=508995fae6d47115765b964baedf87485a5a05d0 branch=master release=v2.11.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=4314e0a7750eb53dbe865c86abe88b59143390cc branch=main release=— scanned=2026-11-24 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5357e807398dcf2aae6d82a9bffa3bfaef7f701f branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-24 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=19a0f955a652ba7f7e4af5a9315686829e884328 branch=main release=v1.3.0 scanned=2026-11-24 -->
