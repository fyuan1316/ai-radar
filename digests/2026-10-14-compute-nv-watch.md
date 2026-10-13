# NVIDIA 算力栈 diff 雷达 2026-10-14

## 摘要
- **KAI-Scheduler 大手术:删除全部 in-tree API 包(191 文件、绝大多数为 `removed`),Config/PodGroup/BindRequest/SchedulingShard 等 `*_types.go` 与 clientset/informers 整体迁出到独立的 `kai-scheduler/api` Go module**(#1928)——调度器主仓从此只消费 API,不再内嵌定义,下游集成改导入新 module。同期为 NUMA 感知放置铺线(#2315)、打分节点排序改单切片(#2410)。
- gpu-operator 把 DRA driver 镜像从 `v0.5.0` 升到 `v0.5.1`(CSV + values.yaml 同步),顺带修 OpenShift 文档死链;dra-driver-nvidia-gpu 本仓无新提交(已停在 v0.5.1)。
- gpu-driver-container 把预编译驱动镜像构建改走**原生 runner + 多架构 OCI 合并**(新增可复用 workflow + `merge-oci-archives.sh` + 固定校验版 regctl),arm64 不再靠 QEMU 模拟——驱动镜像 arm64 供给链路的工程化信号(纯 CI,未动构建代码)。

## 当日重要改变
- **KAI-Scheduler [API/CRD变更][架构方向]** 删除 in-tree API 包整体迁至 `kai-scheduler/api` 独立 module:`pkg/apis/**` 下 `config_types.go`/`podgroup_types.go`/`bindrequest_types.go`/`schedulingshard_types.go` 及 clientset/informers 全部 `removed`。证据见下节。https://github.com/kai-scheduler/KAI-Scheduler/pull/1928
- **KAI-Scheduler [架构方向]** scheduler 为 NUMA 放置预埋管线(refactor,尚未启用实际放置逻辑)。https://github.com/kai-scheduler/KAI-Scheduler/pull/2315

## NVIDIA/gpu-operator: 032e544f -> 8322f077
- 比较: https://github.com/NVIDIA/gpu-operator/compare/032e544fd7704da883fae340f9d024aadfe362c9...8322f0778204f9739019ec6d99cc04f0d7c7304b | ahead=5 | Release: v26.7.1
### AI 总结重点(源码 diff 为据)
- DRA driver 镜像基线从 `v0.5.0` 提到 `v0.5.1`,三处同步:CSV 里 `nvidia-dra-driver-image` 的 relatedImage、validator 的 `DRA_DRIVER_IMAGE` 环境变量、以及 Helm `values.yaml` 的 `draDriver.version`。无字段增删,是镜像版本对齐,不是能力变化。
  <details><summary>代码依据 deployments/gpu-operator/values.yaml</summary>

  ```diff
  draDriver:
    repository: nvcr.io/nvidia
    image: dra-driver-nvidia-gpu
  -  version: v0.5.0
  +  version: v0.5.1
  ```
  </details>
- 唯一实质提交 "olm: fix dead docs link in CSV manifest" 只改 OpenShift 文档跳转 URL(`openshift-on-gpu-install-guide` → `cloud-native/openshift/latest`),无运行时影响。
  <details><summary>代码依据 config/manifests/bases/gpu-operator.clusterserviceversion.yaml</summary>

  ```diff
  -    [here](https://docs.nvidia.com/datacenter/kubernetes/openshift-on-gpu-install-guide/index.html).
  +    [here](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html).
  ```
  </details>
### 后续发展方向 [AI]
- 本期 ClusterPolicy / NVIDIADriver CRD 字段零改动(`api/nvidia/v1` 未命中),operator 侧是例行镜像对齐期。证据只覆盖 CSV/values/doc 三类文件,未见控制器逻辑改动。

## NVIDIA/gpu-driver-container: 9287a541 -> 593a4158
- 比较: https://github.com/NVIDIA/gpu-driver-container/compare/9287a5418573da037ba0d287e059812aa4740e45...593a41587d3a7d856bb67b0fb88ffd1ea381f0f4 | ahead=2 | Release: —
### AI 总结重点(源码 diff 为据)
- 预编译驱动镜像构建抽成可复用 workflow `precompiled-build.yaml`,`precompiled.yaml`/`image.yaml` 的 `pre-compiled` job 从各自内联 ~110 行步骤改为 `uses: ./.github/workflows/precompiled-build.yaml`,原先 job 级的 `runs-on: linux-amd64-cpu4` 被删除——改由被调 workflow 内按架构选 runner,为 arm64 走原生 runner 让路。
  <details><summary>代码依据 .github/workflows/precompiled.yaml</summary>

  ```diff
  -    runs-on: linux-amd64-cpu4
       strategy:
         matrix:
  ...
  -    steps:
  -      - uses: actions/checkout@v7
  -      ... (内联 ~110 行构建步骤删除) ...
  +    uses: ./.github/workflows/precompiled-build.yaml
  +    with:
  +      driver-branch: ${{ matrix.driver_branch }}
  +      dist: ${{ matrix.dist }}
  +      output: oci
  ```
  </details>
- 新增 `merge-oci-archives.sh`:把 per-arch(amd64/arm64)的本地 OCI tar 用 `regctl index create` 合并成多架构镜像,并在导出前校验合并后的 `platform.architecture` 集合与期望一致。配合新增 `setup-regctl` composite action(钉死 regctl v0.11.5 + sha256 校验),把未经测试的定时镜像留在本地 OCI 引用、不进 registry。
  <details><summary>代码依据 .github/scripts/merge-oci-archives.sh</summary>

  ```diff
  +MERGED_REF="ocidir://${WORK_DIR}/merged:combined"
  +"$REGCTL" index create "$MERGED_REF" "${REF_ARGS[@]}" "${PLATFORM_ARGS[@]}"
  +MERGED_ARCHITECTURES_JSON=$("$REGCTL" manifest get "$MERGED_REF" --format raw-body |
  +  jq -c '[.manifests[] | select(.platform.os == "linux") | .platform.architecture] | sort')
  +if [[ "$MERGED_ARCHITECTURES_JSON" != "$EXPECTED_ARCHITECTURES_JSON" ]]; then
  +  echo "Merged index platforms ... do not match ..." >&2; exit 1
  +fi
  ```
  </details>
- dist→base target 映射里 `ubuntu26.04 → resolute` 继续保留(非新增,旧内联步骤已有);arm64 precompiled 仍不覆盖 jammy 与 azure-fde,这条限制在 workflow 的 jq 过滤里被显式注释保留。
### 后续发展方向 [AI]
- 方向是**驱动镜像 arm64 供给去 QEMU 化**:原生 runner 构建 + 本地 OCI 合并校验,利于 arm64 预编译驱动的稳定出包。证据只覆盖 `.github/**`(workflow/action/script),未触及 Dockerfile 或内核矩阵定义(`multi-arch.mk`/`build-kernel-matrix.sh` 仅被注释引用,本期未改),故 OS/内核支持面本身无扩张。

## kai-scheduler/KAI-Scheduler: a2731327 -> 049d1ba6
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/a2731327f29de318c01321b3bdce5b9914b5dd0d...049d1ba67d1c2b4922e681829455c8d042c0b85d | ahead=5 | files=191 | Release: v0.18.5
### AI 总结重点(源码 diff 为据)
- **API 定义整体迁出主仓到 `kai-scheduler/api` module**(#1928):`pkg/apis/scheduling/v2alpha2/podgroup_types.go`(含 `PodGroupSpec`:`MinMember`/`MinSubGroup`/`Preemptibility`/`TopologyConstraint`/`SubGroups`/`SchedulingBackoff` 等字段)、`pkg/apis/scheduling/v1alpha2/bindrequest_types.go`(含 `GPUComputeSharingMode` time-slicing/sm-sharing 枚举、`FractionalGpuGroup`、`ResourceClaimAllocation`、`PredictedNUMAZones`)、`pkg/apis/kai/v1/{config_types,schedulingshard_types,global,binder/binder}.go` 以及整套 client-gen 产物(clientset/informers/factory)全部 `removed`。主仓不再持有类型定义,只做消费方。
  <details><summary>代码依据 pkg/apis/scheduling/v2alpha2/podgroup_types.go(removed +0/-435)</summary>

  ```diff
  -// PodGroupSpec defines the desired state of PodGroup
  -type PodGroupSpec struct {
  -	MinMember *int32 `json:"minMember,omitempty" ...`
  -	MinSubGroup *int32 `json:"minSubGroup,omitempty"`
  -	Preemptibility Preemptibility `json:"preemptibility,omitempty" ...`
  -	TopologyConstraint TopologyConstraint `json:"topologyConstraint,omitempty" ...`
  -	SubGroups []SubGroup `json:"subGroups,omitempty" ...`
  -	SchedulingBackoff *int32 `json:"schedulingBackoff,omitempty" ...`
  -}
  ```
  </details>
  <details><summary>代码依据 pkg/apis/scheduling/v1alpha2/bindrequest_types.go(removed +0/-190)</summary>

  ```diff
  -// GPUComputeSharingMode selects how compute is shared ...
  -// +kubebuilder:validation:Enum=time-slicing;sm-sharing
  -type GPUComputeSharingMode string
  -const (
  -	GPUComputeSharingModeTimeSlicing GPUComputeSharingMode = "time-slicing"
  -	GPUComputeSharingModeSMSharing   GPUComputeSharingMode = "sm-sharing"
  -)
  ```
  </details>
- commit "docs: point API type changes to the kai-scheduler/api module"(#2413)确认迁移意图:类型改动一律去新 module 提。这是**代码组织层面的 API 外置**,不是字段语义变更——GPU 分片(fraction)、sm-sharing/time-slicing 共享模式、NUMA 放置这些能力定义都随之搬家,下游若 import `pkg/apis/**` 需改为 `kai-scheduler/api`。
- 调度器为 **NUMA 放置预埋管线**(#2315,"prepare NUMA placement plumbing"):配合被移除类型里已存在的 `PredictedNUMAZones []NUMAZonePlacement`,但本期是 plumbing 准备,未见实际放置决策逻辑落地。
- 性能:打分后的节点改为"单切片内排序"(#2410,"sort scored nodes in a single slice"),减少调度打分阶段的分配/拷贝开销。
### 后续发展方向 [AI]
- API 外置是为把 KAI 的调度 CRD 作为**独立可被第三方消费的契约**铺路(类似 scheduler-plugins/kueue 的 api module 分离模式),对我们而言意味着对接 KAI 时应锁定 `kai-scheduler/api` 版本而非 vendor 主仓。证据只覆盖"删除+迁移"这一半,新 module 内是否同步调整字段未在本仓 diff 中体现,需另看 `kai-scheduler/api` 仓。
- NUMA 放置 + `GPUComputeSharingMode`(sm-sharing)的存在说明 KAI 的 GPU 细粒度共享与拓扑感知放置仍在推进,方向与我们产品的 GPU 拓扑调度诉求一致;本期只到 plumbing,未到可用。

## 本期无实质改动(折叠)
<details><summary>6 仓 EMPTY</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交(停在 v1.20.1)
- NVIDIA/k8s-device-plugin — 仅 bump/CI/merge(停在 v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(停在 v0.5.1)
- NVIDIA/dcgm-exporter — 无新提交(停在 4.8.4)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — 无新提交(停在 v0.15.1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=8322f0778204f9739019ec6d99cc04f0d7c7304b branch=main release=v26.7.1 scanned=2026-10-14 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=023f35906ee23384b48dc3db3f2d1fb75d29f6b0 branch=main release=v1.20.1 scanned=2026-10-14 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=593a41587d3a7d856bb67b0fb88ffd1ea381f0f4 branch=main release=— scanned=2026-10-14 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=bb99889fbd91ca350ed5023917dba620c747dbc7 branch=main release=v0.20.1 scanned=2026-10-14 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=fb8b9674749c15b35f3bc7535c2e796c86463397 branch=main release=v0.5.1 scanned=2026-10-14 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-14 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-14 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=71640b442b4e33748f6472f5ad0f68ac6551d875 branch=main release=v0.15.1 scanned=2026-10-14 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=049d1ba67d1c2b4922e681829455c8d042c0b85d branch=main release=v0.18.5 scanned=2026-10-14 -->
</content>
</invoke>
