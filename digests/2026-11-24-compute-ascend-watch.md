# 昇腾算力栈 diff 雷达 2026-11-24

## 摘要
- **device-plugin 删掉"优雅容错"整套配置面**:`faultCustomization.json` 的 `GraceTolerance` 段(`WaitProcessReadCMTime`/`WaitDeviceResetTime`/`WaitFaultSelfHealingTime`)、对应结构体、常量、`ParamOption.GraceToleranceOn`、`isSupportGraceTolerance()` 全部删除,`isHealthy()` 不再对"在用卡上的 FreeRestartNPU 故障"报 Healthy。核对 base 版 `manager.go` 发现 `isSupportGraceTolerance()` **早已没有调用方**(开关恒为 false),所以运行时行为不变,本质是把一个已下线的特性从 API 和文档里清掉。
- **卡死检测和设备占用识别修了三处误判**:(1) hang detector 取不到某个进程的 `/proc/<pid>/stat` 时,以前 `continue` 照算(少算 CPU 时间,看上去像卡死),现在整轮放弃并清掉 hang 事件;(2) `ASCEND_VISIBLE_DEVICES` 匹配从 `strings.Contains` 改为精确比较变量名(新 `parser.IsEnvName`),npu-exporter、container-manager、device-plugin 三处一起改;(3) 重复分配检测扫描容器时,把"容器没有运行中的 task"(NotFound)降为 Debug 跳过,把 ctx 取消/超时当作扫描中断返回错误。另外 container-manager 等设备重置的上限从 60s 放宽到 600s。
- **openFuyao 10 仓里 9 仓零提交**;唯一有提交的 ub-network-device-plugin 是 CVE 依赖升级(otel 1.44→1.47、Go 1.25→1.26),没有功能变化。mind-cluster tag 仍是 v26.3.0-beta.2。**覆盖缺口**:`component/container-manager` 不在 PATHPREFIX 清单里,这是第三次因此漏扫;已补进 task 文件。

## 当日重要改变
- mind-cluster [弃用/移除] device-plugin 删除 `GraceToleranceCustomization` 结构体与 `FaultCustomization.GraceTolerance` 字段,以及 `loadGraceToleranceCustomization()`、`ParamOption.GraceToleranceOn` 和 9 个 `*WaitProcessReadCMTime/*WaitDeviceResetTime/*WaitFaultSelfHealingTime` 常量;文档 `02_ascend_device_plugin.md` 同时删掉三个参数。用户 ConfigMap `mindx-dl-fault-config` 里留着的 `GraceTolerance` 键,之后会被 json 反序列化静默忽略。 https://gitcode.com/Ascend/mind-cluster/commit/61193ed47397
- mind-cluster [行为变更] container-manager `waitDevResetMaxTime` 60→600,device-plugin hang detector 在 CPU 时间采集失败时放弃本轮判定(`collectMetrics` 改为返回 error)。 https://gitcode.com/Ascend/mind-cluster/commit/4842f7ac585a

## mind-cluster: 94d21ad9 -> 4b230db0
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/94d21ad9355295041392d28e73704f3e0a04bda8...4b230db07136b3e2a3feff044843cb9c83457305 | tag: v26.3.0-beta.2 | commits=20(10 个实质提交 + 10 个 merge) | truncated=false
- 改动分布(不限 path 全量核对):`component/ascend-faultdiag-online` 241、`component/ascend-faultdiag` 24、`component/ascend-device-plugin` 16、`docs/zh` 5、`component/container-manager` 4、`component/ascend-common` 2、`component/ascend-for-volcano` 2、`component/npu-exporter` 1
- 取数说明:helper 的 patch 节选几乎被 faultdiag-online 的版权头改动占满(241 个文件里绝大多数只改了 Copyright 头,见 `[Usage][FD] Copyright compliance revision part1/2`)。下面的研判是绕过 helper、直接读 compare JSON 写的:先把只改版权头的文件滤掉,再逐个读剩下的实质 hunk。`component/container-manager` 不在 PATHPREFIX 里,helper 输出看不到它,已补进 task。

### AI 总结重点(源码 diff 为据)

#### 1. 优雅容错(GraceTolerance)从配置面整体下线,实际是清理死代码
删除的内容:`FaultCustomization` 里的 `GraceTolerance GraceToleranceCustomization` 字段和整个结构体;`LoadFaultCustomization()` 不再调用 `loadGraceToleranceCustomization()`,该函数(三个参数做 5~90 / 60~180 / 1~30 的范围校验)也一并删除;`Option.GraceToleranceOn` 删除;`isHealthy()` 里"`FreeRestartNPU` 且卡在用且开关打开就报 Healthy"的分支删除。

**行为影响判定**:base 版(94d21ad9)`manager.go` 里 `isSupportGraceTolerance` 只出现在定义处(第 1461、1475 行),没有任何调用点。本期 diff 只删了函数体,也没删调用点,能编过就说明之前已无人调用。所以 `GraceToleranceOn` 早就恒为 false,`isHealthy` 里那条分支是不可达的,**本期删除没有改变运行时行为**。真正有影响的是配置契约:`faultCustomization.json` 少了一个顶层键,文档同步删除。
<details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go</summary>

```diff
 type FaultCustomization struct {
-	GraceTolerance GraceToleranceCustomization
 	FaultFrequency []FaultFrequencyCustomization
 	FaultDuration  []FaultDurationCustomization
 }
-// GraceToleranceCustomization is the customization info of grace tolerance
-type GraceToleranceCustomization struct {
-	WaitProcessReadCMTime    int64
-	WaitDeviceResetTime      int64
-	WaitFaultSelfHealingTime int64
-}
@@ func LoadFaultCustomization(faultCustomizationByte []byte) error {
-	loadGraceToleranceCustomization(faultCustomization.GraceTolerance)
```
</details>
<details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go + pkg/server/manager.go</summary>

```diff
 func (tool *AscendTools) isHealthy(device *common.NpuDevice) string {
 	faultType := common.GetFaultType(device.FaultCodes, device.LogicID)
-	if faultType == common.NormalNPU || faultType == common.NotHandleFault || faultType == common.SubHealthFault ||
-		(faultType == common.FreeRestartNPU &&
-			tool.npuIsUsedNow(device.DeviceName) && common.ParamOption.GraceToleranceOn == true) {
+	if faultType == common.NormalNPU || faultType == common.NotHandleFault || faultType == common.SubHealthFault {
 		return v1beta1.Healthy
 	}
-func (hdm *HwDevManager) isSupportGraceTolerance() {
-	if common.ParamOption.HotReset != common.HotResetTrainOffLine {
-	...
-	if hdm.RunMode != api.Ascend910 {
-		hwlog.RunLog.Debugf("grace tolerance only support training chip")
-	...
-	common.ParamOption.GraceToleranceOn = true
-}
```
</details>

#### 2. Hang detector:CPU 时间采集失败时整轮放弃,不再部分累加
`collectCPUTime()` 以前遇到某个 pid 读 stat 失败就 `continue`。这样 `metrics.CPUTime` 会少算那个进程的时间;如果进程已经退出,或容器看不到宿主机 pid,CPU 时间看上去就"停住了",可能满足卡死判定。现在任一 pid 失败就返回 error,`detectNPU()` 调 `npuHangEventDisappear(logicID, nil)` 清掉 hang 事件并跳过本轮。`collectCPUTime` 也挪到 `collectMetrics` 的第一步,先确认 CPU 时间可信,再去采利用率、显存和流量。`getProcessCPUTime()` 新增空数据保护:`utils.LoadFile` 在文件不存在时返回 nil 而不报错,以前这种情况会被当成 stat 内容去解析。还有一处:入口加了 `IsHangDetectionEnabled()` 检查,关闭时直接 return,不再启动 producer。日志改成 `WarnfWithLimit` 按 pid 限流。
<details><summary>代码依据 component/ascend-device-plugin/pkg/device/hangdetection/hang_detector.go</summary>

```diff
 	common.LoadHangDetectionConfigFromFile()
-
+	if !common.IsHangDetectionEnabled() {
+		hwlog.RunLog.Info("hang detection disabled")
+		return
+	}
 	runHangDetectionProducer(ctx)
@@ func (hd *HangDetector) detectNPU(logicID int32) {
-	hd.collectMetrics(logicID, procInfo, &metrics)
+	if err := hd.collectMetrics(logicID, procInfo, &metrics); err != nil {
+		hd.npuHangEventDisappear(logicID, nil)
+		return
+	}
@@ func (hd *HangDetector) collectCPUTime(...) error {
 		cpuTime, err := getProcessCPUTime(proc.Pid)
 		if err != nil {
-			hwlog.RunLog.Errorf("hang detection get CPU time failed, pid=%d: %v", proc.Pid, err)
-			continue
+			hwlog.RunLog.WarnfWithLimit(domain, proc.Pid, "hang detection get CPU time failed, pid=%d: %v", proc.Pid, err)
+			return err
 		}
+	// utils.LoadFile returns nil data without error when the file does not exist (e.g. the process has
+	// exited or the container has no permission to access the host pid), which must not be parsed as stat content.
+	if len(data) == 0 {
+		return 0, fmt.Errorf("proc stat file of pid %d is empty or not exist", pid)
+	}
```
</details>

#### 3. container-manager:等待设备重置的上限 60s → 600s
跟上一条是同一个提交。`devmgr/workflow.go` 的常量 `waitDevResetMaxTime` 放大 10 倍,也就是说 container-manager 在超时报失败之前,最长会等芯片热复位 10 分钟。
<details><summary>代码依据 component/container-manager/pkg/devmgr/workflow.go</summary>

```diff
 const (
-	waitDevResetMaxTime = 60
+	waitDevResetMaxTime = 600
 )
```
</details>

#### 4. `ASCEND_VISIBLE_DEVICES` 从子串匹配改为精确匹配变量名(三处组件统一)
`ascend-common/common-utils/parser` 新增 `IsEnvName(env, name)`:按第一个 `=` 切开,只比较 key。以前用 `strings.Contains(env, api.AscendDeviceInfo)`,`FOO_ASCEND_VISIBLE_DEVICES=...` 这类带前缀的变量,或者值里恰好含这个字符串的变量,都会被误认成设备分配,从而把错误的卡号归给容器。代码倒序遍历 env、遇到第一个命中就 break,所以误命中会直接盖掉真正的分配。改动覆盖 npu-exporter(containerd 和 iSula 两条解析路径)、container-manager(containerd/docker)、device-plugin 重复分配检测(`ociClient.ParseSingleContainer`)。
<details><summary>代码依据 component/ascend-common/common-utils/parser/device_parser.go + component/npu-exporter/collector/container/parser.go</summary>

```diff
+// IsEnvName reports whether the variable name (the part before the first '=')
+// of the "KEY=VALUE" entry equals name.
+func IsEnvName(env, name string) bool {
+	parts := strings.SplitN(env, "=", envSliceLen)
+	return len(parts) == envSliceLen && parts[0] == name
+}
@@ func (dp *DevicesParser) parseDevicesInContainerd(...)
-		if strings.Contains(e, api.AscendDeviceInfo) {
+		if parser.IsEnvName(e, api.AscendDeviceInfo) {
@@ func (dp *DevicesParser) parseDeviceInIsula(...)
-		if strings.Contains(e, api.AscendDeviceInfo) {
+		if parser.IsEnvName(e, api.AscendDeviceInfo) {
```
</details>

#### 5. 重复分配检测:分清"容器没在跑"和"解析失败"
`containerruntime/interface.go` 新增 `IsNotFound(err)`,统一识别 containerd 的 `errdefs.ErrNotFound`、gRPC `codes.NotFound` 和 docker 的 `client.IsErrNotFound`。`ParseSingleContainer` 遇到 `task.GetProcess()==nil` 时改为返回包着 `errdefs.ErrNotFound` 的错误。`containerdClient.ParseAllContainers` 据此把三种情况分开:已退出的容器 Debug 跳过并计数;ctx 取消或超时(新增 `isScanCanceled`,兼容 gRPC status 包装后 `errors.Is` 认不出的情况)直接中断返回;其余错误按 Warn 记。docker 侧改动相同,而且把真正的解析失败从 Debug 提到 Warn。这就是提交标题里的"消除误报并恢复真故障可见性":以前已退出的容器刷 Warn,真正的解析失败反而被淹没;docker 侧的真失败以前只有 Debug 级别。
<details><summary>代码依据 component/ascend-device-plugin/pkg/duplicatedetector/containerruntime/{interface,containerd_client}.go</summary>

```diff
+func IsNotFound(err error) bool {
+	if err == nil {
+		return false
+	}
+	return errors.Is(err, errdefs.ErrNotFound) || status.Code(err) == codes.NotFound ||
+		client.IsErrNotFound(err)
+}
 	if task.GetProcess() == nil {
-		return nil, fmt.Errorf("task not found for container %s", containerID)
+		return nil, fmt.Errorf("%w: container %s has no running task", errdefs.ErrNotFound, containerID)
 	}
@@ func (c *containerdClient) ParseAllContainers(...)
-				hwlog.RunLog.Warnf("failed to parse container %s: %v", ctr.ID(), err)
+				if isScanCanceled(ctx, err) {
+					return nil, fmt.Errorf("container scan interrupted: %w", err)
+				}
+				if IsNotFound(err) {
+					skipped++
+					continue
+				}
+				hwlog.RunLog.Warnf("failed to parse container %s in namespace %s: %v", ctr.ID(), ns, err)
```
</details>
提交: https://gitcode.com/Ascend/mind-cluster/commit/bccebcc17018

#### 6. ascend-for-volcano:调度失败原因带上芯片拓扑状态
`chipHandler.CheckNodeNPUByTask` 把 `util.Request` 提成局部变量。`FitEvict`/`FitFailed` 的错误信息里新增 `chips<root.State()>`,并输出完整 request(含 Mode、AllowNetUnhealthy),原来只有 `reqNum`。调度逻辑没有变,只是 Pending 原因更好排查。 https://gitcode.com/Ascend/mind-cluster/commit/7eaa655cf610
<details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/chip.go</summary>

```diff
 	case topo.FitEvict:
-		return fmt.Errorf("%s node<%s> don't have enough free npu, req<%d>, can be satisfied by eviction",
-			util.NPUResourceShortageError, node.Name, reqNum)
+		return fmt.Errorf("%s node<%s> chips<%s> don't have enough free npu, req<%v>, can be satisfied by eviction",
+			util.NPUResourceShortageError, node.Name, root.State(), request)
```
</details>

#### 7. ascend-faultdiag:掉卡模式库的描述从"判定规则"改写为"现象说明",并补齐测试
`kg-config.json` 里 HBM 主备空间、UCE panic、热隔离+OS_OOM、AI Core ECC、AICPU CE 等掉卡根因条目的 `description_zh/en`,原来写的是检测规则(sel.txt 锚点、前推 1min、具体错误码 0xA4040001/0x80c98008 等),现在改成面向用户的现象说明;"AICPU Cache CE 风暴"更名为"AICPU Cache CE 故障"。判定规则本身没删,代码在 11-21 那期合入的 `lost_device_checker.py`。本期新增 `test_lost_device_checker.py`(12 个 LostChecker 子类,各测命中、缺锚点、缺证据、出窗口、禁止事件)和 `test_precheck_event_generation.py`(覆盖 NPU history log、BMC fdm_log、sel.txt 三种解析器的事件生成)。`top3_root_sort/chain_complete.py` 的异常捕获从裸 `except` 收窄到 `NetworkXNoPath/NodeNotFound`,并对 (v→u) 链路去重。 https://gitcode.com/Ascend/mind-cluster/commit/b555888042da
<details><summary>代码依据 component/ascend-faultdiag/src/ascend_fd/configuration/kg-config.json(hunk 截断,未覆盖全部)</summary>

```diff
-                "description_zh": "BMC sel.txt检测到NPU掉卡告警（状态Asserted），且伴生0x80c98008告警码，判断为AI Core多bit ECC导致掉卡。",
+                "description_zh": "AI Core多bit ECC导致掉卡",
-                "cause_zh": "AICPU Cache CE风暴导致掉卡",
+                "cause_zh": "AICPU Cache CE故障导致掉卡",
```
</details>

#### 8. 本期噪声(不计入研判)
- `component/ascend-faultdiag-online` 241 个文件中,绝大多数只改了 Copyright 头格式。少数有实质 diff 的文件(slownode 的 `dealdb/query_*.go`、`node_level_detection_data_parser.go`)也只是 SQL 去行尾空格、`allDatas`→`allData` 改名、拼写修正,没有逻辑变化。 https://gitcode.com/Ascend/mind-cluster/commit/7117822c2a84 / https://gitcode.com/Ascend/mind-cluster/commit/b1f588f25e78
- 文档:clusterd `current-job-statistic` 转储日志从"最多 5 份、保留 40 天"改为"最多 180 份、保留 180 天",只改了文档,本区间没有对应代码改动;另外修正了 MindSpore 断点续训示例。

### 后续发展方向 [AI]
- **device-plugin 的故障自愈收敛到一条路径**:优雅容错(业务进程读 ConfigMap 自行等待芯片复位)早已没有入口,本期把配置面也拆了。同一天 container-manager 把设备复位等待放宽到 600s。两条放在一起看,"等芯片复位"这件事正在从"device-plugin 与业务进程协商"收归到 container-manager 一处。证据只覆盖这两处常量和删除,没看到 container-manager 侧新增的复位编排逻辑,方向推断成立度中等。
- **NPU 卡死检测还在打磨误报**:继 HTTPS/运维 Agent 之后,这一期集中修宿主机/容器边界的读取问题(宿主机 pid 不可见、已退出容器、env 子串误匹配)。说明 hang detection 和重复分配检测已经在真实多容器节点上跑,误报是现在的主要问题。证据只覆盖 bugfix hunk,看不到默认开关值的变化(`IsHangDetectionEnabled` 的默认值不在本期 diff 里)。
- **对我们产品的启示**:(1) 我们自己的 GPU/NPU 设备占用识别如果也靠扫 env,应统一按 key 精确匹配,不要用 contains;昇腾这里三个组件各写了一份 contains,同一个 bug 出现了三次。(2) 卡死检测取进程 CPU 时间时,读不到就应整轮放弃,不能部分累加,否则会被容器 pid namespace 隔离直接骗出误报。(3) 文档、配置字段和代码的生命周期应该一起下线;昇腾这次是功能失效很久之后才清理配置面,期间用户 ConfigMap 里的参数一直静默无效。

## ub-network-device-plugin: 37a1d669 -> 9cc5dbdd
- 比较: https://gitcode.com/openFuyao/ub-network-device-plugin/compare/37a1d669b4f5ad815110d509c541d321c0c4fab5...9cc5dbdd87c01f90aa7f9ea8038b7a1ed5b2bd2d | tag: v26.9.0 | commits=2 | truncated=false
### AI 总结重点(源码 diff 为据)
- 只有依赖升级,修 CVE-2026-128085:`go.opentelemetry.io/otel/*` v1.44.0→v1.47.0(新增间接依赖 `otel/log`)、`go` 指令 1.25.0→1.26.0、构建镜像 `BUILDER_VERSION` 1.25.10→1.26.8、testify 1.11.1→1.12.1。没有业务代码改动。 https://gitcode.com/openFuyao/ub-network-device-plugin/commit/68f7f11f2548
<details><summary>代码依据 go.mod / cmd/ub-network-device-plugin/Dockerfile</summary>

```diff
-go 1.25.0
+go 1.26.0
-	go.opentelemetry.io/otel/trace v1.44.0
+	go.opentelemetry.io/otel/trace v1.47.0
-ARG BUILDER_VERSION=1.25.10
+ARG BUILDER_VERSION=1.26.8
```
</details>

### 后续发展方向 [AI]
- 只是例行安全维护;UB fabric 主线没有功能信号。

## 本期无实质改动(折叠)
- npu-operator: ddcf0eb7..ddcf0eb7 无新提交(v26.9.0)
- npu-container-toolkit: c720a3b8..c720a3b8 无新提交(v26.9.0)
- npu-driver-installer: bd1b2a9e..bd1b2a9e 无新提交(v26.9.0)
- vNPU: 529e48a6..529e48a6 无新提交(v26.9.0)
- npu-node-provision: 717ef777..717ef777 无新提交(v26.6.0)
- npu-dra-plugin: f0654355..f0654355 无新提交(v26.9.0)
- npu-feature-discovery: 4ba6e58e..4ba6e58e 无新提交(v26.9.0)
- volcano-ext: 0f265f98..0f265f98 无新提交(v1.9.0)
- ub-network-bandwidth-operator: d4ee1a47..d4ee1a47 无新提交(无 tag)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=4b230db07136b3e2a3feff044843cb9c83457305 tag=v26.3.0-beta.2 scanned=2026-11-24 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f0654355fb65ac3ffca9a41357100a82fde4fc10 tag=v26.9.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=npu-feature-discovery sha=4ba6e58e3e132f61936ae2c619f91d9e75c5ec90 tag=v26.9.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=9cc5dbdd87c01f90aa7f9ea8038b7a1ed5b2bd2d tag=v26.9.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=ub-network-bandwidth-operator sha=d4ee1a478ec50c0c543b73f01a00944467e8018d tag=— scanned=2026-11-24 -->
