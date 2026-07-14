# NVIDIA 算力栈 diff 雷达 2026-07-15

## 摘要
- **gpu-operator 正式弃用 KataManager**:ClusterPolicy CRD 的 `kataManager` 字段标注 Deprecated 且"所有值一律忽略",controller 侧 `state-kata-manager` 状态硬编码 `return false`,并删掉了整套 `TransformKataManager`/kata configmap/artifacts 逻辑(-183 行)。Kata 机密/沙箱 GPU 工作负载编排从 operator 主线退场,字段仅为兼容保留。
- **mig-parted 把 DeviceID 从 uint32 重构成带子系统 ID 的结构体**:device filter 现支持 `<device+vendor>:<subdevice+subvendor>` 语法,能按板卡子系统精确匹配/排除;export 时用 `.Primary()` 剥掉子系统限定,保证导出配置对同型号所有板卡变体通用。是 MIG 静态切分选设备粒度变细的实锤。
- 附带面:gpu-operator 把 DCGM 镜像从 `4.5.2-1-ubi9` 跨到 `4.6.0-1-ubi10`(基础 OS 升 UBI10)、mig-manager v0.14.2→v0.14.3、gdrcopy v2.5.2→v2.6;k8s-device-plugin 把内置 NFD 子 chart 0.17.3→0.19.0 并将仓库源迁到 OCI registry。

## 当日重要改变
- NVIDIA/gpu-operator [弃用/移除][API/CRD变更] ClusterPolicy `kataManager` 字段弃用,CRD description 改为"no longer honored, all values ignored";`state_manager.go` 让 `state-kata-manager` 恒 false;`object_controls.go` 删除 `TransformKataManager`、kata configmap 序列化、`KataManagerAnnotationHashKey`/`DefaultKataArtifactsDir` 常量。 https://github.com/NVIDIA/gpu-operator/compare/17c08086...ce8360e8
- NVIDIA/mig-parted [新能力][API变更] `types.DeviceID` 由 `uint32` 改为含 `SubsystemDevice/SubsystemVendor/HasSubsystem` 的 struct,新增 `NewDeviceIDWithSubsystem`/`NewDeviceIDFromPacked`/`Matches`/`Primary`;`MatchesDeviceFilter` 改用 `Matches` 支持子系统限定过滤。 https://github.com/NVIDIA/mig-parted/compare/4f279a9f...2a081fd0
- NVIDIA/gpu-operator [版本跨档] 捆绑 DCGM 镜像 `4.5.2-1-ubi9` → `4.6.0-1-ubi10`(minor 跨档 + 基础镜像 UBI9→UBI10),mig-manager v0.14.3、gdrcopy v2.6 同步。 https://github.com/NVIDIA/gpu-operator/compare/17c08086...ce8360e8

## NVIDIA/gpu-operator: 17c08086 -> ce8360e8
- 比较 / Release: https://github.com/NVIDIA/gpu-operator/compare/17c08086...ce8360e8 | ahead=17 | files=12 | Release v26.3.3
### AI 总结重点(源码 diff 为据)
- **KataManager 组件被整条摘除,但保留 CRD 字段做兼容**:`ClusterPolicySpec.KataManager` 加了 `// Deprecated: This field is no longer honored ... All values under this field are ignored` 注释;CRD(`config/crd` 与 `deployments/.../crds` 两份)的 `kataManager` description 同步改成弃用文案。字段本身没删——是"软弃用",老 ClusterPolicy 不会报错,但不再生效。
  <details><summary>代码依据 api/nvidia/v1/clusterpolicy_types.go + nvidia.com_clusterpolicies.yaml</summary>

  ```diff
  +	// Deprecated: This field is no longer honored by the GPU Operator. All values under this field are ignored.
   	// KataManager component spec
   	KataManager KataManagerSpec `json:"kataManager,omitempty"`
  ```
  ```diff
                 kataManager:
  -                description: KataManager component spec
  +                description: |-
  +                  Deprecated: This field is no longer honored by the GPU Operator. All values under this field are ignored.
  +                  KataManager component spec
  ```
  </details>
- **控制面让 kata-manager 状态永远关闭**:`state_manager.go` 的 `isStateEnabled("state-kata-manager")` 从"看 sandboxEnabled && KataManager.IsEnabled()"直接改成 `return false`,注释明说"any changes to the cluster policy CRD wrt kata manager will not be honored"。即无论 CRD 怎么填,kata-manager daemonset 都不会被 reconcile 出来。
  <details><summary>代码依据 controllers/state_manager.go</summary>

  ```diff
   	case "state-kata-manager":
  -		return n.sandboxEnabled && clusterPolicySpec.KataManager.IsEnabled()
  +		// always return false for kata manager as it stands deprecated
  +		// this means that any changes to the cluster policy CRD wrt kata manager will not be honored
  +		return false
  ```
  </details>
- **配套删掉全部 kata 编排实现(-183 行)**:`object_controls.go` 移除了 `TransformKataManager` 整个函数、`preProcessDaemonSet` 里 `"nvidia-kata-manager": TransformKataManager` 的注册、`nvidia-kata-manager-config` configmap 的 yaml 序列化分支、`KataManagerAnnotationHashKey`/`DefaultKataArtifactsDir` 常量,以及 `transformRuntimeConfigAndSocketMounts` 里那段"跳过 nvidia-kata-manager 容器"的 drop-in hack。死代码随功能一起清除,不是留白。
  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
  -	// KataManagerAnnotationHashKey is the annotation indicating the hash of the kata-manager configuration
  -	KataManagerAnnotationHashKey = "nvidia.com/kata-manager.last-applied-hash"
  -	// DefaultKataArtifactsDir is the default directory to store kata artifacts on the host
  -	DefaultKataArtifactsDir = "/opt/nvidia-gpu-operator/artifacts/runtimeclasses/"
  ...
  -	if obj.Name == "nvidia-kata-manager-config" {
  -		data, err := yaml.Marshal(config.KataManager.Config)
  -		...
  -	}
  ...
  -		"nvidia-kata-manager":                         TransformKataManager,
  ...
  -// TransformKataManager transforms Kata Manager daemonset with required config as per ClusterPolicy
  -func TransformKataManager(obj *appsv1.DaemonSet, config *gpuv1.ClusterPolicySpec, n ClusterPolicyController) error {
  -	...
  -}
  ```
  </details>
- **捆绑镜像版本推进**:`values.yaml` 把 DCGM `4.5.2-1-ubuntu22.04` → `4.6.0-1-ubuntu24.04`、mig-manager `v0.14.2` → `v0.14.3`、gdrcopy `v2.5.2` → `v2.6`;OLM bundle CSV 同步换镜像 digest,DCGM 从 `ubi9` 基座跳到 `ubi10`。DCGM 4.6/UBI10 是本期最值得留意的传递依赖跨档(dcgm-exporter 本仓没动,exporter 镜像仍 4.5.3-4.8.2)。
  <details><summary>代码依据 deployments/gpu-operator/values.yaml + bundle CSV</summary>

  ```diff
   dcgm:
  -  version: 4.5.2-1-ubuntu22.04
  +  version: 4.6.0-1-ubuntu24.04
   migManager:
  -  version: v0.14.2
  +  version: v0.14.3
   gdrcopy:
  -  version: "v2.5.2"
  +  version: "v2.6"
  ```
  ```diff
       - name: dcgm-image
  -      image: nvcr.io/nvidia/cloud-native/dcgm:4.5.2-1-ubi9@sha256:d7558...
  +      image: nvcr.io/nvidia/cloud-native/dcgm:4.6.0-1-ubi10@sha256:92080...
  ```
  </details>
### 后续发展方向 [AI]
- KataManager 弃用是 gpu-operator 收缩"机密计算/沙箱 GPU"编排面的明确信号:注意仅弃用 **KataManager**(负责下发 kata runtimeclass/artifacts),同期 `state-kata-device-plugin`、`CCManager`(CC = Confidential Computing)、`VFIOManager` 路径都还在,说明退场的是 Kata Containers 运行时这条,而非整个机密计算方向。证据覆盖 CRD 字段+状态开关+实现删除三处一致,未见官方 release note 说明替代方案(可能转由 NVIDIA 自家 kata 项目独立维护)。
- DCGM 跳到 4.6 且基座换 UBI10,是本期唯一 minor 跨档依赖;dcgm-exporter 指标语义是否随 DCGM 4.6 变化,本仓 diff 看不到(exporter 镜像未同步),需下期盯 dcgm-exporter 仓与 DCGM release note。

## NVIDIA/mig-parted: 4f279a9f -> 2a081fd0
- 比较 / Release: https://github.com/NVIDIA/mig-parted/compare/4f279a9f...2a081fd0 | ahead=2 | files=9 | Release v0.14.3
### AI 总结重点(源码 diff 为据)
- **DeviceID 从裸 uint32 升级为带子系统信息的结构体**:`types.DeviceID` 原是 `uint32`(device<<16|vendor 打包),现改为 struct `{Device, Vendor, SubsystemDevice, SubsystemVendor uint16; HasSubsystem bool}`。新增构造器 `NewDeviceIDWithSubsystem`、`NewDeviceIDFromPacked`(从 NVML 的 32 位打包值还原),`NewDeviceID` 保留但返回无子系统的实例。这是把"同一 GPU 芯片、不同板卡厂商子系统"区分开的基础数据结构改造。
  <details><summary>代码依据 pkg/types/device.go</summary>

  ```diff
  -// DeviceID represents a GPU Device ID as read from a GPUs PCIe config space.
  -type DeviceID uint32
  +type DeviceID struct {
  +	Device          uint16
  +	Vendor          uint16
  +	SubsystemDevice uint16
  +	SubsystemVendor uint16
  +	HasSubsystem    bool
  +}
  +
  +// NewDeviceIDWithSubsystem constructs a new 'DeviceID' with subsystem values.
  +func NewDeviceIDWithSubsystem(device, vendor, subDevice, subVendor uint16) DeviceID { ... }
  ```
  </details>
- **device filter 语法扩展为可选子系统限定**:`NewDeviceIDFromString` 现按 `:` 拆分,支持 `0x233010DE`(仅主 ID)或 `0x233010DE:0x16C010DE`(主 ID + 子系统 ID),>2 段报格式错误。匹配逻辑收敛到新方法 `Matches`——`MatchesDeviceFilter` 从 `==` 精确相等改成 `newDeviceID.Matches(deviceID)`。测试明示语义:纯主 ID filter 匹配任何子系统硬件(向后兼容),而带子系统的 filter 只匹配同子系统、拒绝兄弟板卡(`0x16C0` 匹配、`0x16C1` 不匹配)。
  <details><summary>代码依据 api/spec/v1/helpers.go + pkg/types/device.go + helpers_test.go</summary>

  ```diff
   	for _, df := range deviceFilter {
   		newDeviceID, _ := types.NewDeviceIDFromString(df)
  -		if newDeviceID == deviceID {
  +		if newDeviceID.Matches(deviceID) {
   			return true
   		}
   	}
  ```
  ```diff
  +	parts := strings.Split(str, ":")
  +	if len(parts) > 2 { return DeviceID{}, fmt.Errorf("... expected '<devicevendor>' or '<devicevendor>:<subdevicevendor>'", str) }
  ...
  +		{ name: "matching subsystem filter matches hardware",       filter: "0x233010DE:0x16C010DE", want: true  },
  +		{ name: "sibling subsystem filter does not match hardware", filter: "0x233010DE:0x16C110DE", want: false },
  ```
  </details>
- **实际发现与导出两端同步适配**:发现侧 `cmd/.../util/device.go` 的 PCI/NVML 枚举改用 `NewDeviceIDWithSubsystem(...)` 带上 `gpu.SubsystemDevice/SubsystemVendor`;A30 硬编码 profile 的 hack(`discovery.go`)也从 `uint32(deviceID) == deviceIDA30` 改为 `deviceIDA30.Matches(deviceID)`,常量从 `const 0x20B710DE` 改为 `var NewDeviceID(0x20B7, 0x10DE)`。导出侧 `export/config.go` 用 `deviceID.Primary().String()` **剥掉**子系统限定,注释明说"让导出配置对某 GPU 的所有板卡变体通用"——即采集时精细、导出模板时泛化。
  <details><summary>代码依据 cmd/.../util/device.go + pkg/mig/discovery/discovery.go + export/config.go</summary>

  ```diff
  -		ids = append(ids, types.NewDeviceID(gpu.Device, gpu.Vendor))
  +		ids = append(ids, types.NewDeviceIDWithSubsystem(gpu.Device, gpu.Vendor, gpu.SubsystemDevice, gpu.SubsystemVendor))
  ```
  ```diff
  -		deviceFilter := deviceID.String()
  +		// Strip any subsystem qualifier so exported configs apply to all board variants of a GPU.
  +		deviceFilter := deviceID.Primary().String()
  ```
  </details>
### 后续发展方向 [AI]
- 这是给 MIG 配置的 device filter 补上"同芯片、异板卡"的分辨力:同一 GPU die(如 H100 0x2330)在不同 OEM 板卡上子系统 ID 不同,过去只能一刀切,现在可对特定板卡型号下发不同 MIG 切分。默认行为向后兼容(纯主 ID filter 仍匹配全部),属能力增量而非破坏性变更。证据覆盖数据结构、字符串解析、匹配、发现/导出四处闭环;未见 known_configs 里是否已按子系统区分具体机型(本期仅把常量语法从 const 迁到 var,值未细分)。

## NVIDIA/k8s-device-plugin: 7a3ea104 -> 24816472
- 比较 / Release: https://github.com/NVIDIA/k8s-device-plugin/compare/7a3ea104...24816472 | ahead=11 | files=121 | Release v0.19.3
### AI 总结重点(源码 diff 为据)
- 本期唯一实质提交是"bump nvidia-container-toolkit to v1.20.0-rc.1",实体改动集中在打包:内置 NFD 子 chart 从 **0.17.3 → 0.19.0**,且仓库源从 `https://kubernetes-sigs.github.io/node-feature-discovery/charts`(GitHub Pages)迁到 **`oci://registry.k8s.io/nfd/charts`**(OCI registry)。tgz 附件随之替换,`tests/vendor` 下大量 NFD 生成代码更新(vendor 噪声,非本仓 API)。NFD 本体归 k8s-ai-infra 视角,此处只记 device-plugin 捆绑版本与分发方式的边界变化。
  <details><summary>代码依据 deployments/helm/nvidia-device-plugin/Chart.yaml + Chart.lock</summary>

  ```diff
     - name: node-feature-discovery
       alias: nfd
  -    version: "0.17.3"
  +    version: "0.19.0"
       condition: nfd.enabled,gfd.enabled
  -    repository: https://kubernetes-sigs.github.io/node-feature-discovery/charts
  +    repository: oci://registry.k8s.io/nfd/charts
  ```
  </details>
### 后续发展方向 [AI]
- NFD chart 源迁 OCI registry 与上游 NFD 0.19 打包方式一致(gpu-operator 上期也已捆绑 NFD 0.19),是 NVIDIA 全栈统一 NFD 到 0.19 + OCI 分发的收尾动作。证据仅覆盖 Chart 元数据,未见 GFD/device-plugin 自身控制面逻辑变化(本期无生产代码 diff)。

## 本期无实质改动(折叠)
<details><summary>test-only / EMPTY / 无新提交仓(6 仓)</summary>

- kai-scheduler/KAI-Scheduler — 有 1 提交但纯 e2e 测试基建("fix(e2e): restore scale test job creation"):把分布式 job 提交拆成 `SubmitDistributedBatchJob`/`waitForDistributedBatchJob`、`CreateDistributedBatchJob` 返回值收敛为 `JobResult` 结构、新增 `CreateObjectWithRetries` 重试。均在 `test/e2e/` 下,无生产/调度器/API 改动。HEAD 前移到 92128ed1,Release v0.16.4
- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 3db41dec 未动,Release v1.20.0-rc.1)
- NVIDIA/gpu-driver-container — 无新提交(HEAD 1ea5e0fc 未动,Release —)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(HEAD 9001f17e 未动,Release v0.4.1)
- NVIDIA/dcgm-exporter — 无新提交(HEAD d5e5f510 未动,Release 4.5.3-4.8.2)
- NVIDIA/DCGM(master)— 无新提交(HEAD 72fa3fea 未动)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=ce8360e854ed7c2bc53d56f112b8a249dfb39919 branch=main release=v26.3.3 scanned=2026-07-15 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3db41dec03bf1179b4f7259f6a7037f7f158d39b branch=main release=v1.20.0-rc.1 scanned=2026-07-15 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=1ea5e0fca809020c7388ba1058d19ad3788e6aaf branch=main release=— scanned=2026-07-15 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=248164727d5d8bac7024a8e12a13e69246cf0969 branch=main release=v0.19.3 scanned=2026-07-15 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9001f17e513115a9366987bf5fd9f7850ac52368 branch=main release=v0.4.1 scanned=2026-07-15 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-15 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=2a081fd0bd3c6b675ae122bc9178894a84e5aea8 branch=main release=v0.14.3 scanned=2026-07-15 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=92128ed1bc114df35c6980d2994056d5842e6ba3 branch=main release=v0.16.4 scanned=2026-07-15 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-15 -->
