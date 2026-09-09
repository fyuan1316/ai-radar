# 昇腾算力栈 diff 雷达 2026-09-10

## 摘要
- **mind-cluster / ascend-for-volcano 把节点打分从单体 factory 重构成可插拔的「打分框架」**:新增 `scoring.go`+`score_weights.go`,每个维度(topology / previousNode / subHealth / chipCount)成为独立 ScorePlugin,按**位段严格优先级**(高位压低位、低位不补偿)合成到一个 uint16 再 ×ScoreWeight;`BatchNodeOrderFn` 对实现 `ScoreFrameworkAware` 的策略(当前 chip-affinity)走新路径,其余策略保留旧 factory 路径(两者不等价)。
- 同期新增 `ascend.scoreWeight` 调度器插件参数(volcano-scheduler-configmap 可配,默认 100),把原先写死的全局 `scoreWeight` 常量升为可运维调参;并补齐重调度快照读取的两个新打分方法 `ScorePreviousFaultNodes` / `ScoreSubHealthGrade`,使「不开启 prefer-previous-node」时纯重调度场景也能避开历史故障落点。
- vNPU 仅做镜像名下划线→连字符规范化 + volcano 镜像源从 `docker.io/library` 占位改指向 `cr.openfuyao.cn` 官方仓(无功能变化);其余 7 仓(npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期无新提交。

## 当日重要改变
- **mind-cluster [架构方向/新能力] 打分逻辑插件化**:ascend-for-volcano 引入独立打分维度框架,替代单体 factory 打分(仅对 chip-affinity 策略生效,其余策略仍走旧路径)。证据:`component/ascend-for-volcano/plugin/scoring.go`(新增 304 行)、`common/util/score_weights.go`(新增 75 行)、`plugin/factory.go` 的 `BatchNodeOrderFn` 分流。 https://gitcode.com/Ascend/mind-cluster/compare/38933c22...94600c37
- **mind-cluster [API/配置变更] 新增可配置打分权重**:`ascend.scoreWeight` 插件参数(默认 100,非正/非数值回退默认),原全局常量 `scoreWeight` 改为 `ScheduleHandler.ScoreWeight` 字段。证据:`component/ascend-for-volcano/npu.go`。
- **mind-cluster [新能力] 新增子项目 ascend-clusterops-agent**:提交流水 part one~eight,系集群运维 agent 新项目。**证据边界**:该目录不在本 task 的 component/ 路径过滤内,仅见提交标题、未读到代码 hunk。
- **mind-cluster [新能力] 集群调度新增 Atlas 950 SuperPoD Flex 支持**:仅见提交标题,信号文件未落到具体 diff(可能在过滤外目录),未读代码。
- **mind-cluster [Bugfix] npu-exporter 指标空缓存崩溃防护**:`UpdatePrometheus` 从缓存 Load 后由无条件断言改为先判 `ok` 再发指标,缓存未命中时不再对 nil 做 `.(float64)`/`.(int32)` 断言而 panic。证据见下 npu-exporter 节。

## mind-cluster: 38933c22 -> 94600c37
- 比较:https://gitcode.com/Ascend/mind-cluster/compare/38933c22...94600c37 | tag: v26.2.0.beta.1 | commits=32
### AI 总结重点(源码 diff 为据)
- **打分框架位段合约固化**:`score_weights.go` 定义四个维度的位偏移(=各自注册权重):`ScoreOriginalShift=11`(previousNode,bit11/bit12)、`ScoreTopoShift=10`(topology,bit10)、`ScoreHealthShift=8`(subHealth,bit9-8,2 bit)、`ScoreAvailShift=0`(chipCount,bit7-0,8 bit)。合成公式 = Σ(维度段值 << 注册权重) × ScoreWeight;注册顺序 topology→previousNode→subHealth→chipCount 固定,重排会破坏位一致性。段值定义:topology {1 FitNormal, 0 evict-only};previousNode 分层 {2 P1 最近非故障,1 P2 回原节点,0};subHealth {3 健康,2 仅交换机亚健康,1 仅卡亚健康,0 卡+交换机共存};chipCount = (req/free)×255。
  <details><summary>代码依据 component/ascend-for-volcano/common/util/score_weights.go</summary>

  ```diff
  +	ScoreOriginalShift = 11
  +	ScoreTopoShift = 10
  +	ScoreHealthShift = 8
  +	ScoreAvailShift = 0
  ```
  说明(同文件注释):合成 = Σ(段值 << 权重) × ScoreWeight,高位压低位;subHealth `3<<8=0x300` 不溢出到 topo 的 bit10。
  </details>
- **打分入口按策略分流,新旧不等价**:`BatchNodeOrderFn` 判断 `vcJob.policyHandler` 是否 `ScoreFrameworkAware`,是则走 `batchNodeOrderByFramework`,否则保留旧的 `ScoreBestNPUNodes` + `scoreMap *= scoreWeight` 单体路径;权重乘子由包级常量 `scoreWeight` 改成 `sHandle.ScoreWeight` 字段。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/factory.go</summary>

  ```diff
  +	if v, ok := vcJob.policyHandler.(ScoreFrameworkAware); ok && v.ScoreFrameworkAware() {
  +		return sHandle.batchNodeOrderByFramework(task, nodes, vcJob)
  +	}
   	errGet := vcJob.policyHandler.ScoreBestNPUNodes(task, nodes, scoreMap)
   	...
  -		scoreMap[nodeName] *= scoreWeight
  +		scoreMap[nodeName] *= sHandle.ScoreWeight
  ```
  </details>
- **ScoreWeight 成为可运维参数**:`New()` 解析 `ascend.scoreWeight` 参数(ParseFloat 且 >0 才生效,否则回退 `defaultScoreWeight=100`),`HandlerStart()` 初始化 `ScoreWeight: defaultScoreWeight` 并调 `InitScorePlugins()`。含义:集群可通过 volcano-scheduler-configmap 调整昇腾打分的整体缩放,而 ScoreWeight 只做保序正缩放,不改变位段优先级。
  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
  +		ScoreWeight: defaultScoreWeight,
   	scheduleHandler.PolicyBuilder = internal.New
  +	scheduleHandler.InitScorePlugins()
  +	if raw, ok := arguments[ScoreWeightArg]; ok {
  +		if v, err := strconv.ParseFloat(fmt.Sprintf("%v", raw), 64); err == nil && v > 0 {
  +			sHandler.ScoreWeight = v
  +		} else { sHandler.ScoreWeight = defaultScoreWeight }
  +	}
  +	ScoreWeightArg = "ascend.scoreWeight"
  +	defaultScoreWeight = 100
  ```
  </details>
- **重调度快照新增两个只写 0 的打分方法**,并入 `FaultHandler` 接口:`ScorePreviousFaultNodes` 把本 job 历史故障任务落过的节点(读 `getFaultNodeNameByFaultJob` 同一故障快照,识别已恢复节点)在 scoreMap 里写 0;`ScoreSubHealthGrade` 把任意卡/交换机亚健康 FaultNode 原地写 0,健康节点不写、保留维度 predate 默认 1。用途:关闭 prefer-previous-node 时,previousNode 维度退化为 {1,0} 二值,纯重调度器场景也能避开历史故障落点而无需 PrefNodeMap 缓存。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/reschedule.go + plugin/plugin.go</summary>

  ```diff
  +func (reScheduler *ReScheduler) ScorePreviousFaultNodes(task *api.TaskInfo, scoreMap map[string]float64) {
  +	faultNodeNames := reScheduler.getFaultNodeNameByFaultJob(fJob)
  +	for _, faultNodeName := range faultNodeNames {
  +		if _, ok := scoreMap[faultNodeName]; ok { scoreMap[faultNodeName] = 0 }
  +	}
  +}
  +func (reScheduler *ReScheduler) ScoreSubHealthGrade(scoreMap map[string]float64) {
  +	for nodeName := range scoreMap {
  +		fNode, exist := reScheduler.FaultNodes[nodeName]
  +		if !exist || (!fNode.HasCardSubHealthFault && !fNode.HasSwitchSubHealthFault) { continue }
  +		scoreMap[nodeName] = 0
  +	}
  +}
  ```
  接口侧 `plugin.go` 的 `FaultHandler` 同步新增这两个方法签名 + `ScoreFrameworkAware` 判定入 `controller.go`。
  </details>
### 后续发展方向 [AI]
- 昇腾调度打分正从「一个大函数硬编码各因素权重」走向「可插拔维度 + 位段严格优先级 + 可配缩放」的框架,便于后续新增打分维度(如网络亲和、超节点拓扑)而不动主流程;当前只有 chip-affinity 策略切到新框架,其余策略仍走旧路径,说明是**渐进迁移**而非一次性切换。证据只覆盖 ascend-for-volcano 的打分/重调度 diff,未见其他策略何时迁移。
- 故障/亚健康感知被抽成独立打分维度(subHealth、previousNode),配合重调度快照,方向是把「断点续训/进程级在线恢复」的节点规避策略从命令式硬逻辑收进统一打分合成;关闭 prefer-previous-node 后仍保底避开故障落点,利于无缓存的纯重调度部署形态。证据只覆盖打分方法本身,未展开重调度触发链路。
- 新增 ascend-clusterops-agent 与 Atlas 950 SuperPoD Flex 支持是超节点/集群运维方向的信号,但本次未读到代码,方向判断待下期落到具体 diff 再确认。

## vNPU: 9d8a2716 -> d88907ed
- 比较:https://gitcode.com/openFuyao/vNPU/compare/9d8a2716...d88907ed | tag: v0.1.0 | commits=2
### AI 总结重点(源码 diff 为据)
- 纯打包/命名规范化,无功能逻辑改动:`ci/build.sh` 的 IMAGE_MAP、`charts/vnpu/values.yaml`、文档里所有镜像名从下划线(`npu_device_plugin`/`acl_client_update`/`xpu_exporter`)统一改成连字符(`npu-device-plugin`/`acl-client-update`/`xpu-exporter`),消除 chart 默认名与构建产物名不一致导致的手动重命名。
  <details><summary>代码依据 charts/vnpu/values.yaml + ci/build.sh</summary>

  ```diff
  -    name: npu_device_plugin
  +    name: npu-device-plugin
  -    name: xpu_exporter
  +    name: xpu-exporter
  -    ["acl-client"]="acl-client-update.Dockerfile acl_client_update ${CHART_IMAGE_REGISTRY}/acl_client_update 1.0.0"
  +    ["acl-client"]="acl-client-update.Dockerfile acl-client-update ${CHART_IMAGE_REGISTRY}/acl-client-update 1.0.0"
  ```
  </details>
- volcano 部署 yaml 镜像源从 `docker.io/library/vc_*` 占位改指向官方仓 `cr.openfuyao.cn/openfuyao/vnpu/vc-*:${version}`,文档补 `helm pull oci://cr.openfuyao.cn/charts/vnpu` 离线拉取命令。证据:`charts/yaml/volcano-deployment.yaml`、`docs/user-guide.md`。
### 后续发展方向 [AI]
- vNPU 处于把 v0.1.0 发布产物对齐官方镜像仓/规范镜像命名的收尾阶段,尚无虚拟化内核逻辑演进;能力边界仍待后续 device-plugin/xpu-exporter 的代码级改动才能判断。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:本期无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=94600c37549cec594313a636fb31b51395a58759 tag=v26.2.0.beta.1 scanned=2026-09-10 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=vNPU sha=d88907ed4061c5d63babbb79b453a368b55f14d6 tag=v0.1.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f3cfd270f0dda85b259f4041d6c99824920e17e5 tag=v26.6.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=ef44c337d16e208fc1557b8e56a77447f30bc2a7 tag=1.0.2 scanned=2026-09-10 -->
