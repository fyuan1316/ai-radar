# NVIDIA 算力栈 diff 雷达 2026-06-06

> 区间:各仓以 6/05 锚点为 base → 今日 HEAD(单日增量)。

## 摘要
- **nvidia-container-toolkit 改变 CDI hook 的安装形态**:`nvidia-cdi-hook` 不再套 `#!/bin/sh` 包装脚本,改为直接以真实二进制落盘,使其能在**没有 `/bin/sh` 的宿主(distroless/最小化镜像)**上被容器运行时当 CDI hook 调用;同时把 wrapper 渲染从 `html/template` 换成 `text/template`,修掉 shell 包装脚本被 HTML 转义的隐患。
- **gpu-driver-container 扩 RHEL EUS 构建源**:rhel9/rhel10 驱动安装预置阶段在 baseos-eus 之外补开 `appstream-eus-rpms` 仓,影响 EUS 版本上 driver 容器编译依赖的可得性——属 NVIDIA 驱动容器化 OS 矩阵的硬化。
- KAI-Scheduler 仅一笔纯重构(把 `gpu-memory`/`gpu-fraction` 注解常量收口到 common 包),无行为变化;其余 6 仓 EMPTY。

## 当日重要改变
- nvidia-container-toolkit [弃用/移除][新能力] drop `nvidia-cdi-hook` 的 shell shim:`collectExecutables` 对 `nvidia-cdi-hook` 特判,改用新 `executableFile.Install`(直接拷真实二进制、保 basename/mode),不再生成 `.real` + `/bin/sh` 包装。目的是让 CDI hook 在无 `/bin/sh` 的宿主上可被运行时直接执行。证据 `cmd/nvidia-ctk-installer/toolkit/installer/executables.go`、commit "feat: drop `nvidia-cdi-hook` shell shim" https://github.com/NVIDIA/nvidia-container-toolkit/compare/1f7480c8c9f6f2e31d35dad753f77b56c95d2dd4...76094723

## NVIDIA/nvidia-container-toolkit: 1f7480c8 -> 76094723
- 比较 1f7480c8 -> 76094723 | ahead=4 | files=3 | Release: v1.19.1
- 比较页 https://github.com/NVIDIA/nvidia-container-toolkit/compare/1f7480c8c9f6f2e31d35dad753f77b56c95d2dd4...760947232021c818cfd965aaaf76b83d7af4d1a8

### AI 总结重点(源码 diff 为据)
- **CDI hook 改为"裸装"(无 shell 包装)**:原先 toolkit installer 给每个可执行文件都生成一个 `#!/bin/sh` 包装脚本(设 PATH/LD_LIBRARY_PATH 后转调 `<name>.real`)。现在 `collectExecutables` 对 `nvidia-cdi-hook` 单独走新增的 `executableFile` 安装器——直接把真实二进制拷到目标目录(`installFile`,保留 basename 与 mode),不再产 `.real` 副本、不再产 wrapper。注释点明动机:CDI hook 由容器运行时调用,目标宿主可能**没有 `/bin/sh`**(distroless / 最小 OS),套 shell shim 会直接不可执行。这把"容器内 GPU 可见性"链路里关键的 CDI hook 对最小化宿主的适配补上了。
  <details><summary>代码依据 cmd/nvidia-ctk-installer/toolkit/installer/executables.go</summary>

  ```diff
  +		// do not create a shell wraper for nvidia-cdi-hook executable
  +		if executable.path == "nvidia-cdi-hook" {
  +			installers = append(installers, executableFile(executablePath))
  +			continue
  +		}
  ...
  +// executableFile installs an executable directly, without a shell wrapper,
  +// preserving its basename and mode.
  +type executableFile string
  +func (e executableFile) Install(destDir string) error {
  +	dest := filepath.Join(destDir, filepath.Base(string(e)))
  +	_, err := installFile(string(e), dest)
  +	return err
  +}
  ```
  </details>
  <details><summary>代码依据 toolkit_test.go(测试断言从 wrapped 改 unwrapped)</summary>

  ```diff
  -			requireWrappedExecutable(t, toolkitRoot, "nvidia-cdi-hook")
  +			requireUnwrappedExecutable(t, toolkitRoot, "nvidia-cdi-hook")
  ...
  +func requireUnwrappedExecutable(t *testing.T, toolkitRoot string, expectedExecutable string) {
  +	requireExecutable(t, toolkitRoot, expectedExecutable)
  +	require.NoFileExists(t, filepath.Join(toolkitRoot, expectedExecutable+".real"))
  +}
  ```
  </details>
- **wrapper 渲染换 `text/template`,修转义隐患**:`executables.go` 的导入从 `html/template` 换成 `text/template`。这些模板渲染的是 `#!/bin/sh` shell 包装脚本,`html/template` 会对内容做 HTML 转义(如 `&`→`&amp;`、`>`→`&gt;`),会污染 shell 脚本;换 `text/template` 是正确性修复。顺带把八进制字面量现代化(`0111`→`0o111`、`0666`→`0o666` 等,纯风格)。
  <details><summary>代码依据 cmd/nvidia-ctk-installer/toolkit/installer/executables.go</summary>

  ```diff
  -	"html/template"
  +	"text/template"
  ...
  -	return installContent(content, wrapperFile, mode|0111)
  +	return installContent(content, wrapperFile, mode|0o111)
  ```
  </details>

### 后续发展方向 [AI]
- 这是把 CDI hook 路径往"最小化/distroless 宿主"方向硬化的一步;证据只覆盖 installer 的安装形态与模板转义,未见 CDI 规格生成(`nvidia-ctk cdi generate`)或 hook 本体逻辑改动。可盯后续是否把更多 executable 也去 shell-wrapper 化(目前只特判了 cdi-hook,其余仍走 wrapper)。

## NVIDIA/gpu-driver-container: 880c6dc1 -> ef3d0d67
- 比较 880c6dc1 -> ef3d0d67 | ahead=5 | files=3 | Release: —
- 比较页 https://github.com/NVIDIA/gpu-driver-container/compare/880c6dc19ca620fd0011de056829798b83a63c77...ef3d0d673069316b009ed927369121622abf8732

### AI 总结重点(源码 diff 为据)
- **RHEL9/10 驱动安装预置补开 appstream EUS 源**:`_install_prerequisites` 原来只 enable `rhel-N-for-$ARCH-baseos-eus-rpms`,现额外 enable `rhel-N-for-$ARCH-appstream-eus-rpms`;若 `dnf makecache` 失败,两个 EUS 源一并 disable 回退。驱动构建所需的部分编译依赖位于 appstream 仓,此前只开 baseos 会在 EUS 锁版本上缺包——这笔修复直接关系 driver 容器在 RHEL EUS 版本上能否成功编译模块,属 NVIDIA 驱动容器化 OS/版本矩阵的覆盖补全。配套 UBI9 base image tag 微调(`9.8-1780376557`→`9.8-1780554162`)。
  <details><summary>代码依据 rhel9/nvidia-driver(rhel10 同形)</summary>

  ```diff
   dnf config-manager --set-enabled rhel-9-for-$DRIVER_ARCH-baseos-eus-rpms  || true
  +dnf config-manager --set-enabled rhel-9-for-$DRIVER_ARCH-appstream-eus-rpms  || true
   if ! dnf makecache --releasever=${DNF_RELEASEVER}; then
   	dnf config-manager --set-disabled rhel-9-for-$DRIVER_ARCH-baseos-eus-rpms || true
  +    dnf config-manager --set-disabled rhel-9-for-$DRIVER_ARCH-appstream-eus-rpms || true
   fi
  ```
  </details>

### 后续发展方向 [AI]
- 纯构建源/基础镜像维护,无 driver entrypoint 逻辑或预编译矩阵结构变化;证据只覆盖 rhel9/rhel10 两个 OS 分支的 prereq 脚本,未见其它 OS(ubuntu/azure/flatcar)同步调整。

## kai-scheduler/KAI-Scheduler: 71c61d07 -> a55228f7
- 比较 71c61d07 -> a55228f7 | ahead=1 | files=8 | Release: v0.14.5
- 比较页 https://github.com/kai-scheduler/KAI-Scheduler/compare/71c61d07daf217d2b4324ca74d3fef917c9ae107...a55228f7804177655e50857ad8127238289c5d3b

### AI 总结重点(源码 diff 为据)
- **GPU 注解常量收口到 common 包(纯重构,无行为变化)**:删掉散落各处的本地常量 `pod_info.GpuMemoryAnnotationName = "gpu-memory"` 与 `common_info.GPUFraction = "gpu-fraction"`,统一改用 `pkg/common/constants` 的 `commonconstants.GpuMemory` / `commonconstants.GpuFraction`。注解字符串值不变,`updatePodAdditionalFields` 解析 `gpu-memory`/`gpu-fraction` 注解的逻辑不变。意义在于:上一期 RuntimeClass 拆分(fraction/memory 注解 vs 整卡)依赖的这套 GPU 注解契约,现在被集中到单一常量来源,减少多处定义漂移。`#### 重要改变探测` 命中的 `api/` 路径全是 `pod_info.go` + 测试文件,**非 CRD/_types 变更**,是误报。
  <details><summary>代码依据 pkg/scheduler/api/pod_info/pod_info.go</summary>

  ```diff
   const (
  -	GpuMemoryAnnotationName            = "gpu-memory"
   	GPUGroup                           = "runai-gpu-group"
  ...
  -	gpuMemory, err := strconv.ParseInt(pi.Pod.Annotations[GpuMemoryAnnotationName], 10, 64)
  +	gpuMemory, err := strconv.ParseInt(pi.Pod.Annotations[commonconstants.GpuMemory], 10, 64)
  ...
  -	gpuFractionString := pi.Pod.Annotations[common_info.GPUFraction]
  +	gpuFractionString := pi.Pod.Annotations[commonconstants.GpuFraction]
  ```
  </details>

### 后续发展方向 [AI]
- 工程清理,无调度/分配能力变化;证据未见上一期接入的 `NodeInfo.NodeResourceTopology`(NUMA)被打分/过滤插件消费——NUMA 对齐决策仍未落地,继续盯 `pkg/scheduler` 下 numa plugin 的 Allocate/Score 逻辑。

## 本期无实质改动
<details><summary>EMPTY 的 6 仓(保留锚点,详见末尾)</summary>

- NVIDIA/gpu-operator — 无新提交(仍 v26.3.2)。
- NVIDIA/k8s-device-plugin — 无新提交(仍 v0.19.2)。
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(仍 v0.4.0)。
- NVIDIA/dcgm-exporter — 无新提交。
- NVIDIA/DCGM — 无新提交(master)。
- NVIDIA/mig-parted — 无新提交(仍 v0.14.2)。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=32bd22c788693321f4f395599eb859a2ee666241 branch=main release=v26.3.2 scanned=2026-06-06 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=760947232021c818cfd965aaaf76b83d7af4d1a8 branch=main release=v1.19.1 scanned=2026-06-06 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=ef3d0d673069316b009ed927369121622abf8732 branch=main release=— scanned=2026-06-06 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=db1ea9481054448d97ae43bd082147e7d6ba5501 branch=main release=v0.19.2 scanned=2026-06-06 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=1dd7b11b349231a3061aee24f103d6fb4eefe900 branch=main release=v0.4.0 scanned=2026-06-06 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-06 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=0869351a7d89ff24e68c93b92a50d981cea15580 branch=master release=— scanned=2026-06-06 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=b24528651efb64b358e7fc169d4cb18d9ac06347 branch=main release=v0.14.2 scanned=2026-06-06 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=a55228f7804177655e50857ad8127238289c5d3b branch=main release=v0.14.5 scanned=2026-06-06 -->
