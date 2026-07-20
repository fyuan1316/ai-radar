# NVIDIA 算力栈 diff 雷达 2026-07-21

## 摘要
- 本日 8/9 仓无实质改动;唯一有源码改动的 kai-scheduler/KAI-Scheduler(ahead=3)带来一个 **DRA GPU 计数溢出修复**——用户可控的 `ResourceClaim` 超大 `Exactly.Count` 过去会让队列的 int64 GPU 总量累加溢出成负数,进而"低报"队列需求;本期引入 `SaturatingAdd` 饱和加法把 DRA/聚合路径的所有累加钳到 `MaxInt64`。另有一条 agent 友好的 `make changelog` 非交互化工具改动。
- 无 CRD/外部 API 字段增删、无架构或版本跨档信号;命中的 `pkg/scheduler/api/...` 路径是内部资源模型(非 `*_types.go` 外部 CRD),属探测器误报。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [DRA 计数正确性/安全] DRA 路径 GPU 设备计数由裸 `+=` 改为饱和加法,堵住"用户可控 count → int64 溢出为负 → 队列 GPU 需求被低报 → 可能错误准入"的链路。证据 `pkg/common/resources/dra.go`、`pkg/scheduler/api/resource_info/gpu_resource_requirment.go`;PR https://github.com/kai-scheduler/KAI-Scheduler/pull/1874 issue https://github.com/kai-scheduler/KAI-Scheduler/issues/1873

## kai-scheduler/KAI-Scheduler: 7ca4ca72 -> d17b3fbe
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/7ca4ca72b88a2780a6418189e1a5c3bd27d75cb9...d17b3fbe244a2eed41348224c1b230accc85b6ef | ahead=3 | Release: v0.16.4
### AI 总结重点(源码 diff 为据)
- **新增 `pkg/common/math` 包与 `SaturatingAdd(a, b int64) int64`**:一个"依赖极轻"的算术助手(注释明确说不想拉进 k8s / DRA client 包),在两操作数同号且结果符号翻转时把结果钳到 `math.MaxInt64`(正溢出)或 `math.MinInt64`(负溢出),否则原样返回。这是本期所有其它改动的底座。
  <details><summary>代码依据 pkg/common/math/saturating.go(新增)</summary>

  ```diff
  +func SaturatingAdd(a, b int64) int64 {
  +	sum := a + b
  +	// Overflow can only happen when both operands share a sign and the sign of
  +	// the result flips.
  +	if a > 0 && b > 0 && sum < 0 {
  +		return stdmath.MaxInt64
  +	}
  +	if a < 0 && b < 0 && sum >= 0 {
  +		return stdmath.MinInt64
  +	}
  +	return sum
  +}
  ```
  </details>
- **DRA claim 计数从裸 `+=` 切到 `SaturatingAdd`**(`pkg/common/resources/dra.go`):`countGPUDevicesFromClaim` 里对 `request.Exactly.Count` 的累加、以及 `ExtractDRAGPUResourcesFromClaims` 里按 device class 聚合 (`deviceClassCounts[name] += gpuCount`) 全部改用饱和加。新增注释点破根因——`Exactly.Count` 是**用户可控**、apiserver 仅校验 `> 0`,一个超大 count 会在下游配额核算里"回绕成负的 GPU 请求"。
  <details><summary>代码依据 pkg/common/resources/dra.go(modified +10/-4)</summary>

  ```diff
  -			deviceClassCounts[deviceClassName] += gpuCount
  +			deviceClassCounts[deviceClassName] = commonmath.SaturatingAdd(deviceClassCounts[deviceClassName], gpuCount)
  ...
  +// Exactly.Count is user-controlled (the apiserver only enforces > 0), so counts
  +// are summed with SaturatingAdd to keep a very large total from wrapping
  +// into a negative GPU request in downstream quota accounting.
   func countGPUDevicesFromClaim(claim *resourceapi.ResourceClaim) int64 {
  ...
  -				totalCount += request.Exactly.Count
  +				totalCount = commonmath.SaturatingAdd(totalCount, request.Exactly.Count)
  ...
  -			totalCount += 1   // DeviceAllocationModeAll 的保守计 1
  +			totalCount = commonmath.SaturatingAdd(totalCount, 1)
  ```
  </details>
- **资源需求聚合路径同样加固**(`pkg/scheduler/api/resource_info/gpu_resource_requirment.go`):`GpuResourceRequirement.Add`(把多 Pod 汇成队列总量)里对 `draGpuCounts[name]` 的累加、以及 `GetDraGpusCount`(跨 device class 求和)都改用 `SaturatingAdd`,防止"两个 device class 各自已到 int64 上限时求和翻负、污染 `GetGpusQuota`"。附带 3 个新测试(`gpu_dra_overflow_test.go`、`dra_overflow_test.go`、`reclaim_dra_overflow_test.go`)覆盖 MaxInt64 求和不回绕、reclaim action 层的 DRA overflow 场景。
  <details><summary>代码依据 pkg/scheduler/api/resource_info/gpu_resource_requirment.go(modified +3/-2)</summary>

  ```diff
   	for name, ggQuant := range gg.draGpuCounts {
  -		g.draGpuCounts[name] += ggQuant
  +		g.draGpuCounts[name] = commonmath.SaturatingAdd(g.draGpuCounts[name], ggQuant)
  	}
  ...
   func (g *GpuResourceRequirement) GetDraGpusCount() int64 {
   	count := int64(0)
   	for _, singleClaimCount := range g.draGpuCounts {
  -		count += singleClaimCount
  +		count = commonmath.SaturatingAdd(count, singleClaimCount)
   	}
  ```
  </details>
- **工具/流程侧(非调度逻辑)**:`make changelog` 增加 `KIND=/BODY=` 非交互模式,直接写 `.changes/unreleased/<kind>-<ts>.yaml` 供 agent 用,无参时仍走 changie 交互;`AGENTS.md` 同步更新用法。与 GPU 调度能力无关,仅记一笔。
  <details><summary>代码依据 Makefile(modified +13/-2)</summary>

  ```diff
  -changelog: changie ## Add a changelog entry as a fragment (interactive).
  -	$(CHANGIE) new
  +changelog: changie ## Agents: make changelog KIND=Fixed BODY="...". Humans: make changelog (interactive).
  +	@if [ -n "$(KIND)" ] && [ -n "$(BODY)" ]; then \
  +		... printf 'kind: %s\nbody: |-\n  %s\n' "$(KIND)" "$(BODY)" > "$${out}"; \
  +	elif [ -n "$(KIND)" ] || [ -n "$(BODY)" ]; then echo "Both KIND and BODY must be set"; exit 1; \
  +	else $(CHANGIE) new; fi
  ```
  </details>
- 来源提交/PR:https://github.com/kai-scheduler/KAI-Scheduler/pull/1874(DRA overflow 修复)、https://github.com/kai-scheduler/KAI-Scheduler/pull/1940(make changelog 非交互化)
### 后续发展方向 [AI]
- 证据集中在 **DRA 原生路径的配额核算健壮性**:KAI 正把"外部可控输入 → 内部 int64 资源模型"的边界逐个加固(claim 抽取、需求聚合、reclaim action 三层都补了饱和加与测试)。这说明 KAI 的 DRA 支持已从"能算"进入"抗恶意/异常输入"的成熟化阶段——对以 DRA 为 GPU 共享未来主线的路线是正向信号。证据只覆盖计数溢出这一处,未见对 `Exactly.Count` 在准入/校验层(webhook/quota enforcement)做上限拦截,当前策略是"下游钳制"而非"入口拒绝"。
- `SaturatingAdd` 被提取成独立零依赖包,可预期后续 MIG / 整卡 count 等其它累加点也会陆续切过来(本期 `migResources += ggQuant` 仍是裸加,尚未迁移),值得下期跟一眼是否扩面。

## 本期无实质改动(折叠)
- NVIDIA/gpu-operator(ahead=4,仅 bump/CI/merge;Release v26.3.3)
- NVIDIA/nvidia-container-toolkit(无新提交;Release v1.20.0-rc.1)
- NVIDIA/gpu-driver-container(ahead=6,仅 bump/CI/merge)
- NVIDIA/k8s-device-plugin(无新提交;Release v0.19.3)
- kubernetes-sigs/dra-driver-nvidia-gpu(ahead=2,仅 bump/CI/merge;Release v0.4.1)
- NVIDIA/dcgm-exporter(无新提交;Release 4.6.0-4.8.3)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交;Release v0.14.4)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=57752060b8cd83ffa4a54a58b2de093e48f8bb5e branch=main release=v26.3.3 scanned=2026-07-21 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1cddfb0dc179136cd720090f0a13e6ce0de611ed branch=main release=v1.20.0-rc.1 scanned=2026-07-21 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=67e63a775b02587b749867b4f10fd6af56b411f0 branch=main release=— scanned=2026-07-21 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=248164727d5d8bac7024a8e12a13e69246cf0969 branch=main release=v0.19.3 scanned=2026-07-21 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=4d0b3898aa3a1940fa30dd1b16eb242d419be8d1 branch=main release=v0.4.1 scanned=2026-07-21 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-21 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-21 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=567b93739cda8a9d2bad51286171daab25d107f5 branch=main release=v0.14.4 scanned=2026-07-21 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=d17b3fbe244a2eed41348224c1b230accc85b6ef branch=main release=v0.16.4 scanned=2026-07-21 -->
