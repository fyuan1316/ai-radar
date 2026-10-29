# 昇腾算力栈 diff 雷达 2026-10-30

## 摘要
- mind-cluster 当日主线是 **DRA 走向"兼容存量"**:新增 KEP-5004「DRA 扩展资源映射」落地——给 ascend-dra-driver 的两个 `DeviceClass` 挂上 `extendedResourceName`,让仍用 `resources.limits: huawei.com/Ascend910`(整卡)写法的旧任务**不改 YAML**即可被 DRA 调度器消化,等于把 device-plugin 时代的扩展资源申请路径接到了 DRA 后端;同时首次把 **Ascend950 分到通用名 `huawei.com/npu`、910 保留旧名 `huawei.com/Ascend910`**,透露新机型资源命名收敛方向。
- 配套加了**一道 Helm 安装期闸门**:ascend-device-plugin 与 ascend-dynamic-resource-allocation 同 release 同时启用会直接 `fail` 中止安装(两个 DaemonSet 在 NPU 节点上抢设备),把"两种设备接入方式互斥"从文档约定变成构建期硬约束。
- infer-operator 新增 `podautoscalers.mindcluster.huawei.com` CRD 并入 Helm 渲染/元数据链(推理副本自动伸缩)。其余 8 个 openFuyao 仓(npu-operator/container-toolkit/driver-installer/vNPU/node-provision/dra-plugin/volcano-ext/ub-network-device-plugin)当日空,无实质提交。

## 当日重要改变
- **mind-cluster [新能力] KEP-5004:用 extendedResourceName 把整卡申请接到 DRA** —— ascend-dra-driver.yaml 新增 `ascend910.ext.huawei.com` / `npu.ext.huawei.com` 两个 DeviceClass,CEL 选 `deviceKind=='physical-npu'`(未切分整卡)并按 chipName 分流,分别映射到扩展资源名 `huawei.com/Ascend910` 和 `huawei.com/npu`。证据:feat(dra) feb3c0bffc89e85ef74a3e3050b2c75581f4fb74,https://gitcode.com/Ascend/mind-cluster/commit/feb3c0bffc89e85ef74a3e3050b2c75581f4fb74
- **mind-cluster [API/CRD变更] DRA 与 device-plugin 互斥闸门** —— 新增 Helm 模板 `validate-mutex.yaml`,两组件同启则 `fail` 中止 install/upgrade。证据:04e7801f8db367d7d09a33c18fe5f790c3508c08,https://gitcode.com/Ascend/mind-cluster/commit/04e7801f8db367d7d09a33c18fe5f790c3508c08
- **mind-cluster [API/CRD变更] infer-operator 新增 podautoscalers CRD** —— dd289c740a3440a917f21014eefdb23624a2cd79,https://gitcode.com/Ascend/mind-cluster/commit/dd289c740a3440a917f21014eefdb23624a2cd79

## mind-cluster: de37936c -> 7a5f2e25
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/de37936c1bccda4f4b11516da296ac521dfe7aab...7a5f2e25e5afaeeed2eb669a6ffdb9dd9c1d62d3 | tag: v26.3.0-beta.1 | commits=8 | truncated=false

### AI 总结重点(源码 diff 为据)

- **KEP-5004 扩展资源映射:整卡申请不改存量 YAML 即走 DRA。** ascend-dra-driver 原本只有 `npu.huawei.com`(整卡)、`static-vnpu`、`dynamic-vnpu` 三类 DeviceClass,本次在 `dynamic-vnpu` 之后插入两个带 `extendedResourceName` 字段的新 DeviceClass:`ascend910.ext.huawei.com`(CEL 命中 `deviceKind=='physical-npu'` 且 chipName 以 `910`/`Ascend910` 开头)映射到扩展资源名 `huawei.com/Ascend910`,`npu.ext.huawei.com`(chipName 以 `Ascend950` 开头)映射到 `huawei.com/npu`。`extendedResourceName` 是 K8s 1.34 DRA 的 KEP-5004 能力——让仍用传统 `resources.limits.<扩展资源名>` 写法申请"未切分物理整卡"的 Pod,由 DRA 后端承接调度,而无需改写成 ResourceClaim。意味着从 device-plugin 迁 DRA 时整卡场景可平滑过渡,切分场景(static/dynamic-vnpu)才需显式 ResourceClaim。
  <details><summary>代码依据 component/ascend-dynamic-resource-allocation/build/ascend-dra-driver.yaml</summary>

  ```diff
  +apiVersion: resource.k8s.io/v1
  +kind: DeviceClass
  +metadata:
  +  name: ascend910.ext.huawei.com
  +spec:
  +  selectors:
  +  - cel:
  +      expression: >-
  +        device.driver == 'npu.huawei.com' &&
  +        device.attributes['npu.huawei.com'].deviceKind == 'physical-npu' &&
  +        (device.attributes['npu.huawei.com'].chipName.startsWith('910') ||
  +         device.attributes['npu.huawei.com'].chipName.startsWith('Ascend910'))
  +  extendedResourceName: huawei.com/Ascend910
  +---
  +apiVersion: resource.k8s.io/v1
  +kind: DeviceClass
  +metadata:
  +  name: npu.ext.huawei.com
  +spec:
  +  selectors:
  +  - cel:
  +      expression: >-
  +        device.driver == 'npu.huawei.com' &&
  +        device.attributes['npu.huawei.com'].deviceKind == 'physical-npu' &&
  +        device.attributes['npu.huawei.com'].chipName.startsWith('Ascend950')
  +  extendedResourceName: huawei.com/npu
  ```
  </details>

- **机型资源命名收敛信号:950 走通用 `huawei.com/npu`,910 维持旧名。** 上面 CEL 的分流把 Ascend910 系(含裸 `910` 前缀)锚定到历史扩展资源名 `huawei.com/Ascend910`,而新一代 Ascend950 直接用机型无关的 `huawei.com/npu`。对消费侧的启示:存量 910 工作负载的资源名向后兼容不动,新机型推荐用通用名,避免再按型号硬编码。(证据仅覆盖这两类 DeviceClass 的 CEL 表达式,未见调度器/device-plugin 侧对这两个名字的消费代码。)

- **两个新 DeviceClass 被纳入 Helm 元数据链。** helm_tool.sh 的 `component_ascend-dynamic-resource-allocation()` 在已有三个 `add_helm_meta deviceclass`(npu/static-vnpu/dynamic-vnpu)后追加 `ascend910.ext.huawei.com` 与 `npu.ext.huawei.com`,保证上面 yaml 的新对象随 Helm 部署安装。
  <details><summary>代码依据 helm-deploy-tool/build/helm_tool.sh</summary>

  ```diff
       add_helm_meta deviceclass dynamic-vnpu.huawei.com
  +    add_helm_meta deviceclass ascend910.ext.huawei.com
  +    add_helm_meta deviceclass npu.ext.huawei.com
       add_helm_meta validatingadmissionpolicy resourceslices-policy-ascend-dra-driver
  ```
  </details>

- **device-plugin ↔ DRA 互斥变成安装期硬失败。** 新增 `validate-mutex.yaml` Helm 模板:若 `.Values["ascend-device-plugin"].enabled` 与 `.Values["ascend-dynamic-resource-allocation"].enabled` 同时为真,则 `fail`,在任何资源下发到集群前中止整个 install/upgrade。注释点明原因是两个 DaemonSet 会在 NPU 节点上争抢设备。values.yaml 同步加了互斥说明注释。这把此前只在文档里的约定提升为构建期闸门。
  <details><summary>代码依据 helm-deploy-tool/app/templates/validate-mutex.yaml (新增)</summary>

  ```diff
  +{{- if and (index .Values "ascend-device-plugin" "enabled") (index .Values "ascend-dynamic-resource-allocation" "enabled") }}
  +{{- fail "ascend-device-plugin and ascend-dynamic-resource-allocation are mutually exclusive and cannot be enabled at the same time. Please disable one of them in values.yaml and retry." }}
  +{{- end }}
  ```
  </details>

- **infer-operator 新增 podautoscalers CRD(推理副本自动伸缩)。** helm_tool.sh 的 `component_infer-operator()` 在 inferservices/inferservicesets/instancesets 后追加 `add_helm_meta_crds crd podautoscalers.mindcluster.huawei.com`,infer-operator-crds/values.yaml 的 `renderCrds` 同步新增 `podautoscalers` 渲染项。表明推理 operator 开始内建"按负载伸缩推理实例"的 CRD 原语(此前只有 service/serviceset/instanceset 三类)。
  <details><summary>代码依据 helm-deploy-tool/build/helm_tool.sh + infer-operator-crds/values.yaml</summary>

  ```diff
       add_helm_meta_crds crd instancesets.mindcluster.huawei.com
  +    add_helm_meta_crds crd podautoscalers.mindcluster.huawei.com
  ```
  ```diff
     instancesets: "yamls/default/CustomResourceDefinition-instancesets.mindcluster.huawei.com.yaml"
  +  podautoscalers: "yamls/default/CustomResourceDefinition-podautoscalers.mindcluster.huawei.com.yaml"
  ```
  </details>

- **dockerruntime"自定义映射挂载"本期仅文档。** commit `04625078` 只改了 `docs/zh/.../01_configuring_custom_mounted_content.md`(12 行),未见 ascend-docker-runtime 组件代码改动,故不展开能力研判。

### 后续发展方向 [AI]
- **DRA 的采用策略走"整卡兼容、切分显式"两条腿。** extendedResourceName 把整卡申请做成对存量透明的迁移路径,切分(static/dynamic-vnpu)仍需 ResourceClaim——证据是本次新增的两个 DeviceClass 只针对 `physical-npu`,未给 vnpu 类挂 extendedResourceName。对我们产品的启示:若要对标支持昇腾 DRA,需同时暴露"旧扩展资源名透传"与"ResourceClaim 切分"两套入口,且整卡迁移可做到用户 YAML 零改动。(证据仅覆盖 DeviceClass CEL + helm 元数据,未见 DRA 驱动 ResourceSlice 发布侧对 physical-npu 的属性填充代码。)
- **安装期互斥闸门说明 device-plugin 与 DRA 短期内是"二选一"而非共存。** 这意味着昇腾侧 DRA 尚不支持与 device-plugin 在同节点分工,迁移是整节点切换。对标时需注意灰度策略只能按节点池切,不能同节点并行两套。(证据:validate-mutex.yaml 的 `fail` 逻辑;未见是否有 per-node 粒度的放开计划。)
- **Ascend950 资源名收敛到 `huawei.com/npu`** 是机型无关化的早期信号,后续新机型大概率都挂通用名;产品侧资源名匹配逻辑不应再按 `Ascend9xx` 硬编码。(证据仅本次 CEL 分流,未见更多机型。)

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:当日无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=7a5f2e25e5afaeeed2eb669a6ffdb9dd9c1d62d3 tag=v26.3.0-beta.1 scanned=2026-10-30 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-10-30 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-10-30 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-10-30 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-10-30 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-30 -->
<!-- ANCHOR repo=npu-dra-plugin sha=32fc8e917d59a26904b8025f97bf6e3eddeb56d3 tag=v26.9.0 scanned=2026-10-30 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-30 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-10-30 -->
