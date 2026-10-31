# NVIDIA 算力栈 diff 雷达 2026-11-01

## 摘要
- 当日 2 仓有实质改动,均为运行时健壮性修复,无 API/CRD 字段增删。主线:容器内 GPU 应用 profile 文件写入由"直接覆盖"升级为"temp+rename 原子写"并堵住符号链接逃逸;RHEL 驱动容器加载 i2c/ipmi 时跳过内核已内置的模块(OpenShift Driver Toolkit 场景)。
- 其余 7 仓(gpu-operator / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted / KAI-Scheduler)空日,仅保锚点。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [新能力/安全] CDI hook `update-application-profile` 写文件改原子写 + 符号链接防逃逸,`EBUSY` 也纳入可忽略错误。https://github.com/NVIDIA/nvidia-container-toolkit/pull/2194
- NVIDIA/gpu-driver-container [架构方向] RHEL8/9/10 驱动脚本加载 i2c/ipmi 前检查 `insmod_nvidia` 清单,内核内置模块跳过 modprobe(OpenShift DTK 兼容)。https://github.com/NVIDIA/gpu-driver-container/pull/1063

## NVIDIA/nvidia-container-toolkit: 1d479dac -> f18b5791
- 比较 / 最新 Release:https://github.com/NVIDIA/nvidia-container-toolkit/compare/1d479dac4bd652cfb131d67b3662e72a31855a8d...f18b57912a20e967c5f045475f512191d24ef821 | Release v1.20.1 | ahead=2

### AI 总结重点(源码 diff 为据)
- `run()` 写 application profile 由 `containerRoot.WriteFile(applicationProfileFile, …, 0444)` 一步直写,改为调用新函数 `writeApplicationProfile()`:先用 `containerRoot.OpenRoot(applicationProfileDir)` 打开 profile 目录(限制在 container root 内,防目录穿越),写入带 `uuid.NewString()` 后缀的临时文件,`Close` 后 `profileDir.Rename(tmp, profileFileName)` 原子替换。失败路径 `defer` 删除临时文件。效果:避免半截写入被读者看到,且 rename 覆盖目标时若原位是符号链接会被替换而**不写穿到 symlink 指向的宿主文件**(单测 "symlink at profile path is replaced without writing to its target" / "dangling symlink …" 专门锁这一行为)。
  <details><summary>代码依据 cmd/nvidia-cdi-hook/update-application-profile/update-application-profile.go</summary>

  ```diff
  -		if err := containerRoot.WriteFile(applicationProfileFile, buildApplicationProfileConfig(mask), 0444); err != nil {
  +		if err := writeApplicationProfile(containerRoot, buildApplicationProfileConfig(mask)); err != nil {
   			return fmt.Errorf("failed to write application profile: %w", err)
   		}
  +func writeApplicationProfile(containerRoot *os.Root, contents []byte) (rerr error) {
  +	profileDir, err := containerRoot.OpenRoot(applicationProfileDir)
  +	...
  +	tmpFileName := profileFileName + "-" + uuid.NewString()
  +	tmpFile, err := profileDir.OpenFile(tmpFileName, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0444)
  +	...
  +	return profileDir.Rename(tmpFileName, profileFileName)
  +}
  ```
  </details>
- 错误忽略判定由"仅 `syscall.EROFS`(只读文件系统)"扩为 `isIgnorableWriteError()` = `EROFS || EBUSY`,日志文案从 "Ignoring read-only filesystem error" 泛化为 "Ignoring error writing application profile"。即只读 rootfs 之外,文件被占用(EBUSY)也降级为 warning 不中断 hook。
  <details><summary>代码依据 update-application-profile.go</summary>

  ```diff
  -		if !errors.Is(err, syscall.EROFS) {
  +		if !isIgnorableWriteError(err) {
   			return err
   		}
  -		logger.Warningf("Ignoring read-only filesystem error: %v", err)
  +		logger.Warningf("Ignoring error writing application profile: %v", err)
  +func isIgnorableWriteError(err error) bool {
  +	return errors.Is(err, syscall.EROFS) || errors.Is(err, syscall.EBUSY)
  +}
  ```
  </details>

### 后续发展方向 [AI]
- CDI hook 层正在把"写容器内配置文件"这类操作系统化地做成防穿越+原子语义(`os.Root` 受限句柄 + temp/rename),这是容器运行时注入文件的通用安全模式。证据只覆盖 update-application-profile 这一个 hook,未见其它 hook(如 create-symlinks/update-ldcache)同步改造。

## NVIDIA/gpu-driver-container: 062dd15a -> c9baa54d
- 比较 / 最新 Release:https://github.com/NVIDIA/gpu-driver-container/compare/062dd15acb16c7e2beeabf5b3378b439ef533910...c9baa54d84c1e41c1c5ba3af82676fc7f0b0549d | Release — | ahead=24(多为 renovate/dependabot bump)

### AI 总结重点(源码 diff 为据)
- RHEL8/9/10 三份 `nvidia-driver` 脚本的 `_load_driver()`:原先无条件 `modprobe -a i2c_core ipmi_msghandler ipmi_devintf`,现改为逐模块循环,先 grep `/lib/modules/$(uname -r)/insmod_nvidia` 中 `^builtin <mod>$` 标记,命中则打印 "built into the kernel, skipping" 跳过 modprobe。该清单由 OpenShift Driver Toolkit sidecar 写入,记录哪些模块需加载、哪些已内置。修的是内置模块被重复 modprobe 时的报错/失败。
  <details><summary>代码依据 rhel9/nvidia-driver(rhel8/rhel10 同构)</summary>

  ```diff
  -    modprobe -a i2c_core ipmi_msghandler ipmi_devintf
  +    for mod in i2c_core ipmi_msghandler ipmi_devintf; do
  +        if grep -q "^builtin ${mod}\$" "/lib/modules/$(uname -r)/insmod_nvidia" 2>/dev/null; then
  +            echo "Module ${mod} is built into the kernel, skipping"
  +            continue
  +        fi
  +        modprobe "${mod}"
  +    done
  ```
  </details>
- 其余为纯 bump:base Ubuntu 镜像 resolute/noble/jammy 滚日期 tag、vgpu-manager 各 OS 的 CUDA base `13.4.2 -> 13.4.3`、CI action(docker/login-action 4.6.0->4.7.0、yq 4.53.6->4.54.1、holodeck 0.5.0->0.5.1)——无能力改动。
  <details><summary>代码依据 base/Dockerfile</summary>

  ```diff
  -FROM ubuntu:resolute-20261006 AS resolute
  +FROM ubuntu:resolute-20261024.1 AS resolute
  -FROM ubuntu:noble-20260930.1 AS noble
  +FROM ubuntu:noble-20261024.1 AS noble
  ```
  </details>

### 后续发展方向 [AI]
- gpu-driver-container 对 OpenShift Driver Toolkit(DTK)路径的兼容在持续补洞:依赖 DTK sidecar 产出的 `insmod_nvidia` 清单精确控制模块加载,避免与内核内置模块冲突。证据只覆盖 i2c/ipmi 辅助模块加载分支,未见 nvidia 主模块加载逻辑改动。

## 本期无实质改动(折叠)
- NVIDIA/gpu-operator、NVIDIA/k8s-device-plugin、kubernetes-sigs/dra-driver-nvidia-gpu、NVIDIA/dcgm-exporter、NVIDIA/DCGM、NVIDIA/mig-parted、kai-scheduler/KAI-Scheduler:无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=f925d27e396deb925f155a2d427d65e08ec246ff branch=main release=v26.7.2 scanned=2026-11-01 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=f18b57912a20e967c5f045475f512191d24ef821 branch=main release=v1.20.1 scanned=2026-11-01 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=c9baa54d84c1e41c1c5ba3af82676fc7f0b0549d branch=main release=— scanned=2026-11-01 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=62cd70687d62b27e0dd28943c2be7a9d7967c1d2 branch=main release=v0.20.1 scanned=2026-11-01 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=c22815de796dd8af176fb536846e513ca3189112 branch=main release=v0.5.1 scanned=2026-11-01 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-11-01 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-01 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=080132489de972ec5f7ae63be2150931c02aa79b branch=main release=v0.15.1 scanned=2026-11-01 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=0243c4e948b722893897cfd72e7f15cb8e371725 branch=main release=v0.16.14 scanned=2026-11-01 -->
