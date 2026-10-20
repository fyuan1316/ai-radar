# NVIDIA 算力栈 diff 雷达 2026-10-21

## 摘要
- nvidia-container-toolkit 修了一个 IMEX 通道解析 bug:`NVIDIA_IMEX_CHANNELS=none` 原先会被误读成"请求全部 IMEX 通道",现在正确当作"不请求任何通道"。影响 GB200/NVLink 多节点 IMEX 域的容器注入正确性。
- KAI-Scheduler 本日 3 条提交全是 **test/CI/docs**,无生产代码行为变化;但新增的 kwok 规模测试(混合分片饱和,500 节点/20000 pod)透露其工程重心仍在 **GPU 分片(fractioning)的大规模调度性能验证**。
- 其余 7 个 repo 本日无实质改动(仅保锚点)。

## 当日重要改变
- 无(本日改动未命中弃用/API-CRD/架构方向/版本跨档/新 package 信号)

## NVIDIA/nvidia-container-toolkit: 3e112b4a -> 44f1c6ef
- 比较: ahead=2 | files=3 | Release: v1.20.1(未跨档)
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/3e112b4af299bf72a1b23193b4f5c3321475dd6d...44f1c6ef98c9f82ee53c6018086a40b436260f9e

### AI 总结重点(源码 diff 为据)
- **IMEX 通道"none"语义修正**:`CUDA.imexChannelsFromEnvVar()` 的提前返回条件从 `len==1 && [0]=="all"` 扩展为 `len==1 && ([0]=="all" || [0]=="")`,即单个空字符串 ID 现在与 `"all"` 一样直接 `return nil`(不请求任何通道)。根因见新增注释:`NVIDIA_IMEX_CHANNELS=none` 经 `devicesFromEnvvars` 解析后回来是"单个空 ID",而一个空 ID 继续往下走到 `GetSpec` 会被当成"没有指定 ID",在 CDI 语义里"某 mode 不带任何 id"= 请求该 mode 的**全部**设备——于是 `none` 反而被放大成"全部 IMEX 通道"。此补丁在源头把空 ID 截掉,`none`/空值/`none,3` 统一归为"零通道"。这是 GB200 等 NVLink 多节点场景下 IMEX 域设备注入的正确性修复。commit:Do not read NVIDIA_IMEX_CHANNELS=none as a request for every channel
  <details><summary>代码依据 internal/config/image/cuda_image.go</summary>

  ```diff
   func (i CUDA) imexChannelsFromEnvVar() []string {
   	imexChannels := i.devicesFromEnvvars(EnvVarNvidiaImexChannels)
  -	if len(imexChannels) == 1 && imexChannels[0] == "all" {
  +	// "all" is what a legacy image defaults to, and "none" comes back as a single
  +	// empty ID. Neither names a channel, and an empty ID would reach GetSpec as no
  +	// ID at all, which it reads as a request for every channel.
  +	if len(imexChannels) == 1 && (imexChannels[0] == "all" || imexChannels[0] == "") {
   		return nil
   	}
   	return imexChannels
   }
  ```
  </details>
- 另两处改动(`cdi_test.go` +50、`cuda_image_test.go` +18)为上述修复的回归用例:新增 `TestImexDeviceRequests`(覆盖 `none`/空值→零设备)、CDI 层 `an empty id is dropped and leaves the mode unqualified`、以及 `none wins over a channel listed beside it`(`none,3` 仍判零通道)。纯测试,无生产含义。

### 后续发展方向 [AI]
- 该修复确认 IMEX(多节点 NVLink 内存交换通道)的 env→CDI 设备请求链路是 container-toolkit 当前在打磨的正确性热点:一个空 ID 在 CDI "mode 无 id = 全选"约定下会被静默放大。证据只覆盖 `imexChannelsFromEnvVar` 与其测试,未见 `GetSpec`/CDI spec 生成侧改动,不能断定该"空 id = 全选"约定本身被改,仅是入口做了防御性收窄。

## kai-scheduler/KAI-Scheduler: 337b49e0 -> 9f621776
- 比较: ahead=3 | files=10 | Release: v0.16.12(未跨档)
- https://github.com/kai-scheduler/KAI-Scheduler/compare/337b49e0f60816b59d9014d99d71dc1f9e44020c...9f621776ee65ebdf8b2ef9d36093946292c251e7

### AI 总结重点(源码 diff 为据)
- **本期 3 条提交无生产代码变化**,全部落在 test/CI/docs,逐条:
  1. `test(scheduler): add mixed fractions saturation scale test (#2383)`——新增 `test/e2e/scale/kwok_fraction_scenarios.go`(+406),构造多档分片队列(每 pod 请求 `1/fractionsPerGPU` 显存,默认 GPU 显存 81920 MiB),用 kwok 模拟到 500 节点/20000 pod 的"混合分片饱和"场景,产出 `allocation_seconds`/`scheduling_seconds`/`bind_lag_p50/p95/max` 等指标。配套 `kwok_stage.go` 新增一个关键 stage:kwok 不跑容器,于是用 Stage 补丁模拟 KAI 的 resource-reservation 容器——给预留 pod 打上 `run.ai/reserve_for_gpu_index` 注解,否则绑定会一直等一个永不到来的注解。
  2. `fix(ci): only mark a release as latest when it is the highest version (#2460)`——release-publish 流水线改为:对已发布 release(非 tag)按 semver 排序比对,仅当本次版本是最高版本时才 `gh release create --latest=true`,避免老分支补丁把 latest 标志从更高 minor 抢走。
  3. `docs(docs): note device plugin replicas setting is not supported (#2461)`——文档声明 KAI 不支持 NVIDIA device plugin 的 `replicas`(time-slicing 副本)设置,让用户改用 KAI 自己的 `global.gpuSharingMode`。
  <details><summary>代码依据 test/e2e/scale/kwok_stage.go(reservation 注解 stage)</summary>

  ```diff
  +	reservationGpuIndexAnnotation = "run.ai/reserve_for_gpu_index"
  ...
  +// createReservationGpuIndexStage stands in for the KAI resource-reservation container, which writes the reserved GPU
  +// index annotation on its own pod. KWOK runs no containers, so without it binding waits for an annotation that never arrives.
  ```
  </details>

### 后续发展方向 [AI]
- 规模测试新增"混合分片饱和"用例(allocation vs scheduling 分别计时、显式追 bind_lag 分位数),指向 KAI 当前把 **GPU 分片在高密度(单 GPU 多档分片、2 万 pod)下的分配/绑定延迟**作为核心性能回归指标。结合昨日 gpu-fractioning 子 chart 脱钩,KAI 软切分路线在"能力拆分 + 规模化验证"两头同时推进。证据仅覆盖 e2e 规模测试框架与 kwok stage,未见调度器生产代码(allocate/bind)本期改动,不能据此断定调度算法有变。
- `run.ai/reserve_for_gpu_index` 注解暴露了 KAI 分片绑定的内部机制:预留由一个独立 resource-reservation 容器写回"占了哪块物理 GPU index"的注解,binder 据此完成绑定。对我们产品的启示:若自研分片调度器,需注意这类"预留→回写物理索引→绑定"的两段式时序,kwok 等无容器模拟器下必须显式补这一步。证据来自测试桩注释,非生产实现本身。

## 本期无实质改动(折叠)
<details><summary>7 个 repo 本日仅保锚点,无新提交/实质改动</summary>

- NVIDIA/gpu-operator(无新提交)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=dbb11e85129b601afe9fb502ac25b062ad094abd branch=main release=v26.7.2 scanned=2026-10-21 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=44f1c6ef98c9f82ee53c6018086a40b436260f9e branch=main release=v1.20.1 scanned=2026-10-21 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d6d82abedb448b8f67992f1b59c86f163df24772 branch=main release=— scanned=2026-10-21 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-21 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=63e98d305bb66cb9f2a07a0669661329d320ee3f branch=main release=v0.5.1 scanned=2026-10-21 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-21 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-21 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-21 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=9f621776ee65ebdf8b2ef9d36093946292c251e7 branch=main release=v0.16.12 scanned=2026-10-21 -->
</content>
</invoke>
