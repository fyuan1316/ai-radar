# HAMi diff 雷达 2026-10-15

## 摘要
- 仅 HAMi 主仓一条实质提交(#3218):寒武纪 MLU 在 `count > 1` 时按**整卡分配**语义收口——跳过显存/算力校验、分配与配额都按整卡计,软切分(dynamic-smlu)只在 `count == 1` 时生效。属行为明确化而非新能力。
- 其余 4 仓(HAMi-core / volcano-vgpu / ascend-device-plugin / HAMi-WebUI)无新提交。
- 无 API/CRD/proposal 路径命中,无弃用/移除信号。

## 当日重要改变
- 无命中强信号(非 API/CRD 变更,非弃用/架构方向)。本条属 Cambricon 调度语义明确化,归入下方正文。

## Project-HAMi/HAMi: 3cd048cf -> 6d9ab479
- 比较: 3cd048cf603c2441fdfc0768389b55589929cf66 -> 6d9ab479 | ahead=8 | files=14 | Release: v2.10.0
- 实质提交仅 1 条,其余 7 条为 build(deps) 依赖/Action bump。
- 比较页: https://github.com/Project-HAMi/HAMi/compare/3cd048cf603c2441fdfc0768389b55589929cf66...6d9ab479cd090b25270c295eac92ecb554300c8f
- 提交/PR: https://github.com/Project-HAMi/HAMi/commit/6d9ab479cd090b25270c295eac92ecb554300c8f · https://github.com/Project-HAMi/HAMi/pull/3218

### AI 总结重点(源码 diff 为据)
- `GenerateResourceRequests` 对寒武纪容器请求新增 `n > 1` 分支:当申请 MLU 数量大于 1 时,**直接构造整卡请求**(`MemPercentagereq: 100` / `Coresreq: 100`),不再走后面的显存/核校验逻辑。注释点明底层 plugin 对 count>1 本就按整卡发放、忽略 mem/core 值,HAMi 侧与之对齐;但显式声明的显存仍折算进配额(`mem.AsInt64()` × `MemoryFactor` → `req.Memreq`),并带 `MaxInt64/MemoryFactor` 溢出守卫。即:**count>1 不再是软切分路径,而是整卡占用 + 显存仅用于配额计量**。
  <details><summary>代码依据 pkg/device/cambricon/device.go</summary>

  ```diff
   			klog.Info("Found cambricon devices")
  +			if n > 1 {
  +				// The plugin gives a count above 1 whole MLUs and ignores the
  +				// memory and core values, so skip validating them and take the
  +				// whole device. A declared memory still counts toward quota.
  +				req := device.ContainerDeviceRequest{
  +					Nums:             n,
  +					Type:             CambriconMLUDevice,
  +					MemPercentagereq: 100,
  +					Coresreq:         100,
  +				}
  +				mem, ok := ctr.Resources.Limits[mluResourceMem]
  +				if !ok {
  +					mem, ok = ctr.Resources.Requests[mluResourceMem]
  +				}
  +				if memnums, parsed := mem.AsInt64(); ok && parsed && memnums > 0 && memnums <= math.MaxInt64/int64(MemoryFactor) {
  +					req.Memreq = memnums * int64(MemoryFactor)
  +				}
  +				return req, nil
  +			}
  ```
  </details>
- 调度 `Fit` 侧同步收口:当 `originReq > 1` 时把 `memreq` 强制抬到整卡显存 `dev.Totalmem`,保证**分配和配额都按整卡扣减**,避免 count>1 却只按分片显存占配额导致的账本虚低。与上面的请求生成逻辑形成闭环(请求生成 100% + Fit 整卡显存)。
  <details><summary>代码依据 pkg/device/cambricon/device.go</summary>

  ```diff
   			//This incurs an issue
   			memreq = dev.Totalmem * k.MemPercentagereq / 100
   		}
  +		if originReq > 1 {
  +			// The plugin gives a count above 1 whole MLUs, so both the
  +			// allocation and the quota take the whole card.
  +			memreq = dev.Totalmem
  +		}
   		if !fitQuota(pod, tmpDevs, allocated, pod.Namespace, dev.ID, memreq, k.Coresreq) {
  ```
  </details>
- 配套文档:`charts/hami/values.yaml` 与 `README.md` 补齐 `devices.cambricon.resourceCountName/resourceMemoryName/resourceCoreName` 三项注释,明确软切分约束——**显存按 256 MiB 整数单位请求(需 plugin `min-dsmlu-unit=256`),算力按 0-100 整数百分比,分片只支持单卡且 plugin 须 `dynamic-smlu` 模式,count>1 即整卡**;并提示 `device-config.content` / `files/device-config.yaml` 覆盖生成配置时需同步改资源名。README 把原 Cambricon 独立小节删除、改为并入统一参数表。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
     cambricon:
  +    # -- Resource name for the number of MLUs a container requests; it must match the Cambricon device plugin.
  +    # A zero count requests no device; HAMi reads memory and core requests only for a positive count.
  +    # Sharing needs one MLU and the plugin in `dynamic-smlu` mode; a count above 1 allocates whole MLUs and ignores the memory and core values.
       resourceCountName: "cambricon.com/vmlu"
  +    # -- Resource name for MLU memory, requested in integer units of 256 MiB (`20` is 5120 MiB); run the plugin with `min-dsmlu-unit=256`.
       resourceMemoryName: "cambricon.com/mlu.smlu.vmemory"
  +    # -- Resource name for MLU compute, requested as an integer percentage from 0 to 100; omitted requests 100.
       resourceCoreName: "cambricon.com/mlu.smlu.vcore"
  ```
  </details>

### 后续发展方向 [AI]
- 寒武纪路径正在把"软切分(单卡 dynamic-smlu)"与"整卡多卡"两种语义在 HAMi 侧显式分流,消除 count>1 场景下显存/算力校验与配额记账的歧义。这与此前 HAMi 对 AMD/enflame 等厂商做的"整卡数默认值/配额口径归一"是同一条治理线:**各厂商 vXPU 的分片边界与整卡回退规则正逐个被写死进 device driver 层并文档化**。证据只覆盖 cambricon 的 `GenerateResourceRequests`/`Fit` 两处,未见是否对其它厂商(mthreads/hygon 等)同步补 count>1 整卡分支。
- 非软隔离内核层改动(HAMi-core 本期无提交),CUDA hook 能力边界本期无变化。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=6d9ab479cd090b25270c295eac92ecb554300c8f branch=master release=v2.10.0 scanned=2026-10-15 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a55248ecc6e2530602875054e2d334645d08f35b branch=main release=— scanned=2026-10-15 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-15 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=1cf890f96118f38a85f71d31da2e74ca95aeb1a0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-15 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=09f0b75b0773c2caf835933936f0301f7efc248c branch=main release=v1.3.0 scanned=2026-10-15 -->
