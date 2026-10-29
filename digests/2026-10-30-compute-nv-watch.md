# NVIDIA 算力栈 diff 雷达 2026-10-30

## 摘要
- **全栈级 busybox 供应链硬化(接续昨日 container-toolkit)**:gpu-operator、k8s-device-plugin、mig-parted 当日同步把 shell stage 从 Debian `busybox-static` 换成官方 `busybox:1.37.0-musl`,并新增 `hack/check-busybox-prefer-applets.sh` 作构建期闸门——若 busybox 编了 `CONFIG_FEATURE_PREFER_APPLETS=y` 就 fail build,因为那会让 `chroot <host> modprobe` 跑成 busybox applet、吞掉 softdep 导致 `vfio_iommu_type1` 加载失败(关联 k8s-driver-manager#299、mig-parted#553)。这是昨天 container-toolkit 同一改动向整个 NVIDIA 镜像舰队的铺开。
- **gpu-operator 新增 `controllers/cache` 独立 package**:把 controller-runtime 缓存从"全量 Node + 可选 OpenShift/DRA API"收窄——Node 对象只留 `ContainerRuntimeVersion`、剥 ManagedFields,且可选 API(ImageStream/ResourceClaim)缺失时优雅跳过而非启动失败,目标是压降 operator 常驻内存(#2886)。
- **k8s-device-plugin 改了 GPU 架构标签来源**:`nvidia.com/gpu.family` 标签从"按 CUDA compute capability 推断"改为优先读 NVML 上报的架构字符串,NVML 失败/unknown 才回退旧推断逻辑。

## 当日重要改变
- gpu-operator [新能力] 新增 `controllers/cache` package(`New`/`Options`/`stripUnusedNodeFields`),缓存只保留 Node 的 runtime 版本并剥 ManagedFields,降低 operator 内存占用。https://github.com/NVIDIA/gpu-operator/pull/2886
- k8s-device-plugin [新能力] `Device` 接口新增 `GetArchitecture()`,架构家族标签改用 NVML 实测值而非 compute capability 推断。https://github.com/NVIDIA/k8s-device-plugin/compare/e2a65758dcc510af97a526fdad13e830d34300ca...29dad4b682b5abc1df469d50a2bfe1f57abc7132
- gpu-operator / k8s-device-plugin / mig-parted [架构方向] 构建期 busybox applet 闸门全栈铺开,堵 `chroot modprobe` softdep 失效导致的内核模块加载故障。https://github.com/NVIDIA/k8s-driver-manager/issues/299
- 无 API/CRD 路径命中(`clusterpolicy_types.go` 等高价值信号文件本期未动)。

## NVIDIA/gpu-operator: ff1e0171 -> f3126ac2
- 比较: https://github.com/NVIDIA/gpu-operator/compare/ff1e0171b6cea17a04fcd0eab78cdbbad50c64f3...f3126ac2b4a535dd03f0b540cbed179800d336ff | ahead=4 | Release: v26.7.2

### AI 总结重点(源码 diff 为据)
- **缓存逻辑从 main.go 抽成独立 `controllers/cache` package,并改走自定义 `NewCache` 工厂**。原先 main.go 里硬编码 `DefaultNamespaces`(operatorNamespace + openshift namespace)的内联 `cache.Options`;现在 main.go 只调 `operatorcache.Options(operatorNamespace)` + `operatorcache.New`,把可选 API 解析、字段裁剪都收进新包。

  <details><summary>代码依据 cmd/gpu-operator/main.go</summary>

  ```diff
  -	openshiftNamespace := consts.OpenshiftNamespace
  -	cacheOptions := cache.Options{
  -		DefaultNamespaces: map[string]cache.Config{
  -			operatorNamespace: {},
  -			openshiftNamespace: {},
  -		},
  -	}
  	options := ctrl.Options{
  -		Cache:                   cacheOptions,
  +		Cache:                   operatorcache.Options(operatorNamespace),
  +		NewCache:                operatorcache.New,
  	}
  ```
  </details>

- **`New()` 工厂让可选 API 缺失不再是启动硬依赖**:遍历 `options.ByObject`,只对 `*ImageStream` / `*ResourceClaim` 两类做 `IsObjectNamespaced` 探测,命中 `NoMatchError`(集群没装该 API)就从缓存配置里删掉;真连不上 API server 才报错。即同一 operator 镜像能同时适配装/不装 DRA(`resource.k8s.io`)与 OpenShift(ImageStream)的集群。

  <details><summary>代码依据 controllers/cache/cache.go</summary>

  ```diff
  +	for object := range options.ByObject {
  +		switch object.(type) {
  +		case *apiimagev1.ImageStream, *resourcev1.ResourceClaim:
  +		default:
  +			continue
  +		}
  +		_, err := apiutil.IsObjectNamespaced(object, options.Scheme, options.Mapper)
  +		if meta.IsNoMatchError(err) {
  +			delete(options.ByObject, object)
  +		} else if err != nil {
  +			return nil, fmt.Errorf("discover optional cache API %T: %w", object, err)
  +		}
  +	}
  ```
  </details>

- **`stripUnusedNodeFields` 大幅裁剪缓存里的 Node 对象**:把 `Spec` 清空、`Status` 只保留 `NodeInfo.ContainerRuntimeVersion`、ManagedFields 置 nil。gpu-operator 只需要 Node 的 runtime 版本(判断 toolkit 注入方式),其余全丢——这是 #2886 "reduce cache memory footprint" 的核心手段,大集群下节省可观内存。

  <details><summary>代码依据 controllers/cache/cache.go</summary>

  ```diff
  +	runtimeVersion := node.Status.NodeInfo.ContainerRuntimeVersion
  +	node.ManagedFields = nil
  +	node.Spec = corev1.NodeSpec{}
  +	node.Status = corev1.NodeStatus{
  +		NodeInfo: corev1.NodeSystemInfo{ContainerRuntimeVersion: runtimeVersion},
  +	}
  ```
  </details>

- **busybox 基础镜像换官方 musl 版 + 构建期 applet 闸门**(与 k8s-device-plugin/mig-parted 同步):shell stage 从 `debian:trixie-slim` 装 `busybox-static` 改为直接 `FROM busybox:1.37.0-musl`,随后 `RUN check-busybox-prefer-applets.sh` 验证没启 `PREFER_APPLETS`。

  <details><summary>代码依据 docker/Dockerfile</summary>

  ```diff
  -FROM debian:trixie-slim@sha256:... AS shell
  -RUN apt-get update \
  - && apt-get install -y --no-install-recommends busybox-static \
  +FROM busybox:1.37.0-musl@sha256:5cec3fc1... AS shell
  +RUN mkdir /busybox \
   && cp /bin/busybox /busybox/busybox \
   && /busybox/busybox --install -s /busybox
  +COPY hack/check-busybox-prefer-applets.sh /tmp/check-busybox-prefer-applets.sh
  +RUN /tmp/check-busybox-prefer-applets.sh /busybox/busybox
  ```
  </details>

- 次要:`driver-toolkit` 字符串字面量抽成常量 `consts.DriverToolkitImageStreamName`,在 `object_controls.go`、`clusterinfo.go` 两处复用,纯重构无行为变化。

### 后续发展方向 [AI]
- cache 包把"可选 API 探测"做成可扩展的 switch,后续若再接入新的可选 CRD(如更多 DRA 资源类型)会往这里加 case;结合 Node 裁剪,方向是**让单一 operator 镜像在 vanilla K8s / OpenShift / 装或不装 DRA 的集群上都低内存跑**。证据只覆盖 cache.go 的 `New`/`stripUnusedNodeFields` 两函数,hunk 在 `cachedNamespaces` 处截断,未见完整命名空间配置,无法确认是否仍缓存 openshift namespace。

## NVIDIA/gpu-driver-container: f5d915c1 -> ec01bc0b
- 比较: https://github.com/NVIDIA/gpu-driver-container/compare/f5d915c1324483b8166f6da5f9c40bc8299e8c9f...ec01bc0b4e83362b8cb68603a0547b23c9a0d429 | ahead=2 | Release: —

### AI 总结重点(源码 diff 为据)
- **RHEL 预编译 driver 容器新增 driver 配置摘要落盘**:rhel8/9/10 三份 `precompiled/nvidia-driver` 脚本各加 `_store_driver_digest()`,把环境变量 `DRIVER_CONFIG_DIGEST` 写到 `${RUN_DIR}/nvidia-driver.state`,并在 `_load()` 流程里(`_load_driver` + `_mount_rootfs` 之后)调用。给 driver 容器留下一份"当前配置摘要"的持久化锚点,便于上层(operator / driver-manager)判断配置是否变更、是否需要重载。

  <details><summary>代码依据 rhel9/precompiled/nvidia-driver</summary>

  ```diff
  +_store_driver_digest() {
  +    local digest_file="${RUN_DIR}/nvidia-driver.state"
  +    local current_digest="${DRIVER_CONFIG_DIGEST:-}"
  +    echo "${current_digest}" > "$digest_file"
  +}
   _load() {
       _create_module_params_conf
       _load_driver
       _mount_rootfs
  +    _store_driver_digest
  ```
  </details>

### 后续发展方向 [AI]
- 这是"配置漂移检测"基建的一步:先把 digest 落盘,下一步大概率有读取/比对逻辑决定 driver 容器是否需要滚动重启。证据只覆盖写入侧(三份 RHEL 脚本的 `_store_driver_digest`),未见 Ubuntu 分支或读取/比对消费方,`DRIVER_CONFIG_DIGEST` 的来源也未在本 diff 出现。

## NVIDIA/k8s-device-plugin: e2a65758 -> 29dad4b6
- 比较: https://github.com/NVIDIA/k8s-device-plugin/compare/e2a65758dcc510af97a526fdad13e830d34300ca...29dad4b682b5abc1df469d50a2bfe1f57abc7132 | ahead=6 | Release: v0.20.1

### AI 总结重点(源码 diff 为据)
- **`Device` 接口新增 `GetArchitecture() (string, error)`,GPU 家族标签改用 NVML 实测值**:`newArchitectureLabels` 原先直接 `getArchFamily(computeMajor, computeMinor)`(按 CUDA 算力版本号推断家族);现在优先 `device.GetArchitecture()`(nvmlDevice 走 `GetArchitectureAsString()`),把结果小写化、空格换连字符作为 `family`,仅当出错 / 为空 / 为 `unknown` 时才回退到旧的 compute-capability 推断。即 `nvidia.com/gpu.family` 标签来源从"间接推断"变为"NVML 直报"。

  <details><summary>代码依据 internal/lm/resource.go</summary>

  ```diff
  -	family := getArchFamily(computeMajor, computeMinor)
  +	family, err := device.GetArchitecture()
  +	if err == nil {
  +		family = strings.ReplaceAll(family, " ", "-")
  +		family = strings.ToLower(family)
  +	}
  +	if err != nil || len(family) == 0 || family == "unknown" {
  +		family = getArchFamily(computeMajor, computeMinor)
  +	}
  ```
  </details>

- **MIG / vfio 设备不支持该方法**:`nvmlMigDevice` 与 `vfioDevice` 的 `GetArchitecture` 均返回 "not supported" 错误,因此这两类设备会走回退推断分支——确保新路径不破坏 MIG / passthrough 场景的标签。

  <details><summary>代码依据 internal/resource/nvml-mig-device.go, sysfs-device.go</summary>

  ```diff
  +// GetArchitecture is not supported for MIG devices
  +func (d nvmlMigDevice) GetArchitecture() (string, error) {
  +	return "", fmt.Errorf("GetArchitecture is not supported for MIG devices")
  +}
  ```
  </details>

- **同步 busybox musl 迁移 + applet 闸门 + distroless go v4.1.7→v4.1.8**(与 gpu-operator/mig-parted 一致),外加 mock/测试里 `interface{}`→`any` 清理。

  <details><summary>代码依据 deployments/container/Dockerfile</summary>

  ```diff
  -FROM debian:trixie-slim AS shell
  -RUN apt-get update \
  - && apt-get install -y --no-install-recommends busybox-static \
  +FROM busybox:1.37.0-musl AS shell
  +RUN mkdir /busybox \
  +COPY hack/check-busybox-prefer-applets.sh /tmp/check-busybox-prefer-applets.sh
  +RUN /tmp/check-busybox-prefer-applets.sh /busybox/busybox
  -FROM nvcr.io/nvidia/distroless/go:v4.1.7 AS application
  +FROM nvcr.io/nvidia/distroless/go:v4.1.8 AS application
  ```
  </details>

### 后续发展方向 [AI]
- 标签语义更准(新架构如 Blackwell 不再依赖人工维护 compute-capability→family 映射表即可正确打标),对基于 `nvidia.com/gpu.family` 做 nodeAffinity/调度的用户是无缝提升。证据只覆盖 `newArchitectureLabels` 与四个 Device 实现的 `GetArchitecture`,未见 `GetArchitectureAsString` 对各代卡返回的具体字符串,也未见是否影响其他 family 相关标签。

## NVIDIA/mig-parted: 912e13f9 -> 37c87154
- 比较: https://github.com/NVIDIA/mig-parted/compare/912e13f9ff8e31d6a1bf5c66a5c58b343fadf9b8...37c8715496e73eca0cd7739e6107616d7525236a | ahead=4 | Release: v0.15.1

### AI 总结重点(源码 diff 为据)
- **同套 busybox musl 迁移 + applet 闸门**(与 gpu-operator/k8s-device-plugin 同日同构),check 脚本显式引用 `mig-parted#553` 作为背景;同时 `THIRD_PARTY_NOTICES.md` 删掉 `golang.org/x/mod/semver` 依赖项(含其完整 BSD-3 license 段),说明该依赖已从代码中移除。distroless 基础镜像已是 v4.1.8。

  <details><summary>代码依据 deployments/container/Dockerfile + THIRD_PARTY_NOTICES.md</summary>

  ```diff
  -FROM debian:trixie-slim AS shell
  -RUN apt-get update && apt-get install -y --no-install-recommends busybox-static \
  +FROM busybox:1.37.0-musl AS shell
  +RUN mkdir /busybox \
  +RUN /tmp/check-busybox-prefer-applets.sh /busybox/busybox
  ---
  -| `golang.org/x/mod/semver` | BSD-3-Clause | `golang.org/x/mod` |
  ```
  </details>

### 后续发展方向 [AI]
- 纯供应链/依赖清理,无 MIG 切分能力变化;`x/mod/semver` 的移除暗示某处版本比较逻辑被换成别的实现,但本 diff 未含对应 Go 代码,无法确认替换对象。

## 本期无实质改动(折叠)
<details><summary>5 个 repo 仅 bump/CI/merge 或无新提交</summary>

- NVIDIA/nvidia-container-toolkit:ahead=2,仅 bump/CI/merge(昨日已完成 busybox 迁移主改动)
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交(v0.5.1)
- NVIDIA/dcgm-exporter:无新提交(4.8.4)
- NVIDIA/DCGM:无新提交(master)
- kai-scheduler/KAI-Scheduler:无新提交(v0.16.14)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=f3126ac2b4a535dd03f0b540cbed179800d336ff branch=main release=v26.7.2 scanned=2026-10-30 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1d479dac4bd652cfb131d67b3662e72a31855a8d branch=main release=v1.20.1 scanned=2026-10-30 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=ec01bc0b4e83362b8cb68603a0547b23c9a0d429 branch=main release=— scanned=2026-10-30 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=29dad4b682b5abc1df469d50a2bfe1f57abc7132 branch=main release=v0.20.1 scanned=2026-10-30 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=43ce288759a2748748b5c9cacd7a34a8b4e89648 branch=main release=v0.5.1 scanned=2026-10-30 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-30 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-30 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=37c8715496e73eca0cd7739e6107616d7525236a branch=main release=v0.15.1 scanned=2026-10-30 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=0243c4e948b722893897cfd72e7f15cb8e371725 branch=main release=v0.16.14 scanned=2026-10-30 -->
