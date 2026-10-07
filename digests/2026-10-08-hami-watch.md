# HAMi diff 雷达 2026-10-08

## 摘要
- HAMi-WebUI 落地**节点详情页「设备分配」面板**(#331):新建 `NodeDeviceAllocation.vue` 复用 `DeviceSplit`,新增 `/v1/gpus`、`/v1/containers` 两个 POST 查询,按 `allocationStatus`(complete/partial)分档渲染并 `strict-values` 杜绝虚构百分比——延续昨日 `getAllocationSlotDisplay` 的分配可视化主线。
- HAMi-WebUI 修**监控时区正确性**(#327):`QueryRange` 的时间解析从"只按服务端本地 `YYYY-MM-DD HH:mm:ss`"改为"优先 RFC3339(带时区)、失败再回退本地",配套 `useTrendTimeRange` 组合式统一预设/自定义范围与刷新语义。
- 主仓仅补 iluvatar `AddResourceUsage` 单测(无生产代码改动);HAMi-core / volcano-vgpu / ascend-device-plugin 三仓无新提交。

## 当日重要改变
- HAMi-WebUI [新能力] 节点详情页新增设备分配面板 `NodeDeviceAllocation.vue`(+288),按分配完成度分档展示、支持 >4 卡折叠展开 https://github.com/Project-HAMi/HAMi-WebUI/pull/331
- HAMi-WebUI [API/CRD变更] `server/api/v1/monitor.proto` 的 `Range.start/end` 加时区语义注释(仅注释,非字段增删),真实行为改在 `monitor.go` https://github.com/Project-HAMi/HAMi-WebUI/pull/327

## Project-HAMi/HAMi-WebUI: 0aab6c81 -> 54d4bdf0
- 比较: 0aab6c81e4451162402c9fb92caf6313e908b20d -> 54d4bdf0 | ahead=5 | files=30 | Release: v1.3.0
- 比较链接: https://github.com/Project-HAMi/HAMi-WebUI/compare/0aab6c81e4451162402c9fb92caf6313e908b20d...54d4bdf02cb1a6d733c418809eb81d82d72c8d9e

### AI 总结重点(源码 diff 为据)

- **节点详情页新增「设备分配」面板**:新文件 `NodeDeviceAllocation.vue` 渲染一节 `node-allocation`,对每张卡复用 `DeviceSplit` 组件,并按 `entry.allocationStatus` 分三态——`loading/idle` 显示骨架、`error` 显示重试、`complete` 才渲染 `show-chart`/`show-summary`,非 complete 时在 `#chart` 插槽里只显已知分配值(`knownAllocation`)与 profile。卡数 >4 时折叠,余下走展开按钮。透传了 `:show-shared-count="false"` 与 `strict-values`,与昨日"分配汇总尊重切分模式、不虚构百分比"一脉相承。
  <details><summary>代码依据 packages/web/projects/vgpu/views/node/admin/NodeDeviceAllocation.vue</summary>

  ```diff
  +        <DeviceSplit
  +          class="node-device__split"
  +          :device="entry.device"
  +          :containers="entry.containers"
  +          show-device stack-summary :show-holders="false" :show-shared-count="false"
  +          :show-chart="entry.allocationStatus === 'complete'"
  +          :show-summary="entry.allocationStatus === 'complete'"
  +          strict-values
  +        >
  +          <template v-if="entry.allocationStatus !== 'complete'" #chart>
  +            <dl v-if="knownAllocation(entry).length" class="node-device__known-values"> ... </dl>
  +      <div v-if="entries.length > 4" class="node-allocation__expansion">
  ```
  </details>

- **新增两个节点级数据查询 API**:`node.js` 的 `nodeApi` 新增 `getNodeDevices(nodeName)` 打 `POST /v1/gpus`(按 `filters.nodeName`)、`getNodeAllocatedContainers(nodeUid)` 打 `POST /v1/containers`(按 `filters.nodeUid`),都带 `errorFeedback: 'inline'` 和 `signal`(可取消)。这是上面分配面板的取数来源。
  <details><summary>代码依据 packages/web/projects/vgpu/api/node.js</summary>

  ```diff
  +  getNodeDevices(nodeName, signal) {
  +    return request({ url: apiPrefix + '/v1/gpus', method: 'POST',
  +      data: { filters: { nodeName } }, errorFeedback: 'inline', signal });
  +  }
  +  getNodeAllocatedContainers(nodeUid, signal) {
  +    return request({ url: apiPrefix + '/v1/containers', method: 'POST',
  +      data: { filters: { nodeUid } }, errorFeedback: 'inline', signal });
  +  }
  ```
  </details>

- **监控范围查询支持带时区的 RFC3339**:`MonitorService.QueryRange` 原来固定用 `time.ParseInLocation(time.DateTime, ..., time.Local)`——即把 `start/end` 一律当"服务端本地时区的 `YYYY-MM-DD HH:mm:ss`"解析,跨时区客户端会错位。现抽出 `parseRangeTime`:先试 `time.Parse(time.RFC3339Nano, ...)`(显式时区),失败才回退旧的本地 DateTime 解析,老客户端行为不变。
  <details><summary>代码依据 server/internal/service/monitor.go</summary>

  ```diff
  -	startTime, err := time.ParseInLocation(time.DateTime, req.Range.GetStart(), time.Local)
  +	startTime, err := parseRangeTime(req.Range.GetStart())
  ...
  +func parseRangeTime(value string) (time.Time, error) {
  +	if parsed, err := time.Parse(time.RFC3339Nano, value); err == nil {
  +		return parsed, nil
  +	}
  +	// Preserve the server-local interpretation used by older clients.
  +	return time.ParseInLocation(time.DateTime, value, time.Local)
  +}
  ```
  </details>

- **`monitor.proto` 同步标注时区约定**(仅注释,`Range` 字段未增删):`start`/`end` 均加注"优先 RFC3339 带显式时区;遗留 `YYYY-MM-DD HH:mm:ss` 走服务端本地时区"。
  <details><summary>代码依据 server/api/v1/monitor.proto</summary>

  ```diff
   message Range {
  +  // Prefer RFC3339 with an explicit timezone; legacy YYYY-MM-DD HH:mm:ss uses the server's local timezone.
     string start = 1;
  +  // Prefer RFC3339 with an explicit timezone; legacy YYYY-MM-DD HH:mm:ss uses the server's local timezone.
     string end = 2;
  ```
  </details>

- **趋势时间筛选器重构 + 新增 `useTrendTimeRange` 组合式**(#325/#326):`TrendTimeFilter.vue` 把旧 `t-radio-group` 预设换成 `segmented-control`+紧凑态 `t-select`,自定义范围选择器改 `need-confirm`、禁未来日期、`value-type="Date"`,并内嵌新增的 `RefreshButton`;逻辑下沉到 `useTrendTimeRange.js`,其单测断言"父传非默认预设不触发二次查询""绝对范围按 custom 打开不被替换""重选当前预设每次激活仅刷新一次"。属可用性/交互一致性修复,不触 vGPU 切分内核。
  <details><summary>代码依据 packages/web/src/components/useTrendTimeRange.test.mjs</summary>

  ```diff
  +test('a parent-provided non-default preset is preserved without issuing a second query', ...
  +  assert.equal(updates.length, 0); assert.equal(queries.length, 1);
  +test('reselecting the current preset refreshes to now exactly once per activation', ...
  ```
  </details>

### 后续发展方向 [AI]
- WebUI 持续把"分配可观测性"做深:从昨日的切分模式感知汇总(`getAllocationSlotDisplay`)到今日的节点级设备分配面板 + `/v1/gpus`、`/v1/containers` 取数,控制台正在补齐"按节点看每卡被谁占了多少"的视图。证据只覆盖前端组件与 API 封装,未见后端 `/v1/gpus`、`/v1/containers` 的 handler 实现变更(本次 diff 未命中 server 侧对应文件)。
- 时区修复是面向多区域/跨时区部署的工程化信号(RFC3339 优先、旧格式回退),但仅动了 `QueryRange` 一处;证据未覆盖 instant 查询等其它入口是否同步改造。

## 本期无实质改动(折叠)
<details><summary>以下 repo 本期仅 bump/CI 或无新提交,保锚点</summary>

- Project-HAMi/HAMi: 本期 2 commit,仅 `build(deps): bump golang.org/x/tools`(已滤)+ `test(iluvatar): add coverage for AddResourceUsage`(纯单测,无生产代码改动),不单列正文。commit: https://github.com/Project-HAMi/HAMi/commit/b56963440b27e6f2e5f6755315d148fdce6d8fd4
- Project-HAMi/HAMi-core: 无新提交
- Project-HAMi/volcano-vgpu-device-plugin: 无新提交
- Project-HAMi/ascend-device-plugin: 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=b56963440b27e6f2e5f6755315d148fdce6d8fd4 branch=master release=v2.10.0 scanned=2026-10-08 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-10-08 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-10-08 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f6ee0240641e9f03e6e46356910a1579b3cf276 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-08 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=54d4bdf02cb1a6d733c418809eb81d82d72c8d9e branch=main release=v1.3.0 scanned=2026-10-08 -->
