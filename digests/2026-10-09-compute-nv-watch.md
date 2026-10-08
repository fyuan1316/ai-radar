# NVIDIA 算力栈 diff 雷达 2026-10-09

## 摘要
- 9 仓仅 `dra-driver-nvidia-gpu` 有实质改动,且是**单点 API 默认值翻转**:`VfioDeviceConfig.iommu.enableAPIDevice` 的隐式默认从 `false` 改为 `true`(PR #1481 / issue #1415),理由是 VFIO 主消费者 KubeVirt 本就强依赖该设备,原默认逼每个 KubeVirt claim 都手填 opaque 配置块,现改为"开箱即用、显式 false 才 opt-out(如 Kata)"。预计随 v0.6.0 发布。
- 其余 8 仓(gpu-operator/container-toolkit/gpu-driver-container/k8s-device-plugin/dcgm-exporter/DCGM/mig-parted + KAI-Scheduler)本期无实质增量;KAI 唯一提交是 gpu-fractioning chart 依赖 bump 到 v0.1.7,非代码能力改动。

## 当日重要改变
- dra-driver-nvidia-gpu [API/CRD变更] `VfioDeviceConfig` 的 `iommu.enableAPIDevice` 空值默认由 `false` 翻转为 `true`,`DefaultVfioDeviceConfig()` / `Normalize()` 两处 ptr 常量与字段注释、API 文档、KubeVirt 直通指南同步改,KubeVirt claim 不再需显式提供该 opaque 块。证据 api/nvidia.com/resource/v1beta1/vfiodeviceconfig.go、iommu.go。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/e87de98a278caf6a252d0de36f9ae00725c0a81e

## kubernetes-sigs/dra-driver-nvidia-gpu: a59b797a -> b92f77b8
- 比较: a59b797a -> b92f77b8 | ahead=2 | files=5 | Release: v0.5.0
- PR #1481 (issue #1415): https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/pull/1481

### AI 总结重点(源码 diff 为据)
- **`enableAPIDevice` 的隐式默认从 false 翻转为 true**,影响三条代码路径:构造函数 `DefaultVfioDeviceConfig()` 直接置 `ptr.To(true)`;`Normalize()` 在 `Iommu==nil` 分支和 `Iommu.EnableAPIDevice==nil` 分支都改填 `true`。语义:VFIO 设备分配时默认把 `/dev/iommu` 或 `/dev/vfio/vfio` 控制设备纳入 claim CDI spec,原来默认不纳入。注释明确动机是 KubeVirt(主 vfio 消费者)必须要这个设备,显式置 false 才退出(举例 Kata)。
  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/vfiodeviceconfig.go</summary>

  ```diff
  	Iommu: &IOMMUConfig{
  		BackendPolicy:   IOMMUBackendPolicyLegacyOnly,
  -		EnableAPIDevice: ptr.To(false),
  +		EnableAPIDevice: ptr.To(true),
  	},
  ...
  -	// Don't enable API device if not specified.
  +	// Enable the IOMMU API device by default if not specified, since KubeVirt
  +	// (the primary vfio consumer) requires it. Explicitly setting it to false
  +	// opts out.
  	if c.Iommu.EnableAPIDevice == nil {
  -		c.Iommu.EnableAPIDevice = ptr.To(false)
  +		c.Iommu.EnableAPIDevice = ptr.To(true)
  	}
  ```
  </details>
- **字段注释与对外 API 文档同步改**:`IOMMUConfig.EnableAPIDevice` 字段注释补 "Defaults to true when unset; set to false to opt out (for example, for Kata)";`site/content/docs/reference/api.md` 把示例 `enableAPIDevice: false` 改为 `true`、把"Omit to use defaults (…API device disabled)"改为 "enabled"。对外契约从默认关变默认开。
  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/iommu.go + docs/reference/api.md</summary>

  ```diff
  	// EnableAPIDevice represents whether to include the iommu API device.
  	// If set to true, either `/dev/iommu` or `/dev/vfio/vfio` is included in the
  	// claim CDI spec, depending on the selected iommu backend.
  +	// Defaults to true when unset; set to false to opt out (for example, for Kata).
  	EnableAPIDevice *bool `json:"enableAPIDevice,omitempty"`
  ---
  -| `iommu.enableAPIDevice` | bool | Optional. … Defaults to `false`. … |
  +| `iommu.enableAPIDevice` | bool | Optional. … Defaults to `true`; set to `false` to opt out (for example, for Kata). … |
  ```
  </details>
- **KubeVirt VFIO 直通指南大幅简化**:原教程要求在 VirtualMachine 的 devices.config 里塞整段 opaque `VfioDeviceConfig`(含 driver/parameters/iommu),新文档删掉这段,并说明"As of v0.6.0, this defaults to true for VfioDeviceConfig",claim 只需裸 request、无需 opaque 块;顺带把 `backendPolicy: LegacyOnly` 标为默认值。说明本改动随 **v0.6.0** 落地(当前 Release 仍 v0.5.0)。
  <details><summary>代码依据 site/content/docs/guides/gpu-allocation/kubevirt-vfio-gpu-passthrough.md</summary>

  ```diff
  -      config:
  -      - requests:
  -        - dra-gpu
  -        opaque:
  -          driver: gpu.nvidia.com
  -          parameters:
  -            apiVersion: resource.nvidia.com/v1beta1
  -            kind: VfioDeviceConfig
  -            iommu:
  -              backendPolicy: LegacyOnly
  -              enableAPIDevice: true
  +  Note: As of v0.6.0, this defaults to `true` for `VfioDeviceConfig`, so KubeVirt
  +  claims no longer need this setting to be explicitly provided; set it to `false` to opt out.
  ```
  </details>

### 后续发展方向 [AI]
- 这是 DRA 原生路径(非 HAMi 软切分)上**VFIO 整卡直通 + KubeVirt 虚拟机场景的易用性收敛**:把"主流消费者的刚需配置"提为默认,减少 claim 样板。方向上 NVIDIA DRA driver 在围绕 KubeVirt/虚拟机(vfio passthrough)这条线做产品化打磨,而非切分能力。
- 证据只覆盖 `enableAPIDevice` 默认翻转 + 文档,未见 IOMMUFD 后端(`PreferIommuFD`)或 feature gate(`PassthroughSupport`/`DeviceMetadata`)本身的状态变化——这些 gate 仍标 Alpha/default false,本期未动。

## 本期无实质改动(折叠)
- NVIDIA/gpu-operator — 无新提交
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
- kai-scheduler/KAI-Scheduler — 仅 chore(deps):gpu-fractioning chart 依赖 bump v0.1.7 (#2353),非代码能力改动

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=57378e9c2bcc707fb5f30e78cbfa745d361bb14b branch=main release=v26.7.1 scanned=2026-10-09 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-09 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9287a5418573da037ba0d287e059812aa4740e45 branch=main release=— scanned=2026-10-09 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d5dce58aff4ddf572dc52666f949b37d6be2846c branch=main release=v0.20.1 scanned=2026-10-09 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=b92f77b8704f087299f59abebad944b94561ff0f branch=main release=v0.5.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-09 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-09 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=87f9e3c6be56020a346e9d25379734291cfc9cca branch=main release=v0.15.1 scanned=2026-10-09 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=469ad7efa3a601f01f6f213458e040f7c03f6b24 branch=main release=v0.18.3 scanned=2026-10-09 -->
