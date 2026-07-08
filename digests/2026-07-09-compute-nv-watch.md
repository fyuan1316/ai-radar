# NVIDIA 算力栈 diff 雷达 2026-07-09

## 摘要
- **较昨日清淡:4 仓有新提交,但 3 仓低信号**。真正有料的是 nvidia-container-toolkit——一天积压 41 commit(files 被 API 截断到 300,走概览模式),主题里 **IMEX channel 校验进 CDI/JIT-CDI 模式**、**MIG 设备注入 `/dev/dri*` 节点**、**新增 `disable-ipc-discoverer` feature flag** 三条最值得盯,IMEX 那条接续昨日 gpu-driver-container 的 NVLink5+/IMEX 硬件线。
- gpu-operator 仅 1 行改动:node 标签 reconciler 新增对 `nvidia.com/mig.capable` 变化的响应(MIG 能力翻转时触发重打标)。gpu-driver-container 是**例行驱动版本 rev**(580.167.08→580.173.02,CUDA base 13.2→13.3),无架构变化。
- KAI-Scheduler 本期只有测试基建重构:新增 `CreateDistributedBatchJob` helper,把 e2e 里"手搓 PodGroup + 逐 pod 建"统一为"建 batch/v1 Job + `kai.scheduler/batch-min-member` 注解让 podgrouper 生成 PodGroup",顺带暴露了 **elastic gang(MinMember < Parallelism)vs gang(MinMember == Parallelism)** 的语义。测试专属,但反映了 batch-job→podgroup 的产品路径。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [新能力] 一天并入 41 commit(概览模式,未逐 hunk),三条能力级信号:`Validate imex channels for CDI/JIT-CDI mode`(IMEX 通道校验进容器注入路径,接昨日 NVLink5+/IMEX 线)、release note 里 `injecting /dev/dri* device nodes for MIG devices`(MIG 设备补 DRI 显示节点注入)、`disable-ipc-discoverer` 新 feature flag(可关 IPC socket 发现)。证据为实质提交标题 + release body,非 hunk 读证。https://github.com/NVIDIA/nvidia-container-toolkit/compare/8807d7c763603a06aca4055decc86be47a1d4c55...32a6bc582f23ae4f3ade2b482e77ae9915d457ed

## NVIDIA/gpu-operator: 35d35715 -> 16638954
- 比较: 35d35715dd3f2441ddf8323e7f01a2f006116824 -> 16638954 | ahead=2 | files=1 | Release: v26.3.3
- Compare: https://github.com/NVIDIA/gpu-operator/compare/35d35715dd3f2441ddf8323e7f01a2f006116824...1663895412fa5edaec69260e23689c81d31095cd

### AI 总结重点(源码 diff 为据)
- **NodeLabelingReconciler 的 predicate 新增 `migCapableLabelChanged` 判据**:`SetupWithManager` 里在原有触发条件(gpuCommonLabel、commonOperands、gpuWorkloadConfig、osTree、nvidiaDriverOwner)后追加 `hasMIGCapableGPU(oldLabels) != hasMIGCapableGPU(newLabels)`,并 OR 进最终的 `labelsChanged`。即当节点的 `nvidia.com/mig.capable` 标签发生翻转时,也会触发一次 node 重打标 reconcile(之前该标签变化不入触发集,可能漏更新派生标签)。纯行为补洞,无 API/CRD 面变化。
  <details><summary>代码依据 controllers/nodelabeling_controller.go</summary>

  ```diff
  +			migCapableLabelChanged := hasMIGCapableGPU(oldLabels) != hasMIGCapableGPU(newLabels)
   ...
   				commonOperandsLabelChanged ||
   				gpuWorkloadConfigLabelChanged ||
   				osTreeLabelChanged ||
  -				nvidiaDriverOwnerLabelChanged
  +				nvidiaDriverOwnerLabelChanged ||
  +				migCapableLabelChanged
  ```
  </details>

### 后续发展方向 [AI]
- 单点补洞,方向意义有限:说明 MIG 能力标签被纳入 operator 的"标签一致性"闭环,MIG capable 状态在运行中翻转(如切换 MIG 模式)后 operator 会及时收敛派生标签。证据仅这一处 predicate,未见 `hasMIGCapableGPU` 消费方(哪些派生标签依赖它)的 hunk。未命中 `clusterpolicy_types.go`,本期 ClusterPolicy API 面无增删。

## NVIDIA/nvidia-container-toolkit: 8807d7c7 -> 32a6bc58(概览模式)
- 比较: 8807d7c763603a06aca4055decc86be47a1d4c55 -> 32a6bc58 | ahead=41 | files=300(已被 API 截断) | Release: v1.19.1
- Compare: https://github.com/NVIDIA/nvidia-container-toolkit/compare/8807d7c763603a06aca4055decc86be47a1d4c55...32a6bc582f23ae4f3ade2b482e77ae9915d457ed
- **说明**:一天区间但 files 触顶 300、被 API 截断,helper 走概览模式未逐文件读 hunk。下列为"实质提交标题 + release note"聚类,不是符号级证据。

### 概览重点(未读 hunk,聚类)
- **多节点 NVLink/IMEX 线延续**:`Validate imex channels for CDI/JIT-CDI mode`——把 IMEX(多节点 NVLink 内存导出)通道的校验引入 CDI 与 JIT-CDI 两种注入模式。与昨日 gpu-driver-container 把 `nvidia-imex` 装进驱动容器是同一条 GB200/NVL72 超节点线,toolkit 侧开始对 IMEX 通道做合法性把关。
- **MIG 设备补 DRI 节点**:release note 明列 `Add support for injecting /dev/dri* device nodes for MIG devices`——MIG 切片实例现可注入 `/dev/dri*`(DRM 渲染节点),补齐 MIG 上图形/显示相关能力。
- **发现器可关**:新增 `disable-ipc-discoverer` feature flag,可禁用 IPC socket(如 nvidia-persistenced、MPS)的自动发现——给精简/安全场景一个显式关闭点。
- **WSL2 打磨**:`discover all .so, .bin, and .dll files at nvidia driver store path`(WSL2 下扩大驱动 store 发现范围)、修 `nvidia-cdi-refresh` systemd unit 在 WSL2 的条件与去 `multi-user.target` 依赖(issue #1735)。
- **杂项**:`egl-wayland2` 库/配置纳入 CDI、Orin 系统 CUDA compat header 处理修复、cri-o drop-in 配置目录默认路径修正、NRI 插件把 CDI inject 日志降到 debug、`nvml.PciInfo.BusId` 改为 int8。
- 改动热点目录:`pkg/nvcdi`(3)、`third_party/libnvidia-container`、`internal/platform-support`、`cmd/nvidia-ctk-installer` 各 1。

### 后续发展方向 [AI]
- IMEX channel 校验 + MIG DRI 注入两条都指向"CDI 注入面在补齐边缘设备类型"(多节点内存通道、MIG 显示节点)。概览未读 hunk,`Validate imex channels` 具体校验什么(通道号范围?daemon 存活?)、DRI 注入是否受 MIG 隔离约束,均需下期在小区间里读代码确认。标注:证据仅提交标题与 release note。

## NVIDIA/gpu-driver-container: cac25f48 -> 65b0904e
- 比较: cac25f48747d5f4384782a7008c6de55bb00c093 -> 65b0904e | ahead=12 | files=9 | Release: —
- Compare: https://github.com/NVIDIA/gpu-driver-container/compare/cac25f48747d5f4384782a7008c6de55bb00c093...65b0904e77aa95ac77f62a735d8a7aff2e276148

### AI 总结重点(源码 diff 为据)
- **例行驱动版本 rev,非架构改动**:CI/矩阵/Makefile 里的数据中心分支最新版从 `580.167.08` 抬到 `580.173.02`(595.71.05 不变),vgpu-manager 四个 Dockerfile(ubuntu22.04/24.04、rhel8/9)的 CUDA base 镜像从 `13.2.x` 抬到 `13.3.0`。无启动脚本/探测逻辑变化(昨日的 NVLink5+ fabric manager 那类代码本期未再动)。
  <details><summary>代码依据 .common-ci.yml + versions.mk + vgpu-manager/rhel9/Dockerfile</summary>

  ```diff
  -  DRIVER_VERSIONS: 580.167.08 595.71.05
  +  DRIVER_VERSIONS: 580.173.02 595.71.05
  ...
  -DRIVER_VERSIONS ?= 580.167.08 595.71.05
  +DRIVER_VERSIONS ?= 580.173.02 595.71.05
  ...
  -FROM nvcr.io/nvidia/cuda:13.2.0-base-ubi9
  +FROM nvcr.io/nvidia/cuda:13.3.0-base-ubi9
  ```
  </details>

### 后续发展方向 [AI]
- 无方向信号,仅记 580 分支进 580.173.02、CUDA 13.3 base 上线。证据全为版本字符串,无逻辑 hunk。

## kai-scheduler/KAI-Scheduler: 9fad9300 -> e5b7c565
- 比较: 9fad93007f7d41e86e104f85656d106ff4354d50 -> e5b7c565 | ahead=2 | files=5 | Release: v0.14.7
- Compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/9fad93007f7d41e86e104f85656d106ff4354d50...e5b7c56584f9ef897bee1e8dc6af492342ac7e3c

### AI 总结重点(源码 diff 为据)
- **新增 `CreateDistributedBatchJob` e2e helper(#1482),统一分布式作业创建路径**:新文件 `rd/distributed_batch_job.go` 提交一个带 `kai.scheduler/batch-min-member` 注解的 batch/v1 Job,让 podgrouper 自动产出 `MinAvailable=opts.MinMember` 的单个 PodGroup;`kwok_job_creation.go`/`topology_test.go` 里原来"手建 PodGroup + 逐 pod 打 PodGroupNameAnnotation + 起 goroutine 并发建 pod"的写法被整体删掉、改调该 helper。这条重构把测试从"绕过 podgrouper 直接造 PodGroup"改成"走真实的 Job→podgrouper→PodGroup 链路",更贴生产路径。
  <details><summary>代码依据 test/e2e/modules/resources/rd/distributed_batch_job.go(注释即语义)</summary>

  ```diff
  +	// MinMember is the PodGroup MinAvailable. nil means Parallelism (gang).
  +	//   Gang:    MinMember == Parallelism
  +	//   Elastic: 1 <= MinMember < Parallelism
  +	MinMember *int32
  ...
  +// CreateDistributedBatchJob submits a batch Job annotated with kai.scheduler/batch-min-member
  +// so the podgrouper produces a single PodGroup with MinAvailable=opts.MinMember.
  ```
  </details>
- **`TopologyConstraint`/`Preemptibility`/`PriorityClassName` 经 Job 注解/标签透传到 PodGroup**:helper 的 options 里这三项由 podgrouper 读到 PodGroup 上,而非测试直接写 PodGroup。topology_test.go 的 `createDistributedWorkload` 也改走此路,说明 topology-aware gang 的注解透传链已被当作稳定契约来测。同期删掉 `kwok_test_utils.go` 里的 `createObjectWithRetries`(手建重试逻辑随之作废)。
  <details><summary>代码依据 test/e2e/suites/allocate/topology/topology_test.go</summary>

  ```diff
  -	podGroup := pod_group.Create(namespace, "distributed-pod-group"+utils.GenerateRandomK8sName(10), queueName)
  -	podGroup.Spec.MinMember = ptr.To(int32(podCount))
  -	podGroup.Spec.TopologyConstraint = topologyConstraint
  +	_, _, pods, err := rd.CreateDistributedBatchJob(ctx, testCtx.ControllerClient, testCtx.Queues[0],
  +		rd.DistributedBatchJobOptions{
  +			Parallelism:        ptr.To(int32(podCount)),
  +			Resources:          v1.ResourceRequirements{Requests: podResource, Limits: podResource},
  +			TopologyConstraint: &topologyConstraint,
  +		})
  ```
  </details>

### 后续发展方向 [AI]
- 本期是**测试基建重构,非调度器行为改动**,但透露产品路径:KAI 用 batch/v1 Job + `kai.scheduler/batch-min-member` 注解表达 gang/elastic,podgrouper 负责翻译成 PodGroup 的 MinAvailable——elastic(MinMember<Parallelism)与 gang(相等)是一等语义。证据仅 e2e 与 helper 注释,podgrouper 侧 `batch-min-member` 的实际解析代码本期未在 diff 内。另一提交 #1854 是 CI 修复(按 OCI chart 是否已发布来选 upgrade-from 版本),无产品意义。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓</summary>

- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM(master)— 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=1663895412fa5edaec69260e23689c81d31095cd branch=main release=v26.3.3 scanned=2026-07-09 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=32a6bc582f23ae4f3ade2b482e77ae9915d457ed branch=main release=v1.19.1 scanned=2026-07-09 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=65b0904e77aa95ac77f62a735d8a7aff2e276148 branch=main release=— scanned=2026-07-09 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=10fd1c08afa74932e0f949e540eca9d9953d9cec branch=main release=v0.19.3 scanned=2026-07-09 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=2607fc64e99547f604f201b66cefc06eab45090e branch=main release=v0.4.1 scanned=2026-07-09 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-09 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=944764a9e9685d82279eb2d1ee216b7b2451e213 branch=main release=v0.14.3 scanned=2026-07-09 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=e5b7c56584f9ef897bee1e8dc6af492342ac7e3c branch=main release=v0.14.7 scanned=2026-07-09 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-09 -->
