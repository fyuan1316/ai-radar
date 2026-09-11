# NVIDIA 算力栈 diff 雷达 2026-09-12

## 摘要
- **container-toolkit 把 update-ldcache hook 的执行路径整体加固**:host `ldconfig` 改为在任何 namespace/pivot 之前克隆进「密封 memfd」并按 fd 直接 exec(消除对 host 路径的 TOCTOU 竞争),同时用空 tmpfs 罩住容器 `/proc`、`/sys` 再 pivot——L1 容器运行时的安全边界改动,值得重点看。
- **gpu-driver-container 新增 R615(615.71.09)分支,并把 RHEL8/9 的 615+ 默认切到 `-open`(开源内核模块)module stream**——NVIDIA open GPU kernel module 成为新数据中心分支在 RHEL 上的默认形态,OS/驱动矩阵风向。
- device-plugin 仅配置面小改(可选的 `app.kubernetes.io/component` selector 标签,默认关);其余 6 仓无实质改动。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [架构方向/安全] update-ldcache hook 从「mount host ldconfig + mount /proc」重写为「memfd 密封克隆 + fd exec + 屏蔽 /proc /sys」,删除 `safe-exec_{linux,other}.go`。证据:`internal/ldconfig/ldconfig.go`、`ldconfig_linux.go`。PR https://github.com/NVIDIA/nvidia-container-toolkit/pull/2059
- NVIDIA/gpu-driver-container [新能力/OS矩阵] 新增 driver 615.71.09;RHEL8/9 上 `DRIVER_BRANCH >= 615` 时 module stream 从 `${branch}-dkms` 切为 `${branch}-open`。证据:`rhel8/install.sh`、`rhel9/install.sh`。PR https://github.com/NVIDIA/gpu-driver-container/pull/1004

## NVIDIA/nvidia-container-toolkit: 33ba6813 -> 341598c1
- 比较: https://github.com/NVIDIA/nvidia-container-toolkit/compare/33ba68134945dded5fd2060acf3a565421d33f13...341598c1c36ad7fc4a80cb7a00239fdd5a59d053 | ahead=8 | 最新 Release v1.20.0

### AI 总结重点(源码 diff 为据)
- **host `ldconfig` 的载入方式从「mount 进容器 scratch 目录」改为「克隆进密封 memfd」**。旧 `prepareRoot()` 返回一个字符串路径(`mountLdConfig` 在 `/run/nvidia-ctk-hook/<uuid>/ldconfig` 处 bind mount host 二进制);新 `prepareRoot()` 返回 `*os.File`——先调 `cloneLdconfigIntoMemfd`(底层 `libcontainer/exeseal.CloneBinary`)把 host ldconfig 内容复制进匿名 memfd,再 pivot。作者注释点明动机:克隆发生在 pivot 之前,`l.ldconfigPath` 尚无 attacker 可控内容,**消除对该路径的 TOCTOU 竞争**;memfd 无路径、不属任何 mount namespace,pivot_root 后仍可用。
  <details><summary>代码依据 internal/ldconfig/ldconfig.go</summary>

  ```diff
  -func (l *Ldconfig) prepareRoot() (string, error) {
  -	root, err := os.OpenRoot(l.inRoot)
  -	...
  -	if err := mountProc(root); err != nil { return "", ... }
  -	ldconfigPath, err := mountLdConfig(l.ldconfigPath, root)
  +func (l *Ldconfig) prepareRoot() (_ *os.File, rerr error) {
  +	// Clone before touching the root: no TOCTOU race on l.ldconfigPath
  +	memfd, err := cloneLdconfigIntoMemfd(l.ldconfigPath)
  +	...
  +	if err := maskPseudoFilesystems(root); err != nil { return nil, ... }
  ```
  </details>
- **exec 从「按路径 syscall.Exec」改为「按 fd exec memfd」**。`UpdateLDCache()` 拿到 `memfd` 后 `SafeExec(memfd, args, nil)`;`SafeExec` 签名由 `(path string, ...)` 改为 `(file *os.File, ...)`,旧的两个 `safe-exec_{linux,other}.go`(内部再 `cloneBinary` 一次)被整体删除——克隆职责上移到 prepareRoot,exec 阶段只认 fd。
  <details><summary>代码依据 internal/ldconfig/ldconfig.go + safe-exec_linux.go(removed)</summary>

  ```diff
  -	ldconfigPath, err := l.prepareRoot()
  +	memfd, err := l.prepareRoot()
  +	defer memfd.Close()
  ...
  -	return SafeExec(ldconfigPath, args, nil)
  +	return SafeExec(memfd, args, nil)
  # 整文件删除 internal/ldconfig/safe-exec_linux.go(SafeExec/cloneBinary 旧实现)
  ```
  </details>
- **新增 `maskPseudoFilesystems`,替代旧 `mountProc`**:pivot 前在容器 root 的 `proc`、`sys` 上各 mount 一层空 tmpfs。注释说明 ldconfig 本不需要这两个 fs,与其「假设第三方二进制永远不读」,不如把它们无条件置空——无论是从外部带进来的 stale mount 还是镜像里 baked-in 的静态内容,pivot 后都读不到。
  <details><summary>代码依据 internal/ldconfig/ldconfig_linux.go</summary>

  ```diff
  +func maskPseudoFilesystems(root *os.Root) error {
  +	for _, name := range []string{"proc", "sys"} {
  +		f, err := root.Open(name)
  +		...
  +		if err := unix.Mount("tmpfs", utils.GetProcFdPath(f), "tmpfs", 0, ""); err != nil {
  +			return fmt.Errorf("error masking %s: %w", name, err)
  ```
  </details>
- **附带**:`internal/dxcore/dxcore.go` 修 32-bit 构建——`getAdapter` 从 `(*[1 << 30]C.struct_...)` 大数组指针强转改为 `unsafe.Slice(c.adapterList, c.adapterCount)`(`1<<30` 在 32 位上溢出)。dependabot 加 `cooldown.exclude: github.com/NVIDIA/*`(NVIDIA 自家依赖不走冷却期)。

### 后续发展方向 [AI]
- ldconfig hook 的加固方向明确:**把「exec 一个 host 上的、运行时才载入的二进制」这一动作压缩到攻击面最小**——memfd 密封 + fd exec + pseudo-fs 屏蔽,是防「容器镜像/stale mount 影响 host ldconfig 行为」的纵深防御。证据只覆盖 ldconfig hook 这一条 hook 路径,未见其它 hook(如 create-symlinks、update-ldcache 以外)是否同步改造。
- 证据未涉及 CDI/CRD 层,ClusterPolicy 字段无改动;这轮纯运行时 hook 内部实现,配置面不变。

## NVIDIA/gpu-driver-container: ccc2bd60 -> 6357f520
- 比较: https://github.com/NVIDIA/gpu-driver-container/compare/ccc2bd607912c8d8a4fd2bde2b0aaf1cac902d71...6357f5208edce4c8eda53446ad2cb68e03940349 | ahead=11 | 最新 Release —

### AI 总结重点(源码 diff 为据)
- **新增数据中心驱动分支 615.71.09**,进入全 CI 矩阵(`.common-ci.yml`、`versions.mk`、`.nvidia-ci.yml`):`DRIVER_VERSIONS` 从 `580.178.04 595.91.07 610.57.04` 追加 `615.71.09`,ubuntu22.04/24.04/26.04、rhel10 各并行矩阵同步加入;`.nvidia-ci.yml` 的 `PUBLISH_VERSIONS` 本轮只发 615.71.09。
  <details><summary>代码依据 .common-ci.yml</summary>

  ```diff
  -  DRIVER_VERSIONS: 580.178.04 595.91.07 610.57.04
  +  DRIVER_VERSIONS: 580.178.04 595.91.07 610.57.04 615.71.09
  ...
  -      - DRIVER_VERSION: [580.178.04, 595.91.07, 610.57.04]
  +      - DRIVER_VERSION: [580.178.04, 595.91.07, 610.57.04, 615.71.09]
  ```
  </details>
- **RHEL8/9 上 615+ 分支默认切到开源内核模块流(`-open`)**。`extra_pkgs_install()` 原先无条件 `dnf module enable nvidia-driver:${DRIVER_BRANCH}-dkms`;现按分支号分流:`>= 615` 用 `${branch}-open`,否则仍 `${branch}-dkms`。这是 NVIDIA open GPU kernel module 在容器化驱动里对新分支「转正为默认」的信号(此前 open 多为可选)。
  <details><summary>代码依据 rhel9/install.sh(rhel8 同构)</summary>

  ```diff
  -      dnf module enable -y nvidia-driver:${DRIVER_BRANCH}-dkms
  +      if [ "${DRIVER_BRANCH}" -ge "615" ]; then
  +        DRIVER_MODULE_STREAM="${DRIVER_BRANCH}-open"
  +      else
  +        DRIVER_MODULE_STREAM="${DRIVER_BRANCH}-dkms"
  +      fi
  +      dnf module enable -y "nvidia-driver:${DRIVER_MODULE_STREAM}"
  ```
  </details>
- 其余为 UBI base image bump(ubi8 8.10-1789050982、ubi10 10.2-1788943607)与 renovate/logrus 依赖 bump,无功能含义。

### 后续发展方向 [AI]
- 判据信号:615 为界的 `-open` 分流意味着**新数据中心分支起,RHEL 路径默认走开源内核模块**——proprietary dkms 逐步退居旧分支兼容位。证据仅见 RHEL8/9 install.sh 的 dnf module 选择;未见 Ubuntu 路径(deb/precompiled)是否有对应的 open-by-default 切换,趋势是否全 OS 铺开待下期确认。

## NVIDIA/k8s-device-plugin: 4edf2b66 -> 8d14e165
- 比较: https://github.com/NVIDIA/k8s-device-plugin/compare/4edf2b66ec53db87c36e035f82e5629b676893e3...8d14e165dbba1e19179a5bb13c977aefa5f37616 | ahead=8 | 最新 Release v0.20.0

### AI 总结重点(源码 diff 为据)
- **helm 新增可选的 component selector 标签,解决三个 DaemonSet selector 重叠**。新 `values.yaml` 加 `componentSelectorLabels.enabled`(默认 `false`),新 `_helpers.tpl` 定义 `componentLabel`:开启时在 device-plugin / gfd / mps-control-daemon 三个 DaemonSet 的 `selector.matchLabels` 与 pod template labels 上注入 `app.kubernetes.io/component: <组件名>`,避免三者 selector 相同导致互相圈选。默认关的原因写在注释:DaemonSet selector 不可变,存量 release 开启需重建 DaemonSet。
  <details><summary>代码依据 deployments/helm/.../values.yaml + templates/daemonset-gfd.yml</summary>

  ```diff
  +componentSelectorLabels:
  +  # avoid overlap between device-plugin, gpu-feature-discovery, and mps-control-daemon.
  +  # NOTE: disabled by default for upgrade compatibility (DaemonSet selectors are immutable)
  +  enabled: false
  ...
  +      {{- with (include "nvidia-device-plugin.componentLabel" (dict "root" . "component" "gpu-feature-discovery") | trim) }}
  +      {{- . | nindent 6 }}
  ```
  </details>
- 其余为流程文档:新增 PR 模板、CONTRIBUTING 加 issue-first 工作流与 review 规则,无代码行为改动。

### 后续发展方向 [AI]
- 纯打包/部署面修复,不涉及 device-plugin 运行时逻辑或 time-slicing/MPS→DRA 迁移。证据未见调度/分配路径变化,方向上无信号。

## 本期无实质改动(折叠)
<details><summary>6 仓 EMPTY(仅锚点)</summary>

- NVIDIA/gpu-operator — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
- kai-scheduler/KAI-Scheduler — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9f85a2ad08afc43b220cf368543fc2735244df13 branch=main release=v26.7.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=341598c1c36ad7fc4a80cb7a00239fdd5a59d053 branch=main release=v1.20.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=6357f5208edce4c8eda53446ad2cb68e03940349 branch=main release=— scanned=2026-09-12 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=8d14e165dbba1e19179a5bb13c977aefa5f37616 branch=main release=v0.20.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=c3963bcff8a3127da4530f1ace490ba6ed13e8e3 branch=main release=v0.5.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-12 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-12 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=377f931e2d64f1a7e716d57e4084257f4cc09757 branch=main release=v0.15.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=30c25346ee013e67d2e14df0429bec52f1885131 branch=main release=v0.17.1 scanned=2026-09-12 -->
