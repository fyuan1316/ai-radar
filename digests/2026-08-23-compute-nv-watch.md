# NVIDIA 算力栈 diff 雷达 2026-08-23

## 摘要
- **container-toolkit 补齐 CDI 控制设备节点自愈**:新增 udev 规则 `99-nvidia-cdi-refresh.rules`,在 nvidia 内核模块加载时触发 `nvidia-cdi-refresh.service`;service 在生成 CDI spec 前先跑 `nvidia-ctk system create-device-nodes --control-devices --load-kernel-modules`,主动创建 devtmpfs 不会自动生成的 `/dev/nvidiactl`、`/dev/nvidia-modeset`、`/dev/nvidia-uvm*` 控制节点。解决"装了驱动但控制设备节点缺失导致 CDI 生成不全/容器起不来"的边角问题,并加了 driver-root/dev-root 覆盖钩子。
- **container-toolkit 换 semver 库:`golang.org/x/mod/semver` → `Masterminds/semver/v3`**(property.go/cuda_image.go/container_config.go 三处)。语义放宽:不再强制 `v` 前缀、由 `NewVersion` 做解析并返回错误,删掉 `ensurePrefix` 辅助;运行时 hook 的 OCI 版本比较加了解析失败兜底(fallback 到 `0.0.0`)。
- **gpu-operator 正式发版 v26.7.0**(上期 v26.3.3):main 分支无新提交(锚点 sha 不变),纯 Release tag 跨档,承接前几日的 26.7.0 发版工程。
- 其余 7 仓无实质代码改动(无新提交)。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [新能力·CDI 自愈] 新增 udev 规则在内核模块加载时触发 CDI refresh,service 先创建缺失的 NVIDIA 控制设备节点再生成 CDI spec。证据 deployments/udev/99-nvidia-cdi-refresh.rules、deployments/systemd/nvidia-cdi-refresh.service。https://github.com/NVIDIA/nvidia-container-toolkit/compare/6429cdd3c1b40d6ea53bbee868a3e11f54d1f3a7...d34b3046758cb1a5db606b2a39519c731bbf9f56
- NVIDIA/gpu-operator [版本跨档] 正式发版 v26.7.0(上期 v26.3.3),main 分支本窗口无新提交,仅 Release tag 跨档。https://github.com/NVIDIA/gpu-operator/releases/tag/v26.7.0

## NVIDIA/nvidia-container-toolkit: 6429cdd3 -> d34b3046
- 比较: 6429cdd3c1b40d6ea53bbee868a3e11f54d1f3a7 -> d34b3046 | ahead=4 | files=17 | Release: v1.20.0
- 比较页: https://github.com/NVIDIA/nvidia-container-toolkit/compare/6429cdd3c1b40d6ea53bbee868a3e11f54d1f3a7...d34b3046758cb1a5db606b2a39519c731bbf9f56

### AI 总结重点(源码 diff 为据)
- **CDI refresh 服务改为在生成 spec 前主动创建 NVIDIA 控制设备节点**。`nvidia-cdi-refresh.service` 在原有 `nvidia-ctk cdi generate` 之前插入一条 best-effort `ExecStart`:先判非 WSL(`/dev/dxg` 不存在)且非 Tegra(`nvgpu` 模块未加载),再跑 `nvidia-ctk system create-device-nodes --control-devices --load-kernel-modules`,若模块加载失败(如驱动升级中在盘模块被替换)退化为不加载模块只建节点。背景:`/dev/nvidiactl`、`/dev/nvidia-modeset`、`/dev/nvidia-uvm*` 由 userspace 按需创建、devtmpfs 不提供,只加载内核模块不保证它们存在——过去这会让 CDI spec 生成不完整。
  <details><summary>代码依据 deployments/systemd/nvidia-cdi-refresh.service</summary>

  ```diff
   ExecStart=/bin/sh -c '/usr/bin/nvidia-smi -L || /usr/sbin/nvidia-smi -L || /usr/lib/wsl/lib/nvidia-smi -L'
  +# Create any missing NVIDIA control device nodes (loading the kernel modules
  +# they require) before generating the CDI specification; nothing else is
  +# guaranteed to create them. Best-effort, and skipped on WSL where /dev/dxg is
  +# used instead, as well as on Tegra platforms using the nvgpu kernel module.
  +ExecStart=-/bin/sh -c '[ -e /dev/dxg ] || /usr/bin/grep -q "^nvgpu " /proc/modules || /usr/bin/nvidia-ctk system create-device-nodes --control-devices --load-kernel-modules || /usr/bin/nvidia-ctk system create-device-nodes --control-devices'
   ExecStart=/usr/bin/nvidia-ctk cdi generate
   CapabilityBoundingSet=CAP_SYS_MODULE CAP_SYS_ADMIN CAP_MKNOD
  ```
  </details>

- **新增 udev 规则:内核模块加载即触发 CDI refresh**。`99-nvidia-cdi-refresh.rules` 监听 `SUBSYSTEM=="module"` 的 add 事件,匹配 `nvidia`(Debian 打包为 `nvidia-current`,sysfs 显示 `nvidia_current`)后经 `SYSTEMD_WANTS` 拉起 `nvidia-cdi-refresh.service`。RPM spec/debian 打包相应把该规则装到 `_udevrulesdir`,并在 postinst/post 里 `udevadm control --reload-rules` 免重启生效。这把 CDI 刷新从"路径/定时触发"扩展到"驱动模块一上来就自动补节点+刷 spec"。
  <details><summary>代码依据 deployments/udev/99-nvidia-cdi-refresh.rules</summary>

  ```diff
  +# Trigger nvidia-cdi-refresh.service on module load to create the
  +# missing nodes and refresh the CDI specification.
  +# Debian packages the kernel module as nvidia-current, which appears in sysfs
  +# as nvidia_current.
  +ACTION=="add", SUBSYSTEM=="module", KERNEL=="nvidia|nvidia_current", TAG+="systemd", ENV{SYSTEMD_WANTS}+="nvidia-cdi-refresh.service"
  ```
  </details>

- **CDI refresh 环境文件新增 driver-root / dev-root 覆盖**。`nvidia-cdi-refresh.env` 加注释说明 service 会先跑 create-device-nodes,并暴露 `NVIDIA_DRIVER_ROOT`、`NVIDIA_DEV_ROOT` 两个可覆盖变量(区别于 `cdi generate` 用的 `NVIDIA_CTK_DRIVER_ROOT`/`NVIDIA_CTK_DEV_ROOT`),适配非 `/` driver root 的部署。
  <details><summary>代码依据 deployments/systemd/nvidia-cdi-refresh.env</summary>

  ```diff
  +# The service also runs
  +#   nvidia-ctk system create-device-nodes --control-devices --load-kernel-modules
  +# before generating the CDI specification. Its driver and device roots can be
  +# overridden by uncommenting the following lines ...
  +# NVIDIA_DRIVER_ROOT=/
  +# NVIDIA_DEV_ROOT=/
  ```
  </details>

- **semver 库整体从 `golang.org/x/mod/semver` 换到 `Masterminds/semver/v3`**。影响三个文件的版本比较逻辑:requirements 约束求值(`versionProperty.CompareTo`/`Validate`)、CUDA 镜像标签解析(`parseMajorMinorVersion`)、runtime hook 的 OCI spec 版本判定(`GetCapabilities`)。行为差异:旧库要求 `v` 前缀且用全局函数 `semver.Compare`/`IsValid`,靠自写 `ensurePrefix` 补前缀;新库用 `semver.NewVersion(...)` 返回对象+error,不强制前缀、解析失败显式报错,`ensurePrefix` 被删除。runtime hook 里对无法解析的 OCI 版本兜底为 `0.0.0` 再比较,避免直接 panic。
  <details><summary>代码依据 internal/requirements/constraints/property.go</summary>

  ```diff
  -	"golang.org/x/mod/semver"
  +	"github.com/Masterminds/semver/v3"
  ...
  -	vValue := ensurePrefix(p.value, "v")
  -	vOther := ensurePrefix(other, "v")
  -	return semver.Compare(vValue, vOther), nil
  +	value, err := semver.NewVersion(p.value)
  +	if err != nil { return 0, fmt.Errorf("invalid value for %v: %w", p.name, err) }
  +	otherVersion, err := semver.NewVersion(other)
  +	if err != nil { return 0, fmt.Errorf("invalid value for %v: %w", p.name, err) }
  +	return value.Compare(otherVersion), nil
  ...
  -func ensurePrefix(s string, prefix string) string {
  -	return prefix + strings.TrimPrefix(s, prefix)
  -}
  ```
  </details>
  <details><summary>代码依据 cmd/nvidia-container-runtime-hook/container_config.go</summary>

  ```diff
  -	rc1cmp := semver.Compare("v"+*s.Version, "v1.0.0-rc1")
  -	rc5cmp := semver.Compare("v"+*s.Version, "v1.0.0-rc5")
  +	sv, err := semver.NewVersion(*s.Version)
  +	if err != nil { sv = semver.MustParse("0.0.0") }
  +	rc1cmp := sv.Compare(semver.MustParse("v1.0.0-rc1"))
  +	rc5cmp := sv.Compare(semver.MustParse("v1.0.0-rc5"))
  ```
  </details>

### 后续发展方向 [AI]
- 证据覆盖 service/udev/env 三处 CDI-refresh 改动与 semver 库替换四处 hunk,未逐行读 e2e 测试(nvidia-cdi-refresh_test.go +17)。方向:container-toolkit 继续把**非 K8s(systemd 主机 / CDI 原生)路径的自愈能力**做厚——从"路径触发刷 spec"到"模块加载即建节点+刷 spec",目标是驱动升级/裸机重启后 CDI spec 始终自洽,减少对 device-plugin 侧兜底的依赖。semver 换库为工程健壮性(容错、去自写前缀逻辑),放宽了对版本串格式的容忍度,理论上对 CUDA 镜像标签/OCI 版本这类非规范 semver 更稳。证据只覆盖 systemd/打包/version 三块,未见 CDI spec 结构或 runtime hook 挂载语义变化,ClusterPolicy CRD 无涉及。

## 本期无实质改动(折叠)
<details><summary>7 仓无实质代码改动(EMPTY / 无新提交)</summary>

- NVIDIA/gpu-operator(main 无新提交,锚点 sha 不变;仅 Release 从 v26.3.3 跨到 v26.7.0)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交,release 停在 v0.20.0)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交,release v0.5.0)
- NVIDIA/dcgm-exporter(无新提交,release 4.6.0-4.8.3)
- NVIDIA/DCGM(无新提交,branch=master)
- NVIDIA/mig-parted(无新提交,release v0.15.0)
- kai-scheduler/KAI-Scheduler(无新提交,release v0.14.8)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=a22dbf671f2e26f9a1e342f8eea28e196235e110 branch=main release=v26.7.0 scanned=2026-08-23 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d34b3046758cb1a5db606b2a39519c731bbf9f56 branch=main release=v1.20.0 scanned=2026-08-23 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-23 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1b826acc6af3079d8923bac395c3124b8861a9a6 branch=main release=v0.20.0 scanned=2026-08-23 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=d682267c7dd84a76c61663feeaf36d04ac6ebfef branch=main release=v0.5.0 scanned=2026-08-23 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-23 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-08-23 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=bd7160f43f16462eeb21e1eda5e67b5b6b03fd7d branch=main release=v0.15.0 scanned=2026-08-23 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=2914d320160fbb389f69a2c2968a0a6acefb9f76 branch=main release=v0.14.8 scanned=2026-08-23 -->
</content>
