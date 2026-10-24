# NVIDIA 算力栈 diff 雷达 2026-10-25

## 摘要
- gpu-operator 本期两条实质改动都落在**企业级订阅/CDI 接入面**:RHEL/SLES 的 entitlement 挂载从"路径必须存在"放宽为 `*OrCreate`、并把 `/etc/yum.repos.d` 父目录改挂到 driver-manager initContainer;同时 CDI 模式下显式注入 CDI 注解前缀 `cdi.k8s.io/`。回退了上一版"air-gapped 时跳过订阅挂载"的逻辑。
- container-toolkit 让管理态(DCGM)容器额外注入 `libnvsdm.so.1 / libibumad.so.3 / libibmad.so.5` —— 这几个库不随 driver 版本后缀,之前被漏挂,属 NVSDM 遥测初始化依赖补齐。
- DRA 驱动给 **VFIO 整卡直通(PassthroughSupport)** 补了端到端 e2e,间接坐实 `VfioDeviceConfig`(`resource.nvidia.com/v1beta1`)与 `vfio.gpu.nvidia.com` device class 的用法:直通期间该卡的 `gpu` 视图从 ResourceSlice 下线、释放后复现。

## 当日重要改变
- NVIDIA/gpu-operator [行为变更] RHEL/SLES/SL-Micro 的订阅 entitlement 宿主挂载由 `HostPathDirectory/HostPathFile` 改为 `HostPathDirectoryOrCreate/HostPathFileOrCreate`,并新增 `/run/secrets/yum.repos.d` 父目录卷挂到 `k8s-driver-manager` initContainer;宿主缺路径不再导致 driver pod 失败。证据 `controllers/object_controls.go`、`internal/state/driver_volumes.go`、`internal/state/driver.go`。 https://github.com/NVIDIA/gpu-operator/commit/21c6d32e2faf
- NVIDIA/gpu-operator [行为变更] CDI 启用时 toolkit 容器显式设置 CDI 注解前缀环境变量为 `cdi.k8s.io/`(`transformToolkitCtrForCDI`)。 https://github.com/NVIDIA/gpu-operator/commit/e616961d6ebf
- NVIDIA/gpu-operator [弃用/回退] Revert "Updated Red Hat mounts for air-gapped clusters":删除了"当 `Driver.RepoConfig` 配置时跳过宿主订阅挂载"的分支,RHEL 非 CRIO 场景恢复为始终挂载订阅。 https://github.com/NVIDIA/gpu-operator/commit/bfd5046b5054
- kubernetes-sigs/dra-driver-nvidia-gpu [架构方向] 新增 VFIO 直通 e2e,暴露 `VfioDeviceConfig`(含 `iommu.backendPolicy`、`iommu.enableAPIDevice`)opaque 配置与 `vfio.gpu.nvidia.com` device class;验证"直通中 gpu 视图从 ResourceSlice 移除、释放后复现"。证据 `test/e2e/framework/specs/vfio-config.yaml.tmpl`、`test/e2e/vfio_allocation_test.go`。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/e66c07074934

## NVIDIA/gpu-operator: 5c77de84 -> 0fbefd5e
- 比较: 5c77de84882c1f0c13a1ac3f3dbf2cb62687b7ac -> 0fbefd5e | ahead=7 | files=20 | Release: v26.7.2
- 比较链接 https://github.com/NVIDIA/gpu-operator/compare/5c77de84882c1f0c13a1ac3f3dbf2cb62687b7ac...0fbefd5ec6a6235c4ed887298602498506cff6ce

### AI 总结重点(源码 diff 为据)
- **订阅挂载改为"缺则创建",并拆出父目录挂到 driver-manager**:`SubscriptionPathMap` 里 `rhel/sles/sl-micro` 三组的 `HostPathDirectory→HostPathDirectoryOrCreate`、`HostPathFile→HostPathFileOrCreate`(`rhcos` 保持严格 `HostPathDirectory/HostPathFile` 不变);新增 `/run/secrets/yum.repos.d` 目录卷。`transformDriverContainer` 把该父目录卷挂到名为 `k8s-driver-manager` 的 initContainer(缺该 initContainer 直接报错),其余订阅卷仍挂到 driver 主容器。`internal/state/driver.go` 的 `additionalConfigs` 为此新增 `DriverManagerVolumeMounts` 字段。意图:`FileOrCreate` 不会创建父目录,单独给一个 `DirectoryOrCreate` 父目录卷让 kubelet 先建目录再重试文件挂载,宿主缺订阅文件时不再让 pod 卡住。
  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
  -				Type: ptr.To(corev1.HostPathDirectory),
  +				Type: new(corev1.HostPathDirectoryOrCreate),
  ...
  +		// FileOrCreate does not create parents. A separate directory volume
  +		// lets kubelet create the repo directory and retry file setup if needed.
  +		"/run/secrets/yum.repos.d": corev1.VolumeSource{
  +			HostPath: &corev1.HostPathVolumeSource{
  +				Path: "/etc/yum.repos.d",
  +				Type: new(corev1.HostPathDirectoryOrCreate),
  +			},
  +		},
  ...
  +			if mountPath == "/run/secrets/yum.repos.d" {
  +				manager := findContainerByName(podSpec.InitContainers, "k8s-driver-manager")
  +				if manager == nil {
  +					return fmt.Errorf("k8s-driver-manager initContainer is missing from the driver daemonset manifest")
  +				}
  +				manager.VolumeMounts = append(manager.VolumeMounts, volMountSubscription)
  +			} else {
  +				driverContainer.VolumeMounts = append(driverContainer.VolumeMounts, volMountSubscription)
  +			}
  ```
  </details>
- **回退 air-gapped 的"跳过订阅挂载"短路**:`transformDriverContainer` 删掉了"当 `config.Driver.RepoConfig.ConfigMapName != ""` 且 `osID==rhel` 时跳过宿主订阅挂载"的分支,改回无条件 `getSubscriptionPathsToVolumeSources()`。即上一版为 air-gapped 加的开关被撤回。
  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
  -		pathToVolumeSource := MountPathToVolumeSource{}
  -		if config.Driver.RepoConfig != nil && config.Driver.RepoConfig.ConfigMapName != "" && osID == "rhel" {
  -			n.logger.Info("Skipping host subscription mounts because repoConfig is enabled", "OS", osID)
  -		} else {
  -			n.logger.Info("Mounting subscriptions into the driver container", "OS", osID)
  -			pathToVolumeSource, err = n.getSubscriptionPathsToVolumeSources()
  -			...
  -		}
  +		n.logger.Info("Mounting subscriptions into the driver container", "OS", osID)
  +		pathToVolumeSource, err := n.getSubscriptionPathsToVolumeSources()
  ```
  </details>
- **CDI 模式注入注解前缀**:`transformToolkitCtrForCDI` 在设置 runtime mode=cdi 的同时,新增 `setContainerEnv(container, NvidiaCtrRuntimeCDIPrefixesEnvName, "cdi.k8s.io/")`,把 toolkit 容器的 CDI 注解前缀固定为标准 `cdi.k8s.io/`。
  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
   	setContainerEnv(container, NvidiaCtrRuntimeModeEnvName, "cdi")
   	setContainerEnv(container, CRIOConfigModeEnvName, "config")
  +	setContainerEnv(container, NvidiaCtrRuntimeCDIPrefixesEnvName, "cdi.k8s.io/")
  ```
  </details>
- 其余 5 个提交为 CI/发布基础设施:新增 `publish-main-chart.yaml`(每日从 main 发 Helm chart + OLM bundle)、`get-latest-images.sh` 重构为 JSON 驱动的多组件镜像解析(toolkit/device-plugin/mig-manager/driver-manager/vgpu/kata/kubevirt/cc-manager)、forward-compatibility 改为消费每日 main chart。属工程化,不影响 operand 行为。

### 后续发展方向 [AI]
- OpenShift/RHEL 与 SUSE 的 entitlement 接入在做鲁棒性收敛:宿主缺订阅文件/目录从"硬失败"转为"按需创建 + driver-manager 兜底",降低企业环境首次装机门槛。证据覆盖 `SubscriptionPathMap` 与 `transformDriverContainer` 的挂载路由,未见 ClusterPolicy CRD 字段增删(`api/nvidia/v1/clusterpolicy_types.go` 本期未动)。air-gapped 开关被回退说明该路径仍在反复调整,未定型。

## NVIDIA/nvidia-container-toolkit: 57a2c442 -> bb93a6b0
- 比较: 57a2c44242d4163098fc110ca1bf92beca587d5b -> bb93a6b0 | ahead=8 | files=33 | Release: v1.20.1
- 比较链接 https://github.com/NVIDIA/nvidia-container-toolkit/compare/57a2c44242d4163098fc110ca1bf92beca587d5b...bb93a6b00e965191bed3fbdb8e15d51f5af949a1

### AI 总结重点(源码 diff 为据)
- **管理态容器补挂 NVSDM 库**:`managementlib.GetCommonEdits` 在原 driver discoverer 外 `discover.Merge` 进一个新的 `newNVSDMLibraryDiscoverer()`,后者挂载 `libnvsdm.so.1 / libibumad.so.3 / libibmad.so.5`。注释说明这些库(DCGM 初始化 NVSDM 所需)不带 driver 版本后缀,会被"按 driver 版本后缀匹配"的逻辑漏掉,故单独发现。仅影响 management spec(非 management 的 driver 库不挂)。
  <details><summary>代码依据 pkg/nvcdi/management.go</summary>

  ```diff
  -	edits, err := l.editsFactory.FromDiscoverer(driver)
  +	nvsdmLibraries, err := l.newNVSDMLibraryDiscoverer()
  +	if err != nil {
  +		return nil, fmt.Errorf("failed to create nvsdm library discoverer: %w", err)
  +	}
  +	edits, err := l.editsFactory.FromDiscoverer(discover.Merge(driver, nvsdmLibraries))
  ...
  +	return discover.NewMounts(
  +		l.logger, driverLibraryLocator, l.driver.Root,
  +		[]string{"libnvsdm.so.1", "libibumad.so.3", "libibmad.so.5"},
  +	), nil
  ```
  </details>
- 其余为依赖 bump:distroless/go 基础镜像 `v4.1.4→v4.1.7`、logrus `1.9.4→1.10.2`、opencontainers/cgroups `0.0.7→0.1.0`。

### 后续发展方向 [AI]
- 监控/管理面依赖在往"NVSDM(NVLink/InfiniBand 结构遥测)"靠:补齐 DCGM 初始化所需的 IB 管理库,说明 fabric 级遥测在容器化路径上被当作一等依赖。证据仅覆盖 `management.go` 的库发现,未见 CDI spec schema 或 runtime hook 本身变化。

## kubernetes-sigs/dra-driver-nvidia-gpu: 9b0ddb6c -> fc0fccb0
- 比较: 9b0ddb6ca64ef4a41dea94ca06e4978b3230b6f8 -> fc0fccb0 | ahead=2 | files=89 | Release: v0.5.1
- 比较链接 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/9b0ddb6ca64ef4a41dea94ca06e4978b3230b6f8...fc0fccb03bbe77b7c388475a263095c3f2f4539c

### AI 总结重点(源码 diff 为据)
- **VFIO 整卡直通端到端测试落地,坐实其 DRA 配置形态**:新增的 `vfio-config.yaml.tmpl` 用 `ResourceClaimTemplate` 的 opaque config 携带 `VfioDeviceConfig`(`apiVersion: resource.nvidia.com/v1beta1`),可配 `iommu.backendPolicy` 与 `iommu.enableAPIDevice`;claim 通过 `deviceClassName: vfio.gpu.nvidia.com` 请求直通设备。这把"GPU 绑 vfio-pci 交给 VM 使用"的路径与普通 `gpu.nvidia.com` 并列为独立 device class。
  <details><summary>代码依据 test/e2e/framework/specs/vfio-config.yaml.tmpl</summary>

  ```yaml
      config:
      - opaque:
          driver: gpu.nvidia.com
          parameters:
            apiVersion: resource.nvidia.com/v1beta1
            kind: VfioDeviceConfig
            iommu:
              backendPolicy: {{ .BackendPolicy }}
              enableAPIDevice: {{ .EnableAPIDevice }}
      requests:
      - name: gpu
        exactly:
          deviceClassName: vfio.gpu.nvidia.com
  ```
  </details>
- **断言直通期间 GPU 的 DRA 视图下线、释放后复现**:e2e 验证直通卡被绑到 vfio-pci 后,其 `gpu` 视图从 ResourceSlice 移除(`expectGPUDeviceCount(before-1)`),删除 pod/claim 释放后切回 nvidia 驱动并重新发布 `gpu` 视图。另补了 `RestartKubeletPlugin`(校验 checkpoint 恢复:prepared claim 要能熬过 plugin 进程重启)与 `ExecInPod` 测试辅助。
  <details><summary>代码依据 test/e2e/vfio_allocation_test.go</summary>

  ```go
  // The passthrough GPU is bound to vfio-pci, so its `gpu` view is removed
  // from the ResourceSlice while the claim is prepared.
  expectGPUDeviceCount(ctx, before-1)
  // Releasing the claim ... must switch the GPU back to the nvidia driver
  // and republish its `gpu` view.
  deletePod(ctx, ns, "pod1")
  expectGPUDeviceCount(ctx, before)
  ```
  </details>
- Makefile 新增 `E2E_LABEL_FILTER ?= !vfio`(默认跳过 vfio)与 `test-e2e-vfio` 目标(需 IOMMU 硬件 + driver 开 `PassthroughSupport` feature gate)。

### 后续发展方向 [AI]
- DRA 路径在把"整卡 VFIO 直通给 VM"做成可回归能力:API 形态(`VfioDeviceConfig` + `vfio.gpu.nvidia.com` class + `iommu.backendPolicy/enableAPIDevice`)已稳定到可写 e2e,且明确与裸 `gpu.nvidia.com` 共享同一物理设备的互斥语义(直通时 gpu 视图消失)。这与昨日 fabricmanager/UUID 身份校验的方向连起来——DRA 正在补齐 HGX 平台多卡直通分区的可靠性底座。证据仅为 e2e 与模板(非 CRD _types.go 本体),`VfioDeviceConfig` 的字段定义变化未在本区间出现,属对既有 API 的测试覆盖而非新增字段。

## 本期无实质改动(折叠)
<details><summary>gpu-driver-container 仅基础镜像日期 tag 升级;5 repo 无新提交</summary>

- NVIDIA/gpu-driver-container:仅 Ubuntu 基础镜像日期 tag 升级(resolute `20260927→20261006`、noble `20260917→20260930.1`、jammy `20260924.1→20260930`),无 driver 构建逻辑/OS 矩阵变化,不单列正文。 https://github.com/NVIDIA/gpu-driver-container/commit/16ec7fee338536f900ceee015f3991459f2a323b
- NVIDIA/k8s-device-plugin(无新提交,v0.20.1)
- NVIDIA/dcgm-exporter(无新提交,4.8.4)
- NVIDIA/DCGM(无新提交,master)
- NVIDIA/mig-parted(无新提交,v0.15.1)
- kai-scheduler/KAI-Scheduler(无新提交,v0.16.13)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=0fbefd5ec6a6235c4ed887298602498506cff6ce branch=main release=v26.7.2 scanned=2026-10-25 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=bb93a6b00e965191bed3fbdb8e15d51f5af949a1 branch=main release=v1.20.1 scanned=2026-10-25 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=16ec7fee338536f900ceee015f3991459f2a323b branch=main release=— scanned=2026-10-25 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-25 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=fc0fccb03bbe77b7c388475a263095c3f2f4539c branch=main release=v0.5.1 scanned=2026-10-25 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-25 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-25 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-25 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=96eb3764caadc87dfb1508af848970868dfbb8b4 branch=main release=v0.16.13 scanned=2026-10-25 -->
</content>
</invoke>
