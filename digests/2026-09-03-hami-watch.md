# HAMi diff 雷达 2026-09-03

## 摘要
- **HAMi 主仓把 NVIDIA MIG 的放置引擎整体换掉**:从"按 profile 名前缀偏好高位槽"的一次性贪心,升级为**区域(regions)打分 + 回溯搜索(backtracking,预算 4096 候选)+ 整容器联合规划**——同一容器的多个 MIG 切片现在在一张卡上一起排布,排不下才拒绝,并把选中的 profile/placement 缓存进 CustomInfo 供落账复用(#2855)。
- **NUMA refit 的配额校验补上容器位置维度**:refit 在改注解前按原始注解布局(区分 init/app 容器索引)重算配额,`onUpdatePod` 纳入 allocLock,堵住 refit 从"init 用量释放前的陈旧快照"提交的时序 bug(#2836)。
- 其余 4 仓(HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI)本期均无新提交。

## 当日重要改变
- Project-HAMi/HAMi [架构方向] MIG 放置从贪心启发式重写为区域打分+回溯搜索引擎(新增 `migLayout`/`migRegion`/`migPlacementScore` 类型,删除旧 `preferHighMigPlacement`/`orderedMigPlacements`),调度侧决策语义整体改变。证据见下 `pkg/device/nvidia/mig_topology.go`。裸 URL:https://github.com/Project-HAMi/HAMi/pull/2855
- Project-HAMi/HAMi [调度正确性] NUMA refit 配额校验修复 init/app 容器计账混淆 + `onUpdatePod` 上锁修复时序竞态。证据见下 `pkg/scheduler/numa_refit_handler.go`、`scheduler.go`。裸 URL:https://github.com/Project-HAMi/HAMi/pull/2836
- 注:无 `*_types.go`/`config/crd`/`docs/proposals` 路径命中,无 CRD/flag 删除,故非硬信号;上两条为 diff 研判判定的方向级改动。

## Project-HAMi/HAMi: e6932f52 -> 95530c6a
- 比较: https://github.com/Project-HAMi/HAMi/compare/e6932f52b16d3358ef9ac47cd63b73bdbda04714...95530c6ad09c4f3cf8651cfe53a89eda69238a85 | ahead=9 | files=18 | Release: v2.10.0(未跨档)

### AI 总结重点(源码 diff 为据)

- **MIG 放置引擎重写:旧"profile 名前缀偏好"贪心被删,换成"卡分区 + 逐候选打分"**。旧代码 `preferHighMigPlacement` 只看 profile 名是不是 `1g.`/`3g.` 开头来决定从高位还是低位槽排;新代码引入 `migLayout`(每请求从设备插件上报的 profile 表推导一次卡几何),把卡按中点切成两个 `migRegion` 半区,并用 `migPlacementScore{emptyRegions, zoneMismatch, edgeDistance, start}` 四级比较器 `betterMigPlacement` 排候选:优先保留空半区、匹配"保留区(reserved)"归属、向边缘紧凑打包。中点若被非整卡 placement 跨越则退化为单区 first-fit,避免在未知 placement 表上误排。
  <details><summary>代码依据 pkg/device/nvidia/mig_topology.go</summary>

  ```diff
  -func preferHighMigPlacement(profile string) bool {
  -	return strings.HasPrefix(profile, "1g.") || strings.HasPrefix(profile, "3g.")
  -}
  -func orderedMigPlacements(profile string, placements []device.MigPlacement) []device.MigPlacement {
  -	ordered := append([]device.MigPlacement(nil), placements...)
  -	sort.SliceStable(ordered, func(i, j int) bool {
  -		if preferHighMigPlacement(profile) {
  -			return ordered[i].Start > ordered[j].Start
  +// migRegions splits the card into two halves. ... If any placement other than
  +// the full-card one straddles the midpoint, the whole card is a single region
  +// and scoring degrades to first-fit rather than misplacing on an unknown table.
  +func migRegions(profiles []device.MigProfile, sliceCount int) []migRegion { ... }
  +// migPlacementScore ranks one candidate placement; fields are compared in order.
  +type migPlacementScore struct {
  +	emptyRegions int
  +	zoneMismatch int
  +	edgeDistance uint32
  +	start        uint32
  +}
  ```
  </details>

- **新增回溯搜索 `migLayout.place`,替换旧 `canPlaceMigProfiles` 里的朴素回溯,并加装可行性预筛 `fits` 与搜索预算 `migSearchBudget=4096`**。贪心(pickiest-first、best-score-first)成功即用贪心结果;贪心因"先填错半区"失败时,才对同一批 ranked 候选做回溯;每层对未放置请求先跑 `fits`(总占用槽超过空闲槽、或某 placement 表被请求次数多于其空闲 placement 数,则一次性拒绝),把"一串相同请求排不下"从每种排列各拒一次收敛为拒一次。预算耗尽即拒,注释称受支持的 placement 表上穷举远够不到该上限。
  <details><summary>代码依据 pkg/device/nvidia/mig_topology.go</summary>

  ```diff
  +const migSearchBudget = 4096
  +func (l migLayout) fits(occupied []device.MigPlacement, requested []device.MigProfile) bool {
  +	needed := 0
  +	for _, profile := range requested { needed += int(migProfileFootprint(profile)) }
  +	if needed > l.freeSliceCount(occupied) { return false }
  +	... // 每个 placement 表:demand > len(freeMigPlacements) 即拒
  +}
  +func (l migLayout) place(occupied []device.MigPlacement, requested []device.MigProfile) ([]device.MigPlacement, bool) {
  +	budget := migSearchBudget
  +	var search func() bool
  +	search = func() bool {
  +		... if !l.fits(used, remaining) { return false }
  +		idx := nextMigRequest(used, requested, placed)
  +		for _, candidate := range l.rank(used, requested[idx]) {
  +			if budget == 0 { break }
  +			budget--; used = append(used, candidate); result[idx] = candidate
  +			if search() { return true }
  +			used = used[:len(used)-1]
  ```
  </details>

- **调度侧改为"整容器多切片联合规划",而非逐切片顺序分配**。`CustomFilterRule` 在 MIG 模式下先把该容器已排队 + 本次请求的显存需求汇总,调 `planMigAllocations`(每个需求映射到"能覆盖它的最小 profile",再 `placeMigProfiles` 一起排),整体排得下才放行;排不下才退回可能"升配到更大 profile"的旧顺序路径。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
   func (dev *NvidiaGPUDevices) CustomFilterRule(...) bool {
   	if devusage.Mode == MigMode {
   		occupied := occupiedMigPlacements(devusage.MigAllocationsInUse)
  +		// Plan every slice of this container on this card together; reject only when no layout exists.
  +		memories := queuedMigMemories(toAllocate, devusage.ID)
  +		memories = append(memories, request.Memreq)
  +		if _, _, ok := planMigAllocations(devusage.MigProfiles, occupied, memories); ok {
  +			return true
  +		}
  +		// Fall back to the sequential path, which may upgrade a request to a larger profile.
  ```
  </details>

- **规划结果经 CustomInfo 传递到落账,并在 `AddResourceUsage` 落账前重新校验合法性**。`recordMigPlans` 在 `Fit` 的每个成功分支把联合规划出的 profile 名/placement 写进各 tentative 切片的 `CustomInfo[MigProfileCustomInfo/MigPlacementCustomInfo]`(无联合方案则删除陈旧计划);`AddResourceUsage` 先用 `plannedMigAllocation` 读回并校验(profile 仍存在、显存够、placement 仍在合法表内且不冲突),失败才回退 `selectMigCandidate`。即"规划期决定的确切布局被忠实提交",避免 filter 与 add 两阶段各自贪心得到不一致结果。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
   func (dev *NvidiaGPUDevices) AddResourceUsage(...) error {
   	if n.Mode == MigMode {
  -		profile, placement, ok := selectMigCandidate(n.MigProfiles, occupiedMigPlacements(n.MigAllocationsInUse), ctr.Usedmem)
  +		occupied := occupiedMigPlacements(n.MigAllocationsInUse)
  +		profile, placement, ok := plannedMigAllocation(n.MigProfiles, occupied, ctr)
  +		if !ok {
  +			profile, placement, ok = selectMigCandidate(n.MigProfiles, occupied, ctr.Usedmem)
  +		}
  +// Fit 的三个成功返回分支各加一行:
  +		recordMigPlans(devices, tmpDevs[k.Type])
  ```
  </details>

- **NUMA refit 配额校验补齐容器位置维度,修 init/app 容器计账混淆**。`RefitNumaAllocation` 在改注解/缓存前,先把新分配放回原始注解布局(`refitted[req.ContainerIndex] = newDevices`),用新增的 `effectivePodDeviceUsage`(init 用量已释放走 `SteadyStateDeviceUsage`,否则走 `CollapseInitContainerUsage`)重算该命名空间的显存/算力配额并 `FitQuota`,超限则 `failWithQuotaRestore`。原因:受限 fit 只 seed 非空非目标分配,丢了区分 init 与 app 用量所需的容器索引。
  <details><summary>代码依据 pkg/scheduler/numa_refit_handler.go</summary>

  ```diff
  +	refitted := append(device.PodSingleDevice{}, allocatedSingle...)
  +	refitted[req.ContainerIndex] = newDevices
  +	hypothetical := make(device.PodDevices, len(allocated))
  +	maps.Copy(hypothetical, allocated)
  +	hypothetical[req.DeviceType] = refitted
  +	for _, ctrDevs := range effectivePodDeviceUsage(pod, hypothetical, pi.InitContainerResourceReleased)[req.DeviceType] { ... }
  +	if !s.quotaManager.FitQuota(pod.Namespace, quotaMem, resourceNames.MemoryFactor, quotaCores, req.DeviceType) {
  +		return failWithQuotaRestore("refit would exceed the %s resource quota in namespace %s", ...)
  +	}
  +func effectivePodDeviceUsage(pod *corev1.Pod, raw device.PodDevices, initReleased bool) device.PodDevices {
  +	if initReleased { return device.SteadyStateDeviceUsage(pod, raw) }
  +	return device.CollapseInitContainerUsage(pod, raw)
  +}
  ```
  </details>

- **`onUpdatePod` 纳入 allocLock,堵 refit 读到陈旧快照的竞态**。allocLock 语义从"只串行化 Filter 与 refit"扩展到"再加上释放 init 容器用量的 pod 更新",使 refit 读取"释放标志/设备/配额"这一致快照时,不会在本 handler 记录稳态用量后从释放前的旧快照提交。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
   func (s *Scheduler) onUpdatePod(oldObj, newObj any) {
  +	// Keep the normal update and the one-time init-usage transition in the same
  +	// critical section so a refit cannot commit from a stale pre-release snapshot ...
  +	s.allocLock.Lock()
  +	defer s.allocLock.Unlock()
  ```
  </details>

- **admission webhook 增加 device-scoring-weights 校验(纵深防御)**。`webhook.Handle` 对申请 HAMi 资源的 Pod 在准入期调 `GetDeviceScoringWeightsByPod`,注解非法直接 `admission.Denied`;调度器保留同一校验作为准入不可用时的兜底。文档 `scheduler-policy.md` 同步说明。
  <details><summary>代码依据 pkg/scheduler/webhook.go</summary>

  ```diff
  +	if hasResource {
  +		if _, err := util.GetDeviceScoringWeightsByPod(pod); err != nil {
  +			klog.Warningf(template+" - Denying admission: %v", ...)
  +			return admission.Denied(err.Error())
  +		}
  +	}
  ```
  </details>

- **其余**:`fix(dashboard): use native node labels for host panels`(#2852)把主机面板 PromQL 从 `hami_host_gpu_memory_used_bytes and on (device_uuid) hami_gpu_memory_limit_bytes{node=~"$node"}` 简化为 `hami_host_gpu_memory_used_bytes{node=~"$node"}`(利用率面板同改),去掉按 device_uuid 的 join、直接用 node 标签过滤——修此前 host 指标缺 limit 序列时面板空白。另 `test(scheduler): add Go benchmarks for the Filter scoring path`(#2907,新增 `score_bench_test.go`)与 mig/webhook/numa 测试扩充,及 CodeQL action pin bump。

### 后续发展方向 [AI]
- MIG 调度从"名字启发式 + 逐切片"彻底转向"几何感知的联合规划引擎":新引擎显式建模卡的槽位几何(regions/reserved zone/edge 打包)并带回溯与预算上限,意味着 HAMi 对多实例 MIG 混排、碎片化控制、以及"整容器一次排布"有了产品级能力底座。证据覆盖 mig_topology.go 全量 hunk 与 device.go 的 filter/plan/record/add 四处接入;未见对应 CRD/注解面向用户的新配置项,`migSearchBudget=4096` 为硬编码常量、暂不可调。
- 调度正确性投入集中在"配额与用量计账的时序一致性"(refit 的 init/app 区分 + onUpdatePod 上锁 + 准入期前置校验),延续 8 月底以来对 NUMA refit / 断点续训场景计账竞态的收口。证据只到本次两处锁与一处配额重算 hunk,未逐一验证 SteadyStateDeviceUsage/CollapseInitContainerUsage 的既有实现。
- 全部改动落在 NVIDIA MIG(硬切分)与调度器计账层,**未触及 HAMi-core 的 CUDA hook 软切分(时分/显存拦截)**;本期无 vNPU/昇腾侧变化。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi-core:无新提交(HEAD 仍 f01e9f23,无 release tag)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 cbded47b)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92,release ascend-device-plugin-0.1.0)
- Project-HAMi/HAMi-WebUI:无新提交(HEAD 仍 f6ae9160,release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=95530c6ad09c4f3cf8651cfe53a89eda69238a85 branch=master release=v2.10.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-03 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-03 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=f6ae916068e6a8e026343ec7679fd96643472e7c branch=main release=v1.3.0 scanned=2026-09-03 -->
</content>
</invoke>
