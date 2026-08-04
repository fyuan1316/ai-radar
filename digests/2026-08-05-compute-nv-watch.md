# NVIDIA 算力栈 diff 雷达 2026-08-05

## 摘要
- gpu-driver-container 本期最活跃:新增 `_configure_fabric_manager()` 支持用 `NVFM_CONFIG_*` 环境变量覆写 fabricmanager.cfg 任意字段,并安装 FabricManager SDK(`-dev`/`-devel`)包;同时把各 install.sh 里按 `DRIVER_BRANCH` 分档的包名特判**全删**,统一走 ≥580 的裸包名(nvidia-fabricmanager / libnvidia-nscq / libnvsdm / nvidia-imex),imex 顺带带上 nvidia-modprobe。
- KAI-Scheduler [API/CRD 变更] PodGroup `minMember`/`minSubGroup` 的 `Minimum` 由 1 放宽到 0——0 表示"无 gang 约束、pod 全部弹性调度"(scale-to-zero 工作负载),webhook 去掉 <1 拒绝分支,job_info 由 `max(*MinMember,1)` 改为直接透传。
- gpu-operator:rhel-like 发行版的 driver nodePool nodeSelector 从"精确 VERSION_ID"改为"仅匹配主版本号"(新增 `...VERSION_ID.major` NFD 标签),把 rhel9.4/9.5 归入同一 rhel9 池;另修 vfio-manager preStop 钩子、vgpu-device-manager 加 system-node-critical 优先级。其余 6 仓无实质代码改动。

## 当日重要改变
- NVIDIA/gpu-driver-container [新能力] 支持通过 `NVFM_CONFIG_<字段>` 环境变量覆写 NVSwitch fabricmanager.cfg,并加装 FabricManager SDK。证据:各 `*/nvidia-driver` 新增 `_configure_fabric_manager()`;install.sh 加 `nvidia-fabricmanager-dev`/`nvidia-fabric-manager-devel`。 https://github.com/NVIDIA/gpu-driver-container/commit/3142b8367ea77867dc674b9374c62bae649757e2
- NVIDIA/gpu-driver-container [弃用/简化] 删除 install.sh 中按 `DRIVER_BRANCH` 分档的包名特判,统一采用 ≥580 的无分支后缀包名;nvlink5/imex 安装也去掉 `>=570`/`>=550` 门控。证据:rhel8/9、ubuntu22.04/24.04 install.sh 各 -39 行条件逻辑。 https://github.com/NVIDIA/gpu-driver-container/commit/3142b8367ea77867dc674b9374c62bae649757e2
- kai-scheduler/KAI-Scheduler [API/CRD 变更] PodGroup `minMember`/`minSubGroup` 允许 0(无 gang 要求,弹性/scale-to-zero)。证据:podgroup_types.go 与 CRD `minimum: 1`→`0`,podgroup_webhook.go 删 <1 拒绝分支。 https://github.com/kai-scheduler/KAI-Scheduler/pull/1989
- NVIDIA/gpu-operator [行为变更] rhel-like 发行版 driver nodePool nodeSelector 由精确 VERSION_ID 改为仅匹配主版本(新增 NFD `system-os_release.VERSION_ID.major` 标签)。证据:internal/state/nodepool.go + driver.go 新增 `nfdOSVersionIDMajorLabelKey`。 https://github.com/NVIDIA/gpu-operator/commit/ab1524761263e63157b8e7375d38da5053369877

## NVIDIA/gpu-operator: 2afd52ba -> ab152476
- 比较: https://github.com/NVIDIA/gpu-operator/compare/2afd52ba483dd018d213944ebe06c5983b8879bf...ab1524761263e63157b8e7375d38da5053369877 | ahead=8 | files=7 | Release: v26.3.3

### AI 总结重点(源码 diff 为据)
- **rhel-like 发行版的 driver nodePool 选择器从"精确小版本"降级为"仅主版本"**:`getNodePools` 生成每个 OS 池的 nodeSelector 时,原来无条件写入完整 `system-os_release.VERSION_ID`(如 9.4)。新逻辑判断:若 osTag 不以完整 osVersion 结尾(即该发行版的 tag 省略了小版本,如 rhel 只到 `rhel9`),则改为选择新引入的 `system-os_release.VERSION_ID.major` 标签(值 9),否则(如 ubuntu22.04)仍用完整 VERSION_ID。效果:rhel9.4 与 rhel9.5 节点被归入同一个 `rhel9` driver 池、共用一份预编译/容器化 driver,而 ubuntu 仍按 22.04/20.04 精确分池。测试断言同步:`rhel9` 池的 `VERSION_ID` selector 变空、`VERSION_ID.major` 变 "9"。
  <details><summary>代码依据 internal/state/nodepool.go + driver.go</summary>

  ```diff
  // driver.go 新增主版本 NFD 标签常量
  +	nfdOSVersionIDMajorLabelKey = "feature.node.kubernetes.io/system-os_release.VERSION_ID.major"

  // nodepool.go:osTag 省略小版本时,nodeSelector 只钉主版本
  +	if !strings.HasSuffix(osTag, osVersion) {
  +		osMajor, ok := nodeLabels[nfdOSVersionIDMajorLabelKey]
  +		if !ok { logger.Info("WARNING: Could not find NFD label...", "Label", nfdOSVersionIDMajorLabelKey); continue }
  +		nodePool.nodeSelector[nfdOSVersionIDMajorLabelKey] = osMajor
  +	} else {
  +		nodePool.nodeSelector[nfdOSVersionIDLabelKey] = osVersion
  +	}
  ```
  </details>
- **vfio-manager preStop 钩子改用 shell 包裹**:daemonset 的 preStop exec 从 `["vfio-manage unbind --all"]`(把整串当单个可执行文件名,实际不可执行)改为 `["/bin/sh","-c","vfio-manage unbind --all"]`,修复卸载 vfio 绑定的钩子从未真正执行的问题。
  <details><summary>代码依据 assets/state-vfio-manager/0500_daemonset.yaml</summary>

  ```diff
  -                command: ["vfio-manage unbind --all"]
  +                command: ["/bin/sh", "-c", "vfio-manage unbind --all"]
  ```
  </details>
- **vgpu-device-manager DaemonSet 提优先级**:加 `priorityClassName: system-node-critical`,防止节点资源紧张时 vGPU 设备管理器被驱逐。附带 kata-sandbox-device-plugin 镜像 v0.0.3→v0.0.4(CSV + values.yaml)。
  <details><summary>代码依据 assets/state-vgpu-device-manager/0600_daemonset.yaml</summary>

  ```diff
       nodeSelector:
         nvidia.com/gpu.deploy.vgpu-device-manager: "true"
  +      priorityClassName: system-node-critical
  ```
  </details>

### 后续发展方向 [AI]
- 主版本分池是为 RHEL/RHCOS 这类"同主版本二进制兼容、小版本频繁"的发行版减少 driver 池碎片(小版本升一格不再新建池、不触发全量重装)。证据仅覆盖 nodepool 选择器逻辑与 vfio/vgpu 两处运维修正,本次**无 `clusterpolicy_types.go`/`config/crd` 命中**,ClusterPolicy API 面稳定。

## NVIDIA/gpu-driver-container: 62d1d783 -> 3142b836
- 比较: https://github.com/NVIDIA/gpu-driver-container/compare/62d1d78310bbd0dfdaa5d7fb0e362e24e9d9e584...3142b8367ea77867dc674b9374c62bae649757e2 | ahead=14 | files=25 | Release: —

### AI 总结重点(源码 diff 为据)
- **新增 `_configure_fabric_manager()`:用环境变量覆写 NVSwitch fabricmanager.cfg 任意字段**:各发行版 `nvidia-driver` 入口脚本新增该函数,扫描 `NVFM_CONFIG_*` 环境变量,把 `NVFM_CONFIG_<字段>=<值>` 映射为 fabricmanager.cfg 里的 `<字段>=<值>`——已存在的行用 `sed` 原地替换(对 `\ & |` 做转义防注入),不存在的追加。在 NVLink5+ 与 NVSwitch(NVLink4-)两条启动路径里、拉起 fabric manager 之前调用。让 K8s 侧可通过容器 env 声明式调 fabric manager 配置,无需重打镜像。
  <details><summary>代码依据 rhel9/nvidia-driver(各发行版同款)</summary>

  ```diff
  +_configure_fabric_manager() {
  +    local fm_config_file=/usr/share/nvidia/nvswitch/fabricmanager.cfg
  +    nvfm_env_vars=$(env | grep '^NVFM_CONFIG_' || true)
  +    [ -z "${nvfm_env_vars}" ] && return 0
  +    while IFS='=' read -r name value; do
  +        local field="${name#NVFM_CONFIG_}"
  +        if grep -q "^${field}=" "${fm_config_file}"; then
  +            sed_escaped_value=$(printf '%s' "${value}" | sed -e 's/[\\&|]/\\&/g')
  +            sed -i "s|^${field}=.*|${field}=${sed_escaped_value}|" "${fm_config_file}"
  +        else printf '\n%s=%s\n' "${field}" "${value}" >> "${fm_config_file}"; fi
  +    done <<< "${nvfm_env_vars}"
  +}
  ...
       if _assert_nvlink5_system; then
  +        _configure_fabric_manager
  ```
  </details>
- **删除 install.sh 里按 `DRIVER_BRANCH` 分档的包名逻辑,统一 ≥580 无分支后缀命名**:fabricmanager/nscq/nvsdm/imex 四类包原本对 <580(及 nscq/nvsdm 的 <570、imex 的 <550)分别拼 `-${DRIVER_BRANCH}` 后缀或走旧包名(如 rhel 的 `nvidia-fabric-manager`)。新版一律用 `nvidia-fabricmanager`/`libnvidia-nscq`/`libnvsdm`/`nvidia-imex` 裸名,并删掉 nvlink5(`>=570`/`>=550`)与 imex(`>=550`)的分支门控。含义:driver 容器不再兼容 580 以下老分支的旧包命名——面向 580+ 标准化,是安装面的收敛。
  <details><summary>代码依据 rhel9/install.sh(rhel8/ubuntu 同向)</summary>

  ```diff
  fabricmanager_install() {
  -  if [ "$DRIVER_BRANCH" -ge "580" ]; then fabricmanager_package_name=nvidia-fabricmanager
  -  else fabricmanager_package_name=nvidia-fabric-manager; fi
  -  dnf install -y ${fabricmanager_package_name}-${DRIVER_VERSION}
  +  dnf install -y nvidia-fabricmanager-${DRIVER_VERSION} nvidia-fabric-manager-devel-${DRIVER_VERSION}
  +  dnf versionlock add nvidia-fabricmanager nvidia-fabric-manager-devel
  }
  nvlink5_pkgs_install() {
  -  if [ "$DRIVER_BRANCH" -ge "550" ]; then dnf install -y infiniband-diags nvlsm; fi
  +  dnf install -y infiniband-diags nvlsm
  }
  ```
  </details>
- **安装 FabricManager SDK(`-dev`/`-devel`)+ imex 带 nvidia-modprobe**:fabricmanager_install 现同时装开发包(rhel `nvidia-fabric-manager-devel`、ubuntu `nvidia-fabricmanager-dev`);imex_install 现附带装并 hold `nvidia-modprobe`(ubuntu22.04/24.04 另单独 pin nvidia-modprobe 版本)。附带:新增支持 driver 580.178.04 / 595.91.07 / 610.57.04,RHEL UBI 基础镜像上移。
  <details><summary>代码依据 ubuntu24.04/install.sh</summary>

  ```diff
  imex_install() {
  -  if [ "$DRIVER_BRANCH" -ge "580" ]; then imex_package_name=nvidia-imex
  -  elif [ "$DRIVER_BRANCH" -ge "550" ]; then imex_package_name=nvidia-imex-${DRIVER_BRANCH}
  -  else return 0; fi
  +  apt-get install -y --no-install-recommends nvidia-modprobe=${DRIVER_VERSION}* nvidia-imex=${DRIVER_VERSION}*
  +  apt-mark hold nvidia-modprobe nvidia-imex
  }
  ```
  </details>

### 后续发展方向 [AI]
- 两条线:①NVSwitch/NVLink5 大机(GB200 等)运维声明式化——fabricmanager.cfg 可由 env 注入,配合 SDK 开发包,指向 fabric manager 更深的集群化配置需求;②driver 容器安装面向 580+ 标准化收敛,砍掉历史分支的包名兼容。证据为 shell 脚本 hunk,未见 Dockerfile 层面构建矩阵大改(仅基础镜像 digest bump);未逐一核对 610 分支是否已在 versions.mk 全量放开。

## kai-scheduler/KAI-Scheduler: f218c69b -> 98fd1f72
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/f218c69bee5e5fc6031273ba555d09916b1ca89a...98fd1f72b6e774a2363239f847aa98dbf0773432 | ahead=3 | files=15 | Release: v0.17.0

### AI 总结重点(源码 diff 为据)
- **PodGroup `minMember`/`minSubGroup` 下限从 1 放宽到 0,语义为"无 gang 约束、全部弹性调度"**:`podgroup_types.go` 两字段的 `+kubebuilder:validation:Minimum` 由 1 改 0(CRD YAML 同步),注释明确 0 = "no gang requirement: all pods/SubGroups are scheduled elastically(如 scale-to-zero 工作负载)"。webhook 删掉 `minSubGroup < 1` 的拒绝分支;job_info 里 default subgroup 的 minAvailable 由 `max(*MinMember, 1)` 改为直接用 `*MinMember`(0 被如实透传,不再被抬到 1)。e2e 断言从"reject minSubGroup=0"翻转为"accept"。
  <details><summary>代码依据 podgroup_types.go / podgroup_webhook.go / job_info.go</summary>

  ```diff
  // types.go(CRD 同步)
  -	// +kubebuilder:validation:Minimum=1
  +	// +kubebuilder:validation:Minimum=0
  	MinMember *int32 `json:"minMember,omitempty" ...`

  // webhook.go:删掉 <1 拒绝分支
  -		if *spec.MinSubGroup < 1 {
  -			validationErrors... "minSubGroup ... must be equal to or greater than 1"
  -			return validationErrors
  -		}

  // job_info.go:0 如实透传
  -				minAvail = max(*podGroup.Spec.MinMember, 1)
  +				minAvail = *podGroup.Spec.MinMember
  ```
  </details>
- **Helm 值 `global.fips` 更名为 `global.fipsMode`(on/off 枚举)**:上期 v0.17.0 引入的 FIPS 开关由布尔 `global.fips` 改为字符串枚举 `global.fipsMode: on|off`,`_helpers.tpl`/values.yaml/fips_test.yaml 同步。属发布 API 命名收敛,不改能力。
  <details><summary>代码依据 提交标题 + deployments 改动</summary>

  ```
  chore(chart): rename global.fips to global.fipsMode with on/off values (#2007)
  deployments/kai-scheduler/templates/_helpers.tpl / values.yaml / tests/fips_test.yaml
  ```
  </details>
- **文档:HAMi GPU 共享(hamicore 插件)补充 per-container 显存指标**:`docs/gpu-sharing/hami/README.md` 说明 mutating webhook 现注入 `POD_UID`/`CONTAINER_NAME`/`CONTAINER_VGPU_MOUNT`,`kai-resource-isolator` 的可选 monitor DaemonSet 读 libvgpu.so 的共享内存缓存,在 `:9394` 暴露 HAMi 兼容指标(`hami_vgpu_memory_used_bytes` 等);要求 KAI ≥ v0.17.0,chart 升 1.1.0。仅文档,标注能力实现在 Project-HAMi/KAI-resource-isolator 仓(不在本 task 范围)。
  <details><summary>代码依据 docs/gpu-sharing/hami/README.md</summary>

  ```diff
  +│     - POD_UID / CONTAINER_NAME / CONTAINER_VGPU_MOUNT    │
  +│       (for per-container VRAM metrics)                   │
  +| DaemonSet (monitor, optional) | ... exposes HAMi-compatible VRAM metrics on `:9394` |
  +- `hami_vgpu_memory_used_bytes`
  ```
  </details>

### 后续发展方向 [AI]
- minMember=0 让 KAI 的 gang 调度支持"零下限弹性"作业(scale-to-zero、纯 best-effort 批任务),是 gang→弹性混合语义的一步;配合 SubGroup(prefill/decode 分组)可对 disaggregated 推理里"某子组可缩到 0"建模。证据为 API/CRD/webhook/job_info 真实 hunk;FIPS 更名与 HAMi 文档为配套,未见调度核心算法改动。

## 本期无实质改动(折叠)
<details>

- NVIDIA/nvidia-container-toolkit:无新提交
- NVIDIA/k8s-device-plugin:ahead=1,仅 bump/CI/merge,无实质代码
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交
- NVIDIA/dcgm-exporter:无新提交
- NVIDIA/DCGM:无新提交
- NVIDIA/mig-parted:ahead=2,仅 bump/CI/merge,无实质代码
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=ab1524761263e63157b8e7375d38da5053369877 branch=main release=v26.3.3 scanned=2026-08-05 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=828fc6ce327ddca61d6f179a13c18ab94e0c658c branch=main release=v1.20.0-rc.1 scanned=2026-08-05 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=3142b8367ea77867dc674b9374c62bae649757e2 branch=main release=— scanned=2026-08-05 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=c648e14098589a4a917796596bc4f96908b54433 branch=main release=v0.19.3 scanned=2026-08-05 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9c52a7d50994adbf2fbb5f1ce2f6466fa3f9936f branch=main release=v0.4.1 scanned=2026-08-05 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-05 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-05 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=38dc5097efaca03c384959770e3bad69f2346dd1 branch=main release=v0.14.4 scanned=2026-08-05 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=98fd1f72b6e774a2363239f847aa98dbf0773432 branch=main release=v0.17.0 scanned=2026-08-05 -->
</content>
</invoke>
