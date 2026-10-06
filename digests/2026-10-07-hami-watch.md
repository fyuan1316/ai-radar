# HAMi diff 雷达 2026-10-07

## 摘要
- 仅 HAMi-WebUI 有实质改动(2 个 fix PR):控制台把"工作负载数"卡改为"已占用切分槽位",并**只对已验证的等额软切分(NVIDIA/Ascend × hami-core 时分)才显示槽位占用比**,对 MIG/template 分区模式与其他厂商一律不展示容量百分比——避免把分区实例计数误当作容量比例。
- 主仓 HAMi、HAMi-core、volcano-vgpu-device-plugin、ascend-device-plugin 本期均无实质改动(无新提交或仅 bump/CI)。

## 当日重要改变
- 无(未命中弃用/移除、API/CRD、架构方向、版本跨档、新能力等硬信号;WebUI 改动为展示层正确性修复,见下)

## Project-HAMi/HAMi-WebUI: c8c6e808 -> 0aab6c81
- 比较: c8c6e808 -> 0aab6c81 | ahead=2 | files=10 | Release: v1.3.0
- 提交:
  - fix(web): respect sharing modes in allocation summaries (#323) https://github.com/Project-HAMi/HAMi-WebUI/pull/323
  - fix(web): keep device resource summaries compact across widths (#324) https://github.com/Project-HAMi/HAMi-WebUI/pull/324

### AI 总结重点(源码 diff 为据)

- **新增 `getAllocationSlotDisplay` 纯函数(allocation-slot-display.mjs),把"是否显示槽位占用比"收敛成一条可验证规则:仅 `vendor ∈ {NVIDIA, Ascend}` 且 `mode === 'hami-core'` 且非 `unconfigured` 才返回 `{used, limit, percent}`,其余(MIG/template 分区模式、MLU/DCU/HCU/Metax 等厂商)一律返回 `undefined`。** 注释点明理由:分区 profile 不是等额份额,不能把实例计数当容量百分比。这是 #323 的核心——让分配汇总"尊重切分模式"。

  <details><summary>代码依据 packages/web/projects/vgpu/views/card/admin/allocation-slot-display.mjs</summary>

  ```diff
  +export const getAllocationSlotDisplay = (device = {}) => {
  +  // Partition profiles are not equal-sized shares; only show a verified sharing quota.
  +  if (!device || !['NVIDIA', 'Ascend'].includes(device.vendor)
  +    || device.mode !== 'hami-core'
  +    || device.unconfigured) return undefined;
  +
  +  const used = readSlotCount(device.vgpuUsed);
  +  const limit = readSlotCount(device.vgpuTotal);
  +  return {
  +    used,
  +    limit,
  +    percent: used !== undefined && limit > 0 ? (used / limit) * 100 : undefined,
  +  };
  +};
  ```
  </details>

- **`readSlotCount` 做严格数值校验:只接受非负 safe integer,拒绝空串/非数字/负数/浮点/NaN/Infinity/超界整数 → 返回 `undefined`;`percent` 仅在 `used` 有定义且 `limit>0` 时才算。** 效果:数据缺失时不再虚构 0 或假百分比(配套测试覆盖了 NaN/Infinity/'1.5'/MAX_SAFE_INTEGER+1 等边界)。

  <details><summary>代码依据 allocation-slot-display.mjs + allocation-slot-display.test.mjs</summary>

  ```diff
  +const readSlotCount = (value) => {
  +  if (typeof value !== 'number' && typeof value !== 'string') return undefined;
  +  if (typeof value === 'string' && value.trim() === '') return undefined;
  +  const count = Number(value);
  +  return Number.isSafeInteger(count) && count >= 0 ? count : undefined;
  +};
  +// test: partition instance counts never become a capacity percentage
  +assert.equal(getAllocationSlotDisplay({ ...shared, mode: 'mig', vgpuTotal: 7 }), undefined);
  +assert.equal(getAllocationSlotDisplay({ ...shared, vendor: 'Ascend', mode: 'template', vgpuUsed: 1, vgpuTotal: 8 }), undefined);
  ```
  </details>

- **仪表盘组件 `WorkloadSemiProgress.vue`:`percent` 默认值 `0 → undefined`,`normalizedPercent` 对非有限值由"返回 0"改为"返回 undefined",`progressPath` 在 undefined 时返回空串不画进度弧。** 即"无已验证槽位数据"时仪表留空,而不是误显一个 0% 的满弧背景。同时 viewBox 收紧、加 `stroke-linecap: round`、宽度改 `100%` 自适应。

  <details><summary>代码依据 packages/web/projects/vgpu/views/card/admin/components/WorkloadSemiProgress.vue</summary>

  ```diff
  -  percent: { type: Number, default: 0 },
  +  percent: { type: Number, default: undefined },
  ...
  -const normalizedPercent = computed(() => {
  -  const val = Number(props.percent);
  -  if (!Number.isFinite(val)) return 0;
  -  return Math.max(0, Math.min(100, val));
  -});
  +const normalizedPercent = computed(() => {
  +  if (!Number.isFinite(props.percent)) return undefined;
  +  return Math.max(0, Math.min(100, props.percent));
  +});
  ...
  const progressPath = computed(() => {
  +  if (normalizedPercent.value === undefined) return '';
     const angle = (normalizedPercent.value / 100) * 180;
  ```
  </details>

- **卡详情资源总览(Detail.vue)据此重构,并同步改文案:`workloadCount`/`workloadCountTip` → `allocatedSlots`/`allocatedSlotsTip`。** 新文案把"Workloads/每卡可被多工作负载共享"换成"Occupied slots / 已占用切分槽位 / 配置上限,后续分配还取决于可用算力与显存"——把"工作负载计数"语义明确为"切分槽位占用",且提示上限不等于可分配。

  <details><summary>代码依据 packages/web/src/locales/en.js</summary>

  ```diff
  -      workloadCount: 'Workloads',
  -      workloadCountTip:
  -        'Each accelerator card supports sharing by multiple workloads at the same time.\nThe chart shows [Allocated Count / Maximum Supported Count].',
  +      allocatedSlots: 'Occupied slots',
  +      allocatedSlotsTip:
  +        'Occupied sharing slots / configured limit. Further allocations also depend on available compute and memory.',
  ```
  </details>

- **`DeviceSplit.vue` 紧凑化(#324):新增 `showSharedCount` prop(默认 true),可抑制"shared by N"计数文案;header 改为仅在 `showDevice || hasSummary` 时渲染,shared 表仅在 `split.holders.length` 非空时渲染,新增 `hasSummary` 计算属性。** 目的是窄面板下避免空渲染/冗余计数,让设备资源摘要在不同宽度与语言下保持紧凑。

  <details><summary>代码依据 packages/web/projects/vgpu/components/DeviceSplit.vue</summary>

  ```diff
  -      <p v-if="status === 'ready'" class="device-split__summary">
  +      <p v-if="hasSummary" class="device-split__summary">
  ...
  -  } else if (value.kind === 'shared') {
  -    parts.push({ text: value.limit ? ... : ... });
  +  } else if (value.kind === 'shared') {
  +    if (props.showSharedCount) {
  +      parts.push({ text: value.limit ? ... : ... });
  +    }
  +const hasSummary = computed(() => props.status === 'ready' && (summary.value.length > 0 || hasStranded.value));
  ```
  </details>

### 后续发展方向 [AI]
- WebUI 在"软切分(hami-core 时分共享) vs 分区(MIG/template)"的**可视化表达上正式分道**:只对可类比的等额软切分显示"已占用/上限"槽位比,对分区 profile 与未验证厂商拒绝给出容量百分比。方向是把控制台的多模式/多厂商混布做到"不误导"而非"全都给个数"。
- 证据只覆盖前端展示层(`packages/web/projects/vgpu`),未见主仓调度器或 HAMi-core 内核有对应改动——这是可用性/正确性修复,不是切分能力本身的扩展。白名单仅 `{NVIDIA, Ascend} × hami-core`,后续若要让 Ascend template、MLU/Metax 等也显示占用比,需要先定义各自"等额份额"的语义(当前被显式排除)。

## 本期无实质改动(折叠)
<details><summary>4 个 repo 本期无实质改动,仅保锚点</summary>

- Project-HAMi/HAMi:ahead=2,仅 bump/CI/merge,无实质代码改动(Release v2.10.0)
- Project-HAMi/HAMi-core:无新提交
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交(Release ascend-device-plugin-0.1.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=2770728664cd368bfef8eea9bbb750167909051c branch=master release=v2.10.0 scanned=2026-10-07 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-10-07 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-10-07 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f6ee0240641e9f03e6e46356910a1579b3cf276 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-07 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=0aab6c81e4451162402c9fb92caf6313e908b20d branch=main release=v1.3.0 scanned=2026-10-07 -->
