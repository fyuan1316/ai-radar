# HAMi diff 雷达 2026-07-30

## 摘要
- 主仓 9 实质提交(区间 13 commit),核心是一组**数值安全 + 可观测性契约收敛**:`#2142` 修 `memory_allocated_bytes` 高基数泄漏——`hami_node_gpu_overview` 删掉 `shared_containers` 标签、`device_cores` 从动态 `Usedcores` 改报静态 `Totalcore`,让每 GPU 的时序数量收敛为常量。
- 多个 vendor 设备路径统一做 **int32 溢出/非法值兜底**:enflame 新增 `clampToInt32` + NaN 防护(`#2145`),mthreads 在 `MutateAdmission`/`GenerateResourceRequests` 加 count<=0 与超界拒绝(`#2134`)——软切分的资源请求解析开始系统性防御脏输入。
- 供应链/CI 继续昨天(`#2147`)的收紧:auto-release 从 `write-all` 改逐 job 最小权限(`#2192`)、CodeQL 扩到 PR 触发(`#2193`);其余大量为测试补全(fuzz/route/nvml 覆盖率)。HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI 四仓无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力/观测契约变更] `hami_node_gpu_overview` 删除 `shared_containers` 标签,`device_cores` 语义从"已用核"改为"总核"(静态),修高基数泄漏——依赖该标签或旧语义的 dashboard 会失配 https://github.com/Project-HAMi/HAMi/pull/2142
- Project-HAMi/HAMi [安全/数值] enflame DRS 容量与 drsSlice 解析全面加 int32 clamp + NaN 防护,消除 silent wrap https://github.com/Project-HAMi/HAMi/pull/2145
- Project-HAMi/HAMi [安全/供应链] auto-release workflow 顶层 `write-all` 降为逐 job 声明最小权限(release-image 仅 packages:write+id-token:write 供 keyless cosign) https://github.com/Project-HAMi/HAMi/pull/2192

## Project-HAMi/HAMi: 37730dd7 -> e831337d
- 比较: 37730dd7118970bb032273bb4d171003b2c684a3 -> e831337d | ahead=13 | files=18 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/37730dd7118970bb032273bb4d171003b2c684a3...e831337db299f331b170a46d6ca3dba256b9d6f1

### AI 总结重点(源码 diff 为据)
- **`memory_allocated_bytes`/`gpu_overview` 高基数泄漏修复**(#2142)。`nodeGPUOverview`/`hami_node_gpu_overview` 的标签集删掉了 `shared_containers`(legacy `sharedcontainers`),同时 `device_cores`(legacy `devicecores`)填的值从**动态的 `Usedcores`** 改为**静态的 `Totalcore`**。旧实现里 `device_cores`=已用核、`shared_containers`=`Used`(共享容器数)都随分配实时变化,导致同一 GPU 的时序 label 组合每次 scrape 都变、Prometheus 侧时序无限膨胀。改后每个 GPU 的 overview 时序 label 变成常量(设备总核/总显存/类型),`nodevGPUMemoryAllocated` 也把 `device_cores` 从 `Usedcores` 换 `Totalcore`。这是**指标契约变更**:消费 `shared_containers` 标签或按 `device_cores` 当"已用核"聚合的看板会失配。配套 SKILL.md 文档改注"These label values are static … cores are integers"。
  <details><summary>代码依据 cmd/scheduler/metrics.go</summary>

  ```diff
  	nodeGPUOverview := prometheus.NewDesc(
  		"hami_node_gpu_overview", "GPU overview on a certain node",
  -		[]string{"node", "device_uuid", "device_index", "device_cores", "shared_containers", "device_memory_limit", "device_type"}, nil,
  +		[]string{"node", "device_uuid", "device_index", "device_cores", "device_memory_limit", "device_type"}, nil,
  	)
  ...
  		ch <- prometheus.MustNewConstMetric(nodeGPUOverview, prometheus.GaugeValue,
  			float64(devs.Device.Usedmem)*1024*1024,
  -			nodeID, devs.Device.ID, fmt.Sprint(devs.Device.Index), fmt.Sprint(devs.Device.Usedcores), fmt.Sprint(devs.Device.Used), fmt.Sprint(devs.Device.Totalmem), devs.Device.Type,
  +			nodeID, devs.Device.ID, fmt.Sprint(devs.Device.Index), fmt.Sprint(devs.Device.Totalcore), fmt.Sprint(devs.Device.Totalmem), devs.Device.Type,
  		)
  ```
  </details>
- **enflame 设备解析的 int32 溢出兜底**(#2145)。新增 `clampToInt32(v int) int32`(超 `math.MaxInt32`/`MinInt32` 时钳到边界而非 silent wrap),把 `PatchAnnotations`/`AddResourceUsage` 里 `int32(readCustomInfoInt(...,"drsSlice"))` 与 `parseDRSCapacity` 的 int/int64/string 分支全部换成 clamp;`n.Used += slice` 改成 `n.Used = clampToInt32(int(n.Used)+int(slice))` 防累加溢出;`readCustomInfoInt`/`parseDRSCapacity` 的 float64 分支加 `math.IsNaN` 与越界判空。影响 enflame(燧原)DRS 切分的容量/切片解析,脏 annotation 不再让核数/显存回绕成负值污染调度账本。
  <details><summary>代码依据 pkg/device/enflame/device.go</summary>

  ```diff
  -	slice := int32(readCustomInfoInt(chosen.CustomInfo, "drsSlice"))
  +	slice := clampToInt32(readCustomInfoInt(chosen.CustomInfo, "drsSlice"))
  ...
  -	n.Used += slice
  +	n.Used = clampToInt32(int(n.Used) + int(slice))
  ...
  +func clampToInt32(v int) int32 {
  +	if v > math.MaxInt32 { return math.MaxInt32 }
  +	if v < math.MinInt32 { return math.MinInt32 }
  +	return int32(v)
  +}
  ```
  </details>
- **mthreads 零/负设备数守卫**(#2134)。`MutateAdmission` 现在 Limits 无 count 时回落到 Requests 读取,并在 `count.Value() <= 0` 时直接返错 `"<res> must be greater than 0"`;`GenerateResourceRequests` 在 `n <= 0 || n > math.MaxInt32` 时返回空 `ContainerDeviceRequest{}`。此前零/负 count 会继续走下去生成非法资源请求。影响摩尔线程(mthreads)GPU 的准入变换,把非法请求挡在生成前。
  <details><summary>代码依据 pkg/device/mthreads/device.go</summary>

  ```diff
   	count, ok := ctr.Resources.Limits[corev1.ResourceName(MthreadsResourceCount)]
  +	if !ok {
  +		count, ok = ctr.Resources.Requests[corev1.ResourceName(MthreadsResourceCount)]
  +	}
   	if ok {
  +		if count.Value() <= 0 {
  +			return false, fmt.Errorf("%s must be greater than 0", MthreadsResourceCount)
  +		}
  ...
  +		if n <= 0 || n > math.MaxInt32 {
  +			return device.ContainerDeviceRequest{}
  +		}
  ```
  </details>
- **`fitInDevices` 死代码清理**(#2189,"remove unused variables")。删掉函数里从未被消费的累加器 `total/totalCore/totalMem/free/freeCore/freeMem/sums` 及其在设备循环内的累加——纯清理无行为变更。值得记的是:这是昨天 #2105 修分配污染的同一函数,连续两天在收敛 `fitInDevices` 的数据流(先修共享 `devs` 污染,再删悬空累加器),该热点仍在整理中。
  <details><summary>代码依据 pkg/scheduler/score.go</summary>

  ```diff
   func fitInDevices(...) (bool, string) {
  -	total, totalCore, totalMem := int32(0), int32(0), int32(0)
  -	free, freeCore, freeMem := int32(0), int32(0), int32(0)
  -	sums := 0
   	for index := range node.Devices.DeviceLists { ... }
   	for _, k := range requests {
  -		sums += int(k.Nums)
  ...
  -					total += v.Device.Count
  -					free += v.Device.Count - v.Device.Used
  ```
  </details>
- **CI 供应链继续收紧**(#2192/#2193)。`auto-release.yaml` 顶层 `permissions: write-all` 降为 `read-all`,再按 job 精确声明:`ensure-tag`/`release-notes` 给 `contents:write`,`release-image*` 给 `contents:read+packages:write+id-token:write`(keyless cosign 签名所需),其余只读;并给下游 job 显式补 `needs: ensure-tag`。`codeql-analysis.yml` 新增 `pull_request` 触发(master/dev 分支)。延续昨天 #2147 的按 SHA 钉依赖(stale action v10→v11 也按 digest 更新)。
  <details><summary>代码依据 .github/workflows/auto-release.yaml</summary>

  ```diff
  -permissions: write-all
  +permissions: read-all
  ...
     release-image:
  +    permissions:
  +      contents: read
  +      packages: write
  +      id-token: write
       uses: ./.github/workflows/call-release-image.yaml
  ```
  </details>

### 后续发展方向 [AI]
- 多 vendor 设备路径(enflame/mthreads,叠加昨天 mthreads 的 GenerateResourceRequests)正在做**统一的输入健壮性补课**:int32 clamp、NaN 防护、count<=0 拒绝——软切分把"从 Pod annotation / resource spec 反序列化出的切分参数"当不可信输入处理。证据只覆盖 enflame/mthreads 两处,未见 nvidia/ascend 主路径是否同批加固,可下期盯 `pkg/device/*` 是否扩散同类 clamp。
- 可观测性从"堆标签"转向"控基数":#2142 主动删标签、把动态值换静态值,说明 HAMi 指标已在生产触发 Prometheus 时序膨胀。方向是指标契约会继续瘦身/稳定化——证据只覆盖 metrics.go 的 overview 系列,未见是否会为"已用核/共享容器数"另立低频专用 metric 而非塞进 overview 标签。
- `fitInDevices` 连续两天被动(#2105→#2189),配合本期大批测试补全(fuzz DecodeContainerDevices、predicate/bind route、nvml_devices 覆盖率 ~0→83%),是调度核心路径在补测试债、为后续重构铺垫的信号;证据只覆盖 score.go 的删行与各 *_test.go 存在,未逐一读测试断言。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交</summary>

- Project-HAMi/HAMi-core:无新提交(时分软切分内核本期静默)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交(release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=e831337db299f331b170a46d6ca3dba256b9d6f1 branch=master release=v2.9.0 scanned=2026-07-30 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a branch=main release=— scanned=2026-07-30 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-30 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ed35e1c4b003795de84ba942f6965fa269e866b3 branch=main release=— scanned=2026-07-30 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-30 -->
