# 昇腾算力栈 diff 雷达 2026-08-12

## 摘要
- npu-exporter 正把网络类指标采集从 hccn_tool 迁往 **dcmi** 接口:新增 `SupportDcmi()` 采集器接口方法 + `classifyCollectors()` 运行时按"是否支持 dcmi"把采集器路由到单协程/多协程两条链,UB 采集器已首个走 dcmi 探测,network/roce/optical 暂固定返回 false 留待接口就绪(mind-cluster)。
- npu-exporter 新增三个整机健康计数指标 `machine_{healthy,unhealthy,unknown}_npu_nums`,unknown = DCMI 取不到健康态的芯片,三者之和恒等于在位芯片数(mind-cluster)。
- npu-dra-plugin 修 dcmi_init 段错误:弃用 openfuyao 自建 builder 镜像(ONBUILD 触发段错),改用官方 `golang:1.24-bookworm` 内联构建 + `-gcflags="-N -l"` 关优化/内联规避崩溃。

## 当日重要改变
- mind-cluster [架构方向] npu-exporter 采集链引入 dcmi 迁移开关:`MetricsCollector` 接口新增 `SupportDcmi()`,`Register` 时 `classifyCollectors()` 按 IsSupported+SupportDcmi 动态填充单/多协程 map(此前是编译期静态两张表)。证据 component/npu-exporter/collector/common/metrics_collector.go、collector/config/metrics_config.go。https://gitcode.com/Ascend/mind-cluster/commit/4351a8e7aab50b1ff0a4b7e0ca8f1430f1d27391
- mind-cluster [新能力] npu-exporter 暴露整机健康/不健康/未知 NPU 计数指标。证据 component/npu-exporter/collector/metrics/collector_for_npu.go `countHealthStatus`。https://gitcode.com/Ascend/mind-cluster/commit/4351a8e7aab50b1ff0a4b7e0ca8f1430f1d27391

## mind-cluster: 1aa04bb1 -> 4351a8e7
- 比较: 1aa04bb1..4351a8e7 | tag: v26.1.0 | commits=18 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/1aa04bb11642a630a16ba9ac88f392e4b3982e96...4351a8e7aab50b1ff0a4b7e0ca8f1430f1d27391

### AI 总结重点(源码 diff 为据)
- **采集器接口新增 `SupportDcmi(*NpuCollector) bool`,并在采集器上缓存 `DcmiSupported`**。适配器默认返回 true;这是把 UB/网络类指标从 hccn_tool 采集切到 dcmi 采集的能力开关。语义:该采集器能否用 dcmi 而非 hccn_tool 采数。
  <details><summary>代码依据 component/npu-exporter/collector/common/metrics_collector.go</summary>

  ```diff
   	// IsSupported Check whether the current hardware supports this metric
   	IsSupported(*NpuCollector) bool
  +
  +	// SupportDcmi reports whether this collector can collect via dcmi instead of hccn_tool.
  +	SupportDcmi(*NpuCollector) bool
   }
  @@ MetricsCollectorAdapter struct
  +	// DcmiSupported caches the result of SupportDcmi. classifyCollectors calls
  +	// SupportDcmi once at registration; afterwards callers read DcmiSupported directly.
  +	DcmiSupported bool
  +// SupportDcmi default true; multi chain collectors override to probe dcmi.
  +func (c *MetricsCollectorAdapter) SupportDcmi(*NpuCollector) bool { return true }
  ```
  </details>
- **采集器分组从编译期静态两张表改为运行时 `classifyCollectors()` 动态路由**。原先 singleGoroutineMap(hccs/npu/util…)与 multiGoroutineMap(network/roce/optical/ub)在源码里写死;现在全部先塞进 `candidateCollectors`,`Register` 时按 `IsSupported` 过滤、再按 `SupportDcmi` 决定进单协程链(dcmi 支持)还是多协程链(走 hccn_tool)。含义:dcmi 就绪的采集器可收敛到单协程,减少 hccn_tool 多协程开销。
  <details><summary>代码依据 component/npu-exporter/collector/config/metrics_config.go</summary>

  ```diff
  -	singleGoroutineMap = map[string]common.MetricsCollector{
  -		groupHccs: &metrics.HccsCollector{}, groupNpu: &metrics.BaseInfoCollector{}, ... }
  -	multiGoroutineMap = map[string]common.MetricsCollector{
  -		groupNetwork:..., groupRoce:..., groupOptical:..., groupUb:... }
  +	candidateCollectors = map[string]common.MetricsCollector{ /* 全部采集器 */ }
  +	singleGoroutineMap = map[string]common.MetricsCollector{}  // classifyCollectors 填充
  +	multiGoroutineMap  = map[string]common.MetricsCollector{}
  +func classifyCollectors(n *common.NpuCollector) {
  +	for name, c := range candidateCollectors {
  +		if !c.IsSupported(n) { continue }
  +		if c.SupportDcmi(n) { singleGoroutineMap[name] = c } else { multiGoroutineMap[name] = c }
  +	}
  +}
  ```
  </details>
- **UB 采集器首个落地 dcmi 探测**:`SupportDcmi` → `probeUbDcmi` 用第一块有效端口调 `GetPortPktStatsInfo`,若报 `NotSupportErrorCode`/`FuncNotFoundErrorCode` 则判定不支持;`CollectToCache` 据 `useDcmi` 走 `collectUbInfo(logicID, n, useDcmi)` 新签名。network/roce/optical 暂显式返回 false("will probe dcmi once the interface is ready"),即 dcmi 迁移目前只到 UB。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_ub.go</summary>

  ```diff
  +func probeUbDcmi(n *colcommon.NpuCollector) bool {
  +	_, logicIDs, err := n.Dmgr.GetDeviceList()
  +	if err != nil || len(logicIDs) == 0 { return false }
  +	for udie, ports := range colcommon.NpuDevPortInfos.GetPortMap() {
  +		_, err := n.Dmgr.GetPortPktStatsInfo(logicIDs[0], int32(udie), int32(ports[0].PortID))
  +		return !isDcmiFuncMissingErr(err)
  +	}
  +	return false }
  -func collectUbInfo(logicID int32) []*common.UBInfo {
  +func collectUbInfo(logicID int32, n *colcommon.NpuCollector, useDcmi bool) []*common.UBInfo {
  ```
  </details>
- **新增整机健康计数指标**:`machine_healthy_npu_nums` / `machine_unhealthy_npu_nums` / `machine_unknown_npu_nums`,由 `countHealthStatus(chips, caches)` 从当前芯片列表推导,保证三者之和 == 在位芯片数;未缓存或健康态未知的记为 unknown(注释:DCMI 接口取不到健康态)。Prometheus 与 Telegraf 两条上报路径都加了这三项。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_npu.go</summary>

  ```diff
  +	machineHealthyDesc   = colcommon.BuildDescWithLabel("machine_healthy_npu_nums", ...)
  +	machineUnhealthyDesc = colcommon.BuildDescWithLabel("machine_unhealthy_npu_nums", ...)
  +	machineUnknownDesc   = colcommon.BuildDescWithLabel("machine_unknown_npu_nums",
  +		"Amount of the npus whose health status cannot be obtained via DCMI interface on the machine.", nil)
  +func countHealthStatus(chips []colcommon.HuaWeiAIChip, caches map[int32]chipCache) (healthy, unhealthy, unknown int32) {
  +	for _, chip := range chips {
  +		cache, ok := caches[chip.PhyId]
  +		if !ok { unknown++; continue }
  +		switch cache.HealthStatus { case colcommon.Healthy: healthy++ ... } } }
  ```
  </details>
- **infer-operator 修多服务场景第二个服务 P 节点拉不起**:instanceset_controller.go 1 行改动 + 单测,commit `<inferoperator>修复多服务场景下,第二个服务p节点无法拉起问题`。patch 节选未落到该文件(排序后被 npu-exporter 大改挤出前 8),仅从提交标题 + 信号文件路径确认,未读 hunk,不下符号级结论。

### 后续发展方向 [AI]
- npu-exporter 监控采集正从 hccn_tool 向 dcmi 收敛,当前证据只覆盖 UB 采集器真正接了 dcmi 探测,network/roce/optical 的 `SupportDcmi` 仍硬编码 false;后续这三类接入 dcmi 后会自动从多协程链迁到单协程链,是采集架构走向 dcmi 统一 + 协程数下降的明确信号。未见 dcmi 侧数据精度/兼容性处理,证据仅到"探测通不通"。
- 健康计数指标补齐了"整机有多少 NPU 拿不到健康态(unknown)"这个可观测缺口,利于上层调度/告警区分"确实故障"与"探测失败";证据只到指标定义与计数逻辑,未见对应告警规则或消费方改动。

## npu-dra-plugin: fa979c80 -> 90c70b32
- 比较: fa979c80..90c70b32 | tag: v26.6.0 | commits=3 | truncated=false
- https://gitcode.com/openFuyao/npu-dra-plugin/compare/fa979c80357c29e82e576eca1cadc699fadf49c3...90c70b32b9b368efc2cc26bda1209e4f275a804c

### AI 总结重点(源码 diff 为据)
- **修 dcmi_init 段错误——弃用自建 builder 镜像改官方 golang 镜像内联构建**。原 Dockerfile_pipeline 用 `cr.openfuyao.cn/openfuyao/builder/golang:1.24.5`(带 ONBUILD,触发 dcmi_init 段错)+ `# syntax=docker/dockerfile:latest`;现改为 `golang:1.24-bookworm`,在同一 stage 内 `COPY . .` 后 `go build -gcflags="-N -l" -ldflags="-w -s"`。`-gcflags="-N -l"` 关闭编译优化与内联,是规避 dcmi_init 段错的关键手段;并显式设 `GOPROXY=goproxy.cn`、`GOSUMDB=sum.golang.google.cn`。release 阶段从 `COPY --link --chmod=550` 改为普通 `COPY` + `RUN chmod +x`。
  <details><summary>代码依据 Ascend-npu-dra-plugin/build/Dockerfile_pipeline</summary>

  ```diff
  -# syntax=docker/dockerfile:latest
  -ARG BUILDER_IMAGE=cr.openfuyao.cn/openfuyao/builder/$BUILDER:$BUILDER_VERSION
  -ARG PKG=./cmd/ascend-npu-dra-kubeletplugin
  -FROM $BUILDER_IMAGE AS build
  +ARG BUILDER_IMAGE=golang:1.24-bookworm
  +FROM ${BUILDER_IMAGE} AS build
  +WORKDIR /go/src/app
  +ENV GOPROXY=https://goproxy.cn,direct
  +ENV GOSUMDB=sum.golang.google.cn
  +COPY . .
  +RUN cd ./cmd/ascend-npu-dra-kubeletplugin && \
  +    go build -o /go/bin/npu-dra-plugin -gcflags="-N -l" -ldflags="-w -s"
  -COPY --link --from=build --chmod=550 /go/bin/app /npu-dra-plugin
  +COPY --from=build /go/bin/npu-dra-plugin /npu-dra-plugin
  +RUN chmod +x /npu-dra-plugin
  ```
  </details>

### 后续发展方向 [AI]
- 纯构建/打包修复,DRA kubeletplugin 业务逻辑无改动;`-gcflags="-N -l"` 常态化关优化会牺牲运行期性能,若长期保留说明 dcmi CGO 侧对编译优化敏感(疑似内联导致 CGO 初始化崩溃),后续值得盯是否回补真正的 CGO 修复而非一直关优化。证据仅覆盖 Dockerfile,未见 dcmi_init 源码层改动。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin:无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=4351a8e7aab50b1ff0a4b7e0ca8f1430f1d27391 tag=v26.1.0 scanned=2026-08-12 -->
<!-- ANCHOR repo=npu-operator sha=7cddacb58841f285c6f719e2d7a5cb235be32cdb tag=v26.6.0 scanned=2026-08-12 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-12 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-12 -->
<!-- ANCHOR repo=vNPU sha=f5869cd17c57b8392b97fc76a7879a1a9a1eb81f tag=v0.1.0 scanned=2026-08-12 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-12 -->
<!-- ANCHOR repo=npu-dra-plugin sha=90c70b32b9b368efc2cc26bda1209e4f275a804c tag=v26.6.0 scanned=2026-08-12 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-12 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-12 -->
</content>
</invoke>
