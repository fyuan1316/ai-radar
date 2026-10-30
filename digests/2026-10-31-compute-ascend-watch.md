# 昇腾算力栈 diff 雷达 2026-10-31

## 摘要
- 当日唯一动的仓是 `Ascend/mind-cluster`,改动全集中在 `component/ascend-for-volcano`(Volcano NPU 调度插件),主线是**故障调度(fault scheduling)健壮性修复**:给 NPUHandler/chipX-nodeY 策略补上"静默故障(silent-fault)退避",把 `cache.SessionElapsed` 取不到时间的分支从静默吞错统一改成"告警 + fail-open",并修了物理故障 pod 无 Terminated 时间会报错中断重调度的 bug。
- 另一条独立线在 `component/ascend-faultdiag`(诊断工具,不在本 task PATHPREFIX 内但属昇腾栈):新增 BMC 错误码 `0x2800004B`、BMC 日志硬件信息正则扩到支持 `npu3`/`chip1` 多芯片解析,clear_cache 从"只删磁盘缓存"升级为"同时重建进程内 DiagCtx 并关闭旧上下文"。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)全部无新提交,保锚点。无 API/CRD 字段增删、无新顶层 package。

## 当日重要改变(命中信号才列;无则写"无")
- mind-cluster [新能力/故障容忍] ascend-for-volcano 的 `NPUHandler.removeBackoffCards` 新增"静默故障卡退避"分支,补上此前只有 chip 级 handler 有、node 级 NPUHandler 漏掉的能力(修 chipX-nodeY 策略无法退避)。证据 `component/ascend-for-volcano/internal/npu/base/node.go`,提交 9a3cb7befc。https://gitcode.com/Ascend/mind-cluster/commit/9a3cb7befc
- mind-cluster [行为变更] external-force-pod-failed 重调度原因不再记入 job-reschedule-reason configmap 的条件,从"仅 single-pod 重调度"放宽为"只要是 external-force-pod-failed 就跳过记录",覆盖推理任务。证据 `internal/rescheduling/reschedule.go` + 同步改的 4 个单测断言。https://gitcode.com/Ascend/mind-cluster/commit/3079efa35f

## mind-cluster: 7a5f2e25 -> cc1014b1
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/7a5f2e25e5afaeeed2eb669a6ffdb9dd9c1d62d3...cc1014b15844519ff9dfb85ff2f88372b1d30b57 | tag: v26.3.0-beta.1 | commits=8 | truncated=false

### AI 总结重点(源码 diff 为据)

- **`NPUHandler.removeBackoffCards` 新增静默故障(silent-fault)退避分支**。此前该函数只退避两类卡:本 job pod-error 容忍窗内的报错卡 + 节点级亚健康(sub-healthy)卡;本次新增第三类——当 job 的静默故障容忍窗未释放时(`!tp.silentToleranceAllows()`),把 `node.ChipTopo.SilentFaultChips()` 也并入 `backoffTop`。配套新增 `NPUHandler.silentToleranceAllows()` 方法(逻辑镜像 `subHealthyToleranceAllows`,读 `ToleranceConfig.SilentUnhealthyToleranceAfterTime`)。这是修"NPUHandler 没适配静默故障退避导致 chipX-nodeY 策略无法退避"——chip 级 handler 早有 `silentToleranceAllows`,node 级 NPUHandler 此前缺这块。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/base/node.go</summary>

  ```diff
  +	if !tp.silentToleranceAllows() {
  +		for id := range node.ChipTopo.SilentFaultChips() {
  +			backoffTop = append(backoffTop, id)
  +		}
  +	}
   	if len(backoffTop) == 0 {
   		return nodeTop
   	}
  ...
  +// silentToleranceAllows reports whether the job's silent-fault tolerance has
  +// released the silent-fault resources (true) or they are still withheld (false).
  +func (tp *NPUHandler) silentToleranceAllows() bool {
  +	if tp == nil || tp.NPUJob == nil {
  +		return true
  +	}
  +	elapsed, ok := cache.SessionElapsed(tp.Name)
  +	if !ok {
  +		klog.V(util.LogWarningLev).Infof("%s cannot get job %s elapsed time", tp.GetPluginName(), tp.Name)
  +		return true
  +	}
  +	return util.TimeGateAllows(tp.NPUJob.ToleranceConfig.SilentUnhealthyToleranceAfterTime, elapsed)
  +}
  ```
  </details>

- **`cache.SessionElapsed` 取不到会话时长时从"静默吞错按零值继续"统一改为"打 WARNING + fail-open 返回安全值"**,涉及 5 处容忍/退避判定:`node.go` 的 `silentToleranceAllows`/`subHealthyToleranceAllows`、`chip.go` 的两个同名方法、`reschedule.go` 的 `subHealthyBackoffWithinWindow`、`job.go` 的 `rejectSuperPodNodeWithBackoffCards`。前者原来是 `elapsed, _ := ...` 直接用可能为 0 的 elapsed 去过 TimeGate(elapsed=0 会被判成"窗口还没过/资源仍withheld",可能误退避);现在 `ok==false` 时容忍类方法直接 `return true`(视作容忍已放行、不退避),super-pod 的拒绝逻辑 `return nil`(不拒绝节点)。方向是"拿不到可信 elapsed 就不惩罚节点"。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/chip.go(其余 4 处同型)</summary>

  ```diff
  -	elapsed, _ := cache.SessionElapsed(tp.Name)
  +	elapsed, ok := cache.SessionElapsed(tp.Name)
  +	if !ok {
  +		klog.V(util.LogWarningLev).Infof("%s cannot get job %s elapsed time", tp.GetPluginName(), tp.Name)
  +		return true
  +	}
   	return util.TimeGateAllows(tp.NPUJob.ToleranceConfig.SubHealthyToleranceAfterTime, elapsed)
  ```
  </details>
  <details><summary>代码依据 component/ascend-for-volcano/plugin/job.go(super-pod 拒绝路径 fail-open)</summary>

  ```diff
  -	elapsed, _ := cache.SessionElapsed(sJob.Name)
  +	elapsed, ok := cache.SessionElapsed(sJob.Name)
  +	if !ok {
  +		klog.V(util.LogWarningLev).Infof("SchedulerJob cannot get job %s elapsed time", sJob.Name)
  +		return nil
  +	}
   	if !util.TimeGateAllows(sJob.ToleranceConfig.SilentUnhealthyToleranceAfterTime, elapsed) &&
  ```
  </details>

- **external-force-pod-failed 场景跳过记录重调度原因的条件被放宽**。原 `skipRecordReason` 要求 `ReScheduleKey == JobExternalForcePodFailedReschedulingPrefix` **且** `IsJobSingleRescheduling(&schedulerJob)` 同时成立才跳过;现在只要 `ReScheduleKey == JobExternalForcePodFailedReschedulingPrefix` 就跳过,不再区分 pod 级/job 级。效果:推理任务被外力强杀 pod 触发的重调度,其原因一律不写进 job-reschedule-reason configmap(避免把外力行为污染成 job 的故障历史)。4 处单测断言同步从"应记录"翻转为"应跳过记录"(含"未开启 pod-rescheduling"和"升级到 job 级重调度"两种此前会记录的场景)。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/reschedule.go</summary>

  ```diff
  -	// skip recording reschedule reason when pod-level rescheduling is external-force-pod-failed
  -	skipRecordReason := restartFaultJob.ReScheduleKey == JobExternalForcePodFailedReschedulingPrefix &&
  -		restartFaultJob.IsJobSingleRescheduling(&schedulerJob)
  +	// skip recording reschedule reason when fault-scheduling is external-force-pod-failed
  +	skipRecordReason := restartFaultJob.ReScheduleKey == JobExternalForcePodFailedReschedulingPrefix
  ```
  </details>

- **`getPodFailedTime` 对"pod 无 Terminated 时间"的处理从报错中断改为按当前时刻兜底**。原来 `latest == 0` 时返回 `error("pod ... has no Terminated time")`,会打断故障时间计算 → 重调度卡住;现在改成打 WARNING("may physic fault")并返回 `time.Now().Unix()`。意图是物理故障(节点硬下线、pod 根本没走到 Terminated 状态)时也能拿到一个失败时刻让重调度继续推进。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/job.go</summary>

  ```diff
   	if latest == 0 {
  -		return 0, fmt.Errorf("pod %v has no Terminated time", task.Name)
  +		klog.V(util.LogWarningLev).Infof("pod %v has no Terminated time, may physic fault", task.Name)
  +		return time.Now().Unix(), nil
   	}
   	return latest, nil
  ```
  </details>

- **(PATHPREFIX 外,一并记录)`component/ascend-faultdiag` 诊断工具三处改动**,提交 daa6637542「[Bug][FD]add 0x2800004B and modify clear_cache」:
  - `bmc_err_code_config.py`:新增 BMC 错误码 `0x2800004B` 的 `BmcErrCodeEvent`(patch 在该文件处截断,仅见构造器签名重排,新增条目本身未落在节选窗口,依据取自提交标题 + 文件命中)。
  - `bmc_err_code_analyzer.py`:BMC 日志硬件信息解析正则捕获组从 `npu/npu1/npu2 + chip` 扩到额外支持 `npu3` 与 `chip1`,即适配更多芯片位的 BMC 错误定位。
  - `cli_model.py` 的 `ClearCacheCliModel.run_task`:清缓存从"仅 rmtree 磁盘缓存目录 + 删加密连接配置"升级为先 `convert_log_path` 规整路径再删,并**额外重建进程内诊断上下文**(新建 `DiagCtx` 赋给所有 cli_model、`old_diag_ctx.close()`),堵住"磁盘清了但进程内旧缓存仍干扰下一次诊断"的洞。
  <details><summary>代码依据 component/ascend-faultdiag/.../cli_module/cli_model.py</summary>

  ```diff
  +		# 清理进程中的缓存
  +		old_diag_ctx = self.diag_ctx
  +		new_diag_ctx = DiagCtx()
  +		for cli_model in self.cli_ctx.cli_model_map.values():
  +			cli_model.diag_ctx = new_diag_ctx
  +		old_diag_ctx.close()
   		return "清理完成"
  ```
  </details>

### 后续发展方向 [AI]
- ascend-for-volcano 的"三态故障容忍"模型(pod-error / sub-healthy / silent-fault)正在被补齐到所有调度策略层级:本次把 silent-fault 从 chip 级补到 node 级 NPUHandler,下一步大概率是把同样的退避逻辑统一进 super-pod 路径(本期 super-pod 只改了 fail-open,未见 silent-fault 退避并入)。证据只覆盖 node.go/chip.go/job.go 三个文件的 silent/sub-healthy 分支,未见 `ToleranceConfig` 结构体定义或新增容忍类型。
- 重调度可观测性在做"信噪分离":external-force-pod-failed(外力,非硬件故障)的原因一律不入 configmap,说明 job-reschedule-reason 正被收敛成"真·硬件/静默故障"的记录。证据仅 reschedule.go 一处条件 + 单测,未见 configmap schema 变化。
- `getPodFailedTime` 用 `time.Now()` 兜底物理故障是补丁式修复(用调度器时钟替代缺失的 pod 终止时间),可能在容忍窗计算上引入偏差;后续若要精确,需引入节点健康事件时间戳作为失败时刻来源——本期未见此类改动。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓本期无新提交</summary>

- npu-operator(tag v26.9.0,无新提交)
- npu-container-toolkit(tag v26.9.0,无新提交)
- npu-driver-installer(tag v26.9.0,无新提交)
- vNPU(tag v26.9.0,无新提交)
- npu-node-provision(tag v26.6.0,无新提交)
- npu-dra-plugin(tag v26.9.0,无新提交)
- volcano-ext(tag v1.9.0,无新提交)
- ub-network-device-plugin(tag v26.9.0,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=cc1014b15844519ff9dfb85ff2f88372b1d30b57 tag=v26.3.0-beta.1 scanned=2026-10-31 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-10-31 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-10-31 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-10-31 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-10-31 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-31 -->
<!-- ANCHOR repo=npu-dra-plugin sha=32fc8e917d59a26904b8025f97bf6e3eddeb56d3 tag=v26.9.0 scanned=2026-10-31 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-31 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-10-31 -->
