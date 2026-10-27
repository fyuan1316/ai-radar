# HAMi diff 雷达 2026-10-28

## 摘要
- HAMi 主仓唯一实质改动落在 **whole-GPU 监控对动态 MIG 的身份解析**:监控计费从"按 Pod 注解里的父卡 GPU UUID 直接判定"改为**先把父卡 UUID 解析成真实 MIG 实例 UUID(校验 profile 名+显存匹配)再计费**,解析不出来的进 `migPending` 重试窗口而非误判,配套给 DCGM collector 补了优雅关停与 MIG 层级缓存的死实例清理——修的是动态 MIG 场景下利用率被错误归属/陈旧 MIG 条目滞留的保真度问题。
- DCGM 运行时底座 bump 4.5.0-1 → 4.7.0-2,core 包名随 NVIDIA 重新打包从 `datacenter-gpu-manager-4-core` 改 `libdcgm`;go-dcgm 1.4701.2 → 1.4702.0。
- 其余 4 仓(HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI)相对上期锚点无新提交。

## 当日重要改变
- 无(无弃用/移除、无 API/CRD 变更、无架构 proposal、无版本跨档、无新增 package;昆仑芯 Kunlunxin 入支持厂商清单仅为 README 文案)

## Project-HAMi/HAMi: 363a4f5b -> 061001d3
- 比较: 363a4f5b2cf83c0de5cef4b67f0ff0117724c6e4 -> 061001d3 | ahead=6 | files=19 | Release: v2.10.0
- 核心提交:`fix(monitor): resolve dynamic MIG identities and watch profiling fields (#3304)` https://github.com/Project-HAMi/HAMi/pull/3304

### AI 总结重点(源码 diff 为据)

- **whole-GPU 监控对动态 MIG 容器改为"先解析 MIG 实例身份再计费"**:`reconcileWholeGPULocked` 原先直接 `evaluateContainerWholeGPU(cand.devices, inputs.nodeDevs, ...)`,其中 `cand.devices` 携带的是父卡 `GPU-...` UUID;现在插入 `resolveDynamicMIGCandidate(cand, inputs.nodeDevs)`,把父卡 UUID 按 `hami.io` 的 MigAllocations 注解替换成真实 `MIG-...` 实例 UUID,并校验该 MIG profile 的名字与显存(`profile.Name==a.Profile && profile.MemoryMB==dev.Usedmem`)和注解一致后才喂给计费。解析未就绪(`ready==false`)的容器不再当场判定,而是登记到新字段 `migPending`。

  <details><summary>代码依据 pkg/monitor/nvidia/wholegpu.go</summary>

  ```diff
  -				verdict, cause := evaluateContainerWholeGPU(cand.devices, inputs.nodeDevs, state.physTotalMiB)
  +				signature := migCandidateSignature(cand)
  +				pending, seen := state.migPending[key]
  +				if seen && pending.signature == signature && now.Sub(pending.firstSeen) > indeterminateRetryWindow {
  +					continue
  +				}
  +				resolved, registry, ready := resolveDynamicMIGCandidate(cand, inputs.nodeDevs)
  +				if !ready {
  +					if !seen || pending.signature != signature {
  +						state.migPending[key] = migPendingRetry{signature: signature, firstSeen: now}
  +					}
  +					continue
  +				}
  +				delete(state.migPending, key)
  +				verdict, cause := evaluateContainerWholeGPU(resolved, registry, state.physTotalMiB)
  ```
  </details>

- **新增 `resolveDynamicMIGCandidate`**:解码失败、MIG UUID 前缀不是 `MIG-`、或 profile 名/显存与父卡注册的 `MIGProfiles` 对不上,一律返回 `ready=false`(保守拒绝);无 MIG 分配且父卡处于 `MigMode` 时也拒绝(说明 MIG 实例尚未物化)。这是把"MIG 运行期身份缺失或不一致"显式建模成可重试状态,而非沉默错算。

  <details><summary>代码依据 pkg/monitor/nvidia/wholegpu.go(新增函数,hunk 截断)</summary>

  ```diff
  +func resolveDynamicMIGCandidate(c wholeGPUCandidate, registry map[string]*device.DeviceInfo) (device.ContainerDevices, map[string]*device.DeviceInfo, bool) {
  +	allocations, err := nv.DecodeMigAllocations(c.pod.Annotations[nv.MigAllocationsAnnotation])
  +	if err != nil {
  +		return nil, nil, false
  +	}
  +	...
  +			if a.GPUUUID != dev.UUID || !strings.HasPrefix(a.MigUUID, "MIG-") {
  +				return nil, nil, false
  +			}
  +			valid := false
  +			for _, profile := range parent.MIGProfiles {
  +				if profile.Name == a.Profile && profile.MemoryMB == dev.Usedmem {
  +					valid = true
  +				}
  +			}
  +			if !valid { return nil, nil, false }
  +			resolved[di].UUID = a.MigUUID
  +type migPendingRetry struct { signature string; firstSeen time.Time }
  +func migCandidateSignature(c wholeGPUCandidate) string {
  +	return c.pod.Annotations[nv.AllocatedDevicesAnnotation] + "\x00" + c.pod.Annotations[nv.MigAllocationsAnnotation]
  +}
  ```
  </details>

- **pending 的粒度用注解签名而非仅 key**:`migCandidateSignature` 把 `AllocatedDevices` + `MigAllocations` 两个注解拼成签名;重调度/重分配(注解变)会让旧 pending 失效重新计时,`prefetchWholeGPUInputs` 也据签名+超时跳过尚未就绪的候选以省掉 registry GET;容器不再 annotated 时清理 `migPending`。即重试窗口按"这次具体的 MIG 分配"计,不会被上一次分配的计时拖住。

  <details><summary>代码依据 pkg/monitor/nvidia/wholegpu.go</summary>

  ```diff
  +			key := string(cand.pod.UID) + "_" + cand.container
  +			if pending, ok := state.migPending[key]; ok && pending.signature == migCandidateSignature(cand) && time.Since(pending.firstSeen) > indeterminateRetryWindow {
  +				continue
  +			}
  ...
  +	for key := range state.migPending {
  +		if !inputs.stillAnnotated[key] {
  +			delete(state.migPending, key)
  +		}
  +	}
  ```
  </details>

- **DCGM collector 补优雅关停 + MIG 层级缓存清死实例**:`dcgmWholeGPUCollector` 新增 `stopCh/doneCh/closed/shutdown` 字段;`ensureInit` 现在接住 `dcgm.Init` 返回的 `shutdown` 句柄;`fieldUpdateLoop` 从裸 `for range tick.C` 改为 `select{case <-c.stopCh:return; case <-tick.C:}` 可被关停;`refreshMigHierarchy` 用 `live` 集合把已消失的 MIG 实例从 `migHierarchy` 缓存里删掉。对应提交标题的 "watch profiling fields"——保证 DCGM 拉取的 PROF 利用率字段跟随动态 MIG 实例的创建/销毁刷新,陈旧 entity 不再滞留。

  <details><summary>代码依据 pkg/monitor/nvidia/wholegpu_dcgm.go</summary>

  ```diff
  +	watched      map[uint]func()
  +	stopCh       chan struct{}
  +	doneCh       chan struct{}
  +	closed       bool
  +	shutdown     func()
  ...
  -	if _, err := dcgm.Init(dcgm.Embedded); err != nil {
  +	shutdown, err := dcgm.Init(dcgm.Embedded)
  +	if err != nil { ... }
  +	c.shutdown = shutdown
  ...
  -	for range tick.C {
  +	for {
  +		select {
  +		case <-c.stopCh:
  +			return
  +		case <-tick.C:
  +		}
  +	live := make(map[uint]bool, len(m))
  +	for _, id := range m { live[id] = true }
  +	for key, id := range c.migHierarchy { /* prune dead */ }
  ```
  </details>

- **dry-run 路径同步**:`RunWholeGPUDryRun` 也走 `resolveDynamicMIGCandidate`,未就绪时产出 `Status:"pending-mig"`、`Message:"MIG runtime identity is missing or inconsistent"` 诊断,行为与在线 reconcile 对齐。

  <details><summary>代码依据 pkg/monitor/nvidia/wholegpu_dryrun.go</summary>

  ```diff
  -		verdict, _ := evaluateContainerWholeGPU(candidate.devices, nodeDevs, nil)
  +		resolved, registry, ready := resolveDynamicMIGCandidate(candidate, nodeDevs)
  +		if !ready {
  +			report.Diagnostics = append(report.Diagnostics, WholeGPUDiagnostic{... Status: "pending-mig", Message: "MIG runtime identity is missing or inconsistent"})
  +			continue
  +		}
  ```
  </details>

- **底座/杂项**:`docker/Dockerfile` 把 DCGM 从 `v4.5.0-1` bump 到 `v4.7.0-2`,core 包名随 NVIDIA 重新打包由 `datacenter-gpu-manager-4-core` 改为 `libdcgm`(libdcgm.so.4 来源包更名),go-dcgm 依赖 1.4701.2→1.4702.0;`SECURITY-INSIGHTS.yml` 登记 OpenSSF Scorecard(供应链检查上 scorecard.dev);README(中/英/日)把"动态 MIG"挪进调度策略正式列表,并在支持厂商里新增昆仑芯 Kunlunxin。均非能力面变化。

  <details><summary>代码依据 docker/Dockerfile</summary>

  ```diff
  -ARG DCGM_DEB=v4.5.0-1
  +ARG DCGM_DEB=v4.7.0-2
  -             core="datacenter-gpu-manager-4-core_${dcgm_ver}_amd64.deb"; core_sha="$DCGM_AMD64_SHA256"; \
  +             core="libdcgm_${dcgm_ver}_amd64.deb"; core_sha="$DCGM_AMD64_SHA256"; \
  ```
  </details>

### 后续发展方向 [AI]
- HAMi 的监控计费正在把"动态 MIG"当成一等公民收口:不再假设 Pod 注解里的 GPU UUID 就是最终可计费设备,而是要求监控侧自己从 MigAllocations 注解还原出 `MIG-` 实例身份并与父卡 registry 的 profile 交叉校验后才计费,未就绪走有界重试。对标我们产品:若做 MIG/vGPU 利用率归属,"调度分配时刻"与"MIG 实例在卡上物化时刻"之间存在竞态窗口,监控若不做身份解析+重试就会把利用率错算到父卡或误判整卡占用。证据覆盖 reconcile/prefetch/dryrun 三处调用点与 `resolveDynamicMIGCandidate` 的校验分支,未覆盖 `indeterminateRetryWindow` 具体时长与 DCGM `watched`/`watchUUIDs` 字段的消费端(hunk 截断)。
- DCGM collector 从"永不关停的裸 ticker"转为带 stopCh/doneCh/shutdown 的可回收生命周期 + MIG 层级缓存按 live 集合清理,说明动态 MIG 的频繁创建销毁已成为监控侧必须处理的常态(陈旧 entity 会污染 PROF 字段)。证据为字段新增与 loop 改写的 hunk,未见 collector 的 Close/关停触发点被谁调用。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 相对上期锚点无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 相对上期锚点无新提交
- Project-HAMi/ascend-device-plugin — 相对上期锚点无新提交
- Project-HAMi/HAMi-WebUI — 相对上期锚点无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=061001d37b8de1d1610bd2b00a951078cfa020b4 branch=master release=v2.10.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=6736b0589049390ec945bd40dfb4769f9f043def branch=main release=— scanned=2026-10-28 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-28 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ab41bec367ca95ac52ed1bcb8667c33e689f8f37 branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-28 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-28 -->
</content>
</invoke>
