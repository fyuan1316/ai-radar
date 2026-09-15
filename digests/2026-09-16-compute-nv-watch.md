# NVIDIA 算力栈 diff 雷达 2026-09-16

## 摘要
- **gpu-operator** 把 vGPU Device Manager 的校验从内联 shell 轮询重构为标准 `nvidia-validator` 组件框架(COMPONENT=vgpu-manager + WITH_WAIT + host-root/driver-install-dir 挂载 + SELinux s0),并复用 imagePullSecrets——vGPU 路径与主流 operand 校验对齐,不再是特例;同时 revert 掉"停止给已弃用 cdi.default 设默认值"的改动,重新给 `CDIConfigSpec.Default` 补回 `+kubebuilder:default=false`。
- **nvidia-container-toolkit** CDI 生成器把 R615 引入的 `ucodes*.bin` 固件纳入驱动固件发现,与 GSP 固件并列注入容器——新驱动分支下容器内 GPU 固件完整性修复。
- **gpu-driver-container** 从 Ubuntu 26.04 precompiled 镜像删掉未用的 pebble 二进制(缩 CVE 面),golang 提到 1.27.1。

## 当日重要改变
- gpu-operator [API/CRD变更] 重新给已弃用字段 `CDIConfigSpec.Default` 加回 kubebuilder 默认值 `false`(revert PR #2866),CRD schema 同步补 `default: false`。虽是弃用字段,但影响 CSV/CRD 生成的字段呈现。 https://github.com/NVIDIA/gpu-operator/pull/2866
- gpu-operator [新能力] vGPU Device Manager 校验统一到 `nvidia-validator` 组件(PR #2857),支持 pull secret 注入与 host/driver 目录挂载。 https://github.com/NVIDIA/gpu-operator/pull/2857
- nvidia-container-toolkit [新能力] CDI 固件发现新增 ucode 固件(R615),`newDriverFirmwareDiscoverer` 从只发现 GSP 扩到 GSP+ucode。 https://github.com/NVIDIA/nvidia-container-toolkit/commit/3c435c9048e19b09fcc924f25e4630b8f3a2b7b8

## NVIDIA/gpu-operator: 3fc63e23 -> aff3c2d5
- 比较: 3fc63e23 -> aff3c2d5 | ahead=12 | files=69 | Release: v26.7.0
- https://github.com/NVIDIA/gpu-operator/compare/3fc63e234ea12cd1de83d0ef698d438805f86aa7...aff3c2d5898a4ebea9bb6826078e6e4782658b4c

### AI 总结重点(源码 diff 为据)
- **vGPU Device Manager 的校验容器从"内联 shell 等待就绪文件"重构为标准校验组件**。原来 init 容器直接 `until [ -f .../vgpu-manager-ready ] || [ -f .../host-vgpu-manager-ready ]; do sleep 5; done`;现在改跑 `nvidia-validator` 二进制,通过环境变量 `COMPONENT=vgpu-manager`、`WITH_WAIT=true`、`NODE_NAME`(downward API)驱动,并新增 `host-root`(/host, 只读)、`driver-install-dir`(/run/nvidia/driver, 只读)挂载和 `seLinuxOptions.level: s0`。意味着 vGPU 校验不再是手写特例,而是走和其它 operand 一致的 validator 逻辑。
  <details><summary>代码依据 assets/state-vgpu-device-manager/0600_daemonset.yaml</summary>

  ```diff
  -          # The validator writes vgpu-manager-ready when the vGPU Manager is
  -          # deployed as a container, and host-vgpu-manager-ready when ...
  -          args: ["until [ -f /run/nvidia/validations/vgpu-manager-ready ] || [ -f /run/nvidia/validations/host-vgpu-manager-ready ]; do echo waiting ...; sleep 5; done"]
  +          args: ["nvidia-validator"]
  +          env:
  +          - name: WITH_WAIT
  +            value: "true"
  +          - name: COMPONENT
  +            value: vgpu-manager
  +          - name: NODE_NAME
  +            valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
             securityContext:
               privileged: true
  +            seLinuxOptions:
  +              level: "s0"
  +          volumeMounts:
  +            - { name: host-root, mountPath: /host, readOnly: true, mountPropagation: HostToContainer }
  +            - { name: driver-install-dir, mountPath: /run/nvidia/driver, readOnly: true, mountPropagation: HostToContainer }
  ```
  </details>
- **控制器侧同步:`TransformVGPUDeviceManager` 弃用 `transformValidationInitContainer`,改调 `TransformValidatorComponent(config, ..., "vgpu-manager")` 并显式注入 validator 的 imagePullSecrets**。即 vGPU 校验镜像现在也能带私仓拉取凭据。
  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
  -	err := transformValidationInitContainer(obj, config)
  -	if err != nil {
  +	if err := TransformValidatorComponent(config, &obj.Spec.Template.Spec, "vgpu-manager"); err != nil {
  		return err
  	}
  +	// add any pull secrets needed for validation image
  +	if len(config.Validator.ImagePullSecrets) > 0 {
  +		addPullSecrets(&obj.Spec.Template.Spec, config.Validator.ImagePullSecrets)
  +	}
  ```
  </details>
- **revert "Stop defaulting deprecated cdi.default":给 `CDIConfigSpec.Default`(已标 Deprecated)重新补回 `+kubebuilder:default=false`**,CRD/bundle/deployments 三处 schema 同步加 `default: false`。字段虽弃用(逻辑上不再被读),但去掉默认值曾导致下游 CSV/CRD 生成或既有实例行为变化,故回滚保持兼容。
  <details><summary>代码依据 api/nvidia/v1/clusterpolicy_types.go</summary>

  ```diff
  	// Deprecated: This field is no longer used. Setting cdi.enabled=true will configure CDI ...
  	// +kubebuilder:validation:Optional
  +	// +kubebuilder:default=false
  	// +operator-sdk:gen-csv:customresourcedefinitions.specDescriptors=true
  ```
  </details>
- 其余:新增 `leader-lease-renew-deadline` 可配置项(deployments/.../operator.yaml,+5,未见完整 hunk);"fix: wait for driver before starting GPU operands" 修 operand 启动顺序;holodeck CI 基线升 containerd 2.3.5 / k8s v1.36.4;THIRD_PARTY_NOTICES 依赖从 `opencontainers/runc/libcontainer/devices` 换到 `moby/sys/devices`(依赖迁移,非功能)。

### 后续发展方向 [AI]
- vGPU 校验并入统一 validator 框架,说明 operator 在收敛各 operand 的健康校验路径(减少手写 shell 特例、统一 pull secret / SELinux 处理),后续其它遗留内联校验大概率也会迁移。证据只覆盖 vGPU device manager 这一处,未见 driver/toolkit 校验是否同批迁移。
- CDI 默认值反复(先移除再 revert),显示 `cdi.default` 弃用收尾仍在拉扯;真正的开关已是 `cdi.enabled`,但字段清理需谨慎兼容。证据仅到 schema 层,未见运行时读取逻辑变化。

## NVIDIA/nvidia-container-toolkit: bd3398db -> 3c435c90
- 比较: bd3398db -> 3c435c90 | ahead=2 | files=1 | Release: v1.20.0
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/bd3398db7f0002529d00d97640b1e70ed016087f...3c435c9048e19b09fcc924f25e4630b8f3a2b7b8

### AI 总结重点(源码 diff 为据)
- **CDI 固件发现器从只找 GSP 固件扩展到同时发现 ucode 固件**。`newDriverFirmwareDiscoverer` 在 `gsp*.bin` 之外加了 `ucodes*.bin` 搜索路径,变量从 `gspFirmwareSearchPaths` 泛化为 `firmwareSearchPaths`,两类固件一起作为 mount 注入 CDI spec。R615 驱动分支引入了 ucode 固件文件,不注入会导致容器内 GPU 初始化缺固件。
  <details><summary>代码依据 pkg/nvcdi/driver-nvml.go</summary>

  ```diff
  -	gspFirmwareSearchPaths, err := getFirmwareSearchPaths(l.logger)
  +	firmwareSearchPaths, err := getFirmwareSearchPaths(l.logger)
  	gspFirmwarePaths := filepath.Join("nvidia", version, "gsp*.bin")
  +	ucodeFirmwarePaths := filepath.Join("nvidia", version, "ucodes*.bin")
  	return discover.NewMounts(
  		...
  -			lookup.WithSearchPaths(gspFirmwareSearchPaths...),
  +			lookup.WithSearchPaths(firmwareSearchPaths...),
  		l.driver.Root,
  -		[]string{gspFirmwarePaths},
  +		[]string{gspFirmwarePaths, ucodeFirmwarePaths},
  	), nil
  ```
  </details>

### 后续发展方向 [AI]
- CDI 固件注入随新驱动分支(R615)持续补齐,反映 CDI 已是 toolkit 里 GPU 可见性/初始化的主路径,固件级细节都在往 CDI spec 收。证据仅此一处固件类型扩展,未见其它设备节点发现变化。

## NVIDIA/gpu-driver-container: dcbb9031 -> 3036164c
- 比较: dcbb9031 -> 3036164c | ahead=4 | files=2 | Release: —
- https://github.com/NVIDIA/gpu-driver-container/compare/dcbb9031dbb95da2e449fbb632e4b69e5c3d1ba1...3036164c3323ca68c87c1c98b369a447f978a745

### AI 总结重点(源码 diff 为据)
- **Ubuntu 26.04 precompiled 驱动镜像删除基础镜像里带的但未使用的 pebble 二进制**(`rm -rf /usr/bin/pebble /var/lib/pebble`),理由是本镜像 ENTRYPOINT 是 `nvidia-driver` 而非 pebble——纯瘦身/缩 CVE 面。同时 `GOLANG_VERSION` 1.26.6 → 1.27.1;`DRIVER_VERSIONS` 保持 580.178.04 / 595.91.07 / 615.71.09 三个活跃数据中心分支不变。
  <details><summary>代码依据 ubuntu26.04/precompiled/Dockerfile + versions.mk</summary>

  ```diff
  +# pebble ships in the base image but is unused here; ENTRYPOINT is nvidia-driver, not pebble.
  +RUN rm -rf /usr/bin/pebble /var/lib/pebble
  ...
  -GOLANG_VERSION := 1.26.6
  +GOLANG_VERSION := 1.27.1
  ```
  </details>

### 后续发展方向 [AI]
- Ubuntu 26.04 precompiled 镜像已在维护清理阶段(去冗余、CVE),说明该 OS 矩阵已进入常态支持,而非实验分支。证据仅镜像层清理,未见新增 OS/驱动分支。

## 本期无实质改动(折叠)
- **NVIDIA/mig-parted**:仅 CI 与 license 层——`.github/scripts/backport.js` 改成通过 Git Data API 重建 backport commit 以获得 "Verified" 签名;THIRD_PARTY_NOTICES 依赖清单变动(moby/sys/capability→devices、runtime-tools 移除、yaml 迁到 go.yaml.in);distroless/go 基镜 v4.1.3→v4.1.4。无 MIG 切分逻辑变化。
- **NVIDIA/k8s-device-plugin**:仅 bump/CI/merge(ahead=3)。
- **kubernetes-sigs/dra-driver-nvidia-gpu**:无新提交。
- **NVIDIA/dcgm-exporter**:无新提交。
- **NVIDIA/DCGM**:无新提交。
- **kai-scheduler/KAI-Scheduler**:无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=aff3c2d5898a4ebea9bb6826078e6e4782658b4c branch=main release=v26.7.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3c435c9048e19b09fcc924f25e4630b8f3a2b7b8 branch=main release=v1.20.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=3036164c3323ca68c87c1c98b369a447f978a745 branch=main release=— scanned=2026-09-16 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=971c9554a7080d820252ea540f3203f60a4f8a24 branch=main release=v0.20.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=5baf08f63bd266129dbdd27b28e77bb0ad91fd28 branch=main release=v0.5.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-16 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-16 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=0c6185caf792f738649caf132bd6e32bef28b3ef branch=main release=v0.15.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=d942b921b8025257207bc0a687e23cc1a6fcc1c5 branch=main release=v0.17.1 scanned=2026-09-16 -->
