# HAMi diff 雷达 2026-10-18

## 摘要
- **ascend-device-plugin 把 vNPU 软切分数量做成可配置**:新增全局 `deviceSplitCount`(hami-core/ENPU 模式下每张物理 NPU 的虚拟槽位数,默认 10),`VDeviceCount()` 逻辑重写——原先 ENPU 硬编码 100、hami-core 走模板,现统一读该字段;Chart 升到 0.2.0。
- **HAMi-WebUI 把分项搜索(按 UID/IP/名称)统一成模糊关键字过滤**:gRPC `workload.proto` 新增 `keyword` 过滤字段 + `node_counts`/`device_counts` 两个回包 map,控制台下拉项带命中计数。
- HAMi / HAMi-core / volcano-vgpu-device-plugin 本期无实质改动(仅锚点延续)。

## 当日重要改变
- Project-HAMi/ascend-device-plugin [新能力][API/CRD变更] 配置结构体 `VNPUsConfig` 新增 `DeviceSplitCount` 字段,软切分槽位数从硬编码/模板派生改为显式可配(默认 10,ENPU 上限 100)。证据 internal/vnpu.go、internal/manager/manager.go https://github.com/Project-HAMi/ascend-device-plugin/compare/1cf890f9...74d8d109
- Project-HAMi/ascend-device-plugin [版本跨档] Release ascend-device-plugin-0.1.0 -> 0.2.0,Chart version 同步 0.1.0->0.2.0(AppVersion 仍 v1.4.0)。https://github.com/Project-HAMi/ascend-device-plugin/releases/tag/ascend-device-plugin-0.2.0
- Project-HAMi/HAMi-WebUI [API/CRD变更] gRPC 契约 `server/api/v1/workload.proto` 的 `ListWorkloadsRequest.Filters` 新增 `keyword`(第 8 字段),`WorkloadsReply` 新增 `node_counts`(4)/`device_counts`(5)。https://github.com/Project-HAMi/HAMi-WebUI/pull/337

## Project-HAMi/ascend-device-plugin: 1cf890f9 -> 74d8d109
- 比较: 1cf890f9 -> 74d8d109 | ahead=5 | files=12 | Release: ascend-device-plugin-0.2.0
- https://github.com/Project-HAMi/ascend-device-plugin/compare/1cf890f9...74d8d109

### AI 总结重点(源码 diff 为据)
- **`VDeviceCount()` 的取数优先级被重写,软切分槽位数从"ENPU 恒等 100 / hami-core 走模板"改为"统一读全局 `VNPUs.DeviceSplitCount`(默认 10)"**。旧逻辑:节点 override 优先,其次若 `IsEnpu() && !IsHamiVnpuCore()` 直接返回 100,再其次按 `config.Templates` 长度推算;hami-core(非 enpu)在没有节点 override 时会掉进模板分支。新逻辑:引入局部 `count`,节点 override 优先,否则只要是 hami-core 或 enpu 模式就取 `globalConfig.VNPUs.DeviceSplitCount`(≤0 兜底 10);最后对 ENPU 保留 >100 截断到 100 的护栏,模板模式(count 仍为 0)才落到模板分支。效果:hami-core 下首次有了独立于模板的槽位数配置,ENPU 可在 100 以下自由调低。
  <details><summary>代码依据 internal/manager/manager.go</summary>

  ```diff
   func (am *AscendManager) VDeviceCount() int {
  -	// Prefer the per-node override when present, mirroring IsHamiVnpuCore().
  +	count := 0
   	if am.nodeConfig != nil && am.nodeConfig.VDeviceCount > 0 {
  -		if am.IsEnpu() && am.nodeConfig.VDeviceCount > 100 {
  -			klog.Warningf("vDeviceCount %d exceeds ENPU's 100 virtual-NPU slots; using 100", am.nodeConfig.VDeviceCount)
  -			return 100
  +		count = am.nodeConfig.VDeviceCount
  +	} else if am.IsHamiVnpuCore() || am.IsEnpu() {
  +		count = am.globalConfig.VNPUs.DeviceSplitCount
  +		if count <= 0 {
  +			count = 10
   		}
  -		return am.nodeConfig.VDeviceCount
   	}
  -	if am.IsEnpu() && !am.IsHamiVnpuCore() {
  -		return 100
  +	if count > 0 {
  +		if am.IsEnpu() && count > 100 {
  +			klog.Warningf("device count %d exceeds ENPU's 100 virtual-NPU slots; using 100", count)
  +			return 100
  +		}
  +		return count
   	}
   	if len(am.config.Templates) == 0 {
   		return 1
  ```
  </details>
- **配置结构体 `VNPUsConfig` 新增 `DeviceSplitCount int`**(json tag `deviceSplitCount`,无 omitempty,即始终序列化),与已废弃的 `HamiVnpuCore bool` 并列。这是上面逻辑的持久化承载字段,写入 HAMi scheduler 与插件共享的 ConfigMap。
  <details><summary>代码依据 internal/vnpu.go</summary>

  ```diff
   type VNPUsConfig struct {
   	HamiVnpuMode string `json:"hamiVnpuMode,omitempty"`
   	EnpuPolicy   string `json:"enpuPolicy,omitempty"`
  +
  +	DeviceSplitCount int `json:"deviceSplitCount"`
   	// Deprecated: used only when HamiVnpuMode is empty.
   	HamiVnpuCore bool `json:"hamiVnpuCore,omitempty"`
  ```
  </details>
- **Chart 把 `deviceSplitCount` 暴露为顶层 value 并注入 deviceConfig**:values.yaml 默认 10、schema 标 `integer;minimum:1;required`,渲染进共享的 `deviceConfig` ConfigMap(`deviceSplitCount: {{ .Values.deviceSplitCount | int64 }}`)。文档明确:HAMi 主 Chart 对应 `devices.ascend.deviceSplitCount`,独立插件 Chart 用 `deviceSplitCount`;**仅改 Chart 值不生效,插件镜像本身必须含切分支持**,且改共享 ConfigMap 后需重启插件重读。
  <details><summary>代码依据 charts/ascend-device-plugin/values.yaml + values.schema.json</summary>

  ```diff
  +# deviceSplitCount -- Positive integer virtual-device slots per physical NPU in hami-core and ENPU modes. ...
  +deviceSplitCount: 10 # @schema type:integer;minimum:1;required:true
  +
   deviceConfig: |- # @schema required:true
     vnpus:
       hamiVnpuMode: {{ include "ascend-device-plugin.vnpuMode" . | quote }}
  +    deviceSplitCount: {{ .Values.deviceSplitCount | int64 }}
       deviceCoreScaling: {{ .Values.hamiVnpuCore.deviceCoreScaling }}
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 vNPU 的软切分从"模板枚举 + ENPU 固定 100 槽"向"显式密度调参"收敛,与 NVIDIA vGPU 侧按 `deviceSplitCount` 控制单卡虚拟设备数的做法对齐——证据覆盖 manager.go 取数逻辑 + vnpu.go 字段 + Chart 注入三处;**未见调度器侧(HAMi 主仓)对该字段的消费改动**(本期 HAMi 仓 EMPTY),文档亦强调"写新字段前先升级配套 scheduler",说明两端协议仍在对齐中。
- 文档里"调度器按注册 Count 限制分配,显存和算力可能先耗尽"的措辞,暗示槽位数只是分配上限、真正隔离仍靠 hami-core 的显存/算力配额;对我们产品的启示:若对标该能力,需把"槽位密度"与"显存/算力配额"作为两个独立维度暴露,不能用单一超卖比糊弄。证据仅限 docs/hami.md 说明段,未逐 PR 展开分配器实现。

## Project-HAMi/HAMi-WebUI: 09f0b75b -> 4f5875cf
- 比较: 09f0b75b -> 4f5875cf | ahead=4 | files=31 | Release: v1.3.0(未变)
- https://github.com/Project-HAMi/HAMi-WebUI/compare/09f0b75b...4f5875cf

### AI 总结重点(源码 diff 为据)
- **gRPC 契约升级:列表查询从"分项精确过滤"改为"统一模糊关键字"**。`ListWorkloadsRequest.Filters` 新增 `string keyword = 8`(Pod 名 / 容器名 / 命名空间的大小写不敏感片段,多词须全部命中);`WorkloadsReply` 新增 `node_counts = 4` 与 `device_counts = 5` 两个 map,回传"在其他过滤条件下,选中每个节点/设备各会列出多少行"。前端据此把原来的 `filters.uid`(card)、`filters.ip`(node)、`filters.name`(task)三个独立输入框统一换成 `filters.keyword`。
  <details><summary>代码依据 server/api/v1/workload.proto</summary>

  ```diff
   message ListWorkloadsRequest {
       string priority = 7;
  +    // Case-insensitive fragments of the Pod name, container name or namespace; every word must match.
  +    string keyword = 8;
     }
   ...
   message WorkloadsReply {
     map<string, int32> status_counts = 3;
  +  map<string, int32> node_counts = 4;
  +  map<string, int32> device_counts = 5;
   }
  ```
  </details>
- **关键字匹配规则抽成可测试工具 `keyword-search.mjs`**:`parseKeywords` 去空白、按空格拆词、转小写;`matchesKeywords` 要求每个词在**同一字段内**命中(不跨字段边界),且忽略分隔符——设备 UUID `GPU-f95362fb-...` 用带/不带连字符的片段都能命中;`limitOptions` 对超长下拉(>100 项)只保留前 100 条命中、其余计入 `hidden`。
  <details><summary>代码依据 packages/web/src/utils/keyword-search.test.mjs</summary>

  ```diff
  +test('device UUID fragments match with or without dashes', () => {
  +  const fields = ['GPU-f95362fb-79f5-57bb-9972-86156cd5f525'];
  +  assert.equal(matchesKeywords(parseKeywords('f95362fb-79f5'), fields), true);
  +  assert.equal(matchesKeywords(parseKeywords('F95362FB79F5'), fields), true);
  +});
  +test('long option lists keep only the first matches and count the rest', () => {
  +  assert.deepEqual([limitOptions(options, '').options.length, limitOptions(options, '').hidden], [100, 151]);
  ```
  </details>
- **服务端为"节点/设备下拉计数"引入不受设备过滤影响的 unscoped 分支**:`ListWorkloads` 在 `filters.DeviceId != ""` 时额外拉一份全量容器(`GetAllContainers`)做 `deviceItems`,因为设备过滤会把每行分配收窄到该 GPU,而设备计数需忽略该过滤;新增 `nodesHoldingDevice` 按节点清单判断哪些节点持有该设备,回传 `NodeCounts`/`DeviceCounts`。
  <details><summary>代码依据 server/internal/service/workload.go</summary>

  ```diff
  +	// The device filter also narrows each row's allocation to that GPU, so device counts,
  +	// which ignore that filter, need the unfiltered allocations.
  +	unscoped := allocated
  +	if filters.DeviceId != "" {
  +		if unscoped, err = s.containers.GetAllContainers(ctx, &pb.GetAllContainersReq{}); err != nil {
  +			return nil, err
  +		}
  +	}
  ...
  -	result := &pb.WorkloadsReply{Items: ..., StatusCounts: counts}
  +	result := &pb.WorkloadsReply{Items: ..., StatusCounts: counts, NodeCounts: nodeCounts, DeviceCounts: deviceCounts}
  ```
  </details>
- **fix #336:自定义趋势时间段的结束日约束收紧**——结束日只能从可见起始日起选,早于起始或指向未来的提交被拒;首次确认"起始晚于结束"会清空结束并把焦点移到结束框。证据为 TrendTimeFilter 的浏览器测试新增用例(hunk 截断,未覆盖组件实现)。

### 后续发展方向 [AI]
- WebUI 往"大规模集群下的可检索/可定位"打磨:统一模糊搜索 + 下拉命中计数 + 超长列表截断计数,都是节点/设备数量上百时的可用性信号,契合 v1.x 控制台走向商业化运维台。证据覆盖 proto 契约 + 前端三视图 + keyword 工具;**未见权限/多租户维度改动**,仍是单租户运维视角。
- 对我们产品的启示:若自研控制台,"按任意片段(含 UUID 去连字符)跨 Pod/容器/命名空间模糊搜 + 过滤联动计数"已是 HAMi 开源基线,属追平项而非差异点;真正可拉开的是多租户隔离下的检索视图(HAMi 尚缺)。证据仅限本期 diff,未查其 issue 规划。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- Project-HAMi/HAMi:无新提交(锚点未动,Release v2.10.0)
- Project-HAMi/HAMi-core:无新提交
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=0af48d6234dfec4d8fbb8ab76c25af7e2c114ffe branch=master release=v2.10.0 scanned=2026-10-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a55248ecc6e2530602875054e2d334645d08f35b branch=main release=— scanned=2026-10-18 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-18 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=74d8d109c40cb70ba0d2881af3b807aef9984fc6 branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-18 -->
