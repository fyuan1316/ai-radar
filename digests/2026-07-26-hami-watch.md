# HAMi diff 雷达 2026-07-26

## 摘要
- **ascend-device-plugin 放宽 hami-vnpu-core 软切分的调度器约束**:README 删掉"仅支持 HAMi 调度器(Note 2)",新增 docs/volcano.md 明确 hami-core 软切分可跑在 Volcano `deviceshare`(HAMi mode)插件下,需 Volcano ≥ 1.16。软切分不再是 HAMi-scheduler 专属能力。
- **ascend-device-plugin 从 chart 里移除内置 vNPU Prometheus 监控集成**:删掉 ServiceMonitor/PrometheusRule 模板与 values.yaml 的整个 `vnpuMonitor:` 段;插件仍在 `:9395/metrics` 暴露指标,但 Prometheus 接线改为"用户自理,超出 chart 范围"。镜像同步 v1.3.0 → v1.4.0。
- HAMi 主仓、HAMi-core、volcano-vgpu、HAMi-WebUI 本期无实质能力改动(主仓仅安全元数据+CI bump)。

## 当日重要改变
- Project-HAMi/ascend-device-plugin [弃用/移除] chart 不再打包 vNPU 监控的 ServiceMonitor/PrometheusRule 与 `vnpuMonitor:` 配置段,软切分指标接线交给用户。证据:charts/ascend-device-plugin/templates/vnpu-monitor-integration.yaml(-109)、ascend-vnpu-monitor-integration.yaml(-103)、values.yaml(-25)。 https://github.com/Project-HAMi/ascend-device-plugin/compare/f062939e14354a96fb8bfabd3c103d9d8f6de6c2...ed35e1c4b003795de84ba942f6965fa269e866b3
- Project-HAMi/ascend-device-plugin [新能力/约束放宽] hami-vnpu-core 软切分从"仅 HAMi 调度器"扩到 Volcano(≥1.16),README Note 2 删除 + 新增 docs/volcano.md。证据同上 compare。

## Project-HAMi/ascend-device-plugin: f062939e -> ed35e1c4
- 比较: f062939e -> ed35e1c4 | ahead=13 | files=13 | Release: —(镜像 tag v1.3.0 → v1.4.0)
- compare: https://github.com/Project-HAMi/ascend-device-plugin/compare/f062939e14354a96fb8bfabd3c103d9d8f6de6c2...ed35e1c4b003795de84ba942f6965fa269e866b3

### AI 总结重点(源码 diff 为据)
- **软切分调度器约束放宽:删除 README 里 "hami-vnpu-core 只支持 HAMi 调度器" 的 Note 2**。旧 README 明写两条限制(ARM + HAMi-scheduler-only),新版只留 ARM 一条;并新增独立的 Volcano 部署文档,声明 hami-core 软切分需 Volcano ≥ 1.16(硬切分 ≥ 1.14)。含义:软切分能力路径从单一 HAMi scheduler 扩到 Volcano `deviceshare` 的 HAMi mode。注意:这是**文档层证据**,本仓本次未见对应 Go 代码 hunk,实际调度逻辑在 HAMi/volcano 侧。

  <details><summary>代码依据 README.md / docs/volcano.md</summary>

  ```diff
  - **Note 1:** `hami-vnpu-core` currently only supports ARM platforms.
  - **Note 2:** `hami-vnpu-core` currently only supports HAMi scheduler.
  + **Note:** `hami-vnpu-core` currently only supports ARM platforms.
  ```
  ```diff
  + # Deploy & Use with Volcano
  + ... via Volcano's `HAMi mode` `deviceshare` plugin.
  + - **Volcano**: ≥ 1.14 (≥ 1.16 required for `hami-core` soft slicing)
  ```
  </details>

- **移除 chart 内置的 vNPU Prometheus 监控集成**。删掉 `templates/vnpu-monitor-integration.yaml`(受 `.Values.vnpuMonitor.enabled` 守卫的 Service/ServiceMonitor/PrometheusRule,含 `kantaloupe_gpu_*` 记录规则)、根目录独立清单 `ascend-vnpu-monitor-integration.yaml`,并从 values.yaml 删掉整个 `vnpuMonitor:` 配置块。chart README 的 "vNPU Monitor Integration" 段改写为 "Monitoring":插件在 hami-vnpu-core 模式仍暴露 `:9395/metrics`,但 ServiceMonitor/PrometheusRule/告警规则的接线"超出本 chart 范围,用户自行对接"。含义:能力(指标端点)保留,打包的开箱监控被砍,降耦合但增加用户接入成本。

  <details><summary>代码依据 charts/ascend-device-plugin/values.yaml (-25) 与 README.md</summary>

  ```diff
  -vnpuMonitor:
  -  enabled: false
  -  service:
  -    name: hami-ascend-device-plugin-metrics
  -  serviceMonitor:
  -    create: true
  -    ...
  -  prometheusRule:
  -    create: true
  -    ...
  ```
  ```diff
  -## vNPU Monitor Integration
  -The chart can also create the resources from `ascend-vnpu-monitor-integration.yaml`.
  +## Monitoring
  +In `hami-vnpu-core` (soft slicing) mode, the device plugin exposes Prometheus-format
  +metrics on `:9395/metrics` ... Wiring this up ... is outside the scope of this chart
  ```
  </details>

- **文档明确软切分的注解开关与回退语义**。新增 docs/hami.md 记录:仅当 Pod 带注解 `huawei.com/vnpu-mode: hami-core` 时,插件才走软切分(挂载 `libvnpu`/hami-vnpu-core + 环境变量);不带注解的任务仍走原有虚拟化模板 vNPU(`ASCEND_VNPU_SPECS`),因此在只暴露软切分能力的节点上这类 Pod 可能长期 Pending。并给出版本门槛:HAMi ≥ 2.7.0(模板硬切分)、≥ 2.9.0(hami-core 软切分),均需 `devices.ascend.enabled: true`。

  <details><summary>代码依据 docs/hami.md (added +174)</summary>

  ```diff
  + The device plugin applies **soft slicing** ... **only** when the Pod sets
  + `huawei.com/vnpu-mode: hami-core`. Pods **without** this annotation still follow
  + the **original vNPU** path (virtualization templates and `ASCEND_VNPU_SPECS`),
  + so on nodes that only expose `hami-vnpu-core` soft-slicing capacity, such Pods
  + may stay **Pending** indefinitely.
  ```
  </details>

- CI 加固:ci.yml 增加 `concurrency`(同 ref 取消进行中)与最小 `permissions`(contents: read / packages: write);镜像 tag v1.3.0 → v1.4.0(README/values/Chart.yaml/ascend-device-plugin.yaml 同步)。属工程约束,非能力变更。

### 后续发展方向 [AI]
- 软切分正在向"多调度器"收敛:文档已把 hami-vnpu-core 接入 Volcano deviceshare(HAMi mode),下一步观察点是 volcano-vgpu-device-plugin / HAMi 主仓是否落对应 Ascend hami-core 分支代码。证据只覆盖 ascend-device-plugin 的文档与 chart,未见调度器侧代码 hunk。
- 监控从"开箱集成"退为"暴露端点、接线自理",说明团队在收窄 chart 责任边界(避免与用户既有 Prometheus 栈/HAMi 主 chart 冲突)。证据只覆盖 chart/values 删除,未见指标本身的 exporter 代码变化。

## Project-HAMi/HAMi: 9f2c88da -> 96cc5faa
- 比较: 9f2c88da -> 96cc5faa | ahead=5 | files=6 | Release: v2.9.0
- 本期仅安全流程与 CI:SECURITY-INSIGHTS.yml 声明启用 GitHub 原生 secret scanning(push protection),3 个 release/scan workflow 的 `docker/login-action` v4.4.0 → v4.5.0。**无 vGPU/vNPU 能力改动**,不计入"当日重要改变"。 https://github.com/Project-HAMi/HAMi/pull/2113

## 本期无实质改动(折叠)
<details><summary>EMPTY / 非能力 repo</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
- Project-HAMi/HAMi — 仅安全元数据 + CI bump(见上,非能力)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=96cc5faa3404fbb45a41d69fdab44bb1267c1950 branch=master release=v2.9.0 scanned=2026-07-26 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a branch=main release=— scanned=2026-07-26 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-26 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ed35e1c4b003795de84ba942f6965fa269e866b3 branch=main release=— scanned=2026-07-26 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-26 -->
