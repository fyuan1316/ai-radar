# 昇腾算力栈 diff 雷达 2026-09-16

## 摘要
- mind-cluster:昇腾**软切分(soft-share)多容器可观测性**成型——npu-exporter 把 `npu_container_info` / `container_npu_*` 系列指标从"单容器共享卡才上报"改成**遍历同卡上所有容器逐个打标上报**,修复多容器共享一张物理 NPU 时指标全丢的问题;同时 device-plugin 把"普通共享设备"与"软切分虚拟化"拆成两条独立校验轴(各自约束 volcanoType)。
- vNPU:本期为**静态检查/gofmt 整改轮**(codecheck、G.FMT.01),nodelock 解析结构体化 + 若干 helper 抽取,**无能力变更**——只降圈复杂度、去重逻辑。
- 其余 7 仓无新提交。

## 当日重要改变
- mind-cluster [新能力/修复] 软切分多容器场景 NPU 容器级指标不上报的修复——`updateContainerInfo` 从接收单个 `containerInfo` 改为遍历 `[]DevicesInfo`,每容器复制 cardLabel 并回填真实 namespace/pod/container 三段标签。证据 `component/npu-exporter/collector/metrics/collector_for_npu.go`。https://gitcode.com/Ascend/mind-cluster/commits/branch/master
- mind-cluster [架构方向] device-plugin 参数校验拆分:`checkSoftShareDevParam` 一分为二为 `checkShareDevFeatureParam`(共享设备,shareDevCount>1)与 `checkSoftShareDevFeatureParam`(软切分虚拟化,softShareDevConfigDir 非空),二者对 volcanoType 约束相反——共享但非软切分要求 volcanoType=false,软切分要求 volcanoType=true。证据 `component/ascend-device-plugin/main.go`。https://gitcode.com/Ascend/mind-cluster
- vNPU [无功能变更] 全量 codecheck/gofmt 整改,不列入能力信号(详见下)。

## mind-cluster: 7ec21612 -> ea073966
- 比较: 7ec21612..ea073966 | tag: v26.1.1 | commits=36 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/7ec21612e08b67dc4478cc1262e7fc49ed48bd42...ea0739667c742ff3eb3381582166636e75036d39

### AI 总结重点(源码 diff 为据)
- **npu-exporter 支持"一卡多容器软切分"的容器级指标上报**:`updateContainerInfo` 签名从 `containerInfo container.DevicesInfo`(单个)改为 `containerInfos []container.DevicesInfo`(切片),内部 `for` 遍历每个容器,**为每容器复制一份 cardLabel** 再回填 namespace/pod_name/container_name 三段真实值,避免污染共享的 cardLabel。此前逻辑只在 `len(containerInfos)==1` 时取第 0 个上报,多容器共享同卡时该指标直接丢失。

  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_npu.go</summary>

  ```diff
  -func updateContainerInfo(ch chan<- prometheus.Metric, containerInfo container.DevicesInfo,
  +func updateContainerInfo(ch chan<- prometheus.Metric, containerInfos []container.DevicesInfo,
   	cardLabel []string, chip *chipCache, chipWithVnpu colcommon.HuaWeiAIChip) {
  -	containerName := getContainerNameArray(containerInfo)
  -	if len(containerName) != colcommon.ContainerNameLen {
  -		return
  +	for _, containerInfo := range containerInfos {
  +		containerNameArray := getContainerNameArray(containerInfo)
  +		if len(containerNameArray) != colcommon.ContainerNameLen {
  +			continue
  +		}
  +		containerLabel := make([]string, len(cardLabel))
  +		copy(containerLabel, cardLabel)
  +		containerLabel[len(containerLabel)-containerNameIndexOffsetInCardLabel] = containerNameArray[colcommon.ConNameIdx]
  +		containerLabel[len(containerLabel)-podNameIndexOffsetInCardLabel] = containerNameArray[colcommon.PodNameIdx]
  +		containerLabel[len(containerLabel)-namespaceIndexOffsetInCardLabel] = containerNameArray[colcommon.NameSpaceIdx]
  +		doUpdateMetric(ch, chip.timestamp, 1,
  +			append(containerLabel, containerInfo.ID, strings.Join(containerNameArray, "_")), npuCtrInfo)
  +	}
   }
  ```
  </details>

- **HBM/DDR 显存指标解除对多 Pod 占位标签的排除**:`collector_for_hbm.go`/`collector_for_ddr.go` 的上报门槛从"末位标签非空 **且** 非 `NotDisplayedForMultiPod`"放宽为"len>0 且末位非空",即多容器软切分下即使 cardLabel 带多 Pod 占位符也照常上报 `container_npu_total_memory`/`container_npu_used_memory`——与上面容器级逐个打标配套。

  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_hbm.go</summary>

  ```diff
  -	if c.Is910Series &&
  -		cardLabel[len(cardLabel)-1] != "" && cardLabel[len(cardLabel)-1] != colcommon.NotDisplayedForMultiPod {
  +	if c.Is910Series && len(cardLabel) > 0 && cardLabel[len(cardLabel)-1] != "" {
   		doUpdateMetric(ch, timestamp, hbmInfo.MemorySize, cardLabel, npuCtrTotalMemory)
   		doUpdateMetric(ch, timestamp, hbmInfo.Usage, cardLabel, npuCtrUsedMemory)
   	}
  ```
  </details>

- **利用率指标放宽单容器约束**:`collector_for_utilization.go` 把 `if len(containerInfos) == 1` 改为 `>= 1`,多容器场景取第 0 个容器也进入 `container_npu_utilization` 上报路径(未像 npu_info 那样逐容器展开,仍是取首个)。

  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_utilization.go</summary>

  ```diff
  -		if len(containerInfos) == 1 {
  +		if len(containerInfos) >= 1 {
   			containerInfo = containerInfos[0]
   		}
  ```
  </details>

- **device-plugin 参数校验把"共享设备"与"软切分虚拟化"拆成两条正交特性**:删除旧的 `checkSoftShareDevParam`/`checkShareDevCount`/`checkSoftShareDevConfigDir`,新增两个语义独立的校验函数。`checkShareDevFeatureParam`(shareDevCount>1 启用共享):当共享启用但**未开软切分**(softShareDevConfigDir 空)且 volcanoType=true 时报错;`checkSoftShareDevFeatureParam`(softShareDevConfigDir 非空启用软切分):要求 shareDevCount==MaxShareDevCount(100)、绝对路径、volcanoType=true。即"纯共享设备"要求 volcanoType=false、"软切分"要求 volcanoType=true,二者不再耦合在一个函数里。

  <details><summary>代码依据 component/ascend-device-plugin/main.go</summary>

  ```diff
  -		checkSoftShareDevParam,
  +		checkShareDevFeatureParam,
  +		checkSoftShareDevFeatureParam,
  ...
  +func checkShareDevFeatureParam() bool {
  +	if *shareDevCount < 1 || *shareDevCount > common.MaxShareDevCount {
  +		hwlog.RunLog.Error("share device function params invalid"); return false
  +	}
  +	if *shareDevCount > 1 && *softShareDevConfigDir == "" && *volcanoType {
  +		hwlog.RunLog.Error("shared device feature without soft share virtualization " +
  +			"requires volcanoType to be false"); return false
  +	}
  +	return true
  +}
  +func checkSoftShareDevFeatureParam() bool {
  +	if *softShareDevConfigDir == "" { return true }
  +	if *shareDevCount != common.MaxShareDevCount { ...; return false }
  ```
  </details>

- **ascend-for-volcano 增加 Info 级故障/就绪日志**(可观测性,无调度逻辑变更):`reschedule.go` 在 `isFaultTask` 为真时补 Info 日志;`npu.go` 的 `jobReady` 打印 readyTaskNum/minAvailable。

  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
  +	klog.V(util.LogInfoLev).Infof("job<%s/%s> ready: %v, ready task num: %d, minAvailable: %d", job.NameSpace,
  +		job.Name, *job.JobReadyTag, ji.ReadyTaskNum(), job.MinAvailable)
   	return *job.JobReadyTag && ji.ReadyTaskNum() >= job.MinAvailable
  ```
  </details>

- **slice_common 十六进制解析补齐索引对齐**:`HexStringToInt` 解析失败时由"跳过"改为"追加 0 再 continue",保持输出切片与输入长度一致(下游按位取值不再错位)。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/slice_common.go</summary>

  ```diff
   		if err != nil {
   			hwlog.RunLog.Errorf("parse hex int failed and skip it, string: %s", source)
  +			intSlice = append(intSlice, 0)
   			continue
   		}
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾软切分(soft-share)正从"能切"走向"可观测":本期核心是让多容器共享一张物理 910 卡时,每个容器的 `npu_container_info`/显存/利用率都能按 namespace_pod_container 维度独立上报——这是把 vNPU 软切分接入 Prometheus 计费/监控的前置。证据只覆盖 exporter 打标与 device-plugin 参数校验拆分,未见对应的 vNPU 侧切分算法或 CRD 变更。
- device-plugin 把"共享设备"与"软切分虚拟化"解耦成两条特性轴(volcanoType 约束相反),说明昇腾在同一 device-plugin 下并行支持"整卡时分共享(非 volcano)"与"volcano 编排的软切分"两种形态;证据止于参数校验函数,未见两形态在分配路径上的具体分叉。

## vNPU: d88907ed -> 60eb00c7
- 比较: d88907ed..60eb00c7 | tag: v0.1.0 | commits=4 | truncated=false
- https://gitcode.com/openFuyao/vNPU/compare/d88907ed4061c5d63babbb79b453a368b55f14d6...60eb00c70ff741cbb4a3d06779b9995c441a67e6

### AI 总结重点(源码 diff 为据)
- 本期 4 条提交全是 **codecheck/gofmt 整改**(`fix: resolve codecheck issues`、`fix: gofmt test files to resolve G.FMT.01`),**无功能/能力变更**,仅重构降复杂度。关键重构:
  - `nodelock.go`(volcano-xpu-plugin 与 xpu-device-plugin 各一份):`ParseNodeLock` 从返回 `(time, ns, name, error)` 四元组改为返回 `*LockState` 结构体,并抽出 `evaluateLockState` 承接锁过期/悬挂判断——语义不变,只把多返回值收进结构体、拆函数降圈复杂度。
  - `plugin.go`:把 `GetXPUDevicesFromNode` 内联的在用设备统计逻辑抽成 `updateXPUDeviceUsage(v, devices, templates, nodeName)`,行为不变。
  - `service_impl.go`:抽出 `getContainerID(pod, name)` 复用;`getVxpus` 把 `dev := VxpuDevice{...}; res = append(res, dev)` 改为直接 append。
  - `npu.go`:全局变量 `DevShmMount` 改为函数 `GetDevShmMount()`,调用方从判空追加改为直接追加。

  <details><summary>代码依据 xpu-device-plugin/pkg/lock/nodelock.go</summary>

  ```diff
  -func ParseNodeLock(value string) (time.Time, string, string, error) {
  +type LockState struct {
  +	Time      time.Time
  +	Namespace string
  +	PodName   string
  +}
  +func ParseNodeLock(value string) (*LockState, error) {
   	parts := strings.SplitN(value, ",", 3)
   	lockTime, err := time.Parse(time.RFC3339, parts[0])
  -	if err != nil { return time.Time{}, "", "", err }
  -	if len(parts) < 3 { return lockTime, "", "", nil }
  -	return lockTime, parts[1], parts[2], nil
  +	if err != nil { return nil, err }
  +	if len(parts) < 3 { return &LockState{Time: lockTime}, nil }
  +	return &LockState{Time: lockTime, Namespace: parts[1], PodName: parts[2]}, nil
   }
  ```
  </details>

### 后续发展方向 [AI]
- 无能力信号可推断。本轮是仓库刚开源后的静态检查合规化(v0.1.0),nodelock 双份实现(volcano 插件侧 + device-plugin 侧)并行演进,暗示 vNPU 的节点级软切分锁仍在两处维护、尚未收敛为单一来源;证据仅覆盖重构 diff,未见锁逻辑合并计划。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY(仅保锚点)</summary>

- npu-operator — 无新提交
- npu-container-toolkit — 无新提交
- npu-driver-installer — 无新提交
- npu-node-provision — 无新提交
- npu-dra-plugin — 无新提交
- volcano-ext — 无新提交
- ub-network-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=ea0739667c742ff3eb3381582166636e75036d39 tag=v26.1.1 scanned=2026-09-16 -->
<!-- ANCHOR repo=npu-operator sha=802e269728d3528e7864b4d8c04a915c12d1169b tag=v26.6.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-16 -->
</content>
