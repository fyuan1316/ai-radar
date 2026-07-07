# HAMi diff 雷达 2026-07-08

## 摘要
- **ascend-device-plugin 新增节点级 device-share 自动开启**(新文件 `internal/server/device_share.go`):插件启动即对节点每块昇腾芯片跑 `npu-smi set -t device-share -d 1`,彻底去掉"手动 npu-smi + 逐 Pod 注解"这条老开箱路径——HAMi × Ascend vNPU 软切分的启用体验从"运维手动预置"变成"插件自管",且做成 fail-fast 硬门禁。
- **HAMi 主仓把 vGPU 的 `ld.so.preload` 从静态挂载改为运行时生成**:`vgpu-init.sh` 末尾按实际 `DEST_DIR` 重新生成 preload 文件,同步删掉 configmap/daemonset 里的静态 `ld.so.preload` 挂载——修的是 Helm 自定义 `libPath` 时 vGPU 隔离"静默失效"的坑,属软切分核心路径的正确性修复。
- HAMi 另在 `CONTRIBUTING.md` 新增 6 条 "Contribution Gates",其中"影响设备分配/容器内隔离的改动必须在真实 GPU 上验证"是值得注意的治理信号(见下)。HAMi-core / volcano-vgpu / WebUI 三仓 EMPTY。

## 当日重要改变
- ascend-device-plugin [新能力] 新增独立文件 `internal/server/device_share.go`,插件启动阶段节点级自动开启 npu-smi `device-share`,取代手动/逐 Pod 注解路径。https://github.com/Project-HAMi/ascend-device-plugin/commit/3bc81ef07d95a97fcc5e8d32011d6387ef0ea25b
- HAMi [架构方向] vGPU 的 `ld.so.preload` 由 configmap 静态挂载改为 `vgpu-init.sh` 运行时按 `DEST_DIR` 生成,删除 daemonset/configmap 中对应挂载。https://github.com/Project-HAMi/HAMi/commit/229130af3b2df6c0c2f975056b14f6762a79bce7
- HAMi [治理] `CONTRIBUTING.md` 新增 Contribution Gates:隔离/分配类改动强制真实 GPU 验证并记录驱动版本;禁 AI 生成 commit/co-author trailer。https://github.com/Project-HAMi/HAMi/commit/2487a240edb78705c2cbf35829f95f67793817ed

## Project-HAMi/ascend-device-plugin: d7b365d2 -> 6f1113ff
- 比较: d7b365d2fce33fabefc779d24bab249d0cc4bbed -> 6f1113ff | ahead=4 | files=6 | Release: —
- PR #95 https://github.com/Project-HAMi/ascend-device-plugin/pull/95

### AI 总结重点(源码 diff 为据)
- **新增 `applyDeviceShare(chips, enabled)` + `resolveNpuSmi()` + `runNpuSmi`(package var,便于打桩)**,把"开启昇腾 device-share 虚拟化"从人工前置步骤内化进插件:对传入每个 `chipKey{Card,Chip}` 无条件下发 `npu-smi set -t device-share -i <card> -c <chip> -d 1`。npu-smi 无 `-y`,故对 stdin 硬喂 `"Y\n"` 绕过 "continue setting?(Y/N)" 交互(否则 exit 200)。npu-smi 解析顺序:driver hostPath 的 `/usr/local/Ascend/driver/tools/npu-smi` → `/usr/local/sbin` → `/usr/local/bin` → `PATH`。
  <details><summary>代码依据 internal/server/device_share.go</summary>

  ```diff
  +var runNpuSmi = func(args ...string) ([]byte, error) {
  +	bin, err := resolveNpuSmi()
  +	if err != nil { return nil, err }
  +	cmd := exec.Command(bin, args...)
  +	cmd.Stdin = strings.NewReader("Y\n")   // npu-smi 无 -y,喂 Y 绕过交互确认
  +	return cmd.CombinedOutput()
  +}
  +// applyDeviceShare sets device-share on every chip unconditionally ...
  +// Fails fast on the first per-chip error, leaving later chips to be
  +// re-driven by the next Allocate.
  ```
  </details>
- **接入点在 `PluginServer.Start()`**:`serve()` 之前插入 `ps.enableNodeDeviceShare()`,该配置**启动时读一次**(源自 `device-node-config` 的 `hami-vnpu-core` 字段),改配置需重启插件;任一芯片翻转失败则**插件启动失败、节点不上报任何设备**(fail-fast,不给"半开"状态)。
  <details><summary>代码依据 internal/server/server.go</summary>

  ```diff
  	if err != nil { return err }
  +	if err := ps.enableNodeDeviceShare(); err != nil {
  +		return err
  +	}
  	err = ps.serve()
  ```
  </details>
- **顺带修 WaitGroup 复用 panic**:把 `ps.wg.Add(1)` 从 goroutine 内部(`startPeriodicCheckIdleVNPUs` / `watchAndRegister`)提到 `Start()` 里同步先加,避免 Add 与 `Stop()` 的 `Wait()` 竞态触发 "WaitGroup is reused before previous Wait has returned"。属并发正确性修复,不是新能力。
  <details><summary>代码依据 internal/server/server.go / register.go</summary>

  ```diff
  +	ps.wg.Add(1)
  	go ps.startPeriodicCheckIdleVNPUs()
  +	ps.wg.Add(1)
  	go ps.watchAndRegister()
  -	// (原) 各 goroutine 内部各自 ps.wg.Add(1)
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 vNPU 软切分正把"能力启用"的责任从运维/用户手工上移到 device-plugin 自身:老流程要人先跑 npu-smi 并给 Pod 打注解,新流程用节点级配置一次性铺开。这降低了接入门槛,但把 npu-smi 路径解析、驱动版本(README 标 ≥25.5)、fail-fast 三者绑成了硬依赖——证据只覆盖 `Start()` 内的启用与 `applyDeviceShare` 下发,未见 `Allocate` 路径如何消费 device-share 状态、也未见启用失败后的可观测性/告警细节。
- 值得盯:该逻辑"启动读一次配置",与 K8s 里 daemonset 滚动/节点配置热更的语义不匹配(改 `hami-vnpu-core` 需重启),后续若要支持在线切换切分模式,这里会是改造点。

## Project-HAMi/HAMi: 02ac4f03 -> 2487a240
- 比较: 02ac4f03bd8dca36074cfc52e8b99689e20d3523 -> 2487a240 | ahead=2 | files=4 | Release: v2.9.0
- PR #2018 / #2019

### AI 总结重点(源码 diff 为据)
- **`ld.so.preload` 生命周期由"打包静态资产"改为"运行时生成"**:`vgpu-init.sh` 遍历拷贝时**显式跳过** `ld.so.preload`,并在脚本末尾用 `printf '%s/libvgpu.so\n' "$DEST_DIR"` 按实际目标目录重写它。配套删除了 `configmap.yaml` 里硬编码 `{{ .Values.devicePlugin.libPath }}/libvgpu.so` 的 preload 数据、以及 `daemonsetnvidia.yaml` 里对该 subPath 的只读挂载。根因:当 Helm 把运行时目录从历史 `/usr/local/vgpu` 定制走后,静态 preload 指向的 libvgpu.so 路径会与实际挂载错位,导致 **vGPU 隔离静默失效**——现在 preload 恒等于真实 `DEST_DIR`。
  <details><summary>代码依据 docker/vgpu-init.sh</summary>

  ```diff
  +    if [ "$relative_path" = "ld.so.preload" ]; then
  +        echo "Skipped managed file: $source_file"
  +        continue
  +    fi
  ...
  +# Regenerate ld.so.preload so it always points at the actual mounted libvgpu.so
  +printf '%s/libvgpu.so\n' "$DEST_DIR" > "$DEST_DIR/ld.so.preload"
  ```
  </details>
- **`DEST_DIR` 归一化**:入参去掉尾斜杠(`${1%/}`)、空则回落 `/`,相对路径改用 `"${source_file#$SOURCE_DIR/}"` 与 `"$DEST_DIR/$relative_path"` 组合,消除历史上的双斜杠路径。属上一条的前置正确性保障。
  <details><summary>代码依据 docker/vgpu-init.sh</summary>

  ```diff
  -DEST_DIR="$1"
  +DEST_DIR="${1%/}"
  +if [ -z "$DEST_DIR" ]; then DEST_DIR="/"; fi
  ```
  </details>
- **[治理] `CONTRIBUTING.md` 增 6 条 Contribution Gates**:其中第 2 条"影响设备分配或容器内隔离的改动,提交前必须在真实 GPU 上验证,并在 PR 记录测试内容/设备型号/驱动版本;仅调度扩展器改动可用 mock/单测"——这是对 HAMi 软切分类改动质量门槛的显式抬升;另有禁大规模 AI 生成 PR、禁 AI co-author trailer 等。非代码能力,但反映维护者对 AI 生成 PR 冲击的防御姿态。
  <details><summary>代码依据 CONTRIBUTING.md</summary>

  ```diff
  +**2. Hardware validation.** Changes affecting device allocation or in-container
  +isolation must be validated on real GPU hardware before submitting. Record in
  +the PR what was tested, the device type, and the driver version.
  ```
  </details>

### 后续发展方向 [AI]
- HAMi 把 vGPU 隔离最脆弱的一环(preload 指向)从"部署期静态注入"改为"容器启动期自愈生成",意味着运行时目录(`libPath`/`DEST_DIR`)现在是软切分正确性的单一事实源。证据只覆盖 `vgpu-init.sh` 与两个 chart 模板,未见 device-plugin 侧是否还有其它地方假设旧的 `/usr/local/vgpu` 固定路径;若有,是下一处潜在错位点。
- v2.9.0 后主仓仍是稳定性/正确性收口(preload、路径归一),无 API/CRD/proposal 层动作;治理侧的"硬件验证门禁"值得作为 HAMi 改动可信度的背景参考。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=2487a240edb78705c2cbf35829f95f67793817ed branch=master release=v2.9.0 scanned=2026-07-08 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=8f3a89c67b037d8fdfe6c4cd4d8c4f0cd6504811 branch=main release=— scanned=2026-07-08 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-08 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f1113ff2f380da887c8b777635ab158e1d2c2db branch=main release=— scanned=2026-07-08 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-08 -->
