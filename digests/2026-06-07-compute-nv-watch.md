# NVIDIA 算力栈 diff 雷达 2026-06-07

> 区间:各仓以 6/06 锚点为 base → 今日 HEAD(单日增量)。

## 摘要
- **NVIDIA DRA 驱动给 MPS 加多用户(multi-user)模式开关**:`dra-driver-nvidia-gpu` 的 `MpsConfig` CRD 新增 `multiUser *bool` 字段;开启后给 `nvidia-cuda-mps-control` 加 `-M` 启动参数,允许**不同 uid 的用户共享同一 MPS 守护进程**,并在启动前强制校验所涉 GPU 的 CUDA 算力 ≥ 7.0(Volta 及更新),不满足直接拒绝。这是 DRA 原生 GPU 共享路径在"MPS 跨用户隔离/共享"上的能力补齐,且属 API/CRD 字段新增。
- 其余 8 仓本期均无实质改动:gpu-operator / nvidia-container-toolkit / gpu-driver-container 各有 2 笔但全是 dependabot bump/CI/merge;k8s-device-plugin、dcgm-exporter、DCGM、mig-parted、KAI-Scheduler 无新提交。

## 当日重要改变
- kubernetes-sigs/dra-driver-nvidia-gpu [API/CRD变更][新能力] `MpsConfig` 新增 `multiUser *bool` 字段 + MPS multi-user 模式 + Volta 算力门禁:开启时给 `nvidia-cuda-mps-control` 传 `-M`,并要求所有 GPU CUDA compute capability ≥ 7.0。证据 `api/nvidia.com/resource/v1beta1/sharing.go`、`cmd/gpu-kubelet-plugin/{sharing.go,mps_capability.go}`、commit 421c0f49 / PR #1153 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/pull/1153

## kubernetes-sigs/dra-driver-nvidia-gpu: 1dd7b11b -> f51778e2
- 比较 1dd7b11b -> f51778e2 | ahead=6 | files=22 | Release: v0.4.0
- 比较页 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/1dd7b11b349231a3061aee24f103d6fb4eefe900...f51778e2e66c6bf9364d8ae319cdd5ad609ec4a3
- 实质提交仅 1 笔:"Add multi-user MPS configuration and capability validation"(421c0f49,PR #1153),其余 4 笔为 dependabot bump(ginkgo、actions/checkout)+ merge。

### AI 总结重点(源码 diff 为据)
- **CRD 新增 `MpsConfig.MultiUser *bool`(API 字段增)**:在 `MpsConfig` 结构体追加 `MultiUser *bool` 字段(JSON tag `multiUser,omitempty`),注释明确语义:控制 `nvidia-cuda-mps-control` 是否以 multi-user 模式启动,**允许不同 uid 的用户之间共享**;未提供时默认关闭。这是面向 DRA `ResourceClaim` 配置面暴露的新可调项,会带出 `zz_generated.deepcopy.go` 的指针深拷贝。指针类型(而非裸 bool)是为了区分"未设置"与"显式 false"。
  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/sharing.go</summary>

  ```diff
   	DefaultPerDevicePinnedMemoryLimit MpsPerDevicePinnedMemoryLimit `json:"defaultPerDevicePinnedMemoryLimit,omitempty"`
  +	// MultiUser controls if the nvidia-cuda-mps-control daemon should be started in Multi user mode, which allows sharing between users with different uids.
  +	// If not provided it will default to not enabled.
  +	MultiUser *bool `json:"multiUser,omitempty"`
   }
  ```
  </details>
- **MPS 启动模板按开关追加 `-M` 参数**:`MpsControlDaemonTemplateData` 加 `MultiUser bool` 字段;`mps-control-daemon.tmpl.yaml` 把启动命令从 `nvidia-cuda-mps-control -d` 改为 `nvidia-cuda-mps-control -d{{ if .MultiUser }} -M{{ end }}`——即仅当字段为真才追加 MPS 的 multi-user 标志 `-M`。`MpsControlDaemon.Start` 在 `config.MultiUser != nil` 时把值灌进模板数据。
  <details><summary>代码依据 templates/mps-control-daemon.tmpl.yaml + cmd/gpu-kubelet-plugin/sharing.go</summary>

  ```diff
  -          $RUN "nvidia-cuda-mps-control -d"
  +          $RUN "nvidia-cuda-mps-control -d{{ if .MultiUser }} -M{{ end }}"
  ```
  ```diff
   	DefaultPinnedDeviceMemoryLimits map[string]string
  +	MultiUser                       bool
  ...
  +	if config != nil && config.MultiUser != nil {
  +		templateData.MultiUser = *config.MultiUser
  +		if templateData.MultiUser {
  +			// multiuser mode requires architecture to be volta or newer
  +			if err := ensureCapability(m.manager.nvdevlib.gpuInfosByUUID, m.devices.GpuUUIDs(), voltaCudaComputeCapability); err != nil {
  +				return fmt.Errorf("multiuser mode was requested but is not supported: %w", err)
  +			}
  +		}
  +	}
  ```
  </details>
- **新增 Volta 算力门禁 `ensureCapability`**:新文件 `mps_capability.go` 加常量 `voltaCudaComputeCapability = "7.0"` 与函数 `ensureCapability(gpuInfo, gpus, cudaComputeCapability)`——用 `semver` 逐卡比对 GPU 的 `cudaComputeCapability`,任一卡缺信息或低于 7.0 即用 `errors.Join` 聚合报错。仅当 `MultiUser` 为真时在 `Start` 里调用,失败则整个 MPS 守护进程启动报 "multiuser mode was requested but is not supported"。即 multi-user MPS 被硬限定在 Volta(SM 7.0)及更新架构,旧卡上请求该模式会被显式拒绝而非静默降级。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/mps_capability.go(新增)</summary>

  ```diff
  +const voltaCudaComputeCapability = "7.0"
  +
  +// ensureCapability checks if all GPUs meet the required CUDA capability.
  +func ensureCapability(gpuInfo map[string]*GpuInfo, gpus []string, cudaComputeCapability string) (err error) {
  +	required, parseErr := semver.NewVersion(cudaComputeCapability)
  +	...
  +	for _, id := range gpus {
  +		info, ok := gpuInfo[id]
  +		if !ok || info == nil { return fmt.Errorf("could not check gpu %s: missing gpu info ...", id) }
  +		cc, parseErr := semver.NewVersion(info.cudaComputeCapability)
  +		...
  +		if cc.Compare(required) < 0 {
  +			err = errors.Join(fmt.Errorf("%s has insufficient cudaComputeCapability %q, wanted >= %q", id, info.cudaComputeCapability, cudaComputeCapability), err)
  +		}
  +	}
  +	return err
  +}
  ```
  </details>

### 后续发展方向 [AI]
- DRA 原生路径在 MPS 共享上对齐了 device-plugin 时代缺失的"跨 uid 共享"能力,并把架构门禁(Volta+)做进 kubelet-plugin 启动期校验,而非交给运行时报错。证据只覆盖 `MpsConfig` 字段、模板渲染、`ensureCapability` 三处;`MultiUser` 仍是全局布尔(非 per-device),且 `Start` 里 `templateData.MultiUser` 初始化为 false——未见与 `DefaultPerDevicePinnedMemoryLimit` 等按设备粒度配置的协同,也未见对 multi-user 下 shm/pipe 目录权限或用户隔离边界的额外处理,可盯后续是否补 per-user 资源配额。

## 本期无实质改动
<details><summary>EMPTY 的 8 仓(保留锚点,详见末尾)</summary>

- NVIDIA/gpu-operator — ahead=2/files=14,全 dependabot bump/CI/merge,无行为变化(仍 v26.3.2)。
- NVIDIA/nvidia-container-toolkit — ahead=2,仅 bump/CI(仍 v1.19.1)。
- NVIDIA/gpu-driver-container — ahead=2,仅 bump/CI。
- NVIDIA/k8s-device-plugin — 无新提交(仍 v0.19.2)。
- NVIDIA/dcgm-exporter — 无新提交。
- NVIDIA/DCGM — 无新提交(master)。
- NVIDIA/mig-parted — 无新提交(仍 v0.14.2)。
- kai-scheduler/KAI-Scheduler — 无新提交(仍 v0.14.5)。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=2a8a94d3d99fbc771a37d0412d686202396000ab branch=main release=v26.3.2 scanned=2026-06-07 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=e0bcfd493755f5c11ae18c56c5a1f172d061af5c branch=main release=v1.19.1 scanned=2026-06-07 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=df698c2732758def060fb551d433f013866437ac branch=main release=— scanned=2026-06-07 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=db1ea9481054448d97ae43bd082147e7d6ba5501 branch=main release=v0.19.2 scanned=2026-06-07 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=f51778e2e66c6bf9364d8ae319cdd5ad609ec4a3 branch=main release=v0.4.0 scanned=2026-06-07 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-07 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=0869351a7d89ff24e68c93b92a50d981cea15580 branch=master release=— scanned=2026-06-07 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=b24528651efb64b358e7fc169d4cb18d9ac06347 branch=main release=v0.14.2 scanned=2026-06-07 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=a55228f7804177655e50857ad8127238289c5d3b branch=main release=v0.14.5 scanned=2026-06-07 -->
