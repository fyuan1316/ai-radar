# 昇腾算力栈 diff 雷达 2026-11-03

## 摘要
- **mind-cluster [调度策略转向]**:昇腾 volcano 调度器把"静默故障节点退避默认值"从 `0`(立即释放/重调度)改成 `600` 秒——未显式标注的作业,静默故障卡现在默认被扣留 10 分钟而非秒级抢回,降低误判抖动导致的频繁重调度。
- **npu-dra-plugin [DRA 修复]**:整卡独占(full)模式不再向 ResourceSlice 发布 `AllowMultipleAllocations`/`Capacity`,修掉"多 Pod/多独立 Claim 时第二个 Claim 永久 pending"的 bug(对齐 upstream kubernetes#133705);硬切分(hard vNPU)模式则显式打开 `AllowMultipleAllocations=true` 走可消耗容量共享。
- 其余 6 仓无实质改动(仅无新提交)。

## 当日重要改变
- **mind-cluster [架构方向]** 静默故障退避默认 0→600 秒:`DefaultSilentUnhealthyToleranceAfterTime` 常量改值,`setSilentUnhealthyTolerance`/`jobSilentUnhealthyTolerance` 两处 fallback 同步改 600。commit `6dac90d63631` https://gitcode.com/Ascend/mind-cluster/commit/6dac90d63631
- **npu-dra-plugin [API/CRD变更]** full 模式清空 DRA 可消耗容量字段(`AllowMultipleAllocations`/`Capacity`),修整卡独占多 Claim pending。PR !42 / commit `c501aa339054` https://gitcode.com/openFuyao/npu-dra-plugin/commit/c501aa339054b

## mind-cluster: 0b37fe1a -> 0a1f9a1e
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/0b37fe1adc52499a6c0b83fa8b1eaa1795827144...0a1f9a1e27d66474618d960fe0a35edfd06f7733 | tag: v26.3.0-beta.1 | commits=4(2 实质 + 2 merge)

### AI 总结重点(源码 diff 为据)
- **静默故障节点退避默认行为反转:0 秒(立即释放)→ 600 秒(扣留 10 分钟)**。`ascend-for-volcano/common/util/constants.go` 把 `DefaultSilentUnhealthyToleranceAfterTime` 从 `0` 改成 `600`,注释也从"silent-fault nodes are released immediately"改成"withheld for 600 seconds unless the job configures the annotation explicitly"。语义:**未带 `huawei.com/silent.unhealthy-tolerance.after-time` 注解的作业**,其所在的静默故障卡以前被秒级释放参与重调度,现在默认被扣留 600s 才释放;显式标注值(0 立即 / -1 永不 / N 秒)优先级不变,-1 仍是永久扣留,正值仍被 `MaxSilentUnhealthyToleranceAfterTime` 上界 clamp。
  <details><summary>代码依据 component/ascend-for-volcano/common/util/constants.go</summary>

  ```diff
  -	// tolerance in seconds: silent-fault nodes are released immediately.
  -	DefaultSilentUnhealthyToleranceAfterTime = 0
  +	// tolerance in seconds: silent-fault cards are withheld for 600 seconds
  +	// unless the job configures the annotation explicitly.
  +	DefaultSilentUnhealthyToleranceAfterTime = 600
  ```
  </details>
- 默认值反转在两处取值 fallback 同步兜底,确保"作业未知/未配注解"路径一致走 600:`plugin/job.go` 的 `setSilentUnhealthyTolerance`(读注解填 `NPUJob.ToleranceConfig`,注释 defaulting 0→600)、`internal/rescheduling/reschedule.go` 的 `jobSilentUnhealthyTolerance`(作业未知时 default 0→600)。两处仅注释改动,实际默认值由上面的常量驱动——说明是全局策略而非局部。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/reschedule.go</summary>

  ```diff
   // jobSilentUnhealthyTolerance returns the silent-fault after-time of the job,
  -// defaulting to 0 when the job is unknown.
  +// defaulting to 600 when the job is unknown.
   func (reScheduler *ReScheduler) jobSilentUnhealthyTolerance(jobID api.JobID) int64 {
  ```
  </details>
- **ascend-docker-runtime 软链接/挂载校验失败日志从"无上下文"升级到"带路径/errno/解析后路径"**。`cli/src/main.c` 的 `CheckFileLegality` 三处失败分支由固定串("filePath has an illegal character!"/"realpath failed!"/"filePath has a soft link!")改为 `FormatLogMessage` 拼出带实际 `filePath`、`errno`、`resolvedPath` 的消息(并 `free`+置 NULL)。定位软链接拦截问题时不再要靠猜。
  <details><summary>代码依据 component/ascend-docker-runtime/cli/src/main.c</summary>

  ```diff
  -        Logger("filePath has a soft link!", LEVEL_ERROR, SCREEN_YES);
  +        char *str = FormatLogMessage("filePath %s has a soft link, resolved path: %s.", filePath, resolvedPath);
  +        Logger(str, LEVEL_ERROR, SCREEN_YES);
  +        free(str); str = NULL;
  ```
  </details>
- **runtime 挂载配置解析的静默 `continue` 改为告警日志**。`hook/process/process.go` 的 `readMountConfig`:取绝对路径失败、`os.Stat` 路径不存在两处原本静默跳过(`continue // skipping files/dirs with any problems`),现在各打一条 `hwlog.RunLog.Warnf`;并新增 else 分支对"既非普通文件也非目录"的挂载项告警。此前挂载项被悄悄丢弃难排查,现在可见。
  <details><summary>代码依据 component/ascend-docker-runtime/hook/process/process.go</summary>

  ```diff
  -			continue // skipping files/dirs with any problems
  +			hwlog.RunLog.Warnf("skip mount entry %s: path not found: %v", hostPath, err)
  +			continue
   ...
  +		} else {
  +			hwlog.RunLog.Warnf("skip mount entry %s: not a regular file or directory", hostPath)
  ```
  </details>

### 后续发展方向 [AI]
- 静默故障退避默认拉到 600s,是昇腾调度在"可用性(快释放故障卡)vs 稳定性(避免误判抖动导致的频繁重调度)"之间向稳定性倾斜一档。延续近两周"第三类亚健康退避"的治理主线——证据只覆盖默认常量 + 两处 fallback 注释,未见 600 这个值是否可通过全局配置覆盖(当前仅按作业注解覆盖)。
- docker-runtime 两处改动均为**可观测性收口**(把静默失败变成带上下文日志),无功能/接口变化;指向昇腾 runtime 在软链接挂载安全校验这块的现场问题定位需求上升。

## npu-dra-plugin: 32fc8e91 -> f0654355
- 比较: https://gitcode.com/openFuyao/npu-dra-plugin/compare/32fc8e917d59a26904b8025f97bf6e3eddeb56d3...f0654355fb65ac3ffca9a41357100a82fde4fc10 | tag: v26.9.0 | commits=2 实质

### AI 总结重点(源码 diff 为据)
- **整卡独占(full)模式修 DRA 多 Claim pending 根因:不再误把独占卡当"可消耗容量"设备**。`internal/profiles/npu/npu.go` 的 `buildDevice` 原本 full/hard 两分支走同一套 `Capacity` 发布;现在 full 分支改调新增的 `applyExclusiveWholeCardReporting(&dev)`,把 `dev.AllowMultipleAllocations=nil`、`dev.Capacity=nil` 清掉——使每张 full-mode `npu-*` 成为纯独占 DRA 设备(one Claim ↔ one chip)。注释直接点名根因:发布了 `AllowMultipleAllocations`/`Capacity` 后调度器按可消耗容量份额处理,**第二个独立 Claim 即便其他 npu 空闲也常卡 "cannot allocate all claims"**,引 kubernetes/kubernetes#133705。
  <details><summary>代码依据 Ascend-npu-dra-plugin/internal/profiles/npu/npu.go</summary>

  ```diff
   	if mode == HardVNPUMode {
  +		// Hard vNPU shares one physical card across multiple Claims via consumable capacity.
  +		dev.AllowMultipleAllocations = ptr.To(true)
   		dev.Capacity = profile.getHardDeviceCapacities(dev)
   	} else {
  +		// Exclusive whole-card: must NOT publish AllowMultipleAllocations / Capacity.
  +		applyExclusiveWholeCardReporting(&dev)
   	}
  +func applyExclusiveWholeCardReporting(dev *resourceapi.Device) {
  +	dev.AllowMultipleAllocations = nil
  +	dev.Capacity = nil
  +}
  ```
  </details>
- **hard vNPU 分支显式打开 `AllowMultipleAllocations=true`**(之前只设 `Capacity`,未显式设该标志)。至此三模式语义被测试钉死:full → `AllowMultipleAllocations==nil` 且 `Capacity` 为空;hard → `AllowMultipleAllocations==true` 且 `Capacity` 非空;soft(elastic)→ `AllowMultipleAllocations==true` 且带 `shareCount` 容量;soft 且 shareCount==1 → 回退 full 语义(两字段清空)。
  <details><summary>代码依据 Ascend-npu-dra-plugin/internal/profiles/npu/scenario_test.go</summary>

  ```diff
   	assert.Equal(t, "full", *d.Attributes["vnpuMode"].StringValue)
  +	// Exclusive whole-card must not publish consumable-capacity fields.
  +	assert.Nil(t, d.AllowMultipleAllocations)
  +	assert.Empty(t, d.Capacity)
  ...
   	assert.Equal(t, "hard", *d.Attributes["vnpuMode"].StringValue)
  +	require.NotNil(t, d.AllowMultipleAllocations)
  +	assert.True(t, *d.AllowMultipleAllocations)
  +	assert.NotEmpty(t, d.Capacity)
  ```
  </details>

### 后续发展方向 [AI]
- 这是昇腾 DRA 从"能跑"到"正确处理独占/共享语义"的收口:`AllowMultipleAllocations` 是 K8s 1.33+ DRA 的 consumable-capacity 新字段,昇腾此前一刀切发布导致独占卡被当共享,本次把"整卡独占"与"硬/软切分共享"在 ResourceSlice 层彻底分开。方向上昇腾 DRA 路径已覆盖 full/hard/soft 三态并与 upstream DRA 语义对齐。证据只覆盖 `buildDevice` 设备发布逻辑 + 测试断言,未见调度器侧(allocator)或 kubelet plugin 侧是否还有残留假设。

## 本期无实质改动(折叠)
<details><summary>6 仓无新提交</summary>

- npu-operator(v26.9.0,无新提交)
- npu-container-toolkit(v26.9.0,无新提交)
- npu-driver-installer(v26.9.0,无新提交)
- vNPU(v26.9.0,无新提交)
- npu-node-provision(v26.6.0,无新提交)
- volcano-ext(v1.9.0,无新提交)
- ub-network-device-plugin(v26.9.0,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=0a1f9a1e27d66474618d960fe0a35edfd06f7733 tag=v26.3.0-beta.1 scanned=2026-11-03 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-03 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-03 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-03 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-11-03 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-03 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f0654355fb65ac3ffca9a41357100a82fde4fc10 tag=v26.9.0 scanned=2026-11-03 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-03 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-11-03 -->
