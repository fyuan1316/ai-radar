# NVIDIA 算力栈 diff 雷达 2026-06-11

## 摘要
- **GDS/GDRCopy/MOFED 特性开关默认值改写**:k8s-device-plugin 把 `gds/gdrcopy/mofed-enabled` 三个 flag 的默认值从 `true` 改回 `false`(#1837),gpu-operator 配套让 state-device-plugin 在启动前 `lsmod` 探测 `gdrdrv`/`nvidia_fs` 内核模块、按需注入对应 envar——能力开启从"插件侧默认全开"转为"算子侧按宿主实际加载的模块推断",两仓协同的行为变更。
- gpu-operator 修 NRI 插件模式下的挂载:NRI 模式只挂 NRI socket,不再挂 containerd 运行时配置文件/socket(在 Talos 等只读宿主上会崩),`transformForRuntime` 拆成两条独立路径。
- KAI-Scheduler 跨 minor 到 v0.15.2(上期 v0.14.5),本期增量为两个 Helm 开关(`kaiConfigDeployer.enabled`/`defaultShard.enabled`,默认 true)+ node-scale-adjuster 镜像名对齐 GHCR。

## 当日重要改变
- **NVIDIA/k8s-device-plugin [架构方向/能力调整]** GDS/GDRCopy/MOFED 三特性 flag 默认值由 `true` 回退为 `false`,改由 gpu-operator 探测内核模块决定是否开启。证据:`cmd/nvidia-device-plugin/main.go` 删去三个 BoolFlag 的 `Value: true`;`assets/state-device-plugin/0400_configmap.yaml` 新增 lsmod 探测逻辑。https://github.com/NVIDIA/k8s-device-plugin/pull/1837
- **kai-scheduler/KAI-Scheduler [版本跨档]** Release v0.14.5 → v0.15.2(跨 minor),SUPPORT.md 将 v0.15 纳入 Active、v0.13 标 EOL。https://github.com/kai-scheduler/KAI-Scheduler/releases/tag/v0.15.2

## NVIDIA/gpu-operator: 1ab8a08a -> 27b9f650
- 比较 / Release: v26.3.2 | ahead=4 | files=3 | https://github.com/NVIDIA/gpu-operator/compare/1ab8a08a932c72475de7cdc28410b91fac23c7d1...27b9f65048828ab1b50d3e33a572dfd361500a3c

### AI 总结重点(源码 diff 为据)
- `transformForRuntime` 拆分:NRI 插件模式(`config.CDI.IsNRIPluginEnabled()`)与传统 runtime-config 模式分成两条互斥路径。NRI 模式只调新抽出的 `transformNRISocketMounts`(仅挂 NRI socket),不再走 `transformRuntimeConfigAndSocketMounts`(挂 `/etc/containerd/conf.d` 等 hostPath)。动机:noop runtime configurer 在 NRI 模式下不读写运行时配置,这些 hostPath(`DirectoryOrCreate`)在 Talos 等只读宿主上会失败。

  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
  -	if runtime == gpuv1.Containerd.String() {
  -		setContainerEnv(container, "CONTAINERD_RUNTIME_CLASS", getRuntimeClassName(config))
  +	if config.CDI.IsNRIPluginEnabled() {
  +		transformNRISocketMounts(obj, container)
  +	} else {
  +		if runtime == gpuv1.Containerd.String() {
  +			setContainerEnv(container, "CONTAINERD_RUNTIME_CLASS", getRuntimeClassName(config))
  +		}
  +		if err := transformRuntimeConfigAndSocketMounts(obj, runtime, container); err != nil {
  +			return err
  +		}
   	}
  ```
  顺带修正了 `NRI_SOCKET` 目标路径拼接:旧 `DefaultRuntimeNRISocketTargetDir+path.Base(...)` 改用 `path.Join(...)`。
  </details>

- state-device-plugin 启动脚本新增内核模块探测:`lsmod` 查 `gdrdrv` / `nvidia_fs`,命中则在未显式设置时分别写入 `GDRCOPY_ENABLED=true` / `GDS_ENABLED=true` / `MOFED_ENABLED=true` 到 feature-flags.env 并 source。即特性开启转为"按宿主实际加载模块推断",与下方 k8s-device-plugin 的默认值回退是同一动作的两端。

  <details><summary>代码依据 assets/state-device-plugin/0400_configmap.yaml</summary>

  ```diff
  +    extra_modules="gdrdrv nvidia_fs"
  +    > feature-flags.env
  +    for module in ${extra_modules}; do
  +        if lsmod | grep -q "^$module "; then
  +            case "$module" in
  +                "gdrdrv") [ -z "$GDRCOPY_ENABLED" ] && echo "GDRCOPY_ENABLED=true" >> feature-flags.env ;;
  +                "nvidia_fs")
  +                  [ -z "$GDS_ENABLED" ] && echo "GDS_ENABLED=true" >> feature-flags.env
  +                  [ -z "$MOFED_ENABLED" ] && echo "MOFED_ENABLED=true" >> feature-flags.env ;;
  +            esac
  +        fi
  +    done
  +    if [ -s "feature-flags.env" ]; then . ./feature-flags.env; fi
  ```
  </details>

### 后续发展方向 [AI]
- GDS/GDRCopy/MOFED 从"声明即开"转向"探测到驱动副模块才开",减少在缺 `nvidia_fs`/`gdrdrv` 节点上误开特性导致的设备插件启动副作用。证据仅覆盖 configmap 脚本与 device-plugin flag 默认值,未见对应 e2e 或 ClusterPolicy CRD 字段变化(`clusterpolicy_types.go` 本期未改)。
- NRI 路径的独立化是 CDI/NRI 取代传统 runtime-config 改写的持续推进信号;证据只到挂载分流这一层,未涉及 NRI 注入设备的具体逻辑。

## NVIDIA/k8s-device-plugin: febb5056 -> 8d844dca
- 比较 / Release: v0.19.2 | ahead=1 | files=1 | https://github.com/NVIDIA/k8s-device-plugin/pull/1837

### AI 总结重点(源码 diff 为据)
- `revert default enablement of features mofed, gdrcopy and gds (#1837)`:`gdrcopy-enabled`、`gds-enabled`、`mofed-enabled` 三个 CLI BoolFlag 删去 `Value: true`,默认值落回 Go 零值 `false`。等于撤回早前"默认全开"的决定,把开关决策权交还给 gpu-operator 的模块探测(见上)。

  <details><summary>代码依据 cmd/nvidia-device-plugin/main.go</summary>

  ```diff
   		&cli.BoolFlag{
   			Name:    "gdrcopy-enabled",
  -			Value:   true,
   			EnvVars: []string{"GDRCOPY_ENABLED"},
   		},
   		&cli.BoolFlag{
   			Name:    "gds-enabled",
  -			Value:   true,
   			EnvVars: []string{"GDS_ENABLED"},
   		},
   		&cli.BoolFlag{
   			Name:    "mofed-enabled",
  -			Value:   true,
   			EnvVars: []string{"MOFED_ENABLED"},
   		},
  ```
  </details>

### 后续发展方向 [AI]
- 与 gpu-operator 的 configmap 探测合起来看,是一次"避免在无 GDS/GDRCopy 能力的集群上凭默认值强开特性"的纠偏;裸跑 device-plugin(不经 operator)的用户现在需显式 `--gds-enabled` 才开。证据仅 1 文件 3 行,未覆盖文档/Helm values 是否同步说明。

## kai-scheduler/KAI-Scheduler: c87cdb20 -> 26e50a96
- 比较 / Release: v0.15.2 | ahead=3 | files=10 | https://github.com/kai-scheduler/KAI-Scheduler/compare/c87cdb20d241b80f3d36b7b0c3c4c2508862fcd3...26e50a964f1fdd16aca49aa1c3d227ddc3900939

### AI 总结重点(源码 diff 为据)
- 新增两个 Helm 顶层开关(默认 `true`),让 chart 安装时可不部署对应 CR,改为带外管理:`kaiConfigDeployer.enabled` 门控 post-install/upgrade 钩子(applies kai-config CR 的 Job/RBAC/ConfigMap),`defaultShard.enabled` 门控 chart 托管的默认 `SchedulingShard` CR。#1675

  <details><summary>代码依据 values.yaml + templates</summary>

  ```diff
  + defaultShard:
  +   enabled: true
    kaiConfigDeployer:
  +   enabled: true
  ```
  模板侧对应包 `{{- if .Values.kaiConfigDeployer.enabled }}` / `{{- if .Values.defaultShard.enabled }}`(default-shard.yaml、hooks/post/kai-config-deployer/{job,rbac,configmap}.yaml)。
  </details>

- node-scale-adjuster 默认镜像名修正:`node-scale-adjuster` → `nodescaleadjuster`,对齐 GHCR 实际发布名(#1677)。

  <details><summary>代码依据 pkg/apis/kai/v1/node_scale_adjuster/node_scale_adjuster.go</summary>

  ```diff
  -	imageName           = "node-scale-adjuster"
  +	imageName           = "nodescaleadjuster"
  ```
  </details>

### 后续发展方向 [AI]
- 两个 `*.enabled` 开关延续 KAI 把 kai-config / SchedulingShard 等 CR 从 chart 内联交付改为可带外 GitOps 管理的趋势(承接上期 `kaiConfigDeployer` out-of-release 钩子)。证据只到 Helm 模板门控层,未见调度器运行时逻辑变化;本期无 scheduler/binder 算法侧改动。

## 本期无实质改动(折叠)
<details><summary>5 仓 EMPTY + dra-driver 仅文档迁移</summary>

- NVIDIA/nvidia-container-toolkit(无新提交)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
- kubernetes-sigs/dra-driver-nvidia-gpu(ahead=2,files=30):仅 `Migrate docs to new website`——把 `docs/*.md` 移到 `site/content/docs/` 并填充原占位页(install/upgrade/prerequisites),删除 proposals 模板/README。无 Go 代码、CRD、Helm values 改动;upgrade.md 文字提及的 v0.4.0 行为(checkpoint 加 `BootID`、ComputeDomain 允许省略 `numNodes`)属对既有 release 的补充说明,非本期新代码。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/c4ee89702d334ce52d95450d09e7bc6bca3da519...d4dd860047e2a16de5c2f4775ccce25eff453622
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=27b9f65048828ab1b50d3e33a572dfd361500a3c branch=main release=v26.3.2 scanned=2026-06-11 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=538606ca9f4949f7b46f60e5e612143de1f17079 branch=main release=v1.19.1 scanned=2026-06-11 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=0dbfbb9cfab989f59f1960ac4554fc54dc61c529 branch=main release=— scanned=2026-06-11 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=8d844dca549ccd35eeb6f44bd65b0af97234c77c branch=main release=v0.19.2 scanned=2026-06-11 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=d4dd860047e2a16de5c2f4775ccce25eff453622 branch=main release=v0.4.0 scanned=2026-06-11 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-11 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=0869351a7d89ff24e68c93b92a50d981cea15580 branch=master release=— scanned=2026-06-11 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9221140671899b3c0dd281cd849927c0ba02120f branch=main release=v0.14.2 scanned=2026-06-11 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=26e50a964f1fdd16aca49aa1c3d227ddc3900939 branch=main release=v0.15.2 scanned=2026-06-11 -->
</content>
</invoke>
