# NVIDIA 算力栈 diff 雷达 2026-10-15

## 摘要
- **L1 驱动容器化**最有料:`gpu-driver-container` 新增 `nvidia-64k` 预编译驱动容器 flavor(arm64 专属、64KB 页内核),是 Grace/ARM64 服务器侧的能力补齐;同时修了 DOCA-OFED≥3.2.1 的 `ofa_kernel-dkms` 符号链接导致 GPUDirect RDMA 构建失败。
- **L4 调度**:KAI-Scheduler 给 scheduler cache 的 ConfigMap informer 加了 transform,只保留对象身份(Name/NS/UID/RV)丢掉 Data/BinaryData,降低调度器常驻内存——纯 perf,无调度语义变化。
- 其余均为小修:gpu-operator 把 4 个 operand DaemonSet 的 `priorityClassName` 统一改成可被 `.Daemonsets.PriorityClassName` 覆盖并 `quote`;container-toolkit、k8s-device-plugin 各一处 bug fix。无 CRD/API 字段增删,无弃用,无跨 major 版本。

## 当日重要改变
- NVIDIA/gpu-driver-container [新能力] 新增 `nvidia-64k` 预编译驱动容器 flavor,仅构建/发布 arm64(64KB 页内核),CI 矩阵与 `precompiled.sh`/`build-kernel-matrix.sh` 三处同步加 arm64-only 约束。https://github.com/NVIDIA/gpu-driver-container/commit/883d2c86946e5116c864f1a338606eadb4239cea
- NVIDIA/gpu-driver-container [新能力/修复] GPUDirect RDMA 适配 DOCA-OFED≥3.2.1:头文件迁到 `ofa_kernel-dkms` 后在容器内按宿主绝对路径补建软链,否则 peermem/dkms 构建断链。https://github.com/NVIDIA/gpu-driver-container/commit/883d2c86946e5116c864f1a338606eadb4239cea

## NVIDIA/gpu-driver-container: 593a4158 -> 883d2c86
- 比较: 593a41587d3a7d856bb67b0fb88ffd1ea381f0f4 -> 883d2c86 | ahead=6 | files=17 | Release: —

### AI 总结重点(源码 diff 为据)
- **新增 `nvidia-64k` 预编译 flavor,全链路强制 arm64-only**。`.github/workflows/image.yaml` 的 flavor 枚举加入 `nvidia-64k`,并在 include/exclude 矩阵里排除所有 amd64 组合、PR 只跑 595+6.8 一个 arm64 组合覆盖该路径;`precompiled-build.yaml` 的 `discover-kernel` runner 由固定 amd64 改成按 flavor 选 `arm64`(`inputs.flavor == 'nvidia-64k'`),base image 发现镜像也随 `DISCOVERY_ARCH` 走 arm64。这是对 Grace/ARM64 服务器 64KB 页内核的发布面补齐。
  <details><summary>代码依据 .github/workflows/precompiled-build.yaml</summary>

  ```diff
  -    runs-on: linux-amd64-cpu4
  +    runs-on: linux-${{ inputs.flavor == 'nvidia-64k' && 'arm64' || 'amd64' }}-cpu4
  +    env:
  +      DISCOVERY_ARCH: ${{ inputs.flavor == 'nvidia-64k' && 'arm64' || 'amd64' }}
  ...
  -          ARCHITECTURES=$(jq -c ... '[.[] | select(. == "amd64" or ($dist != "ubuntu22.04" and $flavor != "azure-fde"))] | unique' <<< "$PLATFORMS")
  +          ARCHITECTURES=$(jq -c ... '[.[] | select(
  +              if $flavor == "nvidia-64k" then . == "arm64"
  +              else . == "amd64" or ($dist != "ubuntu22.04" and $flavor != "azure-fde") end
  +            )] | unique' <<< "$PLATFORMS")
  ```
  </details>
- **构建脚本/base 镜像同步补 arm64 包源**。`scripts/precompiled.sh` 在 `buildBaseImage`/`targetPlatforms` 里对 `nvidia-64k` 强制 `--platform=linux/arm64` 并只回 `linux/arm64`;`base/Dockerfile` 从硬编码 `[arch=amd64] archive.ubuntu.com` 改成按 `dpkg --print-architecture` 分流,arm64 走 `ports.ubuntu.com/ubuntu-ports`;`tests/scripts/build-kernel-matrix.sh` 在非多拱分支里把 `nvidia-64k` 从 flavor 列表剔除。三处都注释"nvidia-64k is arm64-only",口径统一。
  <details><summary>代码依据 scripts/precompiled.sh / base/Dockerfile</summary>

  ```diff
  +    if [[ "${KERNEL_FLAVOR}" == "nvidia-64k" ]]; then
  +        export DOCKER_BUILD_PLATFORM_OPTIONS="--platform=linux/arm64"
  +    fi
  ...
  +    if [[ "$KERNEL_FLAVOR" == "nvidia-64k" ]]; then
  +        echo "linux/arm64"
  +    elif [[ "$DIST" == "signed_ubuntu24.04" || "$DIST" == "signed_ubuntu26.04" ]] && [[ "$KERNEL_FLAVOR" != "azure-fde" ]]; then
  +        echo "linux/amd64 linux/arm64"
  -    if [[ "$DIST" == "signed_ubuntu24.04" ... ]]
  ```
  </details>
- **GPUDirect RDMA 适配 DOCA-OFED≥3.2.1 的目录迁移**。rhel8/9/10、ubuntu22/24/26 六个 `nvidia-driver` 脚本的 `_link_ofa_kernel`(ubuntu22.04 是 `_create_driver_package`)里,检测到宿主 `/run/mellanox/drivers/usr/src/ofa_kernel-dkms` 存在则在容器内同绝对路径补建软链——因为 `mlnx-ofed-kernel-dkms` 把头文件挪到了 `ofa_kernel-dkms` 且留的是绝对符号链接,不补链会在容器根解析失败。配套还有一条 "Fix nvidia-peermem build with dkms" 提交。
  <details><summary>代码依据 ubuntu24.04/nvidia-driver(六个脚本同形)</summary>

  ```diff
   _link_ofa_kernel() (
       if _gpu_direct_rdma_enabled; then
  +        if [[ -d /run/mellanox/drivers/usr/src/ofa_kernel-dkms && ! -e /usr/src/ofa_kernel-dkms ]]; then
  +            ln -s /run/mellanox/drivers/usr/src/ofa_kernel-dkms /usr/src/ofa_kernel-dkms
  +        fi
           ln -s /run/mellanox/drivers/usr/src/ofa_kernel /usr/src/
  ```
  </details>

### 后续发展方向 [AI]
- arm64/Grace 的预编译驱动发布面在系统性补齐(先前 azure-fde/jammy 的 arm64 缺位是硬编码排除,现在 `nvidia-64k` 反向成为 arm64-only 的一等 flavor)。证据只覆盖 CI/构建脚本的 flavor 分流与包源,未见运行时(device-plugin/toolkit)对 64KB 页内核的专门处理——是否需要上层配合暂无 diff 佐证。
- GPUDirect RDMA 对 DOCA-OFED 新目录布局的跟随是被动修复,说明 Mellanox/DOCA 侧的打包仍在变动;需持续盯 `_link_ofa_kernel` 这类宿主路径假设。

## kai-scheduler/KAI-Scheduler: 049d1ba6 -> 85eb6560
- 比较: 049d1ba67d1c2b4922e681829455c8d042c0b85d -> 85eb6560 | ahead=3 | files=9 | Release: v0.18.5

### AI 总结重点(源码 diff 为据)
- **调度器 cache 给 ConfigMap informer 装 transform,只留对象身份**。新增 `pkg/scheduler/cache/configmap_transform.go`:`compactSchedulerConfigMap` 把 informer 里的 `*v1.ConfigMap` 重建成只含 `Name/Namespace/UID/ResourceVersion` 的壳,丢弃 `Data/BinaryData/Labels/Annotations/ManagedFields`;`cache.go` 的 `newSchedulerCache` 在 Pod transform 之后挂上 `setSchedulerConfigMapTransform`。目的是降常驻内存(changelog:"Reduce scheduler cache memory by retaining only ConfigMap identity",#2376)。测试断言 informer lister 返回的壳 `Data/BinaryData` 为 nil,但底层 API 对象与 Snapshot 的 `ConfigMapInfo` 不受影响——即调度决策用的信息面不变,仅缓存瘦身。
  <details><summary>代码依据 pkg/scheduler/cache/configmap_transform.go</summary>

  ```diff
  +func compactSchedulerConfigMap(obj any) (any, error) {
  +	configMap, ok := obj.(*v1.ConfigMap)
  +	if !ok { return obj, nil }
  +	return &v1.ConfigMap{
  +		ObjectMeta: metav1.ObjectMeta{
  +			Name:            configMap.Name,
  +			Namespace:       configMap.Namespace,
  +			UID:             configMap.UID,
  +			ResourceVersion: configMap.ResourceVersion,
  +		},
  +	}, nil
  +}
  ```
  </details>
- 其余两条是 release CI 收口(#2423):`on-release.yaml` 删掉"上传 chart 作为 release asset"、改为 e2e 优先装 `push-artifacts.yaml` 已发布的 chart(带 10×30s 轮询等待并发发布),`push-artifacts.yaml` 在 tag 时用 `gh release upload --clobber` 把 chart 挂到已存在的 GitHub Release。纯发布流程,无调度逻辑。

### 后续发展方向 [AI]
- KAI-Scheduler 近期在做 cache 内存优化(此前已见 Pod transform,本次补 ConfigMap transform),方向是大规模集群下调度器常驻足迹收敛。证据只覆盖 cache 层 informer transform,未触及打分/抢占/GPU sharing 语义。

## 本期无实质改动(折叠)
<details><summary>下列 repo 本期仅 bug fix 小改或无新提交/仅 bump,未单列正文</summary>

- NVIDIA/gpu-operator:仅 1 条提交(#2922),把 dcgm/dcgm-exporter/dra-validator/dra-driver 四个 operand 的 DaemonSet `priorityClassName` 从硬编码/未 quote 统一为 `{{ .Daemonsets.PriorityClassName | default "system-node-critical" | quote }}`,让 GPUCluster 自定义优先级类生效且避免 `on`/`null` 等 YAML 保留字被误解析;纯模板+测试,无 CRD 字段改动。https://github.com/NVIDIA/gpu-operator/pull/2922
- NVIDIA/nvidia-container-toolkit:一处 bug fix,`hook_config.go` 的 `getConfigOption` 把 `reflect.TypeFor[**hookConfig]()`(双指针,反射取不到字段,导致 unsupported-capability panic 里报错的 config 选项名错误)改为 `reflect.TypeFor[hookConfig]()`。https://github.com/NVIDIA/nvidia-container-toolkit/commit/cec3a629d1ae486b0b6c984a67c61acd0350027a
- NVIDIA/k8s-device-plugin:一处错误信息修正,`nvml_devices.go` 的 MIG `GetPaths` 在 compute instance 路径缺失时误报 GPU instance 路径(`giCapPath`→`ciCapPath`)。https://github.com/NVIDIA/k8s-device-plugin/commit/a0d31ccbc26e83a4a4ebe027912a79bc3b909728
- kubernetes-sigs/dra-driver-nvidia-gpu:ahead=6 全是 dependabot bump(go-nvlib 0.12→0.13、prometheus/client_golang、source-map-js)+ merge,无实质代码。
- NVIDIA/dcgm-exporter:无新提交。
- NVIDIA/DCGM:无新提交(master 分支)。
- NVIDIA/mig-parted:ahead=4 仅 bump/CI。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=fbe793082611bfdba1621b614edefdd3461bf14d branch=main release=v26.7.1 scanned=2026-10-15 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=cec3a629d1ae486b0b6c984a67c61acd0350027a branch=main release=v1.20.1 scanned=2026-10-15 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=883d2c86946e5116c864f1a338606eadb4239cea branch=main release=— scanned=2026-10-15 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=a0d31ccbc26e83a4a4ebe027912a79bc3b909728 branch=main release=v0.20.1 scanned=2026-10-15 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=35fa51e30ba914fbe1b9b237c5eebba5bb2ac7ec branch=main release=v0.5.1 scanned=2026-10-15 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-15 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-15 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-15 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=85eb6560a96d4cee09a5bd72b479f61bdc49947c branch=main release=v0.18.5 scanned=2026-10-15 -->
