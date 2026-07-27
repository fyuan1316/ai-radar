# HAMi diff 雷达 2026-07-28

## 摘要
- HAMi 主仓落 2 个实质提交:一是安全加固——所有 HTTP server(scheduler、metrics、vGPUmonitor)加 `ReadHeaderTimeout`/`ReadTimeout` 防 Slowloris,并把 MIG 配置文件写入权限从 `os.ModePerm`(0777)收紧到 `0o600` 且写失败即删旧文件避免 apply 陈旧配置;二是新硬件适配——dynamic MIG 支持 RTX PRO 6000 Blackwell Server Edition,内建 1g.24gb/2g.48gb/4g.96gb 三档几何,并把 `nvidia-mig-parted` bump 到 v0.12.3。
- 无 CRD/API/proposal 路径命中;软切分内核 HAMi-core 及 volcano/ascend/WebUI 四仓均无新提交。
- 方向:本期两条都围绕 NVIDIA MIG(硬切分)路径——Blackwell 新卡几何入库 + 供应链/传输面安全收口,未见 HAMi-core 时分软切分侧的动作。

## 当日重要改变
- Project-HAMi/HAMi [新能力] dynamic MIG 新增 RTX PRO 6000 Blackwell Server Edition 机型几何(1g.24gb×4 / 2g.48gb×2 / 4g.96gb×1),mig-parted 升 v0.12.3。证据:charts/hami/templates/scheduler/device-configmap.yaml、docs/develop/dynamic-mig.md、docker/Dockerfile.withlib。https://github.com/Project-HAMi/HAMi/commit/c343242d983151f8152e318f52ae4e6e388540f9
- Project-HAMi/HAMi [安全加固] MIG 配置文件权限 0777→0600 + HTTP server 加读超时。证据:pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go、cmd/scheduler/main.go。https://github.com/Project-HAMi/HAMi/pull/2100

## Project-HAMi/HAMi: 96cc5faa -> c343242d
- 比较: 96cc5faa3404fbb45a41d69fdab44bb1267c1950 -> c343242d | ahead=5 | files=18 | Release: v2.9.0
- 比较页:https://github.com/Project-HAMi/HAMi/compare/96cc5faa3404fbb45a41d69fdab44bb1267c1950...c343242d983151f8152e318f52ae4e6e388540f9

### AI 总结重点(源码 diff 为据)
- 新增 `writeMigConfig(data []byte)` 封装 MIG 配置落盘:写入权限从 `os.ModePerm`(0777,任意用户可读写)收紧到 `0o600`(仅 owner 读写);且写失败时 `os.Remove(migConfigPath)` 删掉旧文件,使后续 `nvidia-mig-parted apply` 因文件缺失而失败,而不是静默 apply 陈旧配置。原两处直接 `os.WriteFile("/tmp/migconfig.yaml", data, os.ModePerm)`(util.go 的 `ApplyMigTemplate` 与 server.go 的 `Start`)统一改调 `writeMigConfig`。`migConfigPath` 改为 `var` 以便测试重定向。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go</summary>

  ```diff
  +// writeMigConfig persists the rendered MIG config with owner-only permissions.
  +func writeMigConfig(data []byte) {
  +	if err := os.WriteFile(migConfigPath, data, 0o600); err != nil {
  +		klog.Errorf("failed to write %s: %v", migConfigPath, err)
  +		_ = os.Remove(migConfigPath)
  +		return
  +	}
  +	klog.V(4).InfoS("wrote MIG config", "path", migConfigPath, "bytes", len(data))
  +}
  -	os.WriteFile("/tmp/migconfig.yaml", data, os.ModePerm)
  -	cmd := exec.Command("nvidia-mig-parted", "apply", "-f", "/tmp/migconfig.yaml")
  +	writeMigConfig(data)
  +	cmd := exec.Command("nvidia-mig-parted", "apply", "-f", migConfigPath)
  ```
  </details>

- 三处 HTTP server 全部加读超时,收敛 Slowloris/慢连接面:scheduler 的 `start()` 明文与 TLS 两条路径都从裸 `http.ListenAndServe` 改为构造 `&http.Server{ReadHeaderTimeout: 15s, ReadTimeout: 60s}`;scheduler metrics 与 vGPUmonitor 的 `initMetrics` 从全局默认 mux(`http.Handle`+`http.ListenAndServe(bindAddress, nil)`)改为独立 `http.NewServeMux()` + 带超时的 `http.Server`(独立 mux 顺带消除全局默认 mux 被意外注册的隐患)。

  <details><summary>代码依据 cmd/scheduler/main.go</summary>

  ```diff
  -		if err := http.ListenAndServe(config.HTTPBind, router); err != nil {
  +		server := &http.Server{
  +			Addr:              config.HTTPBind,
  +			Handler:           router,
  +			ReadHeaderTimeout: 15 * time.Second,
  +			ReadTimeout:       60 * time.Second,
  +		}
  +		if err := server.ListenAndServe(); err != nil {
  ```
  </details>

  <details><summary>代码依据 cmd/scheduler/metrics.go</summary>

  ```diff
  -	http.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
  -	log.Fatal(http.ListenAndServe(bindAddress, nil))
  +	mux := http.NewServeMux()
  +	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
  +	server := &http.Server{
  +		Addr:              bindAddress,
  +		Handler:           mux,
  +		ReadHeaderTimeout: 15 * time.Second,
  +		ReadTimeout:       60 * time.Second,
  +	}
  +	log.Fatal(server.ListenAndServe())
  ```
  </details>

- dynamic MIG 机型库新增 "RTX PRO 6000 Blackwell Server Edition":scheduler 的 device-configmap 内 `allowedGeometries` 加三档切分——`1g.24gb`(core 25/mem 24576/count 4)、`2g.48gb`(core 50/mem 49152/count 2)、`4g.96gb`(core 100/mem 98304/count 1),即整卡 96GB 显存可切 4/2/1 份;docs 同步该几何(文档版不含 core 字段)。配套 `Dockerfile.withlib` 把 `nvidia-mig-parted` 从 v0.12.2 升到 v0.12.3(Blackwell MIG profile 依赖新版 mig-parted)。

  <details><summary>代码依据 charts/hami/templates/scheduler/device-configmap.yaml</summary>

  ```diff
  +      - models: [ "RTX PRO 6000 Blackwell Server Edition" ]
  +        allowedGeometries:
  +          -
  +            - name: 1g.24gb
  +              core: 25
  +              memory: 24576
  +              count: 4
  +          -
  +            - name: 2g.48gb
  +              core: 50
  +              memory: 49152
  +              count: 2
  +          -
  +            - name: 4g.96gb
  +              core: 100
  +              memory: 98304
  +              count: 1
  ```
  </details>

  <details><summary>代码依据 docker/Dockerfile.withlib</summary>

  ```diff
  -RUN go install github.com/NVIDIA/mig-parted/cmd/nvidia-mig-parted@v0.12.2
  +RUN go install github.com/NVIDIA/mig-parted/cmd/nvidia-mig-parted@v0.12.3
  ```
  </details>

### 后续发展方向 [AI]
- 硬切分(MIG)路径持续扩机型:Blackwell RTX PRO 6000 入库延续 HAMi 用 `allowedGeometries` 声明式描述每卡可切几何的模式,新卡上市即补 configmap 条目——证据只覆盖 device-configmap.yaml 与 dynamic-mig.md 的几何新增,未见调度器几何选择算法本身改动。
- 安全面向"默认最小权限 + 显式超时"收口:本期把文件权限与 HTTP 超时两类常见 lint/scorecard 告警一起清了(同期 scorecard/ci-image-scanning workflow 也有微调),推测受 OpenSSF scorecard 驱动;证据只覆盖三处 server 与 migconfig 落盘,未逐一核对是否还有其他裸 `ListenAndServe`。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交</summary>

- Project-HAMi/HAMi-core:无新提交(时分软切分内核本期静默)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交(release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=c343242d983151f8152e318f52ae4e6e388540f9 branch=master release=v2.9.0 scanned=2026-07-28 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a branch=main release=— scanned=2026-07-28 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-28 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ed35e1c4b003795de84ba942f6965fa269e866b3 branch=main release=— scanned=2026-07-28 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-28 -->
