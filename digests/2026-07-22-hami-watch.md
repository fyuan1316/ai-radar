# HAMi diff 雷达 2026-07-22

## 摘要
- **HAMi 主仓做了一处真正的调度稳固性修复**:MIG 模板/实例索引过去直接从 Pod 上**用户可控的 device UUID 注解**解析后**无校验就下标访问** `MigUsage.UsageList[Instance]`,越界即 scheduler panic;本期补齐 err 检查 + 三重边界/一致性校验(#2088)。
- **Helm 新增 `manageNamespaceSelector` 开关**(#2091):允许在 AKS 等托管平台上让 chart 不再渲染/管理 webhook 的 `namespaceSelector`,规避 server-side apply 的字段属主冲突。
- 其余为清扫类:删无用 `ParseConfig` 空桩 + 死脚本(#2098)、删无引用图片/pptx(#2097/#2099)、Go 工具链 1.26.2→1.26.5(#2092)、新增 OpenSSF SECURITY-INSIGHTS.yml(#2093)。HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI 四仓 EMPTY。

## 当日重要改变
- **Project-HAMi/HAMi [弃用/移除] 三个 remove 提交均为资产/死代码清扫,非能力删除**:#2098 删掉 `awsneuron`/`amd` 两个 device 里从不做事的 `ParseConfig(fs *flag.FlagSet){}` 空桩与 boilerplate 模板;#2097/#2099 删 imgs/ 下 pptx 与无引用 png。无 CRD 字段/flag 被删,不影响对外契约。 https://github.com/Project-HAMi/HAMi/pull/2098
- 说明:本期无 `*_types.go`/`config/crd`/`docs/proposals` 路径命中,无 API/CRD/架构提案级形式信号;最实质的代码改动(MIG 越界修复)归入下方仓段落。

## Project-HAMi/HAMi: 53da8247 -> 044a749f
- 比较: 53da8247b1c2868b9b70de8fbf5462542950375b -> 044a749f | ahead=8 | files=28 | Release: v2.9.0
- 比较视图: https://github.com/Project-HAMi/HAMi/compare/53da8247b1c2868b9b70de8fbf5462542950375b...044a749f979d76dd2cb30b9c63f9f714185b2c2a

### AI 总结重点(源码 diff 为据)
- **MIG 使用态回填从"信任用户注解"改为"全链路校验后再下标"**(#2088,`pkg/scheduler/scheduler.go` `getNodesUsage`)。`ExtractMigTemplatesFromUUID(udevice.UUID)` 解析的是 Pod 上**用户可写的设备 UUID 注解**;改前用 `_` 吞掉 error,并直接 `MigUsage.UsageList[Instance].InUse = true` 下标写入。改后:①解析 error 直接 `continue`;②`tmpIdx` 对 `d.Device.MigTemplate` 长度做上下界校验;③当已有 UsageList 时校验 `tmpIdx` 与 `MigUsage.Index` 一致(不一致 continue);④`instanceIdx` 对 `UsageList` 长度做上下界校验。这把一个"构造异常 UUID 注解即可让 scheduler 数组越界 panic"的面收敛成记日志跳过。**每条结论后必须贴出代码依据**:
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -   tmpIdx, Instance, _ := device.ExtractMigTemplatesFromUUID(udevice.UUID)
  +   tmpIdx, instanceIdx, err := device.ExtractMigTemplatesFromUUID(udevice.UUID)
  +   if err != nil {
  +       klog.Errorf("failed to extract mig templates from uuid %s: %v", udevice.UUID, err)
  +       continue
  +   }
  +   if tmpIdx < 0 || tmpIdx >= len(d.Device.MigTemplate) {
  +       klog.Errorf("invalid mig template index %d in uuid %s (templates length: %d)", tmpIdx, udevice.UUID, len(d.Device.MigTemplate))
  +       continue
  +   }
      if len(d.Device.MigUsage.UsageList) == 0 {
          device.PlatternMIG(&d.Device.MigUsage, d.Device.MigTemplate, tmpIdx)
  +   } else if tmpIdx != int(d.Device.MigUsage.Index) {
  +       klog.Errorf("mig template index mismatch in uuid %s: expected %d, got %d", udevice.UUID, d.Device.MigUsage.Index, tmpIdx)
  +       continue
  +   }
  +   if instanceIdx < 0 || instanceIdx >= len(d.Device.MigUsage.UsageList) {
  +       klog.Errorf("invalid mig instance in uuid %s", udevice.UUID)
  +       continue
      }
  -   d.Device.MigUsage.UsageList[Instance].InUse = true
  +   d.Device.MigUsage.UsageList[instanceIdx].InUse = true
  ```
  </details>

- **Helm 新增 `scheduler.admissionWebhook`(values 层)`manageNamespaceSelector` 布尔开关,默认 true**(#2091,`charts/hami/values.yaml`)。语义:默认在标准 K8s 上仍由 chart 渲染并托管 webhook 的 `namespaceSelector`;在 AKS 等"平台自己会 mutate 并拥有 `namespaceSelector`"的托管环境置 false,避免 server-side apply 的字段 ownership 冲突。这是把"是否交出 namespaceSelector 属主权"做成可配置,而非改默认行为。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
  +    # manageNamespaceSelector controls whether the chart renders and manages the webhook's
  +    # namespaceSelector field. Keep it true on standard Kubernetes clusters.
  +    # Set it to false on managed platforms (e.g. AKS) where the platform mutates and owns
  +    # the namespaceSelector field, to avoid server-side apply ownership conflicts.
  +    manageNamespaceSelector: true
       # namespaceSelector controls which namespaces the webhook will be applied to.
  ```
  </details>

- **删除 `amd` / `awsneuron` 两个后端里空的 `ParseConfig(fs *flag.FlagSet)` 桩函数及 `flag` import**(#2098,`pkg/device/amd/device.go`、`pkg/device/awsneuron/device.go`)。两个函数体本就为空、无人调用,属设备后端注册接口收敛后的死代码清理,不改变 AMD/AWS Neuron 设备的 admission/分配行为。
  <details><summary>代码依据 pkg/device/amd/device.go(awsneuron 同形)</summary>

  ```diff
   import (
  -	"flag"
   	"fmt"
   	"slices"
   )
  -func (dev *AMDDevices) CommonWord() string { ... }
  -func ParseConfig(fs *flag.FlagSet) {
  -}
  ```
  </details>

- **新增 `SECURITY-INSIGHTS.yml`(OpenSSF Security Insights 2.0.0)**(#2093)+ **Go 工具链 1.26.2→1.26.5**(#2092,`version.mk`、`hack/build.sh`)。前者是供应链安全元数据(声明漏洞报告走 GitHub Security Advisories、列 core-team/仓库清单),CNCF Sandbox 项目常见的合规动作;后者纯补丁位工具链升级。
  <details><summary>代码依据 version.mk</summary>

  ```diff
  -GOLANG_IMAGE=golang:1.26.2-bookworm
  +GOLANG_IMAGE=golang:1.26.5-bookworm
  ```
  </details>

### 后续发展方向 [AI]
- **调度器把"用户可控注解"当不可信输入加固的趋势在延续**:#2088 与近期(参考前几期 KAI/device-plugin 那类"用户可控字段打崩控制面")同源——凡从 Pod annotation 解析出的索引/数量,HAMi 正逐个补边界校验。可预期后续对其它 `Extract*FromUUID` / 注解解析路径做同样收敛。证据只覆盖 MIG UUID 这一条路径(scheduler.go getNodesUsage),未见对 vGPU/vNPU 其它注解解析的同批加固。
- **Helm 面向托管 K8s(AKS/EKS 类)做部署适配**:`manageNamespaceSelector` 说明 HAMi 在正视"平台托管字段属主权 vs GitOps/SSA"这类真实落地摩擦。证据仅 values.yaml 注释与开关本身,webhook.yaml 模板条件渲染的具体实现未在本期 patch 节选内(仅 2 行改动未入 top hunk),未逐行确认。
- 其余提交(删图/删死码/Go bump/安全元数据)是 v2.9.0 发布后的仓库卫生与合规打扫,不含能力/架构信号。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=044a749f979d76dd2cb30b9c63f9f714185b2c2a branch=master release=v2.9.0 scanned=2026-07-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=06e698079335cffd0009f3c119bd95b012600ae5 branch=main release=— scanned=2026-07-22 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-22 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=f062939e14354a96fb8bfabd3c103d9d8f6de6c2 branch=main release=— scanned=2026-07-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-22 -->
