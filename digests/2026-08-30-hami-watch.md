# HAMi diff 雷达 2026-08-30

## 摘要
- HAMi-WebUI 发 v1.3.0(minor 跨档 v1.2.0→v1.3.0),核心是**算力利用率口径的一次全面纠偏**:NVIDIA 容器算力从"复杂 sum/count_over_time + 卡级 util 回填"改为 `avg(avg_over_time[1m])` 单查询并**明确禁用卡级回填**(多容器共卡时物理卡活跃度无法归因到单容器);概览页也删掉了"除以集群 hami_core_size"的错误归一(设备越多显示值越缩水)。
- 架构方向定调:新 proposal 宣布**砍掉 NestJS 运行时**,Chart 1.x 内用"静态文件+反向代理 Gateway"替代,单 Go 镜像推迟到 Chart 2.0.0;并**正式废弃多集群方向**,回归"单集群、只读"定位。
- 昇腾设备信息解析连修两处 index 越界 panic(`fetchContainerInfo` 与 `DecodePodDevices`),按容器索引对齐、预分配切片、空段兜底。

## 当日重要改变
- Project-HAMi/HAMi-WebUI [架构方向] 新增 `docs/proposals/web-entry-and-embedding.md`:NestJS 运行时将被最小化 static-file+reverse-proxy Gateway 取代,废弃多集群、锁定单集群只读,认证划为部署边界外置。 https://github.com/Project-HAMi/HAMi-WebUI/blob/566bb06f/docs/proposals/web-entry-and-embedding.md
- Project-HAMi/HAMi-WebUI [版本跨档] Release v1.2.0 → v1.3.0(minor),并落地 fail-closed 的原子化"Verified Stable Release"发布控制器,替换旧 tag 触发的 chart workflow。 https://github.com/Project-HAMi/HAMi-WebUI/releases/tag/v1.3.0

## Project-HAMi/HAMi-WebUI: 03121b80 -> 566bb06f
- 比较: 03121b80 -> 566bb06f | ahead=52 | files=75 | Release: v1.3.0
- https://github.com/Project-HAMi/HAMi-WebUI/compare/03121b8056cd2a608d6a9418a2c6593ab91763f2...566bb06f

### AI 总结重点(源码 diff 为据)

- **NVIDIA 容器算力查询彻底简化**:`taskCoreUsed` 里 NVIDIA 分支从原来带注释残留的 `sum_over_time(...[1m]) == 0 or (sum_over_time(...[10m:]) / count_over_time((...!=0)[10m:]))` 拼接,收敛为单独函数 `nvidiaTaskCoreUsedQuery` 返回 `avg(avg_over_time(<selector>[1m]))`;且新增"无数据即报错"语义——NVIDIA 查询命中空结果时返回 `errNoMetricData` 而非静默 0。
  <details><summary>代码依据 server/internal/exporter/exporter.go</summary>

  ```diff
  -		queryTemplate := fmt.Sprintf("hami_container_device_utilization_ratio{device_uuid=\"%s\", ...}", ...)
  -		query = fmt.Sprintf("sum_over_time(%s[1m]) == 0 or (sum_over_time(%s[10m:]) / count_over_time(( %s !=0)[10m:])) ", queryTemplate, queryTemplate, queryTemplate)
  +		query = nvidiaTaskCoreUsedQuery(deviceUUID, namespace, pod, container)
  ...
  -	return s.queryInstantVal(ctx, query)
  +	val, present, err := s.queryInstantValWithPresence(ctx, query)
  +	if err != nil { return 0, err }
  +	if !present && provider == biz.NvidiaGPUDevice { return 0, errNoMetricData }
  +	return val, nil
  +}
  +func nvidiaTaskCoreUsedQuery(deviceUUID, namespace, pod, container string) string {
  +	selector := fmt.Sprintf("hami_container_device_utilization_ratio{device_uuid=\"%s\", ...}", ...)
  +	return fmt.Sprintf("avg(avg_over_time(%s[1m]))", selector)
  ```
  </details>

- **算力换算逻辑抽出 `containerCoreMetrics` 并对 NVIDIA 关掉卡级回填**:原来所有 provider 共用一段 switch,且末尾有"当 `cardCoreUtil > 95` 时用整卡利用率覆盖 used/util"的回填。重构后 NVIDIA 走独立分支:活跃度 clamp 到 0–100、NaN/Inf 直接返 `errNoMetricData`、`used = min(100, activity*allocatedCore/100)`,**且提前 return 不进入卡级回填**;注释点明"多工作负载共卡时物理卡活跃度无法归因到单容器"。Cambricon/Hygon/Metax 保留旧回填。另 `allocatedCore <= 0` 返回 `errInvalidCoreCapacity`。
  <details><summary>代码依据 server/internal/exporter/exporter.go</summary>

  ```diff
  +	case biz.NvidiaGPUDevice:
  +		rawActivity := float64(taskCoreUsed)
  +		if math.IsNaN(rawActivity) || math.IsInf(rawActivity, 0) { return 0, 0, errNoMetricData }
  +		activity := math.Max(0, math.Min(100, rawActivity))
  +		used = roundToTwoDecimal(math.Min(100, activity*float64(allocatedCore)/100))
  +		util = roundToOneDecimal(activity)
  +		return used, util, nil   // NVIDIA 提前返回,不进入下方卡级回填
  ...
  +	// Keep the legacy fallback ... It must not be used for NVIDIA ...
  +	cardCoreUtil, err := s.deviceCoreUtil(ctx, provider, deviceUUID)
  +	if err == nil && used != 0 && cardCoreUtil > 95 {
  +		used = float64(cardCoreUtil) / 100 * float64(allocatedCore)
  +		util = float64(cardCoreUtil)
  +	}
  ```
  </details>

- **`monitorService` 字段从具体类型改为 `instantQuerier` 接口**:仅暴露 `QueryInstant`,`MetricsGenerator` 依赖抽象而非 `*service.MonitorService`,便于对算力口径做单测(本期同时新增 exporter_test.go +171)。
  <details><summary>代码依据 server/internal/exporter/exporter.go</summary>

  ```diff
  +type instantQuerier interface {
  +	QueryInstant(context.Context, *pb.QueryInstantRequest) (*pb.InstantResponse, error)
  +}
  -	monitorService *service.MonitorService
  +	monitorService instantQuerier
  ```
  </details>

- **概览页算力利用率修错**:前端把内联的 gauge 配置抽成 `createComputeUsageGaugeConfig()`,查询从按 `instance` 聚合改为按 `(node, device_uuid)` 聚合,并**删除 `totalQuery: avg(sum(hami_core_size) by (instance))`**——注释说明 `hami_core_util` 本身已是 0–100 百分比,再除以全集群 `hami_core_size` 会让显示值随集群设备数增多而缩水。
  <details><summary>代码依据 packages/web/.../overview/metric-config.mjs</summary>

  ```diff
  -    title: 'computeUsageRate',
  -    query: `avg(sum(hami_core_util) by (instance))`,
  -    percentQuery: `avg(sum(hami_core_util_avg) by (instance))`,
  -    totalQuery: `avg(sum(hami_core_size) by (instance))`,
  +export const createComputeUsageGaugeConfig = () => ({
  +  title: 'computeUsageRate',
  +  query: 'avg(avg(hami_core_util) by (node, device_uuid))',
  +  percentQuery: 'avg(avg(hami_core_util_avg) by (node, device_uuid))',
  +  // hami_core_util is already a percentage ... Dividing by cluster-wide hami_core_size would shrink the value
  +  total: 100,
  ```
  </details>

- **昇腾 `fetchContainerInfo` index 越界 panic 修复**:原来把所有 device type 的 `pdevices` 直接 `copier.Copy` 平铺进一个切片、再以 `len<1` 判空,昇腾多设备类型时容器索引错位甚至越界。改为按 `initContainers+containers` 总数**预分配切片**,逐 device type 拷贝后按容器索引 `i < totalContainers` 守卫 append 合并。
  <details><summary>代码依据 server/internal/data/pod.go</summary>

  ```diff
  -	bizContainerDevices := []biz.ContainerDevices{}
  -	for _, pds := range pdevices { copier.Copy(&bizContainerDevices, pds) }
  +	totalContainers := len(pod.Spec.InitContainers) + len(pod.Spec.Containers)
  +	bizContainerDevices := make([]biz.ContainerDevices, totalContainers)
  +	for devType, pds := range pdevices {
  +		var bizPds biz.PodSingleDevice
  +		if err := copier.Copy(&bizPds, pds); err != nil { r.log.Warnf(...); continue }
  +		for i, cd := range bizPds { if i < totalContainers { bizContainerDevices[i] = append(bizContainerDevices[i], cd...) } }
  +	}
  -	if len(bizContainerDevices) < 1 { return containers }
  +	if len(pdevices) == 0 { return containers }
  ```
  </details>

- **`DecodePodDevices` 昇腾解析加边界与空段兜底**:切分注解字符串时,超过 `podContainerCount(pod)` 直接 break,空段落 append 空 `ContainerDevices{}` 占位而非跳过,保证容器索引与设备切片一一对应(与上面 pod.go 修复同一条越界链路)。
  <details><summary>代码依据 server/internal/provider/util/util.go</summary>

  ```diff
  -			for _, s := range strings.Split(str, OnePodMultiContainerSplitSymbol) {
  +			for i, s := range strings.Split(str, OnePodMultiContainerSplitSymbol) {
  +				if i >= podContainerCount(pod) { break }
  +				if s == "" { pd[devType] = append(pd[devType], ContainerDevices{}); continue }
  ```
  </details>

- **架构 proposal:去 NestJS + 弃多集群**:`web-entry-and-embedding.md`(status: proposed,@Nimbus318)声明 HAMi-WebUI 维持"单集群、只读可观测 UI";生产用 NestJS 进程(现负责 serve Vue 资源、SPA fallback、`/api/vgpu/*` 反代、健康检查)在 Chart 1.x 内被"最小 static-file+reverse-proxy Gateway"替换,单一 Go 镜像推迟到 Chart 2.0.0;认证明确为"部署边界外置",非内置 OAuth/RBAC/session。同时 `webui-redesign.md` 加注:多集群方向已被本 proposal 取代。
  <details><summary>代码依据 docs/proposals/web-entry-and-embedding.md / webui-redesign.md</summary>

  ```diff
  +> **Architecture update:** The multi-cluster direction in this proposal has
  +> been replaced by [Single-Cluster Web Entry and Embedding Architecture](web-entry-and-embedding.md).
  ...
  +the production NestJS runtime will be replaced by a minimal
  +static-file and reverse-proxy Gateway while preserving the public Helm and HTTP contracts.
  +A single Go application image is deferred to Chart version 2.0.0 ...
  ```
  </details>

- **发布链路重做为 fail-closed 原子控制器**:新增 `.github/workflows/release.yaml`(+638)"Verified Stable Release",分 bootstrap-oci/candidate/publish 三 phase、`stable-release` 并发串行、`permissions: {}` 收紧;合入即默认关闭,须 `release` 环境的 `STABLE_RELEASES_ENABLED=true` 才发。删除旧 `release-chart.yaml`;`ci.yaml` 从"Build and Push"降级为"Build Development Images"(PR 只 build 不 push)。另有 `scripts/verify-vite-env-boundary.mjs` 限制 Vite 构建期环境变量暴露(供应链/构建面收敛)。
  <details><summary>代码依据 .github/workflows/ci.yaml</summary>

  ```diff
  -name: Build and Push Images
  +name: Build Development Images
  ...
  -  packages: write
  +  validate-images:
  +    if: github.event_name == 'pull_request'
  ```
  </details>

### 后续发展方向 [AI]
- 算力口径这次是"以任务级 utilization_ratio 为准、显式不再用整卡 util 回填 NVIDIA"的方向确立:证据覆盖 NVIDIA(已改)与前端概览(已改),但 Cambricon/Hygon/Metax 仍保留旧 `cardCoreUtil>95` 回填分支——未见这几家的口径统一,后续大概率跟进。证据只覆盖 exporter.go/metric-config.mjs 两处 hunk,未逐一验证各 provider PromQL 正确性。
- WebUI 运行时正从"NestJS 双运行时"向"Go 静态网关"收敛,且明确不做多集群/不做内置认证——这意味着企业多集群纳管仍需上层平台自己聚合/嵌 iframe。证据仅到 proposal(status: proposed),未见 Gateway 实现代码落地,方向已定但落地时点(Chart 1.x 某版)未见。
- 发布链路 fail-closed + Vite 环境隔离显示项目在往"可审计、供应链安全"的商业化交付靠拢;证据只在 CI/release workflow 与 scripts,未见运行时安全能力(RBAC/多租户)相应增强。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi:无新提交(HEAD 仍 ebcd8ae0)
- Project-HAMi/HAMi-core:无新提交(HEAD 仍 de6ce39d)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 32162c65)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=ebcd8ae000d0ded373cad0ebfabb8289f2c5810a branch=master release=v2.10.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=de6ce39dc36246d4161e931ae2fd93929e676e55 branch=main release=— scanned=2026-08-30 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=32162c65332b649084b07894fa2c6101469012f5 branch=main release=— scanned=2026-08-30 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=566bb06fc5acf79d92b98034e3f5d13951ce14bb branch=main release=v1.3.0 scanned=2026-08-30 -->
