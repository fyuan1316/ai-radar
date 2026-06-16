# NVIDIA 算力栈 diff 雷达 2026-06-17

## 摘要
- **DRA 主线两处方向性改动**:`dra-driver-nvidia-gpu` 停止隐式注入 TimeSlicing 默认共享(default/Normalize 不再在 TimeSlicingSettings gate 开时强塞 `Strategy=TimeSlicing`),共享策略回归"显式声明";同时 VFIO passthrough 路径成熟——弃用 `bind/unbind_from_driver.sh` shell 脚本改走 `nvpassthrough` 包,新增可配 `--host-root` 并在 PassthroughSupport gate 下强校验。
- **KAI-Scheduler 押注 NUMA 拓扑感知调度**:新增 NUMA Placement Exporter(NPE)per-node DaemonSet,读 kubelet podresources API 反推每 pod 的 GPU/CPU/NIC/内存实际 NUMA 落位并回写注解;配套 `numa` 调度插件设计文档(消费 NodeResourceTopology,复刻 kubelet Topology Manager 的 single-numa-node/restricted 准入判定做过滤)。GPU↔CPU↔NIC 亲和性是其首要目标场景。
- gpu-operator 仅死代码清理 + OCP 支持窗口右移(v4.14-v4.21 → v4.16-v4.22);device-plugin/container-toolkit 仅 helm 注释修复、runc 1.4.2 bump、CI;DCGM/dcgm-exporter/mig-parted 无实质改动。

## 当日重要改变
- `kubernetes-sigs/dra-driver-nvidia-gpu` [API/CRD变更][架构方向] TimeSlicing 不再是隐式默认共享策略;`DefaultGpuConfig`/`DefaultMigDeviceConfig` 与 `Normalize()` 删除在 `TimeSlicingSettings` feature gate 下自动注入 `Sharing.Strategy=TimeSlicing` 的逻辑,无 Sharing 即不共享。证据 `api/nvidia.com/resource/v1beta1/gpuconfig.go`、`migconfig.go`。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/dccc5fee48302b3522369acd598af57420fbd6a1...ed0d0e5593dad7f0f7594ce08fd3239e52fb15ba
- `kubernetes-sigs/dra-driver-nvidia-gpu` [弃用/移除][架构方向] VFIO passthrough 弃用两个 shell 脚本(`scripts/bind_to_driver.sh`、`unbind_from_driver.sh` 各删除),改用 `nvpassthrough` 包做 driver-switch;新增 `--host-root`/`HOST_ROOT` flag 并加 `validateCLIFlags` 校验。证据 `cmd/gpu-kubelet-plugin/vfio-device.go`、`main.go`。同上 compare。
- `kai-scheduler/KAI-Scheduler` [新能力][架构方向] 新增 NUMA 拓扑感知调度:NPE 发现 agent(`pkg/npe/*` + `cmd/numa-placement-exporter`)+ `numa` 插件设计文档。证据 `pkg/npe/exporter.go`、`docs/developer/designs/numa-topology/README.md`。 https://github.com/kai-scheduler/KAI-Scheduler/pull/1714
- `NVIDIA/gpu-operator` [版本跨档] OCP 兼容窗口右移:bundle 注解 `com.redhat.openshift.versions` 由 `v4.14-v4.21` 改为 `v4.16-v4.22`(掉 4.14/4.15,加 4.22)。证据 `bundle/metadata/annotations.yaml`。 https://github.com/NVIDIA/gpu-operator/compare/cb50bd3c36c1a2295495d14448c565442f90b0a3...4a456ddf5cb48b97f8d2194cff9cc9b0530c13c5

## kubernetes-sigs/dra-driver-nvidia-gpu: dccc5fee -> ed0d0e55
- 比较 / Release:ahead=11, files=26 | Release v0.4.1-rc.1 | https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/dccc5fee48302b3522369acd598af57420fbd6a1...ed0d0e5593dad7f0f7594ce08fd3239e52fb15ba

### AI 总结重点(源码 diff 为据)
- **TimeSlicing 从"隐式默认"退回"显式声明"**:`DefaultGpuConfig()`/`DefaultMigDeviceConfig()` 删掉了"若 `TimeSlicingSettings` gate 开则把 `Sharing` 预置成 TimeSlicing"的分支,直接返回只含 TypeMeta 的空 config;`Normalize()` 里 `Sharing==nil` 时也从"补一个 TimeSlicing 策略"改成直接 `return nil`。即:用户不写 Sharing,设备就按整卡独占走,不再被默认切成时间片。这是 GPU 共享语义的方向性收敛(避免 gate 开关无声改变默认行为)。

  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/gpuconfig.go</summary>

  ```diff
   func DefaultGpuConfig() *GpuConfig {
  -	config := &GpuConfig{
  +	return &GpuConfig{
   		TypeMeta: metav1.TypeMeta{ APIVersion: GroupName + "/" + Version, Kind: GpuConfigKind },
   	}
  -	if featuregates.Enabled(featuregates.TimeSlicingSettings) {
  -		config.Sharing = &GpuSharing{
  -			Strategy: TimeSlicingStrategy,
  -			TimeSlicingConfig: &TimeSlicingConfig{ Interval: ptr.To(DefaultTimeSlice) },
  -		}
  -	}
  -	return config
   }
   func (c *GpuConfig) Normalize() error {
   	if c.Sharing == nil {
  -		if !featuregates.Enabled(featuregates.TimeSlicingSettings) { return nil }
  -		c.Sharing = &GpuSharing{ Strategy: TimeSlicingStrategy }
  +		return nil
   	}
  ```
  </details>

- **compute-domain 引入 PrepareAborted checkpoint 状态,堵 unprepare 后的 stale prepare 重放**:`Unprepare()` 对 `PrepareStarted` 态不再直接从 checkpoint 删除,而是 `markClaimPrepareAbortedInCheckpoint` 保留一个短命的 `PrepareAborted` 条目;`Prepare()` 遇到同版本 claim 已是 `PrepareAborted` 则返回 `permanentError`("stale prepare ... already aborted"),防止调度器 goroutine 竞态导致 unprepare 后又被重建设备状态。新增 `claimMatchesPreparedClaim`(按 `Status` DeepEqual 判同版本)。

  <details><summary>代码依据 cmd/compute-domain-kubelet-plugin/device_state.go</summary>

  ```diff
  +	if exists && preparedClaim.CheckpointState == ClaimCheckpointStatePrepareAborted && claimMatchesPreparedClaim(preparedClaim, claim) {
  +		return nil, permanentError{fmt.Errorf("stale prepare for claim %s: claim prepare was already aborted", ResourceClaimToString(claim))}
  +	}
   	switch pc.CheckpointState {
  -	case ClaimCheckpointStatePrepareStarted, ClaimCheckpointStatePrepareCompleted:
  +	case ClaimCheckpointStatePrepareCompleted:
  +		... unprepareDevices + deleteClaimFromCheckpoint
  +	case ClaimCheckpointStatePrepareStarted:
  +		... unprepareDevices
  +		// Keep a short-lived PrepareAborted entry so stale prepare retries cannot recreate device state
  +		if err := s.markClaimPrepareAbortedInCheckpoint(claimRef, pc); err != nil { ... }
  +	case ClaimCheckpointStatePrepareAborted:
  +		klog.V(2).Infof("Unprepare noop: claim in PrepareAborted state: %v", claimRef.String())
  +		return nil
  ```
  </details>

- **PrepareAborted 条目带 TTL 周期清理**:`cleanup.go` 新增 `PrepareAbortedClaimEntryTTL = 2 * ErrorRetryMaxTimeout` 与 `expiredEntryCleanupFn` 回调,周期 cleanup 在处理 stale PrepareStarted 之外,再删过期的 PrepareAborted 条目,保证墓碑条目不无限堆积。

  <details><summary>代码依据 cmd/compute-domain-kubelet-plugin/cleanup.go</summary>

  ```diff
  +	PrepareAbortedClaimEntryTTL  = 2 * ErrorRetryMaxTimeout
  +	expiredEntries, err := m.expiredEntryCleanupFn(ctx, time.Now(), PrepareAbortedClaimEntryTTL)
  +	if expiredEntries > 0 { klog.V(4).Infof("...deleted expired PrepareAborted claim entries: %d", expiredEntries) }
  ```
  </details>

- **VFIO passthrough 改造:去 shell 化 + host-root 可配 + 显式校验**:`NewVfioPciManager` 删除启动时 `checkVfioPCIModuleLoaded`/`loadVfioPciModule` 与硬编码 `vfioPciDriver`/`hostRoot` 常量,`checkIommuEnabled` 改吃 `nvlib.hostRoot`;`bind_to_driver.sh`/`unbind_from_driver.sh` 整文件删除(改走 `nvpassthrough` 包);`main.go` 新增 `--host-root`(默认 `/host-root`,env `HOST_ROOT`)与 `validateCLIFlags`——`PassthroughSupport` gate 开时强制 host-root 已挂载,否则启动报错。passthrough(整卡直通 VM/容器)路径在向生产可配性靠拢。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/main.go + vfio-device.go</summary>

  ```diff
  +		&cli.StringFlag{ Name: "host-root", Value: "/host-root", EnvVars: []string{"HOST_ROOT"},
  +			Usage: "...required when PassthroughSupport feature gate is enabled" },
  +func validateCLIFlags(flags *Flags) error {
  +	if featuregates.Enabled(featuregates.PassthroughSupport) {
  +		if flags.hostRoot == "" { return fmt.Errorf("host root is required when PassthroughSupport ... enabled") }
  +		if _, err := os.Stat(flags.hostRoot); err != nil { ... "host root is not mounted at %q" }
  +	}
  // vfio-device.go: 删 loadVfioPciModule/checkVfioPCIModuleLoaded 调用与 vfioPciDriver/hostRoot 常量
  -	iommuEnabled, err := checkIommuEnabled()
  +	iommuEnabled, err := checkIommuEnabled(nvlib.hostRoot)
  ```
  </details>

### 后续发展方向 [AI]
- 共享策略默认值的"去隐式化"暗示 DRA 驱动正把 TimeSlicing/MPS/MIG 三态都收敛到"用户显式声明、gate 只控可用性不控默认"的模型,降低升级时无声行为变更风险。证据只覆盖 gpuconfig/migconfig 的 default 与 Normalize,未见 MPS 侧是否同步改(MPSSupport gate 仍在 Normalize 后段引用)。
- PrepareAborted 状态机 + TTL 清理是 compute-domain(多 GPU NVLink 域)在 DRA 下抗调度器竞态的硬化,方向是 checkpoint 一致性而非新功能。证据仅 device_state.go/cleanup.go 两文件 hunk,未展开 checkpointv.go 的序列化兼容。
- VFIO passthrough 去 shell 化 + host-root 校验,意味整卡直通(给 KubeVirt/VM 或裸直通)从 PoC 往可运维靠;`nvpassthrough` 包本体未在本区间 diff 中(只见调用方改动),其能力边界需下期看包内提交。

## kai-scheduler/KAI-Scheduler: 255142d8 -> 38951dc7
- 比较 / Release:ahead=3, files=27 | Release v0.15.2 | https://github.com/kai-scheduler/KAI-Scheduler/compare/255142d8348faf0680b082a224f8a6c4dfd8fdaf...38951dc7b9dc31256df3759648cfdae6e0283567

### AI 总结重点(源码 diff 为据)
- **新增 NUMA Placement Exporter(NPE)——per-node 观测 agent**:新包 `pkg/npe` + 二进制 `cmd/numa-placement-exporter`。`Exporter.Run` 周期(podresources 快轮询 + API-server 慢漂移校正双 ticker)读本地 kubelet podresources gRPC socket,`placement.Compute` 把每 pod 每容器的 device(GPU/NIC,NUMA 来自 podresources `Topology`)、`cpu_ids`(经 `cputopology` sysfs 映射)、memory 归到 NUMA zone,序列化成注解 `kai.scheduler/numa-placement-observed`(形如 `[{"zone":"node-0","amount":{"nvidia.com/gpu":"2","cpu":"8"}}]`)回写 pod。写缓存去重,仅 placement 变化才 patch。

  <details><summary>代码依据 pkg/npe/placement/placement.go</summary>

  ```go
  // Compute attributes a single pod's allocated resources to NUMA nodes.
  for _, device := range container.GetDevices() {
      node, ok := singleNUMANode(device.GetTopology())
      if !ok { continue }
      result.add(device.GetResourceName(), node, int64(len(device.GetDeviceIds())))
  }
  for _, cpuID := range container.GetCpuIds() {
      node, ok := cpuToNUMA[cpuID]; if !ok { continue }
      result.add(cpuResourceName, node, 1)
  }
  // Marshal -> [{"zone":"node-0","amount":{"cpu":"8","nvidia.com/gpu":"2"}}, ...]
  ```
  </details>

- **`numa` 调度插件设计落档**:`docs/developer/designs/numa-topology/README.md`(785 行)定义 v1——消费 `NodeResourceTopology`(NRT)CRD,在调度器侧复刻 kubelet Topology Manager 的 `single-numa-node` 与 `restricted` 准入判定做 **filter predicate**,并在单个调度 cycle 内跟踪 per-NUMA-zone 消耗,避免同 cycle 多 pod 过量挤占同一 zone。明确把"GPU↔CPU↔NIC 严格 NUMA 亲和"列为最高价值场景(分布式训练吞吐)。NPE 文档(`numa-placement-exporter/README.md`)说明:插件默认用"预测"落位,部署 NPE 后改用"观测"落位,主要修复 reclaim/抢占模拟的准确性(预测错 victim 的 zone 会无效驱逐)。

  <details><summary>代码依据 docs/developer/designs/numa-topology/README.md</summary>

  ```text
  A new `numa` plugin replicates the kubelet's Topology Manager admission check — for both the
  `single-numa-node` and `restricted` policies — against the NRT data as a filter predicate,
  and tracks per-NUMA-zone consumption within a scheduling cycle ...
  The highest-value case for KAI seems to be GPU locality: strict GPU↔CPU↔NIC NUMA affinity
  materially affects throughput for AI/ML workloads.
  ```
  </details>

- **本地镜像 gpu-operator ClusterPolicy 类型,规避 CVE 扫描误报**:新增 `third_party/nvidia/gpu-operator/api/nvidia/v1/types.go`,手维护 ClusterPolicy 的最小子集(`OperatorSpec.DefaultRuntime`、`CDIConfigSpec.Enabled/Default`)。注释点名原因:gpu-operator 发 CalVer tag(v24/25/26)却无 `/vN` module 后缀,Go 语义导入只能解析到 v1.x 伪版本,CVE 扫描器恒判为"低于修复版本"→ 误报且无法 bump。故不 import 上游而保本地副本。

  <details><summary>代码依据 third_party/nvidia/gpu-operator/api/nvidia/v1/types.go</summary>

  ```go
  // ...github.com/NVIDIA/gpu-operator publishes CalVer release tags (v24.x/v25.x/v26.x)
  // without the matching "/vN" module-path suffix that Go's semantic import versioning requires.
  // As a result the module can only ever be resolved at v1.x pseudo-versions, which CVE scanners
  // always compare as lower than the advisory's fixed version ... so the dependency is reported
  // as vulnerable and cannot be bumped to a fixed version.
  type ClusterPolicySpec struct { Operator OperatorSpec; CDI CDIConfigSpec }
  ```
  </details>

### 后续发展方向 [AI]
- KAI 把 NUMA 感知做成"NRT 预测 + NPE 观测"两层:v1 先上 filter(防 kubelet 拒绝导致的 Pending 热循环),NPE 是 reclaim/抢占模拟精度的可选增强(operator 在 numa 插件启用时自动部署)。这是对标 scheduler-plugins 的 `NodeResourceTopologyMatch` 但深入到抢占场景。证据为设计文档 + NPE 代码,`numa` 插件 filter 本体代码未在本区间出现(仅 exporter 落地),下期看 `pkg/plugins` 侧实现。
- 给上游 gpu-operator CRD 做本地裁剪镜像,反映 KAI 作为独立 org 后对供应链/CVE 合规的工程化处理(CalVer 模块不可 bump 是真实痛点),也说明它运行时确实读 ClusterPolicy 的 `defaultRuntime`/`cdi` 字段做适配。证据仅 types.go,未见消费方调用点改动。

## gpu-operator: cb50bd3c -> 4a456ddf
- 比较 / Release:ahead=18, files=39 | Release v26.3.2 | https://github.com/NVIDIA/gpu-operator/compare/cb50bd3c36c1a2295495d14448c565442f90b0a3...4a456ddf5cb48b97f8d2194cff9cc9b0530c13c5

### AI 总结重点(源码 diff 为据)
- **本期主体为 lint/死代码清理,非功能改动**:`internal/state/state_skel.go` 删 61 行——移除从未被调用的 `handleStateObjectsDeletion`/`deleteStateRelatedObjects`/`checkAttributesExist`(连同 `nolint` 与 `meta`/`nodeinfo` import);`nvidiadriver_types.go` 仅删一行 `// nolint` 注释,CRD 字段无增删。功能面零变化,信号是代码库在收敛未使用的 state 删除路径。

  <details><summary>代码依据 internal/state/state_skel.go</summary>

  ```diff
  -// nolint
  -func (s *stateSkel) handleStateObjectsDeletion(ctx context.Context) (SyncState, error) { ... }
  -// nolint
  -func (s *stateSkel) deleteStateRelatedObjects(ctx context.Context) (bool, error) { ... }
  -// Check if provided attrTypes are present in NodeAttributes.Attributes
  -// nolint
  -func (s *stateSkel) checkAttributesExist(...) error { ... }
  ```
  </details>

- **OCP 支持窗口右移**:见"当日重要改变",`annotations.yaml` 把 OpenShift 兼容声明从 `v4.14-v4.21` 改成 `v4.16-v4.22`——对标 OAI 的我们应留意:gpu-operator v26.3.x 起官方不再声明支持 OCP 4.14/4.15。

### 后续发展方向 [AI]
- 无功能性方向变化;OCP 窗口右移是发布节奏信号(随 4.22 临近上调下界)。证据仅 bundle 注解一行,未见对应 driver/toolkit 支持矩阵改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 近 EMPTY 的 repo</summary>

- `NVIDIA/nvidia-container-toolkit`:仅 runc 依赖 bump 至 1.4.2(go.mod,已滤)+ e2e workflow 去 `E2E_SSH_USER` secret 改硬编码 `ubuntu`,无产品代码改动。
- `NVIDIA/k8s-device-plugin`:仅把 helm 模板版权头从 `#` 注释改成 `{{- /* */ -}}` 块(消除渲染出的空 yaml)+ holodeck CI bump v0.3.3→v0.3.6,无功能改动。
- `NVIDIA/gpu-driver-container`:仅 bump/CI/merge。
- `NVIDIA/dcgm-exporter`:无新提交。
- `NVIDIA/DCGM`:无新提交(master)。
- `NVIDIA/mig-parted`:仅 bump/CI/merge。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=4a456ddf5cb48b97f8d2194cff9cc9b0530c13c5 branch=main release=v26.3.2 scanned=2026-06-17 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=6d1a53dbd83f7b95eff3645afedf2335466014f2 branch=main release=v1.19.1 scanned=2026-06-17 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d5f839873900dc0f985eae0ff4d975c9aacff0b4 branch=main release=— scanned=2026-06-17 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=3171a238ce1cce34a41ea56e087300382b0d6669 branch=main release=v0.19.2 scanned=2026-06-17 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=ed0d0e5593dad7f0f7594ce08fd3239e52fb15ba branch=main release=v0.4.1-rc.1 scanned=2026-06-17 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-17 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-17 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=d8348422bc7338fba3e112fa3f733e7eecaf51da branch=main release=v0.14.2 scanned=2026-06-17 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=38951dc7b9dc31256df3759648cfdae6e0283567 branch=main release=v0.15.2 scanned=2026-06-17 -->
</content>
</invoke>
