# NVIDIA 算力栈 diff 雷达 2026-08-26

## 摘要
- **gpu-operator 修 ClusterPolicy→NVIDIADriver CRD 迁移的状态机竞态**:`state_manager.go` 把 `n.idx++`(推进状态机指针)从 driver daemonset 清理**之前**挪到清理**成功之后**。此前若 `cleanupAllDriverDaemonSets` 失败,指针已前移,重试时会跳过该清理步骤、留下由 ClusterPolicy 拥有的孤儿 driver daemonset。属驱动容器化迁移路径的正确性修复。
- **nvidia-container-toolkit 让 WSL 尊重 `NVIDIA_VISIBLE_DEVICES=none`**:WSL 路径的 `DeviceSpecGenerators` 现在若设备列表含 `none` 就返回空生成器,与 Linux 语义对齐(none = 不注入任何 GPU 设备);另修若干 `Warningf("%w", …)` 误用(Warningf 不做 wrap,应为 `%v`)与 go 1.26→1.27。
- **dra-driver-nvidia-gpu 一次大范围错误信息/日志规整("fix error and logs formatting" + "second pass")**:改动虽命中 `api/nvidia.com/resource/v1beta1/` 路径(sharing.go/computedomainconfig.go),但**仅是错误字符串措辞与 `%w` 补全,无任何 CRD/字段 schema 变更**,不构成 API 变更信号。
- 其余六仓无实质改动:mig-parted 仅 go 1.27 工具链 bump;gpu-driver-container/dcgm-exporter/DCGM/KAI-Scheduler 无新提交;k8s-device-plugin 仅 bump/CI。

## 当日重要改变
- 无强信号命中(无弃用/CRD schema 变更/新 package/版本跨档)。本期最实质的是两处**行为修复**,详见下方 repo 正文:gpu-operator 状态机指针推进时机、nvidia-container-toolkit WSL `none` 语义对齐。dra-driver 虽改动 `api/` 路径但仅错误文案,**非** API/CRD 变更(已核实 hunk,防误报)。

## NVIDIA/gpu-operator: 90e932f1 -> 9004c9d7
- 比较: 90e932f1efbc9b4caeca966ae3f90dec3422cfda...9004c9d7 | ahead=8 | files=18 | Release: v26.7.0 | https://github.com/NVIDIA/gpu-operator/compare/90e932f1efbc9b4caeca966ae3f90dec3422cfda...9004c9d7

### AI 总结重点(源码 diff 为据)
- **状态机指针 `n.idx++` 从清理前移到清理成功后,修迁移竞态**:`ClusterPolicyController.step()` 在 `state-driver`/`state-vgpu-manager` 且启用 NVIDIADriver CRD 时,会孤儿式(`DeletePropagationOrphan`)清理 ClusterPolicy 拥有的 driver daemonset。改动前 `n.idx++` 在 `cleanupAllDriverDaemonSets` 调用**之前**执行——一旦清理返回 err,函数返回 `NotReady` 触发重试,但指针已前移,下次 reconcile 会跳过这个清理状态,导致旧 driver daemonset 永久残留。改动后指针只在清理成功后推进,失败即原地重试。直接影响 ClusterPolicy→NVIDIADriver CRD 驱动管理迁移的可靠性。配套新增 `TestStep` 覆盖"正常态成功推进/出错不推进/driver 清理成功推进/清理失败不推进"四例。
  <details><summary>代码依据 controllers/state_manager.go</summary>

  ```diff
   	if (n.stateNames[n.idx] == "state-driver" || n.stateNames[n.idx] == "state-vgpu-manager") &&
   		n.singleton.Spec.Driver.UseNvidiaDriverCRDType() {
   		n.logger.Info("NVIDIADriver CRD is enabled, cleaning up all NVIDIA driver daemonsets owned by ClusterPolicy")
  -		n.idx++
   		// Cleanup all driver daemonsets owned by ClusterPolicy while keeping the
   		// running driver pods available until NVIDIADriver rolls replacements.
   		err := n.cleanupAllDriverDaemonSets(n.ctx, metav1.DeletePropagationOrphan)
   		if err != nil {
   			return gpuv1.NotReady, fmt.Errorf("failed to cleanup all NVIDIA driver daemonsets owned by ClusterPolicy: %w", err)
   		}
  +		n.idx++
   		return gpuv1.Disabled, nil
   	}
  ```
  </details>
- **工程/CI**:Dependabot 的 docker 生态排除 `golang`(改由 Renovate 管,避免双写冲突,`.github/dependabot.yml`);e2e 与 helm-oci-chart 发布流水线里 `mikefarah/yq` action 固定 SHA 升级。均不涉能力面。

### 后续发展方向 [AI]
- 证据只覆盖本区间 diff:改动集中在 ClusterPolicy 与 NVIDIADriver CRD 双轨并存期的状态机健壮性,印证 gpu-operator 仍把"从 ClusterPolicy 内联 driver 管理迁到独立 NVIDIADriver CRD"当作进行中的主线(清理保留运行中 pod、靠 CRD 滚动替换)。本区间无 `*_types.go`/CRD 命中,故非 schema 级变化。

## NVIDIA/nvidia-container-toolkit: d34b3046 -> b5a4721d
- 比较: d34b3046758cb1a5db606b2a39519c731bbf9f56...b5a4721d | ahead=6 | files=7 | Release: v1.20.0 | https://github.com/NVIDIA/nvidia-container-toolkit/compare/d34b3046758cb1a5db606b2a39519c731bbf9f56...b5a4721d

### AI 总结重点(源码 diff 为据)
- **WSL 路径尊重 `NVIDIA_VISIBLE_DEVICES=none`**:`wsllib.DeviceSpecGenerators` 原先忽略入参 id、恒返回自身;现在若 id 列表 `slices.Contains(ids, "none")` 就返回 `emptyDeviceSpecGenerator("none")`——即不生成任何 CDI 设备规格。此前 WSL 上设 `none` 仍会注入 GPU,与 Linux 侧"none = 显式不挂 GPU"的约定不一致,本次对齐。
  <details><summary>代码依据 pkg/nvcdi/lib-wsl.go</summary>

  ```diff
  +	"slices"
  ...
  -func (l *wsllib) DeviceSpecGenerators(...string) (DeviceSpecGenerator, error) {
  +func (l *wsllib) DeviceSpecGenerators(ids ...string) (DeviceSpecGenerator, error) {
  +	if slices.Contains(ids, "none") {
  +		return emptyDeviceSpecGenerator("none"), nil
  +	}
   	return l, nil
   }
  ```
  </details>
- **修 `Warningf` 中 `%w` 误用为 `%v`**:`cudacompat.go`、`driver-wsl.go` 里 `logger.Warningf(..., "%w", err)` 改为 `%v`。`Warningf` 走 `Sprintf` 语义,不做 error wrap,`%w` 只会打出字面 `%!w(...)`,属日志正确性修复(非行为面)。
  <details><summary>代码依据 cmd/nvidia-cdi-hook/cudacompat/cudacompat.go</summary>

  ```diff
  -		m.logger.Warningf("Failed to find CUDA compat library: %w", err)
  +		m.logger.Warningf("Failed to find CUDA compat library: %v", err)
  ```
  </details>
- **工程**:开发镜像 go 1.26.5→1.27.0(`deployments/devel/Dockerfile`),及 golang 升级后的 lint 修复。

### 后续发展方向 [AI]
- 证据覆盖:改动是 CDI 生成器在 WSL 平台补齐 Linux 已有的 `none` 短路语义,说明 toolkit 在收敛 WSL 与 Linux 两条 CDI 路径的行为差异(WSL 走 dxcore 发现,长期是二等公民)。未见 runtime hook / CDI spec 结构变化,非架构级。

## kubernetes-sigs/dra-driver-nvidia-gpu: d682267c -> 71dd3635
- 比较: d682267c7dd84a76c61663feeaf36d04ac6ebfef...71dd3635 | ahead=3 | files=21 | Release: v0.5.0 | https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/d682267c7dd84a76c61663feeaf36d04ac6ebfef...71dd3635

### AI 总结重点(源码 diff 为据)
- **一次贯穿全仓的错误信息/日志措辞规整,非功能改动**:两个提交("fix error and logs formatting"、"second pass")统一了错误文案风格——加设备/claim 标识、补 `%w` 让错误可 `errors.Is` 解包、把 `"still exists"`/`"strategy is not set to X"` 这类无上下文串换成带对象名的完整句。**关键:虽命中 `api/nvidia.com/resource/v1beta1/sharing.go`(GPU 共享 TimeSlicing/MPS 策略校验)与 `computedomainconfig.go`(ComputeDomain domainID 校验),但改的全是 `fmt.Errorf` 的文案与 wrap,无任何字段/常量/校验逻辑变更**,不构成 API/CRD 信号。GPU sharing 策略(TimeSlicing/MPS)、MIG 分片、ComputeDomain/IMEX 的实际行为均未变。
  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/sharing.go(仅文案)</summary>

  ```diff
  -		return nil, fmt.Errorf("strategy is not set to '%v'", TimeSlicingStrategy)
  +		return nil, fmt.Errorf("GPU sharing strategy is %s, expected %s", s.Strategy, TimeSlicingStrategy)
  ...
  -		return "", fmt.Errorf("%w: invalid device index: %v", ErrInvalidDeviceSelector, index)
  +		return "", fmt.Errorf("%w: device index %d is outside the valid range [0, %d)", ErrInvalidDeviceSelector, index, len(s.uuids))
  ```
  </details>
- **`nvlib.go`/`device_state.go` 里 NVML 返回码现在被 wrap 进错误**:多处 `fmt.Errorf("... on GPU %v", uuid)` 补上 `: %w, ret`(把 `nvml.SUCCESS` 外的具体 ret 码带出),MIG 设备删除/prepare/unprepare 的回滚错误也统一为 "failed to ..." 句式并带设备名。属可观测性/诊断改进,行为不变。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/nvlib.go</summary>

  ```diff
  -			return nil, fmt.Errorf("error retrieving GpuInstanceProfileInfo for profile %d on GPU %v", i, uuid)
  +			return nil, fmt.Errorf("error retrieving GpuInstanceProfileInfo for profile %d on GPU %v: %w", i, uuid, ret)
  ```
  </details>

### 后续发展方向 [AI]
- 证据边界:本区间纯属错误处理卫生(error hygiene)扫尾,未触及 DRA prepare/unprepare、MIG 动态切分、ComputeDomain/IMEX 编排的任何实质逻辑,无从推断能力走向。仅可判断项目在 v0.5.0 后进入打磨期,把散落的 NVML/kubelet-plugin 错误路径统一到可解包、带上下文的规范——利于生产环境从日志定位 DRA 分配失败根因。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- NVIDIA/mig-parted:仅 go 1.27.0 工具链 bump(`deployments/{devel,container}/Dockerfile`),无能力改动(HEAD 8bac7a58,Release v0.15.0)
- NVIDIA/gpu-driver-container:无新提交(HEAD 仍 06a208ca,Release —)
- NVIDIA/k8s-device-plugin:仅 bump/CI,无实质提交(HEAD ad174fb0,Release v0.20.0)
- NVIDIA/dcgm-exporter:无新提交(HEAD 仍 181290c3,Release 4.6.0-4.8.3)
- NVIDIA/DCGM:无新提交(HEAD 仍 64df9f89,分支 master,Release —)
- kai-scheduler/KAI-Scheduler:无新提交(HEAD 仍 920e8a01,Release v0.14.8)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9004c9d75b6e78825be6bc744ed9ad56bdb41433 branch=main release=v26.7.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=b5a4721daa18ec48fb3bcc2c9e04cbd6baff373a branch=main release=v1.20.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-26 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=ad174fb06833406f841f7396ed8c450a1a38a9fd branch=main release=v0.20.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=71dd363545415dea363639ff9cea98b39afe7f80 branch=main release=v0.5.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-26 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-08-26 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=8bac7a587a30504efbce56f0416b0cd9330c618e branch=main release=v0.15.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=920e8a015168c31ccc811403a0323bd078e6c9d6 branch=main release=v0.14.8 scanned=2026-08-26 -->
</content>
</invoke>
