# 昇腾算力栈 diff 雷达 2026-10-21

## 摘要
- **npu-dra-plugin 落两份 DRA 架构设计文档**(均 `doc/*.md`,尚无 .go 实现):① 软切分 vNPU **算力优先级抢占**——新增 `priority.npu.huawei.com` DeviceClass,把"高优先级"编码进类名,端到端透传到 `npu_info.config` 新键 `vnpu_priority`,抢占下沉 vCANN 时间片层(无 Pod 驱逐);② DRA driver **内嵌 vNPU 指标**——driver 进程内置 Prometheus `/metrics`(:8082),暴露与 vNPU 仓 `xpu-exporter` 同名同 label 的 6 个指标,vNPU 仓零改动。
- 指标设计顺带夹带一处**硬切分缺陷修复方向**:硬切分 vNPU 生命周期从"委托 Ascend Docker Runtime 启动时创建"改为"driver 经 `pkg/dcmi` 直管(CreateVDevice/DestroyVDevice)",消除 UnprepareResources 的 no-op + 手工 `npu-smi set -t destroy-vnpu` 清残留。
- mind-cluster 本期 4 commit 仅为 26.2.0 镜像发布说明 + docs 链接修改,无 `component/` 代码改动;其余 7 个 openFuyao 仓(npu-operator / vNPU / npu-container-toolkit / npu-driver-installer 等)均无新提交。

## 当日重要改变
- npu-dra-plugin [架构方向] 新增软切分 vNPU 算力优先级抢占 DRA 设计:`priority.npu.huawei.com` DeviceClass + `npu_info.config` 新键 `vnpu_priority`,抢占在 vCANN 时间片层即时生效、不驱逐 Pod。证据 doc/npu-soft-vnpu-priority-preemption-design.md(设计文档,未见 .go) https://gitcode.com/openFuyao/npu-dra-plugin/commit/031dc691f082fdb90610f77eab3bcf91ad8e9aa3
- npu-dra-plugin [架构方向] 新增 DRA driver 内嵌 vNPU 指标采集设计:driver 进程内置 Prometheus /metrics(:8082),6 个指标与 vNPU xpu-exporter 同名同 label,flag 控制、默认关闭。证据 doc/npu-dra-driver-metrics-design.md 关联 issue https://gitcode.com/openFuyao/npu-dra-plugin/issues/35

## npu-dra-plugin: a091c786 -> 031dc691
- 比较: https://gitcode.com/openFuyao/npu-dra-plugin/compare/a091c78614ecd0c00412b15aa8a0d2ecd717ba39...031dc691f082fdb90610f77eab3bcf91ad8e9aa3 | tag: v26.6.0 | commits=3 | truncated=false
- 本期两次提交均为**设计文档(`doc/*.md`,共 +551 行)**,无 .go 变更。下面按文档内对代码的具体改造计划做符号级解读,并标注"设计阶段、未见实现 diff"。

### AI 总结重点(源码 diff 为据)

- **[优先级抢占] 优先级声明通道选 DeviceClass 名前缀,而非 Pod/claim annotation**——新增 `priority.npu.huawei.com`,与既有 `elastic./fixed./best-effort.npu.huawei.com` 前缀编码策略完全同构。理由:DRA 下 DeviceClass 是**唯一参与 kube-scheduler 设备选择的声明通道**,优先级必须对调度期可见才能解决"高优先级在线 + 任意策略离线同卡混部"的放置问题;且全仓无 `pod.Annotations` 读取先例。annotation 覆盖通道仅在 `extractPriority` 处预留、本期不做。

  <details><summary>代码依据 doc/npu-soft-vnpu-priority-preemption-design.md §3.2/§2.3</summary>

  ```markdown
  ### 3.2 优先级声明方式
  新增 DeviceClass `priority.npu.huawei.com`,优先级由类名前缀编码:
  `priority.` → 高优先级(1);既有 elastic./fixed./best-effort. 及其他类 → 普通服务(0)。
  与调度策略的类名前缀编码(extractPolicy,state.go L361)完全同构。
  1. 调度期可见:混部放置由 DeviceClass CEL 选择器实现,DeviceClass 是 DRA 下唯一参与设备选择的声明通道;
  (差距分析 §2.3-1:DRA 下无 Pod annotation 读取先例(全仓无 pod.Annotations 代码))
  若未来需要声明级覆盖通道,可在 extractPriority 处扩展 claim annotation 解析,架构已预留。
  ```
  </details>

- **[优先级抢占] 端到端传递链新增一条平行于既有 policy 的 priority 分支**:`extractPriority`(DeviceClassName 前缀 `priority.`→1 否则 0)→ `ApplyParameters.Priority` → `CreateVNPUParams.Priority` → `SoftManager.CreateVNPU` → `writeConfigFile` 在既有 6 项(physical-npu-id / virtual-npu-id / aicore-quota / memory-quota / shm-id / scheduling-policy)后**追加第 7 项 `vnpu_priority=<0|1>`**。即 K8s 层只做"声明契约 + 透传",不改 kube-scheduler 原生 DRA 排序算法,抢占完全下沉到容器内 vCANN 劫持库(`libvruntime.so`)的 AICore 时间片调度。

  <details><summary>代码依据 §3.1 端到端数据流 + §2.1 writeConfigFile 现状</summary>

  ```markdown
  → kubeletplugin:extractPriority(DeviceClassName 前缀 "priority." → 1,否则 0)
  → ApplyParameters.Priority → CreateVNPUParams.Priority
  → SoftManager.CreateVNPU:低优先级归属记账(不翻转卡级属性)
  → writeConfigFile:npu_info.config 追加 vnpu_priority=<0|1>
     (aicore-quota / scheduling-policy 仍按声明值写入)
  // §2.1 当前 writeConfigFile(soft_manager.go L307-331)仅 6 项
  ```
  </details>

- **[优先级抢占] vCANN 运行时契约:`vnpu_priority=1` 时所有运行时配额/策略字段失效**——vCANN 将 `core_limit_quota/core_quota_timeslice/core_cur_timeslice` 置 0、`sched_policy` 置 3,高优先级 vNPU 有任务时优先占满 AICore,**同卡所有低优先级 vNPU(含 fixed-share 保底配额)均可被抢占**;高优先级空闲时低优先级按各自模式恢复。显存(memory-quota)为硬隔离、不可抢占,保持现状。依赖 `third_party/ubs-virt` 子模块升级到带 `vnpu_priority` 能力的 master 并重编。旧 vCANN 节点遇未知键忽略,退化为按声明配额运行的普通 vNPU(灰度兼容,契约标"待验证")。

  <details><summary>代码依据 §3.4 vCANN 运行时契约 + §2.3-6 子模块落后</summary>

  ```markdown
  | 5 | 高优先级默认值 | vnpu_priority=1 时其他调度策略全部失效:
      core_limit_quota/core_quota_timeslice/core_cur_timeslice 置 0、sched_policy 置 3;
      npu_info.config 中的 aicore-quota/scheduling-policy 取值被忽略 | 已确认 |
  | 4 | 抢占语义 | 所有低优先级(vnpu_priority=0)vNPU 均可被高优先级抢占(含 fixed-share 保底配额) | 已确认 |
  // §2.3-6:third_party/ubs-virt 当前代码不含 vnpu_priority 能力,需升级 master 最新并重编 libvruntime.so
  ```
  </details>

- **[优先级抢占] 高优先级对"卡级策略翻转"透明,绕开 CEL 同卡同策略硬约束**:既有 `getNextVNPUID`(soft_manager.go L232-254)在卡从全闲到首次分配时按 claim 策略翻转 ResourceSlice 属性,且三个 policy 类 CEL 都 `require attributes.schedulingPolicy == <policy>`,导致高优先级在线 Pod 无法与 best-effort 离线 Pod 同卡。新设计让 `priority.` 类的 CEL **只匹配 `vnpuMode == "soft"`、不匹配 schedulingPolicy**,且高优先级 vNPU 不参与卡级策略翻转;`softVNPURef` JSON(soft_manager.go L348-356)需补 priority 字段以支持重启恢复优先级归属。

  <details><summary>代码依据 §2.2 既有传递链 #3/#5 + §2.3-2/3/5</summary>

  ```markdown
  | 3 | 调度期匹配 | DeviceClass CEL:elastic./fixed./best-effort. 均要求 attributes.schedulingPolicy==<policy>
      | 同卡只允许同策略 claim 共存(CEL 硬约束) |
  | 5 | 卡级策略动态翻转 | getNextVNPUID(soft_manager.go L232-254)...notifyPolicyChange L217 → driver.go updateDevices L59 |
  // §2.3-2 CEL 阻止跨策略同卡混部;§2.3-5 softVNPURef JSON 无 priority 字段,重启后无法恢复
  ```
  </details>

- **[可观测] DRA driver 内嵌 vNPU 指标,数据面全复用 driver 已有状态、vNPU 仓零改动**:driver(`ascend-npu-dra-kubeletplugin`)进程内置 metrics server(`/metrics`,:8082,HTTP/HTTPS + 限流),暴露 6 个 Gauge——`npu_exporter_version_info / xpu_vnpu_mode / xpu_vnpu_soft_scheduler_policy / xpu_vnpu_mem_util / xpu_vnpu_num / xpu_vnpu_pod_num`,与 vNPU 仓 `xpu-exporter` **同名、同 label、同语义**(Grafana 看板/告警直接复用)。`--metrics-port` 启动参数控制,默认关闭时不改任何现有行为;双定时器(后台 60s 刷新缓存 + scrape 缓存未命中同步兜底),与 DRA gRPC(dra.sock)完全隔离、metrics 异常只打日志。数据取自 `EnumerateDevices` 内部状态 + checkpoint PreparedClaims + DCMI `DcGetDevProcessInfo`。

  <details><summary>代码依据 doc/npu-dra-driver-metrics-design.md §1.2/§2/§3</summary>

  ```markdown
  1. DRA driver 内嵌 Prometheus 指标服务,暴露与 vNPU xpu-exporter 同名、同 label、同语义的 6 个指标。
  2. 指标能力通过启动参数控制开启/关闭,默认关闭时不改变 driver 任何现有行为。
  3. 数据面全部复用 driver 已有状态与能力...vNPU 仓(device plugin、xpu-exporter)零改动。
  // npu_uuid 取物理 NPU 的 dieID(DCMI DcGetDieID(VDIE));vnpu_id 格式 "{dieID}-{vNPU ID}"
  ```
  </details>

- **[缺陷修复/架构方向] 硬切分 vNPU 生命周期改由 driver 经 DCMI 直管(为指标 `vnpu_id` 精确化)**:现状硬切分委托 Ascend Docker Runtime 在容器启动时创建 vNPU,ID 后行且无回传通道。新设计让 driver 经 `pkg/dcmi`(dcmi.go:371-408 已封装)直管——Prepare 调 `dcmi_create_vdevice`(HDK 返回真实 `vdev_id` + PCIe BDF)、Unprepare 调 `dcmi_set_destroy_vdevice` 按 ID 销毁(替换现有 no-op + 手工 `npu-smi set -t destroy-vnpu` 清残留)、RecoverState 幂等恢复并枚举既有 vdevice 防 ID 冲突;`--hard-vnpu-manager=dcmi|runtime`(默认 dcmi)可回退。另 checkpoint `PreparedDevice` 新增 `PodUID/PodName/ContainerNames/CoreLimitMi` 字段(版本 +1,旧格式兼容读),RBAC ClusterRole 新增 `pods get`(反查 container name)。

  <details><summary>代码依据 §5.4 硬切分生命周期直管 + §5.2 checkpoint 字段</summary>

  ```markdown
  本设计改为 driver 经 pkg/dcmi 直管硬切分 vNPU 生命周期
  (CreateVDevice 由 HDK 返回真实 vdev_id 与 PCIe BDF,DestroyVDevice 按 ID 销毁,pkg/dcmi/dcmi.go:371-408 已封装):
  - Unprepare:dcmi_set_destroy_vdevice 按 ID 销毁(替换现有 no-op + 手工 npu-smi set -t destroy-vnpu 清理残留的告警)。
  - 回退:--hard-vnpu-manager=dcmi|runtime(默认 dcmi)
  // §5.2:checkpoint PreparedDevice 新增 PodUID/PodName/ContainerNames/CoreLimitMi(版本号 +1,旧格式兼容读取);RBAC 新增 pods get
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾 DRA 路径正在从"能分配"走向"能混部 + 能观测",对标 NVIDIA DRA 的 QoS/metrics 成熟度**:优先级抢占把"在线/离线混部同卡保 QoS"做进 DRA 声明契约,且刻意不碰 kube-scheduler 排序、把抢占下沉到 vCANN 时间片(无驱逐),是最小侵入的工程选型。但**当前仅 doc/ 设计文档,extractPriority / CreateVNPUParams.Priority / writeConfigFile 第 7 键 / priority DeviceClass CEL 均未落 .go**,且核心依赖 `third_party/ubs-virt` 子模块升级(契约多项标"待验证/待确认"),能否如期落地取决于 vCANN 侧 `vnpu_priority` 键名与抢占语义最终确认。证据边界:只读到设计文档,未见实现 diff,也未见 ubs-virt 子模块 bump。
- **指标设计暴露的真实工程动作是"硬切分生命周期收归 driver"**:相比"再加一套 exporter",driver 经 DCMI 直管 vNPU(create/destroy/recover)才是解决"委托 runtime 导致 ID 后行 + Unprepare 残留"的根因修复,指标 `vnpu_id` 精确化只是其受益项。对我们产品的启示:多厂商纳管做 DRA 时,vNPU 生命周期应由 driver(kubeletplugin)自身经厂商 SDK 闭环管理、而非委托容器运行时,否则拿不到稳定设备 ID、也难做幂等恢复与可观测;且指标契约与既有 device-plugin exporter 对齐(同名同 label)能让两条链路共用一套 Grafana/告警,是降低迁移成本的务实做法。证据仅覆盖设计文档对代码位置(pkg/dcmi、state.go、soft_manager.go)的引用,未见实际改动。

## 本期无实质改动(折叠)
<details><summary>mind-cluster(仅镜像/文档)+ 7 个仓无新提交</summary>

- mind-cluster:本期 4 commit 仅「26.2.0 版本镜像发布,镜像概述更新」+「docs 修改参考文档链接」,PATHPREFIX 限定的 component/ 下无代码改动,跳过正文保锚点。
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin:比较 base..HEAD 无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=2240d93db1810b0230b453db14d925f4d517ba71 tag=v26.2.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.6.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.6.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=npu-dra-plugin sha=031dc691f082fdb90610f77eab3bcf91ad8e9aa3 tag=v26.6.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=1.0.2 scanned=2026-10-21 -->
</content>
</invoke>
