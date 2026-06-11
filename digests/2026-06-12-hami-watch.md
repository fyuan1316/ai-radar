# HAMi diff 雷达 2026-06-12

## 摘要
- HAMi 主仓 1 笔实质修复(#1930):device plugin 启动流程把整段 MIG 初始化收口到 `operatingMode=="mig"` 之内,并把 `nvidia-mig-parted` 调用失败从 **`klog.Fatalf` 崩溃改为告警 + 回退到非 MIG 配置**——纯软切分(vGPU)节点/缺 mig-parted 二进制时不再让 device plugin 整体起不来。
- HAMi-core、volcano-vgpu、ascend-device-plugin、WebUI 四仓本期均无新提交。无 CRD/API/proposal 路径命中。

## 当日重要改变
- 无(无 `[弃用/移除]`/`[API/CRD变更]`/`[架构方向]`/`[版本跨档]`/`[新能力]` 信号命中;本笔属健壮性修复,未改对外接口/字段)。

## Project-HAMi/HAMi: 8d6644c9 -> 5dca58eb
- 比较: 8d6644c9445cf509563ccc5a60b57914a35ede60 -> 5dca58eb | ahead=2 | files=4 | Release: v2.9.0
- 实质提交: Fix: Skip nvidia-mig-parted when MIG is disabled (#1930) https://github.com/Project-HAMi/HAMi/commit/47b01ad3560cb1f3231e9c39b3a66258077fb635
- (另 1 笔为 deps bump golang.org/x/net 0.55→0.56 #1943,已滤)

### AI 总结重点(源码 diff 为据)
- **`NvidiaDevicePlugin.Start()` 把整段 MIG 探测/初始化用 `if plugin.operatingMode == "mig"` 包起来**。改前:`CreateMigApplyLockDir`/`RemoveMigApplyLock` 与 `deviceSupportMig` 遍历在每个节点无条件执行(只有最末的配置处理才按 mode 分支);改后:非 MIG 模式节点(纯 hami-core 软切分场景)完全跳过锁目录创建与 `nvidia-mig-parted export` 调用。即软虚拟化路径与 MIG 硬切分路径在启动逻辑上彻底解耦。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  -	err = CreateMigApplyLockDir()
  -	if err != nil {
  -		klog.Fatalf("CreateMIGLockSubDir failed:%v", err)
  -	}
  -	err = RemoveMigApplyLock()
  -	...
  -	var deviceSupportMig bool
  -	for _, name := range deviceNames { ... }
  +	migApplied := false
  +	if plugin.operatingMode == "mig" {
  +		deviceSupportMig := true
  +		for _, name := range deviceNames { ... }
  +		if deviceSupportMig {
  +			err = CreateMigApplyLockDir()
  +			...
  +			err = RemoveMigApplyLock()
  ```
  </details>

- **`nvidia-mig-parted export` 失败从致命崩溃降级为告警 + 回退**。改前:`cmd.Run()` 出错直接 `klog.Fatalf`(进程退出,device plugin 整体不可用);改后:`klog.Errorf` 打印 stderr + `klog.Warning("Falling back to non‑MIG configuration")`,继续走非 MIG 配置。对缺 `nvidia-mig-parted` 二进制或 MIG 探测异常的节点,device plugin 不再 crash-loop。

  <details><summary>代码依据 server.go(mig-parted 错误处理)</summary>

  ```diff
  -		err := cmd.Run()
  -		if err != nil {
  -			klog.Fatalf("nvidia-mig-parted failed with %s\n", err)
  -		}
  -		outStr := stdout.Bytes()
  -		yaml.Unmarshal(outStr, &plugin.migCurrent)
  +			err := cmd.Run()
  +			if err != nil {
  +				klog.Errorf("nvidia-mig-parted failed: %v (stderr: %s)", err, stderr.String())
  +				klog.Warning("Falling back to non‑MIG configuration")
  +			} else {
  +				outStr := stdout.Bytes()
  +				yaml.Unmarshal(outStr, &plugin.migCurrent)
  +				...
  +				migApplied = true
  +			}
  ```
  </details>

- **新增私有方法 `buildFallbackMigConfig(deviceNumbers int)`**,把"为每个设备写一条 `MigEnabled:false` 的 current 配置"从内联逻辑抽成函数;并新增 `migApplied bool` 哨兵统一收口:只要 MIG 没真正成功 apply(非 mig 模式、设备不支持、mig-parted 失败),末尾就调 `buildFallbackMigConfig` 并打印 "Using non‑MIG configuration"。文末 `ApplyMigTemplate()` 的触发条件也从 `deviceSupportMig` 改为 `migApplied`——只有真正导出成功才套用 MIG 模板。

  <details><summary>代码依据 server.go(fallback 函数 + migApplied 哨兵)</summary>

  ```diff
  +// BuildFallbackMigConfig - fallback to non-MIG mode
  +func (plugin *NvidiaDevicePlugin) buildFallbackMigConfig(deviceNumbers int) {
  +	plugin.migCurrent.MigConfigs = make(map[string]nvidia.MigConfigSpecSlice)
  +	configSlice := nvidia.MigConfigSpecSlice{}
  +	for i := 0; i < deviceNumbers; i++ {
  +		conf := nvidia.MigConfigSpec{MigEnabled: false, Devices: []int32{int32(i)}}
  +		configSlice = append(configSlice, conf)
  +	}
  +	plugin.migCurrent.MigConfigs["current"] = configSlice
  +}
  ...
  +	if !migApplied {
  +		plugin.buildFallbackMigConfig(deviceNumbers)
  +		klog.Infoln("Using non‑MIG configuration")
  +	}
  ...
  -	if deviceSupportMig {
  +	if migApplied {
  		plugin.ApplyMigTemplate()
  	}
  ```
  </details>

- 配套 `server_test.go` 新增 `TestMigConfigFilePermissions`/`TestMigConfigFilePermissionSecurityImprovement` 等用例,校验 `/tmp/migconfig.yaml` 写出权限为 `0644`(-rw-r--r--)而非此前 `os.ModePerm`(0777)——侧面提示 mig 配置文件写权限做了收紧(本 patch 节选未直接含 0777→0644 主代码改动,(hunk 截断,未覆盖全部))。

### 后续发展方向 [AI]
- 方向是**把"软切分(hami-core hook/时分)"与"MIG 硬切分"两条启动路径在 device plugin 层面正式分离并提升非 MIG 路径的容错**:此前两路径共用一段会 `Fatalf` 的初始化,任何 mig-parted 异常都会拖垮纯 vGPU 节点;现在非 mig 模式直接短路、mig 模式失败也回退。证据只覆盖 `server.go::Start` 与新增 fallback 函数,未见调度器侧(scheduler/webhook)相关改动,也未见 `operatingMode` 取值来源的改动,无法判断 mode 是否新增了自动探测。
- 权限收紧(0644)若属本 commit 配套主代码改动,指向 device plugin 在宿主写文件的安全基线在补齐;但当前 patch 节选只见测试用例,主代码依据需看源链接确认。

## 本期无实质改动(折叠)
<details><summary>四仓无新提交</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release: hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=5dca58eb3d4c75806517ffe910c1c03ba6220af9 branch=master release=v2.9.0 scanned=2026-06-12 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=02a9ac22a438824b411e13ad4144fc152a1ec63b branch=main release=— scanned=2026-06-12 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-12 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-12 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-12 -->
