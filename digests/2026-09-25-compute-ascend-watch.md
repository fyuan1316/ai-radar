# 昇腾算力栈 diff 雷达 2026-09-25

## 摘要
- mind-cluster 的 clusterd 本期落地一整套**静默故障(silent fault)检测与上报**能力(commit 标题 part1~5),新增 `component/clusterd/pkg/{domain,application}/silentfault/` 两级包:消费 ascend-for-volcano 产出的 reschedule-reason configmap,在"同节点连续 C 次首错、且在窗口 M 秒内"时判定为静默故障,走公共故障入口下发 occur 消息隔离节点卡。这正好接上昨天 ascend-for-volcano 给该 CM 打 consumer 标签 + 补 JobUID 的改动——生产者/消费者两端本周先后成型。
- 同包对 manualfault 主循环做了重构:把静默故障纳入手动隔离 CM 的同一份写入/释放路径(`RegisterSilentFaultHandler` + `releaseSilentFault(cm)`),并改成先 `TryGetManualCm` 失败即跳过本轮,避免覆盖用户手工删除。
- npu-operator 仅一处硬件适配:vCANN 客户端更新镜像从通用 `acl-client-update` 改名为 `acl-client-update-910b`(910B 专用)。其余 7 个 openFuyao 仓无新提交。

## 当日重要改变
- mind-cluster [新能力] clusterd 新增 silentfault 静默故障检测包(两级缓存 + 60s 周期检测),把"反复重调度且集中在同一节点首错"识别为硬件静默故障并自动隔离 https://gitcode.com/Ascend/mind-cluster/compare/fc5ebd5f6693824842f77b9147909ed6e209a952...e90da9d8cf8070525451363bdd320579bba07105
- npu-operator [硬件适配] vCANN acl-client-update 镜像收窄为 910B 专用镜像 `acl-client-update-910b`(vnpuClientUpdate 与 draVCANNRTInstaller 两处) https://gitcode.com/openFuyao/npu-operator/compare/802e269728d3528e7864b4d8c04a915c12d1169b...817e8a2372642f0e5b143a0faf1928d30cc12bdf

## mind-cluster: fc5ebd5f -> e90da9d8
- 比较: fc5ebd5f..e90da9d8 | tag: v26.1.1 | commits=36 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/fc5ebd5f6693824842f77b9147909ed6e209a952...e90da9d8cf8070525451363bdd320579bba07105

### AI 总结重点(源码 diff 为据)
- **新增两级 silentfault 检测流水线**。`domain/silentfault/cache.go` 定义两级缓存:一级 `PendingCache`(`events: jobID->[]PendingEvent` 待验证事件 + `processed` 去重集),二级 `FirstFaultMgr`(`events: nodeName->[]FirstFaultEvent` 首错/非首错时间线)。`PendingEvent` 快照了该 job 触发重调度时占用的全部节点 `TaskNodes`(含首错节点 `FailNode`)。语义:重调度不等于故障,要经过延时验证 + 跨节点关联才升级为"静默故障"。

  <details><summary>代码依据 component/clusterd/pkg/domain/silentfault/cache.go</summary>

  ```diff
  +type PendingEvent struct {
  +	JobID     string   // job identifier (vcjob UID)
  +	FailNode  string   // first-error node
  +	TaskNodes []string // all nodes occupied by the job (PreServerList snapshot, incl FailNode)
  +	Timestamp int64    // reschedule occurrence time (seconds)
  +}
  +type FirstFaultEvent struct {
  +	JobID   string
  +	IsFirst bool  // true: first-error record; false: breaks the consecutive run
  +	Timestamp int64
  +}
  ```
  </details>

- **二级检测 `detectFirstFault` 固定 60s 周期,逆序扫描节点事件时间线,命中"窗口 M 秒内连续 C 次首错"即判静默故障**。任一非首错事件(`IsFirst==false`)会把连续计数清零,防止偶发单点抖动误判;命中后 `writeSilentFault` 造标准 occur 消息、经公共故障入口下发(不直接写缓存),并清空该节点时间线。C=`GetConsecutiveTimes()`、M=`GetWindowSeconds()` 均来自配置。

  <details><summary>代码依据 component/clusterd/pkg/application/silentfault/detector.go</summary>

  ```diff
  +	for i := len(events) - 1; i >= 0; i-- {
  +		if events[i].Timestamp < now-m { break }
  +		if !events[i].IsFirst { run, hitJobs = 0, hitJobs[:0]; continue }
  +		run++; hitJobs = append(hitJobs, events[i].JobID)
  +		if run >= c { hit = true; break }
  +	}
  +	if hit { writeSilentFault(node, hitJobs); firstFaultMgr.ClearNode(node) }
  ```
  </details>

- **一级入口 `CmHandler` 直接消费 ascend-for-volcano 输出的 reschedule-reason configmap**:反序列化 CM 里的 `rescheduleReason{JobUID, RescheduleRecords[].ReasonOfTask[]{PodName,NodeName}}`,据此生成待验证事件;CM 被删时只清 `processed` 去重集、保留 pending。这印证昨天 ascend-for-volcano 给该 CM 补 JobUID + consumer 标签就是为了给 clusterd 这个新消费者用。

  <details><summary>代码依据 component/clusterd/pkg/application/silentfault/collector.go</summary>

  ```diff
  +func CmHandler(oldCm, newCm *v1.ConfigMap, op string) {
  +	if !conf.GetSilentFaultEnabled() { return }
  +	if op == constant.DeleteOperator {
  +		pendingCache.ResetProcessed(); return  // keep pending events
  +	}
  +	data := newCm.Data[constant.RescheduleReasonCmKey]
  +	var reasons map[string]rescheduleReason
  +	json.Unmarshal([]byte(data), &reasons)
  ```
  </details>

- **新增静默故障策略配置块 `SilentFaultPolicy`**(config.go):`Enabled` 总开关;`Detect{MinTaskCards, ConsecutiveTimes, HardwareFaultWindowSecond, WindowSecond}` 四个检测阈值,含下界(HwWindow>3s、Window>30s、Times/Cards>0);`Release.FaultFreeSecond` 控制自动解除——`-1` 永不自动解除,`0` 取默认 48 小时。说明这套隔离是可调阈值 + 可配置无故障时长后自动放行的闭环,而非一次性拉黑。

  <details><summary>代码依据 component/clusterd/pkg/domain/conf/config.go</summary>

  ```diff
  +type SilentFaultPolicy struct {
  +	Enabled bool `yaml:"enabled"`
  +	Detect struct {
  +		MinTaskCards, ConsecutiveTimes int
  +		HardwareFaultWindowSecond, WindowSecond int
  +	}
  +	Release struct{ FaultFreeSecond int }
  +}
  +	DefaultSilentReleaseSeconds = 48 * 60 * 60 // 48h; -1 no auto release, 0 -> default
  ```
  </details>

- **manualfault 主循环重构,把静默故障并入手动隔离 CM 的同一份读改写路径**。`ProcessManuSep` 现在的空判改成 `manualfault.FaultCmInfo.Len()==0 && silentfault.SilentFaultIsEmpty()` 两者皆空才删 CM;并把原 `checkDiffAndDelete/release/UpdateOrCreateManualCm` 拆成 `checkManualDiffAndDelete(cm)/releaseManualFault()/releaseSilentFault(cm)/updateManualCm(cm)`,统一先 `TryGetManualCm`,取不到就跳过本轮以免覆盖用户手工删除。`publicfault.RegisterSilentFaultHandler(handleSilentFaultEvent)` 完成注册接线。

  <details><summary>代码依据 component/clusterd/pkg/application/manualfault/cm.go</summary>

  ```diff
  +func init() { publicfault.RegisterSilentFaultHandler(handleSilentFaultEvent) }
  -			if manualfault.FaultCmInfo.Len() == 0 {
  +			if manualfault.FaultCmInfo.Len() == 0 && silentfault.SilentFaultIsEmpty() {
  				manualfault.DeleteManualCm(); continue
  			}
  +			cm, err := manualfault.TryGetManualCm()
  +			if err != nil { /* skip round to avoid overwriting user deletion */ continue }
  +			checkManualDiffAndDelete(cm); releaseManualFault(); releaseSilentFault(cm); updateManualCm(cm)
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾正在把"故障判定"从单点硬件告警,升级为**跨 job/跨节点、带时间窗与连续性统计的推断式检测**:靠重调度行为反推底层静默故障(硬件报不出错但训练反复挂在同一节点)。这是训练稳定性/大集群 MTBF 的核心能力,和 NVIDIA 侧 fault-tolerance/健康检查是同一战场。生产者(ascend-for-volcano 的 reschedule-reason CM)与消费者(clusterd silentfault)本周先后落地,链路已闭环。证据覆盖 detector/collector/cache/config 与 manualfault 接线;未见默认阈值(ConsecutiveTimes/Window 的推荐值)和 UT 外的实际下发 occur 消息格式细节。
- 本区间 36 commit 中其余为:ascend-docker-runtime 与 ascend-device-plugin 的 README 大改(补 CDI 注入模式、容器快照 checkpoint/restore、动态 vNPU 切分等能力说明,**doc-only 无代码**);dra 与 dpu-exporter 的安全编译选项(BIND_NOW)修复;rdma-dp 改 npu-nic-mapping.json 读取逻辑;volcano 删除 SuperPodSizeFromConf 判断;均非核心能力变更,未逐一展开。

## npu-operator: 802e2697 -> 817e8a23
- 比较: 802e2697..817e8a23 | tag: v26.6.0 | commits=2 | truncated=false
- 源: https://gitcode.com/openFuyao/npu-operator/compare/802e269728d3528e7864b4d8c04a915c12d1169b...817e8a2372642f0e5b143a0faf1928d30cc12bdf

### AI 总结重点(源码 diff 为据)
- **charts values.yaml 把 vCANN 客户端更新镜像从通用名改为 910B 专用名**:`vnpuClientUpdate.repository` 与 `draVCANNRTInstaller.repository` 均从 `.../vnpu/acl-client-update` 改为 `.../vnpu/acl-client-update-910b`。含义:vCANN(容器内 CANN 运行时客户端热更新)镜像按硬件形态(910B)拆分打包,而非一份通用镜像通吃——暗示不同昇腾卡形态的 vCANN 客户端已需差异化构建。

  <details><summary>代码依据 charts/npu-operator/values.yaml</summary>

  ```diff
     vnpuClientUpdate:
  -    repository: cr.openfuyao.cn/openfuyao/vnpu/acl-client-update
  +    repository: cr.openfuyao.cn/openfuyao/vnpu/acl-client-update-910b
     draVCANNRTInstaller:
  -    repository: cr.openfuyao.cn/openfuyao/vnpu/acl-client-update
  +    repository: cr.openfuyao.cn/openfuyao/vnpu/acl-client-update-910b
  ```
  </details>

### 后续发展方向 [AI]
- vCANN 镜像按卡型号分叉,可能预示后续会有 910C/300I 等更多硬件专属 client 镜像并存,operator 需按节点硬件选镜像。证据仅一处改名,未见 operator 侧是否已有按硬件形态选择镜像的逻辑(本次只改 chart 默认值)。

## 本期无实质改动(折叠)
<details><summary>7 个仓无新提交</summary>

- npu-container-toolkit(无新提交)
- npu-driver-installer(无新提交)
- vNPU(无新提交)
- npu-node-provision(无新提交)
- npu-dra-plugin(无新提交)
- volcano-ext(无新提交)
- ub-network-device-plugin(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=e90da9d8cf8070525451363bdd320579bba07105 tag=v26.1.1 scanned=2026-09-25 -->
<!-- ANCHOR repo=npu-operator sha=817e8a2372642f0e5b143a0faf1928d30cc12bdf tag=v26.6.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-25 -->
</content>
</invoke>
