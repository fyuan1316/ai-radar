# HAMi diff 雷达 2026-11-22

## 摘要

- **HAMi 调度器开始往"抢占"伸手**:新增 `/preempt` extender verb(新文件 `pkg/scheduler/preempt.go` + `routes.PreemptRoute` + `extenderRouter` 注册),但实现是**原样回传 kube-scheduler 提议的 victim**,不做任何 vGPU 维度的受害者筛选;chart 的 `KubeSchedulerConfiguration` 也**没有加 `preemptVerb`**,所以默认编译进去但不被调用。这是一条先占端点、后补策略的路子。
- **ResourceQuota 口子补上**:新增导出函数 `device.FitPodQuota`,并在 metax / iluvatar / mthreads / kunlun / hygon 五家后端的 `Fit()` 里统一调用。此前"不写显存请求=整卡"的请求会绕过命名空间 ResourceQuota;现在整卡请求也按解析后的实际显存计入配额。**这是会改变现网可调度性的行为变更**(原来能调上的整卡 Pod 可能开始报 `ResourceQuotaNotFit`)。
- **HAMi-core 降低空载开销**:`utilization_watcher` 轮询周期从固定 120ms 改为"按卡上的 core limit 选档"——只有存在 1..99 的限额才用 120ms,其余(含 limit=100 的整卡/满核场景)降到 1s,约 8.3 倍减少唤醒。软隔离的算力限流精度没变,变的是不限流时的 CPU 常态成本。

## 当日重要改变

- `Project-HAMi/HAMi` [新能力] 新增 scheduler extender 抢占端点 `/preempt`,新文件 `pkg/scheduler/preempt.go`(`Scheduler.Preempt` + `preemptionCandidates`)、`pkg/scheduler/routes/route.go` 的 `PreemptRoute`、`cmd/scheduler/main.go` 的 `router.POST("/preempt", ...)`;当前为透传实现,chart 未配置 `preemptVerb`。https://github.com/Project-HAMi/HAMi/commit/52d12401cf83595dd95eb14243abd0ab75ffbd36
- `Project-HAMi/HAMi` [新能力] 新增打分维度与启动参数 `--taint-toleration-score-weight`(`pkg/scheduler/config/config.go` 的 `TaintTolerationScoreWeight`、`pkg/scheduler/policy/node_policy.go` 的 `AddTaintTolerationScore`、chart 值 `scheduler.defaultSchedulerPolicy.taintTolerationScoreWeight`,默认 0 关闭)。https://github.com/Project-HAMi/HAMi/commit/e5eff95e47111c9a2ba7ac83ea792a66cba5b5e9
- `Project-HAMi/HAMi` [行为变更] 整卡(未显式写显存)请求此前不计入命名空间 ResourceQuota,本期在 5 家后端 `Fit()` 中补上配额校验,新增公共实现 `device.FitPodQuota`,并删掉 hygon 私有的 `fitQuota`。https://github.com/Project-HAMi/HAMi/commit/35214b1b2ffdb91385759eff1a07c6f25536e12c
- `Project-HAMi/volcano-vgpu-device-plugin` [新能力] chart 开始正式分发:README 从"尚未发布 Helm 仓库、请 git clone"改为 `helm repo add volcano-vgpu https://project-hami.github.io/volcano-vgpu-device-plugin` 与 `oci://ghcr.io/project-hami/charts/volcano-vgpu-device-plugin`;CI 拆出 `validate-chart` / `oci-release` 两个 job 并做 tag↔Chart.yaml 版本一致性校验。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/0f4769b043662b38afcb2977e8aa44d70ea85b76

## Project-HAMi/HAMi: db50ead6 -> e5eff95e

- 比较: db50ead676875f95db018c00081e68189b5d1e0e -> e5eff95e  | ahead=4 | files=37 | Release: v2.11.0
- 比较链接:https://github.com/Project-HAMi/HAMi/compare/db50ead676875f95db018c00081e68189b5d1e0e...e5eff95e47111c9a2ba7ac83ea792a66cba5b5e9

### AI 总结重点(源码 diff 为据)

- **新增 `/preempt` extender verb,但抢占决策完全不由 HAMi 做。** `Scheduler.Preempt` 把请求里的 `NodeNameToVictims` / `NodeNameToMetaVictims` 合并成 `MetaVictims` 后原样返回(日志字面写 "Returning preemption candidates unchanged"),没有按 vGPU 显存/算力账面去判断"驱逐这些 Pod 后新 Pod 能不能放下",也没有剔除任何候选节点。换句话说:端点已存在,HAMi 的设备账本还没参与抢占。

  <details><summary>代码依据 pkg/scheduler/preempt.go</summary>

  ```diff
  +func (s *Scheduler) Preempt(args extenderv1.ExtenderPreemptionArgs) (*extenderv1.ExtenderPreemptionResult, error) {
  +	if args.Pod == nil {
  +		return nil, errors.New("extender preemption args missing pod")
  +	}
  +	candidates := preemptionCandidates(args)
  +	klog.V(4).InfoS("Returning preemption candidates unchanged",
  +		"pod", klog.KObj(args.Pod), "uid", args.Pod.UID, "candidateNodes", len(candidates))
  +	return &extenderv1.ExtenderPreemptionResult{NodeNameToMetaVictims: candidates}, nil
  +}
  ```
  </details>

- **双形态入参兼容:nodeCacheCapable 与否都能解。** `preemptionCandidates` 同时遍历 `NodeNameToVictims`(非 cache-capable extender 收到的完整 Pod)和 `NodeNameToMetaVictims`(cache-capable 收到的仅 UID),前者把 `pod.UID` 降级成 `MetaPod{UID:}`;两者同时存在时 meta 版本覆盖。HAMi chart 里 `nodeCacheCapable: true`,所以实际走的是后一条。

  <details><summary>代码依据 pkg/scheduler/preempt.go</summary>

  ```diff
  +	for nodeName, victims := range args.NodeNameToVictims {
  +		meta := &extenderv1.MetaVictims{Pods: []*extenderv1.MetaPod{}}
  +		if victims != nil {
  +			meta.NumPDBViolations = victims.NumPDBViolations
  +			for _, pod := range victims.Pods {
  +				if pod != nil {
  +					meta.Pods = append(meta.Pods, &extenderv1.MetaPod{UID: string(pod.UID)})
  +				}
  +			}
  +		}
  +		candidates[nodeName] = meta
  +	}
  +	for nodeName, victims := range args.NodeNameToMetaVictims {
  +		...
  +		candidates[nodeName] = meta
  +	}
  ```
  </details>

- **路由侧与 `/filter`、`/bind` 同规格加固:** `PreemptRoute` 用 `io.LimitReader(r.Body, maxRequestSize)` 限体积(注释点明防深嵌套/资源耗尽)、`Pod == nil` 直接 400、`WaitForCacheSync` 未同步返回 503。并且端点只挂在 `extenderRouter` 上,`clusterRouter` 不提供(测试 `TestClusterRouterDoesNotServeExtenderVerbs` 把 `/preempt` 加进了必须 404 的列表),延续了"集群端口与 extender 端口分离"的既有分层。

  <details><summary>代码依据 pkg/scheduler/routes/route.go + cmd/scheduler/main.go + cmd/scheduler/router_test.go</summary>

  ```diff
  +func PreemptRoute(s *scheduler.Scheduler) httprouter.Handle {
  +	return func(w http.ResponseWriter, r *http.Request, _ httprouter.Params) {
  +		body := io.LimitReader(r.Body, maxRequestSize)
  +		var extenderPreemptionArgs extenderv1.ExtenderPreemptionArgs
  +		if err := json.NewDecoder(body).Decode(&extenderPreemptionArgs); err != nil { ... 400 }
  +		if extenderPreemptionArgs.Pod == nil { ... 400 }
  +		if !s.WaitForCacheSync(r.Context()) { ... 503 }
  +		extenderPreemptionResult, err := s.Preempt(extenderPreemptionArgs)
  ```
  ```diff
   	router.POST("/filter", routes.PredicateRoute(s))
   	router.POST("/bind", routes.Bind(s))
  +	router.POST("/preempt", routes.PreemptRoute(s))
  ```
  ```diff
  -	for _, path := range []string{"/filter", "/bind"} {
  +	for _, path := range []string{"/filter", "/bind", "/preempt"} {
   		router.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, strings.NewReader(undecodableBody)))
   		if rec.Code != http.StatusNotFound {
  ```
  </details>

- **该端点默认不生效:chart 的 extender 配置没有 `preemptVerb`。** HEAD 上 `charts/hami/templates/scheduler/configmap.yaml` 的 `KubeSchedulerConfiguration` 与 legacy Policy 两套分支都只声明 `filterVerb: filter` / `bindVerb: bind`;全仓搜索 `preemptVerb` 只命中 `route.go` 的注释。即默认安装下 kube-scheduler 不会调 `/preempt`,要手改 ConfigMap 才通。

  <details><summary>代码依据 charts/hami/templates/scheduler/configmap.yaml(HEAD 现状,本期未改)</summary>

  ```yaml
        filterVerb: filter
        bindVerb: bind
        nodeCacheCapable: true
        weight: 1
  ```
  ```diff
  +// PreemptRoute serves the preempt verb of the scheduler extender, which
  +// kube-scheduler calls during preemption once preemptVerb is set in the extender configuration.
  ```
  </details>

- **新增第二个"软偏好"打分维度:PreferNoSchedule 污点惩罚。** `applyTaintTolerationScore` 在所有节点打完分之后(`calcScoreWithOptions` 的 `wg.Wait()` 之后)跑一轮,按 kube-scheduler TaintToleration 插件的口径归一化:惩罚 = `weight * (本节点未被容忍的 PreferNoSchedule 污点数 / 候选节点中最大数)`。只统计 `PreferNoSchedule`(NoSchedule/NoExecute 由 kube-scheduler 自己在 Filter 阶段滤掉),容忍度先用 `PreferNoScheduleTolerations` 过滤成"空 effect 或 PreferNoSchedule"两类,每个 Pod 只算一次。污点从 informer 的 node 副本读(`s.currentNode`),注释明说这样 `kubectl taint` 不必等设备握手就生效。

  <details><summary>代码依据 pkg/scheduler/score.go + pkg/scheduler/policy/node_policy.go</summary>

  ```diff
  +func (s *Scheduler) applyTaintTolerationScore(res *policy.NodeScoreList, task *corev1.Pod) {
  +	weight := config.TaintTolerationScoreWeight
  +	if weight == 0 || len(res.NodeList) == 0 {
  +		return
  +	}
  +	tolerations := policy.PreferNoScheduleTolerations(task.Spec.Tolerations)
  +	counts := make([]int, len(res.NodeList))
  +	maxCount := 0
  +	for i, ns := range res.NodeList {
  +		counts[i] = policy.CountIntolerablePreferNoScheduleTaints(s.currentNode(ns.NodeID, ns.Node), tolerations)
  +		maxCount = max(maxCount, counts[i])
  +	}
  +	if maxCount == 0 {
  +		return
  +	}
  +	for i, ns := range res.NodeList {
  +		ns.AddTaintTolerationScore(counts[i], maxCount, res.Policy, weight)
  +	}
  +}
  @@ calcScoreWithOptions
   	wg.Wait()
   	close(errCh)
  +	s.applyTaintTolerationScore(&res, task)
  ```
  ```diff
  +func CountIntolerablePreferNoScheduleTaints(node *corev1.Node, tolerations []corev1.Toleration) int {
  +	for i := range node.Spec.Taints {
  +		taint := &node.Spec.Taints[i]
  +		if taint.Effect != corev1.TaintEffectPreferNoSchedule {
  +			continue
  +		}
  +		if !corev1helpers.TolerationsTolerateTaint(klog.Background(), tolerations, taint, true) {
  +			count++
  +		}
  +	}
  ```
  </details>

- **惩罚在 spread 策略下取负号,这是 HAMi 打分语义的既有坑被显式处理。** `AddTaintTolerationScore` 里,binpack 取最高分、spread 取最低分,所以 spread 时把 penalty 取反才能继续把 Pod 推离污点节点。另外作者刻意"先归一化再乘权重",注释写明是为了避免大权重在 float32 下先溢出。这与上期的 `AddNodeAffinityScore` 共用同一套"软偏好叠加到 GPU 用量分"的模型。

  <details><summary>代码依据 pkg/scheduler/policy/node_policy.go</summary>

  ```diff
  +func (ns *NodeScore) AddTaintTolerationScore(count, maxCount int, policy string, weight float32) {
  +	if count <= 0 || maxCount <= 0 {
  +		return
  +	}
  +	// Normalize first so a large finite weight cannot overflow float32 before the division.
  +	penalty := weight * (float32(count) / float32(maxCount))
  +	if policy == util.NodeSchedulerPolicySpread.String() {
  +		penalty = -penalty
  +	}
  +	ns.Score -= penalty
  ```
  </details>

- **权重校验被抽成公共函数,两个 flag 共用同一条"有限且 >= 0"规则。** `ValidateNodeAffinityScoreWeight` 原本自带 NaN/Inf/负数检查,现在改为委托 `validateScoreWeight(flag, weight)`,新增 `ValidateTaintTolerationScoreWeight` 复用;`cmd/scheduler/scheduler_options.go` 在启动前串联两个校验。chart 侧新值默认 0,文档注明 "Values above `30` let the taint outweigh GPU usage"——即权重量级与 GPU 用量分同轴,>30 就会压过算力账面。

  <details><summary>代码依据 pkg/scheduler/config/config.go + cmd/scheduler/scheduler_options.go + charts/hami/values.yaml</summary>

  ```diff
   func ValidateNodeAffinityScoreWeight(weight float32) error {
  +	return validateScoreWeight("--node-affinity-score-weight", weight)
  +}
  +
  +func ValidateTaintTolerationScoreWeight(weight float32) error {
  +	return validateScoreWeight("--taint-toleration-score-weight", weight)
  +}
  +
  +func validateScoreWeight(flag string, weight float32) error {
   	w := float64(weight)
   	if math.IsNaN(w) || math.IsInf(w, 0) || w < 0 {
  -		return fmt.Errorf("--node-affinity-score-weight must be a finite number >= 0, got %v", weight)
  +		return fmt.Errorf("%s must be a finite number >= 0, got %v", flag, weight)
   	}
  ```
  ```diff
  +	if err := config.ValidateTaintTolerationScoreWeight(config.TaintTolerationScoreWeight); err != nil {
  +		return err
  +	}
  ```
  ```diff
  +    # -- (float) Penalty applied to the node score for `PreferNoSchedule` taints a Pod does not tolerate, scaled by the node's untolerated taint count
  +    # over the highest count among candidate nodes (0..1). `0` disables it. ... Values above `30` let the taint outweigh GPU usage.
  +    taintTolerationScoreWeight: 0
  ```
  </details>

- **配额校验从 hygon 私有实现升级为 `pkg/device` 公共 API。** hygon 里 23 行的私有 `fitQuota` 被删除,等价逻辑搬进 `device.FitPodQuota(pod, allocated, devType, tentative, candidates...)`:拷贝一份 `allocated` 做假设态、把本容器已暂定设备 + 候选设备拼进去、用 `CollapseInitContainerUsage` 折叠 init 容器峰值后求和显存与核数,再问 `GetLocalCache().FitQuota(ns, mem, core, devType)`。注释显式声明不改调用方切片,且 `Usedcores` 按纯数值累加——"把 core 位图塞进 Usedcores 的后端需要自己算",这给异构后端留了口子。

  <details><summary>代码依据 pkg/device/quota.go + pkg/device/hygon/device.go</summary>

  ```diff
  +func FitPodQuota(pod *corev1.Pod, allocated *PodDevices, devType string, tentative ContainerDevices, candidates ...ContainerDevice) bool {
  +	hypo := PodDevices{}
  +	if allocated != nil {
  +		for t, podSingle := range *allocated {
  +			hypo[t] = append(PodSingleDevice{}, podSingle...)
  +		}
  +	}
  +	cur := append(ContainerDevices{}, tentative...)
  +	cur = append(cur, candidates...)
  +	hypo[devType] = append(hypo[devType], cur)
  +	var mem, core int64
  +	for _, ctrDevs := range CollapseInitContainerUsage(pod, hypo)[devType] { ... }
  +	return GetLocalCache().FitQuota(pod.Namespace, mem, core, devType)
  +}
  ```
  ```diff
  -// fitQuota checks the pod's hypothetical usage, including the resolved candidate
  -func fitQuota(pod *corev1.Pod, tmpDevs map[string]device.ContainerDevices, allocated *device.PodDevices, ns string, devUUID string, memreq int64, coresreq int64) bool {
  -	...23 行...
  -}
  @@ (hcu *HCUDevices) Fit
  -		if !fitQuota(pod, tmpDevs, allocated, pod.Namespace, dev.ID, memreq, k.Coresreq) {
  +		if !device.FitPodQuota(pod, allocated, HygonHCUDevice, tmpDevs[HygonHCUDevice], device.ContainerDevice{
  +			UUID: dev.ID, Type: HygonHCUDevice, Usedmem: memreq, Usedcores: k.Coresreq,
  +		}) {
  ```
  </details>

- **四家后端补上同一处漏检,且插入点都在"显存够不够"判断之前。** iluvatar / mthreads 在逐卡循环里按 `memreq`(含 `MemPercentagereq` 百分比解析成的绝对值)先过配额再比卡内余量;kunlun 没有逐卡配额,而是在选完 `tmpDevs` 后整体过一次,并在注释里写明理由:"webhook 在 admission 时查过配额,但命名空间用量在 Pod 被调度前可能变化"——说明这是修 admission 与 scheduling 之间的 TOCTOU 窗口,不只是补一个 if。

  <details><summary>代码依据 pkg/device/iluvatar/device.go + pkg/device/mthreads/device.go + pkg/device/kunlun/vdevice.go</summary>

  ```diff
  @@ (ilu *IluvatarDevices) Fit
   			memreq = dev.Totalmem * k.MemPercentagereq / 100
   		}
  +		if !device.FitPodQuota(pod, allocated, k.Type, tmpDevs[k.Type], device.ContainerDevice{
  +			UUID: dev.ID, Type: k.Type, Usedmem: memreq, Usedcores: k.Coresreq,
  +		}) {
  +			reason[common.ResourceQuotaNotFit]++
  +			continue
  +		}
   		if dev.Totalmem-dev.Usedmem < memreq {
  ```
  ```diff
  @@ (dev *KunlunVDevices) Fit
  +	// The webhook checks the quota at admission, but the namespace's usage can
  +	// change before the pod is scheduled, so check the selected devices again.
  +	if !device.FitPodQuota(pod, allocated, request.Type, tmpDevs[request.Type]) {
  +		reason[common.ResourceQuotaNotFit] += len(tmpDevs[request.Type])
  +		return false, map[string]device.ContainerDevices{}, common.GenReason(reason, len(devices))
  +	}
   	return true, tmpDevs, ""
  ```
  </details>

- **metax sGPU 做了两段校验,并把 Online 类业务的核数从配额里剔除。** 逐卡阶段:`appClass == Online` 时 `quotaCores = 0` 再送去查配额(即在线推理类 sGPU 的算力不计入 core 配额,只计显存);选完整套设备后再整体校验一次,注释说明"每个候选单独合规不等于合在一起合规"。这是本期唯一按业务分类改变配额口径的地方。

  <details><summary>代码依据 pkg/device/metax/sdevice.go</summary>

  ```diff
  +		quotaCores := request.Coresreq
  +		if appClass == Online {
  +			quotaCores = 0
  +		}
  +		if !device.FitPodQuota(pod, allocated, MetaxSGPUDevice, nil, device.ContainerDevice{
  +			UUID: dev.ID, Type: MetaxSGPUDevice, Usedmem: memreq, Usedcores: quotaCores,
  +		}) {
  +			reason[common.ResourceQuotaNotFit]++
  +			continue
  +		}
   		if dev.Totalmem-dev.Usedmem < memreq {
  @@ 选完设备后
  +	// Each candidate fits the quota on its own; the selected set must fit together.
  +	if !device.FitPodQuota(pod, allocated, MetaxSGPUDevice, containerDevices) {
  +		reason[common.ResourceQuotaNotFit] += len(containerDevices)
  +		return false, map[string]device.ContainerDevices{}, common.GenReason(reason, len(devices))
  +	}
  ```
  </details>

- **测试侧确认了"整卡请求"才是修复目标。** 四个新测试文件同名用例 `TestFit_WholeCardRequestRespectsMemoryQuota`,注释统一写"覆盖不设显存的请求:Fit 把它解析为整卡,整卡也必须满足配额";用例对 `limit ∈ {0, 整卡容量}` 两档断言。`TestFitPodQuota` 还专门用 sentinel 元素验证 `FitPodQuota` 不会写穿调用方切片、不改 `allocated`,并覆盖 init 容器峰值复用与 sidecar(`RestartPolicy: Always`)并存两种口径。

  <details><summary>代码依据 pkg/device/mthreads/quota_test.go + pkg/device/quota_test.go</summary>

  ```diff
  +// TestFit_WholeCardRequestRespectsMemoryQuota covers a request that sets no
  +// memory: Fit resolves it to the whole card, which must still fit the quota.
  +	for _, limit := range []int64{0, defaultMemoryPerMthreadsGPU} {
  ```
  ```diff
  +		{name: "app_reuses_init_peak", init: []corev1.Container{{Name: "init"}}, allocated: PodDevices{dev: {{{Usedmem: 8192}}}}, candidate: ContainerDevice{Usedmem: 8192}, want: true},
  +		{name: "sidecar_runs_with_app", init: []corev1.Container{{Name: "sidecar", RestartPolicy: &sidecar}}, allocated: PodDevices{dev: {{{Usedmem: 4096}}}}, candidate: ContainerDevice{Usedmem: 4097}},
  +			// Spare capacity detects appends that write past the caller's slice.
  +			tentative := append(append(ContainerDevices{}, tt.tentative...), ContainerDevice{UUID: "sentinel"})[:len(tt.tentative)]
  +			if tentative[:cap(tentative)][len(tentative)].UUID != "sentinel" {
  +				t.Error("FitPodQuota wrote into the tentative slice")
  ```
  </details>

- 剩余 1 个提交为 CI 依赖 bump(`actions/setup-go` 7.0.0 → 7.1.0,#3503),Release 仍 v2.11.0,未跨档。

### 后续发展方向 [AI]

- **抢占是下一个要补策略的位置。** 当前 `Preempt` 透传、chart 不配 `preemptVerb`,说明这是"先把协议面接上"的一步;要让抢占真正服务 vGPU,必须在这里引入 HAMi 自己的设备账本判断(驱逐哪些 Pod 能腾出足够显存/算力、哪些节点其实腾不出来),否则 kube-scheduler 按 request 维度选出的 victim 和 HAMi 按 `Usedmem/Usedcores` 维度的账面会不一致。证据只覆盖本期 diff 与 HEAD 的 chart 模板,未见任何 proposal 或 victim 筛选代码,也没有 PR 讨论展开。
- **调度器正在从"纯设备打分"补齐成"kube-scheduler 打分语义的子集"。** 本期 taint-toleration 与上期 node-affinity 是同一模式:因为 HAMi 从 Filter 只返回单个节点,kube-scheduler 的原生 score 插件全被旁路,所以这些偏好只能在 HAMi 内部一个个重新实现。按这条线往下,`PodTopologySpread`、`InterPodAffinity` 这类同样被旁路的插件是候选补齐对象。证据只覆盖 `score.go` / `node_policy.go` 两个新增打分函数和两个 flag,未见通用插件框架或配置化打分链的迹象——目前仍是逐个 flag 硬编码。
- **多厂商 vGPU 的配额口径开始需要分业务语义,而且仍不统一。** `device.FitPodQuota` 把"假设态求和 + init 峰值折叠"抽成公共实现是收敛;但同一期里 metax 为 `Online` 类把核数清零、注释又明说"把 core 位图塞进 Usedcores 的后端要自己算"——说明 core 维度在不同厂商后端语义不同,公共函数只统一了显存。往下要么各后端补自己的 core 计数,要么把 `Usedcores` 的语义显式分型。证据只覆盖本期 5 家后端的 `Fit()` 改动,未见 NVIDIA/昇腾后端是否也有同样漏检(本期未改动这两家)。
- **配额补检会带来现网行为变化,需要预期到报错面变宽。** 新增路径一律记 `common.ResourceQuotaNotFit` 并进 `GenReason`,原先"不写显存=整卡"绕过配额的 Pod 现在会调度失败。证据只覆盖 `Fit()` 侧,未见是否同步调整 webhook 的 admission 校验或给出灰度/开关(本期没有任何 feature gate)。

## Project-HAMi/HAMi-core: 6ef40c6e -> 4314e0a7

- 比较: 6ef40c6e481b22057f6ac8fe0fbe54344ff34a6e -> 4314e0a7  | ahead=4 | files=4 | Release: —
- 比较链接:https://github.com/Project-HAMi/HAMi-core/compare/6ef40c6e481b22057f6ac8fe0fbe54344ff34a6e...4314e0a7750eb53dbe865c86abe88b59143390cc
- PR:https://github.com/Project-HAMi/HAMi-core/pull/427

### AI 总结重点(源码 diff 为据)

- **`utilization_watcher` 的轮询周期由编译期常量变为 init 期选择的变量。** 原来循环固定 `nanosleep(&g_wait)`(120ms);现在新增文件级 `static struct timespec watcher_interval`,`init_utilization_watcher` 在建线程前用 `choose_watcher_interval` 填好,循环改睡 `watcher_interval`。注释点明"选择发生在 watcher 线程启动之前",即无运行期竞争、也无法热调。

  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c</summary>

  ```diff
  +/* Chosen at init, before the watcher thread starts. */
  +static struct timespec watcher_interval;
  @@ void* utilization_watcher()
   	while (1){
  -		nanosleep(&g_wait, NULL);
  +		nanosleep(&watcher_interval, NULL);
  ```
  </details>

- **选档规则:只有存在 `1..99` 的 core limit 才需要 120ms,否则 1s。** 新增 `g_idle_wait = {1s, 0}` 与 `choose_watcher_interval(limits, count, out)`:遍历 `cached_sm_limit`,命中 `limits[dev] > 0 && limits[dev] < 100` 立刻取 `g_wait`(120ms)并返回,全不命中取 `g_idle_wait`。注释说明不限流时 watcher 只刷 `sm_util`/`monitorused` 和重试 host pid 查找,"一秒一次足够"。

  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.h + .c</summary>

  ```diff
  +static const struct timespec g_idle_wait = {
  +    .tv_sec = 1,
  +    .tv_nsec = 0,
  +};
  ```
  ```diff
  +static void choose_watcher_interval(const int *limits, unsigned int count, struct timespec *out) {
  +    unsigned int dev;
  +    for (dev = 0; dev < count; dev++) {
  +        if (limits[dev] > 0 && limits[dev] < 100) {
  +            *out = g_wait;
  +            return;
  +        }
  +    }
  +    *out = g_idle_wait;
  +}
  ```
  </details>

- **真正受益的是"满核"场景,而不是"无限额"场景。** `init_utilization_watcher` 里的 `has_limit` 判定是 `cached_sm_limit[dev] > 0 && <= 100`(含 100),所以 limit=100 仍然建线程;而 `choose_watcher_interval` 的条件是 `< 100`,limit=100 落到 1s 档。即:要求整卡算力(gpucore=100)的容器,watcher 线程照旧存在但唤醒频率从 ~8.3 次/秒降到 1 次/秒。线程数量模型没变,变的是每容器常态 CPU 占用。

  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c(HEAD 全文,本期在此函数插入)</summary>

  ```c
      int has_limit = 0;
      for (unsigned int dev = 0; dev < device_count && dev < CUDA_DEVICE_MAX_COUNT; dev++) {
          cached_sm_limit[dev] = get_current_device_sm_limit(dev);
          if (cached_sm_limit[dev] > 0 && cached_sm_limit[dev] <= 100) {
              has_limit = 1;
          }
      }
      pthread_t tid;
      if (has_limit) {
  ```
  ```diff
       if (has_limit) {
  +        choose_watcher_interval(cached_sm_limit,
  +                                device_count < CUDA_DEVICE_MAX_COUNT ? device_count : CUDA_DEVICE_MAX_COUNT,
  +                                &watcher_interval);
  +        LOG_INFO("utilization watcher polls every %d ms",
  +                 (int)(watcher_interval.tv_sec * 1000 + watcher_interval.tv_nsec / 1000000));
           pthread_create(&tid, NULL, utilization_watcher, NULL);
       }
  ```
  </details>

- **可观测性细节:周期日志只在真的建了线程时打。** `LOG_INFO("utilization watcher polls every %d ms", ...)` 放在 `if (has_limit)` 块内(提交 `642d433` 标题即 "log interval only when started"),避免在没有限额、不启 watcher 的容器里误报一条"在轮询"的日志。排障时这条日志可直接确认容器落在哪一档。

  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c</summary>

  ```diff
       if (has_limit) {
  +        choose_watcher_interval(...);
  +        LOG_INFO("utilization watcher polls every %d ms",
  +                 (int)(watcher_interval.tv_sec * 1000 + watcher_interval.tv_nsec / 1000000));
           pthread_create(&tid, NULL, utilization_watcher, NULL);
  ```
  </details>

- **新增 GPU-free 单测,把边界条件钉死。** `test/test_utilization_watcher_interval.c` 直接 `#include` watcher 的 `.c` 以触达 static 函数、stub 掉共享内存区,因此 CI 无需 GPU;断言覆盖 `limit=1`/`99` 走 120ms,`limit=0`/`100`/`-1`/`101` 与 `count=0` 走 1s,并额外断言"超出 count 的设备被忽略"。CMake 侧把该 target 并入既有 `test_sm_limiter_step` 的"含源文件编译 + 链 pthread"分支,超时 10s。

  <details><summary>代码依据 test/test_utilization_watcher_interval.c + test/CMakeLists.txt</summary>

  ```diff
  +    check(polls_every(unlimited, 4, &g_idle_wait), "limit 100 on every device: 1 s");
  +    check(polls_every(unset, 2, &g_idle_wait), "limit 0: 1 s");
  +    check(polls_every(one_limited, 4, &g_wait), "one device at 50: 120 ms");
  +    check(polls_every(lowest, 1, &g_wait), "limit 1: 120 ms");
  +    check(polls_every(highest, 1, &g_wait), "limit 99: 120 ms");
  +    check(polls_every(out_of_range, 2, &g_idle_wait), "limits outside 1..99 do not need the limiter: 1 s");
  +    check(polls_every(one_limited, 2, &g_idle_wait), "devices past count are ignored: 1 s");
  ```
  ```diff
  -    elseif (TEST_TARGET_NAME STREQUAL "test_sm_limiter_step")
  +    elseif (TEST_TARGET_NAME STREQUAL "test_sm_limiter_step"
  +            OR TEST_TARGET_NAME STREQUAL "test_utilization_watcher_interval")
  ```
  </details>

### 后续发展方向 [AI]

- **软切分的"常态开销"开始被当作正经指标治理。** 这次改动不碰隔离精度,纯粹砍掉不需要限流时的唤醒频率——与前几期"把 `sm_limit`/`util_switch` 在 init 期缓存"是同一条线:把 hook 内的热路径和冷路径分开,冷路径尽量不花 CPU。往下可做的是把 1s 这档也变成按需(例如完全无 limit 时干脆不建线程,或 limit=100 时不建),但本期没有动 `has_limit` 的判定。证据只覆盖本期 4 个文件,未见任何配置项或环境变量把周期暴露给用户。
- **测试策略值得注意:用 `#include .c` + stub 共享内存换来 GPU-free 覆盖。** 这是 HAMi-core 这类 CUDA hook 代码能在 CI 里被单测覆盖的现实路径,`test_sm_limiter_step` 之后又多一例,说明维护者在系统性扩大"无卡可测"的面。证据只覆盖 CMakeLists 里这两个 target 的分支合并,未统计全仓 GPU-free 测试比例。

## Project-HAMi/volcano-vgpu-device-plugin: ad7518bf -> 5357e807

- 比较: ad7518bf612f8e5ba09fd9bca56761793324b8f7 -> 5357e807  | ahead=5 | files=3 | Release: volcano-vgpu-device-plugin-1.13.0
- 比较链接:https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/ad7518bf612f8e5ba09fd9bca56761793324b8f7...5357e807398dcf2aae6d82a9bffa3bfaef7f701f

> 本期无生产代码改动(仅 CI workflow + README + 一个校验 workflow 的测试),但分发方式和运维约束发生实质变化,故仍写正文。

### AI 总结重点(源码 diff 为据)

- **chart 分发从"自己 clone"升级为两条正式渠道。** README 的 Install 段把 `git clone ... && helm install deployments/helm/...` 替换为 gh-pages Helm 仓库(`helm repo add volcano-vgpu https://project-hami.github.io/volcano-vgpu-device-plugin`)与 GHCR OCI(`oci://ghcr.io/project-hami/charts/volcano-vgpu-device-plugin`),均锁 `--version 1.13.0`。这是 HAMi×Volcano 集成路径第一次具备可被上游/下游直接依赖的发布物。

  <details><summary>代码依据 README.md</summary>

  ```diff
  -No Helm repository is published yet, so install from a checkout:
  +Install chart version 1.13.0 from the Helm repository:
  -git clone https://github.com/Project-HAMi/volcano-vgpu-device-plugin
  -cd volcano-vgpu-device-plugin
  -helm install volcano-vgpu-device-plugin deployments/helm/volcano-vgpu-device-plugin
  +helm repo add volcano-vgpu https://project-hami.github.io/volcano-vgpu-device-plugin
  +helm repo update
  +helm install volcano-vgpu-device-plugin volcano-vgpu/volcano-vgpu-device-plugin --version 1.13.0
  +The same chart is also available through GHCR OCI:
  +helm install volcano-vgpu-device-plugin \
  +  oci://ghcr.io/project-hami/charts/volcano-vgpu-device-plugin --version 1.13.0
  ```
  </details>

- **发布流水线拆成三段并加版本一致性闸门。** 新增 `validate-chart` job:用 `helm show chart` 取 Chart.yaml 的 version,空值直接失败,且当触发源是 tag 时强制 `GITHUB_REF_NAME == "v${chart_version}"`,版本通过 job output 向下传;`helm-release`(gh-pages,`contents: write`)与新 `oci-release`(GHCR,`packages: write` + `contents: read`)拆成两个 job,各自只拿必要权限——原来是一个 job 同时握两种写权限。

  <details><summary>代码依据 .github/workflows/helm-release.yml</summary>

  ```diff
  +  validate-chart:
  +    outputs:
  +      version: ${{ steps.version.outputs.version }}
  +          chart_version="$(helm show chart deployments/helm/volcano-vgpu-device-plugin | awk '$1 == "version:" { print $2; exit }')"
  +          if [[ -z "${chart_version}" ]]; then exit 1; fi
  +          if [[ "${GITHUB_REF_TYPE}" == "tag" && "${GITHUB_REF_NAME}" != "v${chart_version}" ]]; then
  +            echo "Tag ${GITHUB_REF_NAME} does not match chart version ${chart_version}" >&2
  +            exit 1
  +          fi
     helm-release:
  +    needs: [validate-chart]
       permissions:
  -      contents: write   # create GitHub Releases & push to gh-pages
  -      packages: write   # push OCI chart to GHCR
  +      contents: write # create GitHub Releases & push to gh-pages
  +  oci-release:
  +    needs: [validate-chart]
  +    permissions:
  +      contents: read
  +      packages: write
  ```
  </details>

- **OCI 推送从"盲推"改为"先探测是否已存在,且只接受明确的 not-found 才继续"。** 旧逻辑直接 `grep '^version:' Chart.yaml` 再 `helm push`;新逻辑先 `helm show chart oci://...` 探测,已存在就跳过(幂等重跑),不存在时**必须**匹配三类已知错误(`...: not found`、`manifest unknown`/`MANIFEST_UNKNOWN`、`<manifest_url>: 404 Not Found`)才继续推,否则把错误原文打出来并失败——避免把网络/鉴权故障误当作"包不存在"而重复发布。同时 tag 做 `${CHART_VERSION//+/_}`(OCI tag 不允许 `+`)、临时目录从 `/tmp` 改 `${RUNNER_TEMP}`。

  <details><summary>代码依据 .github/workflows/helm-release.yml</summary>

  ```diff
  -          REPO_LOWER=$(echo "$GITHUB_REPOSITORY_OWNER" | tr '[:upper:]' '[:lower:]')
  -          CHART_VERSION=$(grep '^version:' deployments/helm/volcano-vgpu-device-plugin/Chart.yaml | awk '{print $2}')
  +          namespace="${GITHUB_REPOSITORY_OWNER,,}"
  +          chart_ref="oci://ghcr.io/${namespace}/charts/volcano-vgpu-device-plugin"
  +          registry_tag="${CHART_VERSION//+/_}"
  +          if helm show chart "${chart_ref}" --version "${CHART_VERSION}" >/dev/null 2>"${lookup_error}"; then
  +            echo "${chart_ref}:${CHART_VERSION} already exists; skipping GHCR push"
  +            exit 0
  +          fi
  +          if ! grep -Fq "${chart_ref#oci://}:${registry_tag}: not found" "${lookup_error}" &&
  +             ! grep -Eqi 'manifest unknown|MANIFEST_UNKNOWN' "${lookup_error}" &&
  +             ! grep -Fq "${manifest_url}: 404 Not Found" "${lookup_error}"; then
  +            echo "Failed to query ${chart_ref}:${CHART_VERSION}" >&2
  +            exit 1
  +          fi
  +concurrency:
  +  group: helm-release
  +  queue: max
  +  cancel-in-progress: false
  ```
  </details>

- **README 记入一条真实的运维坑:Volcano 侧 vGPU 注册靠 `sync.Once`,热加载不够。** 新增步骤要求改完 `volcano-scheduler-configmap` 后 `rollout restart volcano-scheduler` 并等 rollout 完成,再 `kubectl annotate nodes --all volcano.sh/vgpu-resync=$(date +%s) --overwrite` 强制一次 node update 事件,让 scheduler 重新把 `volcano.sh/node-vgpu-register` 注解同步进缓存;文中明确"只靠热加载会漏掉 `deviceshare` 的 `sync.Once` vGPU 注册",其他 Volcano 组件无需重启。配套新增"分配后怎么验"段:查 `volcano.sh/(devices-to-allocate|vgpu-ids-new|vgpu-node)` 三个注解,并给出缺注解时 kubelet 的确切报错 `UnexpectedAdmissionError: ... cannot get valid pod`。

  <details><summary>代码依据 README.md</summary>

  ```diff
  +After updating `volcano-scheduler-configmap`, restart `volcano-scheduler`, wait
  +for the rollout to finish, and trigger a node annotation update before creating
  +vGPU workloads (relying on hot reload alone can leave `deviceshare`'s
  +`sync.Once` vGPU registration skipped, ...):
  +kubectl rollout restart deployment/volcano-scheduler -n volcano-system
  +kubectl rollout status deployment/volcano-scheduler -n volcano-system
  +kubectl annotate nodes --all volcano.sh/vgpu-resync="$(date +%s)" --overwrite
  +kubectl get pod <pod> -o yaml | grep -E \
  +  'volcano.sh/(devices-to-allocate|vgpu-ids-new|vgpu-node)'
  +with `UnexpectedAdmissionError: Allocate failed due to rpc error: code =
  +Unknown desc = cannot get valid pod`; recreate it after the `volcano-scheduler`
  +restart and node annotation step.
  ```
  </details>

- **兼容矩阵收紧:v1.13.0 的 Volcano 下限从 v1.15.0 提到 v1.15.1。** 单行表格修改,`v1.12.0 and below` 一行保持 "v1.15.0 and below" 不变——即 v1.15.0 现在落在"两边都不推荐"的位置。diff 未附理由。

  <details><summary>代码依据 README.md</summary>

  ```diff
   | volcano-vgpu | Volcano |
   |---|---|
  -| v1.13.0 | v1.15.0 and above |
  +| v1.13.0 | v1.15.1 and above |
   | v1.12.0 and below | v1.15.0 and below |
  ```
  </details>

- **新增 277 行 Go 测试去校验 workflow 自身。** `tests/helmrelease/helm_release_test.go` 把 `helm-release.yml` 当 YAML 解析成 `releaseWorkflow{Jobs, Concurrency}`,用 `dependsOn` 做 job 依赖图的可达性遍历,断言 concurrency 组/queue/cancel 设置与各步骤归属。即发布流水线的结构约束被当作代码来测。(hunk 截断,未覆盖全部断言)

  <details><summary>代码依据 tests/helmrelease/helm_release_test.go</summary>

  ```diff
  +type releaseWorkflow struct {
  +	Jobs        map[string]releaseJob `json:"jobs"`
  +	Concurrency struct {
  +		Group            string `json:"group"`
  +		Queue            string `json:"queue"`
  +		CancelInProgress bool   `json:"cancel-in-progress"`
  +	} `json:"concurrency"`
  +}
  +func dependsOn(workflow releaseWorkflow, job, dependency string) bool {
  ```
  </details>

### 后续发展方向 [AI]

- **这条集成路径正在做"可被别人依赖"的准备。** 正式 Helm 仓库 + GHCR OCI + tag↔Chart.yaml 强一致 + 幂等推送,整套是发布工程成熟度的信号,对把 volcano-vgpu 作为产品组件引入的一方意味着可以钉版本依赖而不再 vendor 源码。证据只覆盖 workflow 与 README,未验证仓库是否真的已有 gh-pages index 与 GHCR 包(本期 diff 不含发布产物)。
- **Volcano 侧 vGPU 注册的 `sync.Once` 是真实架构弱点,但本期只在文档里绕过。** 需要"重启 scheduler + 强制 node annotate"两步人工操作才能让配置生效,这对自动化交付是个硬伤:任何 GitOps 流程都得额外编排这两步。修法应该在 Volcano `deviceshare` 插件侧(让 vGPU 注册可重入),不在本仓。证据只覆盖 README 文本与报错串,未读 Volcano `deviceshare` 源码确认 `sync.Once` 的具体位置。
- **Volcano 下限提到 v1.15.1 但无理由说明,属于需要跟的隐性依赖。** 若后续出现 v1.15.0 上的功能性问题报告,应回到此处对照。证据只有一行表格 diff,本期无 code 变更可指向具体不兼容点。

## 本期无实质改动(折叠)

<details><summary>EMPTY repos</summary>

- `Project-HAMi/ascend-device-plugin`:无新提交(仍 9325759b / ascend-device-plugin-0.2.2),连续多期静默
- `Project-HAMi/HAMi-WebUI`:无新提交(仍 19a0f955 / v1.3.0),连续多期静默
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=e5eff95e47111c9a2ba7ac83ea792a66cba5b5e9 branch=master release=v2.11.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=4314e0a7750eb53dbe865c86abe88b59143390cc branch=main release=— scanned=2026-11-22 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5357e807398dcf2aae6d82a9bffa3bfaef7f701f branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=19a0f955a652ba7f7e4af5a9315686829e884328 branch=main release=v1.3.0 scanned=2026-11-22 -->
