# NVIDIA 算力栈 diff 雷达 2026-09-10

## 摘要
- **KAI-Scheduler 给 Deployment 引入 gang 调度**:新增 CRD/config 字段 `gangScheduleDeployment`(默认 true),把一个 Deployment 的所有 Pod 收到单个 PodGroup 下整体调度;老对象经 annotation 判定走 per-pod 兼容路径。这是调度层的 API 变更,推理型 Deployment 从此默认整组起停。
- **KAI-Scheduler 修复扩展资源(RDMA/自定义标量)的口径 bug**:标量/扩展资源解析从 `MilliValue()` 改回 `Value()`,`minScalarResources` 阈值 10→1,消除对 `intel.com/mlnx_sriov_rdma` 等扩展资源被 ×1000 的错误放大,node 向量与 resourceInfo 现在一致。
- 其余以修补为主:dcgm-exporter 修 HPC job 映射去重(指标语义);gpu-driver-container 修 unzboot 仅 aarch64 才拷贝 + UBI 基镜像滚动;gpu-operator / container-toolkit 本期仅补测试与文档治理,无功能变化。

## 当日重要改变
- **KAI-Scheduler [API/CRD变更+架构方向]** 新增 `Args.GangScheduleDeployment *bool` 字段与 CRD `gangScheduleDeployment`(默认 true),DeploymentGrouper 重写为"整 Deployment 一个 PodGroup + MinAvailable 取自 annotation",关掉则回退 per-pod。 https://github.com/kai-scheduler/KAI-Scheduler/commit/948cd1c834be0ebd5ebd6e1e42812c7e8ffd4403
- **KAI-Scheduler [缺陷/口径]** 扩展标量资源解析统一用 `Value()`(原 `MilliValue()`),`minMilliScalarResources(=10)` → `minScalarResources(=1)`,修复 resourceInfo 与 node vector 对扩展资源(如 RDMA)不一致。 https://github.com/kai-scheduler/KAI-Scheduler/commit/948cd1c834be0ebd5ebd6e1e42812c7e8ffd4403
- **dcgm-exporter [指标语义]** HPC job 映射文件同一 job ID 现只计一次,避免同卡重复 job 导致指标重复富化。 https://github.com/NVIDIA/dcgm-exporter/commit/16ecae49e4d6174e556e768c87cd4e49d844b909

## kai-scheduler/KAI-Scheduler: abbad9c7 -> 948cd1c8
- 比较 ahead=2 / files=27 | Release: v0.17.1
### AI 总结重点(源码 diff 为据)
- **Deployment 级 gang 调度落地**。`pod_grouper.Args` 新增字段 `GangScheduleDeployment *bool`,CRD `kai.scheduler_configs.yaml` 同步加入 `gangScheduleDeployment`(描述:是否把一个 deployment 的所有 pod 归到单个 podgroup,默认 true;关掉则每 pod 一个 podgroup)。`DeploymentGrouper` 从"只包 DefaultGrouper"重构为持有 `client` + `gangSchedule` 开关:开启时 `GetPodGroupMetadata` 走整组路径,`MinAvailable` 由 `minmember.FromAnnotations(topOwner, "Deployment", 1)` 决定;检测到历史 per-pod 对象(`hasPodGroupPerPod`)或开关关闭时退回 `setPodGroupPerPod`(owner 指向 pod 本身)。
  <details><summary>代码依据 pkg/apis/kai/v1/pod_grouper/pod_grouper.go + crds/kai.scheduler_configs.yaml + deployment_grouper.go</summary>

  ```diff
  + // GangScheduleDeployment specifies whether to group all the pods of a deployment under a single podgroup. Default is true. Disable to create a podgroup per pod.
  + // +kubebuilder:validation:Optional
  + GangScheduleDeployment *bool `json:"gangScheduleDeployment,omitempty"`
  ```
  ```diff
  + gangScheduleDeployment:
  +   description: GangScheduleDeployment specifies whether to group
  +     all the pods of a deployment under a single podgroup. Default
  +     is true. Disable to create a podgroup per pod.
  +   type: boolean
  ```
  ```diff
  - func NewDeploymentGrouper(defaultGrouper *defaultgrouper.DefaultGrouper) *DeploymentGrouper {
  + func NewDeploymentGrouper(client client.Client, defaultGrouper *defaultgrouper.DefaultGrouper, gangSchedule bool) *DeploymentGrouper {
  ...
  + if !dg.gangSchedule { return setPodGroupPerPod(metadata, pod), nil }
  + legacy, err := dg.hasPodGroupPerPod(topOwner)  // 历史对象保持 per-pod
  + if legacy { return setPodGroupPerPod(metadata, pod), nil }
  + metadata.MinAvailable, err = minmember.FromAnnotations(topOwner, "Deployment", 1)
  ```
  </details>
- **扩展/标量资源解析口径统一为整数值**。`RequirementsFromResourceList` 与 `ResourceFromResourceList` 里对 `IsScalarResourceName` 分支从 `+= rQuant.MilliValue()` 改为 `+= rQuant.Value()`;`base_resources.go` 常量 `minMilliScalarResources int64 = 10` 改名并降为 `minScalarResources int64 = 1`,`ToResourceList` 里标量资源从 `NewMilliQuantity` 改为 `NewQuantity`。效果:请求 `kai.scheduler/test-resource: 1` 现返回 `1` 而非 `1000`;RDMA 类扩展资源 `resourceInfo.ToVector` 与 `NewResourceVectorFromResourceList` 结果一致。这是纠正之前把整数扩展资源当 milli 处理导致的 ×1000 放大。
  <details><summary>代码依据 pkg/scheduler/api/resource_info/{resource_requirment,resource_info,base_resources}.go</summary>

  ```diff
  - } else if k8s_internal.IsScalarResourceName(rName) {
  -     r.scalarResources[rName] += rQuant.MilliValue()
  + } else if k8s_internal.IsScalarResourceName(rName) {
  +     r.scalarResources[rName] += rQuant.Value()
  ```
  ```diff
  - minMilliScalarResources int64 = 10
  + minScalarResources      int64 = 1
  ...
  - rl[rName] = *resource.NewMilliQuantity(int64(rQuant), resource.DecimalSI)
  + rl[rName] = *resource.NewQuantity(int64(rQuant), resource.DecimalSI)
  ```
  </details>
### 后续发展方向 [AI]
- gang 调度从"框架型 workload(JobSet/Job/minmember)"扩到"原生 Deployment 推理服务",且默认开启——KAI 把整组起停当作推理副本的默认语义,对标 OAI 里 KServe 多副本的调度一致性。证据只覆盖 podgrouper 侧的分组逻辑与 CRD 字段,未见 scheduler 主循环对新 PodGroup 的抢占/回填如何联动。
- 资源口径 bug 说明 KAI 的扩展资源(RDMA/网卡/自定义卡)支持还在夯实期,此前存在数量级错误;关注后续是否对 MIG(`IsMigResource` 走 `Value()` 分支未变)与标量资源统一测试覆盖。

## NVIDIA/dcgm-exporter: 181290c3 -> 16ecae49
- 比较 ahead=1 / files=4 | Release: 4.6.0-4.8.3
### AI 总结重点(源码 diff 为据)
- **HPC job 映射读取去重**。`readFile` 读取 GPU→job 映射文件时新增 `seen map[string]struct{}`,同一文件内重复 job ID 只保留首次出现(保序)。避免同一 job 在一张卡的映射里出现多次,导致 `hpc_job` 标签在指标里被重复富化。跨卡的同名 job 仍各自计入(不同映射文件)。
  <details><summary>代码依据 internal/pkg/transformation/hpc.go</summary>

  ```diff
    scanner := bufio.NewScanner(file)
  + seen := make(map[string]struct{})
    for scanner.Scan() {
  -     jobs = append(jobs, scanner.Text())
  +     job := scanner.Text()
  +     if _, exists := seen[job]; exists { continue }
  +     seen[job] = struct{}{}
  +     jobs = append(jobs, job)
    }
  ```
  </details>
### 后续发展方向 [AI]
- 纯正确性修补,不涉指标 schema。对我们产品的启示:如果基于 dcgm-exporter 做 HPC/作业级 GPU 计量,升级到含此 fix 的版本前后同一 job 的 series 计数会变(去重),报表口径需对齐。证据仅覆盖 hpc mapper 读取路径。

## NVIDIA/gpu-driver-container: 9ac64592 -> f9d09ec2
- 比较 ahead=4 / files=4 | Release: —
### AI 总结重点(源码 diff 为据)
- **OpenShift DTK 入口按架构守卫 unzboot 拷贝**。`rhel10/ocp_dtk_entrypoint` 里原本无条件把 `/usr/bin/unzboot` 拷进 DTK 共享目录,现改为仅当 `DRIVER_ARCH==aarch64` 才拷(amd64 镜像不构建该二进制,原逻辑会因文件缺失出错)。`dtk-build-driver` 阶段同样加了 aarch64 守卫。属驱动容器 OS/架构矩阵的构建修补。
  <details><summary>代码依据 rhel10/ocp_dtk_entrypoint</summary>

  ```diff
  - /usr/bin/unzboot \
    /drivers \
    "$DRIVER_TOOLKIT_SHARED_DIR/"
  + # unzboot is only built/installed on aarch64 (see install.sh); it doesn't exist on amd64 images
  + DRIVER_ARCH=${TARGETARCH/amd64/x86_64} && DRIVER_ARCH=${DRIVER_ARCH/arm64/aarch64}
  + if [[ "$DRIVER_ARCH" == "aarch64" ]]; then
  +   cp /usr/bin/unzboot "$DRIVER_TOOLKIT_SHARED_DIR/"
  + fi
  ```
  </details>
- RHEL8/9/10 三个 Dockerfile 的 UBI 基镜像 tag 例行滚动(如 ubi9 `9.8-1788245065`→`9.8-1788939089`),无逻辑变化。
### 后续发展方向 [AI]
- ARM(aarch64)驱动容器与 x86 的构建产物差异(unzboot 仅 arm)正被逐一补齐,反映 NVIDIA 对 arm64 GPU 节点(如 GH/GB 系列)的一等公民支持还在填坑。证据仅覆盖 rhel10 入口脚本,未见 install.sh 里 unzboot 的构建条件。

## 本期仅测试/文档,无功能变化(折叠)
<details><summary>gpu-operator / nvidia-container-toolkit</summary>

- **NVIDIA/gpu-operator** (bde36141, ahead=4):仅为 `internal/state`(driver manifest / cleanup / skel / sync / manager)新增单测 ~3000 行 + `docs/README.md`、CONTRIBUTING 文档链接。无生产代码/ClusterPolicy CRD 改动。
- **NVIDIA/nvidia-container-toolkit** (e7bb2d49, ahead=8):新增 `AGENTS.md`(AI 协作指南,其中文字确认"默认走 CDI、legacy hook 仅 opt-in"为既有行为)、`CODEOWNERS`、docs 链接。无 runtime/CDI 代码改动。
</details>

## 本期无实质改动(EMPTY)
- NVIDIA/k8s-device-plugin(无新提交)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=bde36141b3a5abed397d77412265bbe568cc67fb branch=main release=v26.7.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=e7bb2d492f46c6797fd6c850032ca91e4b94b896 branch=main release=v1.20.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=f9d09ec20c066ee41d6f0d38e8b9434829478c1d branch=main release=— scanned=2026-09-10 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=4edf2b66ec53db87c36e035f82e5629b676893e3 branch=main release=v0.20.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=2aa7e2c95821b1e3df9f6b0ca345ae3f915c87bb branch=main release=v0.5.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-10 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-10 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=2098686586250d28c472aaa821643a069f8464ec branch=main release=v0.15.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=948cd1c834be0ebd5ebd6e1e42812c7e8ffd4403 branch=main release=v0.17.1 scanned=2026-09-10 -->
</content>
</invoke>
