# 昇腾算力栈 diff 雷达 2026-06-05

## 摘要
- mind-cluster 本期两条主线:① ascend-device-plugin 把**热复位/故障处理改成插件化框架**(新增 PluginManager + builtin 插件 + 令牌桶限频),② infer-operator 给 InstanceSet **加 HPA 弹性扩缩容**(新 CRD 字段 ScalingPolicy/ScalingResourceStatus)。
- vNPU 仅 bump 了 ubs-virt submodule 指针,无自身代码改动;其余 7 个 openFuyao 仓本期无新提交。

## 当日重要改变
- mind-cluster [API/CRD变更] infer-operator 的 InstanceSet 新增 `ScalingPolicy` 入参与 `ScalingResourceStatus` 状态字段,支持声明式挂 HPA。证据 `component/infer-operator/pkg/api/v1/instanceset_types.go`。 https://gitcode.com/Ascend/mind-cluster/blob/a1074aba3b01ca9ced1973e98874801a19991745/component/infer-operator/pkg/api/v1/instanceset_types.go
- mind-cluster [新能力] ascend-device-plugin 新增 `pkg/plugin/builtin/` 插件包 + `PluginManager` 热加载框架,热复位逻辑从硬编码改为可插拔(outbandReset / resetRecord 两个内置插件)。证据 `component/ascend-device-plugin/pkg/plugin/plugin_manager.go`、`pkg/plugin/builtin/`。 https://gitcode.com/Ascend/mind-cluster/blob/a1074aba3b01ca9ced1973e98874801a19991745/component/ascend-device-plugin/pkg/plugin/plugin_manager.go
- mind-cluster [架构方向] 热复位引入**令牌桶限频**(每设备 6 小时补满、上限 3 次),从"无限次复位"收窄为"限频复位",防复位风暴。证据 `component/ascend-device-plugin/pkg/server/token_bucket.go`。 https://gitcode.com/Ascend/mind-cluster/blob/a1074aba3b01ca9ced1973e98874801a19991745/component/ascend-device-plugin/pkg/server/token_bucket.go

## mind-cluster: 4d0dde86 -> a1074aba
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/4d0dde8601e715acc313f913fb0c442f59657171...a1074aba3b01ca9ced1973e98874801a19991745 | tag v26.0.0 | commits=48 | truncated=false(信号已按 component/ 限定)

### AI 总结重点(源码 diff 为据)

- **ascend-device-plugin:热复位/故障处理重构为插件化框架**。新增 `UnifiedHotResetManager` 统一调度热复位,并引入 `PluginManager` 从配置文件 `/usr/local/hotResetPluginConfiguration.json` 用 fsnotify 监听插件开关(`ON`/`OFF`),配置变更后延迟 5 分钟(`configApplyDelay`)再生效。意味着热复位行为可在不重启 DP 的情况下按插件粒度热切换。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/plugin/plugin_manager.go</summary>

  ```diff
  +type PluginConfig struct {
  +	PluginName string `json:"pluginName"`
  +	State      string `json:"state"`
  +}
  +const (
  +	PluginStateOn     = "ON"
  +	PluginStateOff    = "OFF"
  +	configApplyDelay  = 5 * time.Minute
  +	defaultConfigPath = "/usr/local/hotResetPluginConfiguration.json"
  +)
  +type PluginConfigMgr struct {
  +	...
  +	watcher        *fsnotify.Watcher
  +	pendingConfigs []PluginConfig
  +	applyTimer     *time.Timer
  +	onConfigChange func()
  +}
  ```
  </details>

- **令牌桶给热复位限频**。新增 `TokenBucket`:`tokenRefillInterval = 6h`、`tokenMaxCount = 3`,`Consume()` 成功才允许一次复位,桶空(`tokens<=0`)直接拒绝。`TokenBucketMgr` 用 `sync.Map` 按设备维护各自的桶。把热复位从"故障即复位"收窄成"每卡 6 小时最多复位 3 次",防止坏卡反复触发复位拖垮节点。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/token_bucket.go</summary>

  ```diff
  +const (
  +	tokenRefillInterval = 6 * time.Hour
  +	tokenMaxCount       = 3
  +)
  +func (tb *TokenBucket) Consume() bool {
  +	tb.mu.Lock(); defer tb.mu.Unlock()
  +	tb.refill()
  +	if tb.tokens <= 0 { return false }
  +	tb.tokens--
  +	return true
  +}
  ```
  </details>

- **新增带外复位插件 OutBandResetPlugin**,仅对 `Ascend910A3` 卡生效:当常规(带内)`CustomReset` 报错时,走带外通道 `resetDeviceOutBand(LogicID)` 兜底,并轮询整环复位完成(`outBandBootPollTimeout = 150s`)。这是针对 A3 整机/超节点形态的可靠性补强。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/plugin/builtin/outband_reset_plugin.go</summary>

  ```diff
  +func (p *OutBandResetPlugin) CustomReset(_ context.Context, deviceList []plugin.ResetDevice, resetErr error) error {
  +	if resetErr == nil { return nil }
  +	for _, dev := range deviceList {
  +		if dev.CardType != api.Ascend910A3 { return resetErr }   // 非 A3 不接管
  +	}
  +	for _, dev := range deviceList {
  +		if err := p.resetDeviceOutBand(dev.LogicID); err != nil { ... continue }
  +		if err := p.waitRingResetComplete(deviceList); err != nil { ... continue }
  +	}
  ```
  </details>

- **新增 ResetRecordPlugin,把复位过程落成 K8s Event**。复位开始/完成/失败分别发 `HotResetStart`/`HotResetComplete`/`HotResetFailed` Event 到 Node 对象,消息体带 nodeName、环上设备列表、故障 devID、剩余令牌数。等于把热复位做成了可观测、可审计的运维事件流(配合上面的令牌桶,运维能从 Event 看到"还剩几次复位额度")。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/plugin/builtin/reset_record_plugin.go</summary>

  ```diff
  +const (
  +	hotResetStartReason    = "HotResetStart"
  +	hotResetCompleteReason = "HotResetComplete"
  +	hotResetFailedReason   = "HotResetFailed"
  +)
  +func (p *ResetRecordPlugin) PreReset(_ context.Context, deviceList []plugin.ResetDevice) error {
  +	event := &v1.Event{ ...
  +		Message: fmt.Sprintf("hot reset start, nodeName:%s, ringDevs:%s, faultDev:%d, tokensLeft:%d, ...",
  +			p.nodeName, devIDs, getFaultDevID(deviceList), getFaultTokensLeft(deviceList), ...),
  +		Reason:    hotResetStartReason, ...
  +		InvolvedObject: v1.ObjectReference{ Kind: "Node", Name: p.nodeName },
  ```
  </details>

- **infer-operator:InstanceSet 接入 HPA 弹性扩缩容**。Spec 新增 `ScalingPolicy{Type, Spec}`(Type 当前支持 `HPA`),Status 新增 `LabelSelector` 与 `ScalingResourceStatus{Type,Name,Ready,Message}`。新增 `ScalingManager.ReconcileScalingResource`:Policy 为空则清理已建的扩缩容资源,Type=HPA 则 `reconcileHPA` 创建/对账 `autoscaling/v2` 的 HPA,并打 owner label `<prefix>/scaling-owned-by`。即昇腾推理服务从"固定副本"走向"声明式自动弹性"。
  <details><summary>代码依据 component/infer-operator/pkg/api/v1/instanceset_types.go + scaling/scaling_manager.go</summary>

  ```diff
  +type ScalingPolicy struct {
  +	Type string               `json:"type,omitempty"`
  +	Spec runtime.RawExtension `json:"spec,omitempty"`
  +}
   type InstanceSetSpec struct {
  +	ScalingPolicy      *ScalingPolicy       `json:"scalingPolicy,omitempty"`
   }
   type InstanceSetStatus struct {
  +	LabelSelector         string                 `json:"labelSelector,omitempty"`
  +	ScalingResourceStatus *ScalingResourceStatus `json:"scalingResourceStatus,omitempty"`
   }
  +func (m *ScalingManager) ReconcileScalingResource(ctx, instanceSet) (*apiv1.ScalingResourceStatus, error) {
  +	if instanceSet.Spec.ScalingPolicy == nil { return m.cleanupScalingResource(ctx, instanceSet) }
  +	switch instanceSet.Spec.ScalingPolicy.Type {
  +	case common.ScalingPolicyTypeHPA: return m.reconcileHPA(ctx, instanceSet)
  ```
  </details>

- **infer-operator 主对账循环接入扩缩容**。`InstanceSetReconciler` 新增 `ScalingManager` 字段;`Reconcile` 把原来串行的 workload 对账拆成 `workloadErr` 与独立的 `reconcileScalingResources`,扩缩容状态单独写回 `Status.ScalingResourceStatus`。扩缩容失败不再连带 workload 一起 requeue,二者错误路径解耦。
  <details><summary>代码依据 component/infer-operator/pkg/controller/v1/instanceset_controller.go</summary>

  ```diff
  +	autoscalingv2 "k8s.io/api/autoscaling/v2"
  +	"infer-operator/pkg/controller/scaling"
   type InstanceSetReconciler struct {
  +	ScalingManager     *scaling.ScalingManager
   }
  -	err = r.reconcileWorkLoads(ctx, instanceSet)
  +	workloadErr := r.reconcileWorkLoads(ctx, instanceSet)
  +	scalingStatus, scalingErr := r.reconcileScalingResources(ctx, instanceSet)
  +	instanceSet.Status.ScalingResourceStatus = scalingStatus
  ```
  </details>

> 仅见标题、未见 patch(信号文件里只命中其 test 文件或未进前 8 节选),不展开符号级:`npu-exporter 部分指标获取失败时上报 unknown 状态`、`rdma-dp 新增 1825 故障检测及上报`、`inferOperator 自定义资源扩缩容 part0/1`(后者应即上面 HPA 一线)。

### 后续发展方向 [AI]
- 昇腾 DP 的可靠性叙事正在从"被动复位"升级为"插件化 + 限频 + 可观测"的故障自愈框架:令牌桶 + Event 落库 + 带外兜底三件套,指向大规模 910A3 超节点集群里"坏卡自治、运维可审计"。证据覆盖 plugin_manager/token_bucket/outband/reset_record 四个新文件,**未见**配套的 CRD/配置文档与上层调度器(noded/clusterd)如何消费这些 Event,需后续区间确认闭环。
- infer-operator 把弹性扩缩容做成可插拔 Policy(当前只实现 HPA 分支,`default` 直接报 unsupported),架构上预留了非 HPA 策略(如自定义/KEDA 式)扩展位。证据为 `ScalingPolicy.Type` 的 switch 仅 HPA 一个 case + default 报错;**未见**是否计划接 vNPU/NPU 利用率作为扩缩容指标源。

## vNPU: 5dc0751e -> 1c407018
- 比较: https://gitcode.com/openFuyao/vNPU/compare/5dc0751eefdb922d48ee653a10b52c7aa02ddcc6...1c407018907f5a41b9ffba929aa98453ca7798d3 | tag v0.1.0 | commits=2 | truncated=false
- 本期仅把 `third_party/ubs-virt` submodule 指针从 `94c4537a` bump 到 `69b6901e`(PR !53,"Update ubs-virt submodule to master branch"),vNPU 仓自身无代码改动。ubs-virt(UB 超节点虚拟化)的实际变更不在本仓 diff 内,需到 ubs-virt 仓单独看。无符号级结论可写。

## 本期无实质改动(保锚点)
- npu-operator、npu-container-toolkit、npu-driver-installer、npu-node-provision、npu-dra-plugin、volcano-ext、ub-network-device-plugin:无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=a1074aba3b01ca9ced1973e98874801a19991745 tag=v26.0.0 scanned=2026-06-05 -->
<!-- ANCHOR repo=npu-operator sha=83270337c25487948cbf56685561e273730f9bbf tag=1.2.0 scanned=2026-06-05 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-05 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-05 -->
<!-- ANCHOR repo=vNPU sha=1c407018907f5a41b9ffba929aa98453ca7798d3 tag=v0.1.0 scanned=2026-06-05 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-05 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-05 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-05 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-05 -->
