# HAMi diff 雷达 2026-07-31

## 摘要
- 仅 `ascend-device-plugin` 一条实质提交(#120):**把周期性 idle vNPU 回收从"始终开启"改成默认关闭的可选项**,新增 flag `enable_periodic_idle_vnpu_cleanup`(默认 `false`)。动机是"避免过早回收"——ticker 定时扫到"看似空闲"的 vNPU 会误回收仍在用的切片;默认关掉后只保留"重启时一次性清理",周期扫描需显式开启。这是**升级即生效的默认行为翻转**,依赖 60s 周期回收自动腾 vNPU 的部署会发现回收停了。
- 同一提交顺手把三处 goroutine 迁到 Go 1.25 的 `sync.WaitGroup.Go`,由其内部管 `Add(1)/Done()`,删掉旧代码里为规避 "WaitGroup is reused before previous Wait has returned" panic 而手写的 `wg.Add(1)`+`defer wg.Done()` 配对——并发生命周期管理收敛,顺带消一类竞态。
- HAMi 主仓 / HAMi-core / volcano-vgpu / HAMi-WebUI 四仓本期无实质改动(主仓 ahead=2 仅 bump/CI,其余无新提交)。

## 当日重要改变
- Project-HAMi/ascend-device-plugin [行为默认变更] 新增 `--enable_periodic_idle_vnpu_cleanup`(默认 false),周期性 idle vNPU 回收由"始终跑"变为"默认不跑",仅保留重启时一次性清理;为避免定时扫描误回收仍在用的 vNPU https://github.com/Project-HAMi/ascend-device-plugin/pull/120

## Project-HAMi/ascend-device-plugin: ed35e1c4 -> ffadaa96
- 比较: ed35e1c4b003795de84ba942f6965fa269e866b3 -> ffadaa96 | ahead=2 | files=4 | Release: —
- https://github.com/Project-HAMi/ascend-device-plugin/compare/ed35e1c4b003795de84ba942f6965fa269e866b3...ffadaa96270de157fbe461be321f7b17c79a16de

### AI 总结重点(源码 diff 为据)
- **周期性 idle vNPU 回收改为默认关闭的开关**(#120)。`PluginServer` 新增字段 `enablePeriodicIdleVNPUCleanup bool`,`NewPluginServer` 签名多一个同名参数;`cmd/main.go` 新增 flag `enable_periodic_idle_vnpu_cleanup`(`flag.Bool`,**默认 `false`**),help 明确写"当关闭时,重启时的一次性清理仍会跑(default false: periodic cleanup disabled)"。`Start()` 里原本无条件 `go ps.startPeriodicCheckIdleVNPUs()`,现在包在 `if ps.enablePeriodicIdleVNPUCleanup { ps.wg.Go(...) }` 里。**前→后行为差异**:此前无论如何都有一个每 `checkIdleVNPUInterval`(默认 60s)跑一次的 ticker 去扫并释放空闲 vNPU;改后默认这条 goroutine 根本不启动,只有 `watchAndRegister` 常驻。提交标题点名"avoid premature reclamation"——即周期扫描会把"当下看空闲、实际仍被占用/即将复用"的 vNPU 提前回收,现选择默认不承担这个风险。
  <details><summary>代码依据 internal/server/server.go</summary>

  ```diff
  -	ps.wg.Add(1)
  -	go ps.startPeriodicCheckIdleVNPUs()
  -	ps.wg.Add(1)
  -	go ps.watchAndRegister()
  +	if ps.enablePeriodicIdleVNPUCleanup {
  +		ps.wg.Go(ps.startPeriodicCheckIdleVNPUs)
  +	}
  +	ps.wg.Go(ps.watchAndRegister)
  ```
  </details>
  <details><summary>代码依据 cmd/main.go</summary>

  ```diff
  +	enablePeriodicIdleVNPUCleanup = flag.Bool("enable_periodic_idle_vnpu_cleanup", false, "whether to enable the periodic idle vNPU cleanup goroutine; when disabled, the one-shot cleanup on restart still runs (default false: periodic cleanup disabled)")
  ...
  -	server, err := server.NewPluginServer(mgr, *nodeName, *checkIdleVNPUInterval)
  +	server, err := server.NewPluginServer(mgr, *nodeName, *checkIdleVNPUInterval, *enablePeriodicIdleVNPUCleanup)
  ```
  </details>
- **goroutine 生命周期迁 `sync.WaitGroup.Go`,消手写 Add/Done 竞态**(#120)。三处 goroutine(`startPeriodicCheckIdleVNPUs`、`watchAndRegister`、`serve()` 里的重启循环)从"`wg.Add(1)` + 体内 `defer wg.Done()`"改为 `ps.wg.Go(fn)`,由 `WaitGroup.Go`(Go 1.25 新 API)内部成对管理 Add/Done。旧代码专门写了注释解释"必须在启 goroutine 前同步 Add,否则和 `Stop()` 的 `Wait()` 竞态、panic 'WaitGroup is reused before previous Wait has returned'";新写法把这个约束交给标准库,注释和 `defer ps.wg.Done()` 一并删除。纯并发管理重构,不改回收/注册的业务语义。
  <details><summary>代码依据 internal/server/register.go</summary>

  ```diff
  -// watchAndRegister must be launched with ps.wg.Add(1) already called by the
  -// caller (see Start()); doing the Add here would race with Stop()'s wg.Wait().
  +// watchAndRegister is launched via ps.wg.Go in Start(), which owns the
  +// WaitGroup Add(1)/Done() pairing; this function must not call wg.Done itself.
   func (ps *PluginServer) watchAndRegister() {
  -	defer ps.wg.Done()
  ```
  </details>
- **Go 版本现代化的顺带清理**(#120,无行为影响):`chan interface{}` → `chan any`(含 `stopCh`/`StopCh()` 返回类型)、`for i := 0; i < vCount; i++` → `for i := range vCount`(Go 1.22 range-over-int)、测试里 `slices.Backward` 反向遍历、`interface{}` 全量换 `any`。纯语法层,列此仅为说明本次 diff 的其余体量都在这里,不含新能力。

### 后续发展方向 [AI]
- vNPU 回收策略正从"激进定时腾资源"退回"保守、显式开启":默认只在重启时清一次,周期扫描要用户按需打开。证据只覆盖 `Start()` 的 gating 与 flag 定义,**未见 `startPeriodicCheckIdleVNPUs` 内部的"空闲判定"逻辑本身是否也改**(判定阈值/依据没进本次 diff)——若后续要把周期回收默认打回开启,大概率得先补硬"idle 判定"的准确性,可下期盯 `startPeriodicCheckIdleVNPUs` 与其调用的 idle 判定函数是否有改动。
- 该仓在做 Go 1.25 工具链跟进(`WaitGroup.Go`),并发骨架在标准化;证据只覆盖 server/register 两文件的 goroutine 启动方式,未见是否已全面切到新 Go(如 go.mod 版本行未进滤后信号文件)。

## 本期无实质改动(折叠)
<details><summary>4 仓无实质改动</summary>

- Project-HAMi/HAMi:ahead=2 但仅 bump/CI/merge,无实质代码改动(Release 仍 v2.9.0)
- Project-HAMi/HAMi-core:无新提交(时分软切分内核本期静默)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交(release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=05e6c800b41c5544356682ad5b6bf19d8d6fe838 branch=master release=v2.9.0 scanned=2026-07-31 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a branch=main release=— scanned=2026-07-31 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-31 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ffadaa96270de157fbe461be321f7b17c79a16de branch=main release=— scanned=2026-07-31 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-31 -->
