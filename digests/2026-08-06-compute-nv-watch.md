# NVIDIA 算力栈 diff 雷达 2026-08-06

## 摘要
- **driver 容器化的 OS/vGPU 矩阵在换代**:gpu-driver-container 给 **vGPU Manager 新增 rhel10(UBI10)镜像**,同期把 EOL 的 rhcos4.14~4.17 从 CI/Makefile 清掉、只留 rhcos4.18 并补 rhel9.8——预编译/发行版支持面向新一代 OS 收敛。
- container-toolkit 修一处 containerd 配置生成 bug:新增 runtime 从 runc 复制 options 时 `runtime_type` 为空会被默认值补齐,避免 containerd 不认新注册的 nvidia runtime。
- P0 主仓(k8s-device-plugin / DRA driver / dcgm-exporter / DCGM)本期均无新提交;gpu-operator 仅 nvidia-fs 镜像 bump,无 ClusterPolicy CRD 变更。

## 当日重要改变
- NVIDIA/gpu-driver-container [新能力/OS矩阵] vGPU Manager 加 rhel10 支持 + 下线 EOL rhcos 版本,driver 镜像的发行版矩阵换代。PR https://github.com/NVIDIA/gpu-driver-container/pull/905 、https://github.com/NVIDIA/gpu-driver-container/pull/904
- NVIDIA/nvidia-container-toolkit [缺陷修复] containerd 新增 runtime 时空 `runtime_type` 用默认值回填,防止 runtime 注册后 containerd 不识别。PR https://github.com/NVIDIA/nvidia-container-toolkit/pull/1969

## NVIDIA/gpu-driver-container: 3142b836 -> ba907417
- 比较: ab..(上期)-> ba907417 | ahead=6 | files=8 | Release: —(该仓不发 GitHub Release)
### AI 总结重点(源码 diff 为据)
- **新增 vGPU Manager 的 rhel10 镜像栈**:新增 `vgpu-manager/rhel10/{Dockerfile,nvidia-driver,ocp_dtk_entrypoint,certs/.gitkeep}`。Dockerfile 基于 `ubi10:10.2`,装 `gcc make kmod pciutils procps-ng` 编译 vGPU KVM 驱动,入口 `nvidia-driver init`;并支持 `CUSTOM_CA_CERTS_DIR`(默认 `certs/`)注入企业 MITM 代理 CA。这是把 vGPU Manager 容器的 OS 基线抬到 RHEL10/UBI10。
  <details><summary>代码依据 vgpu-manager/rhel10/Dockerfile</summary>

  ```diff
  +FROM registry.access.redhat.com/ubi10/ubi:10.2-1784668814
  +ARG DRIVER_VERSION
  +COPY NVIDIA-Linux-${DRIVER_ARCH}-${DRIVER_VERSION}-vgpu-kvm.run .
  +ARG CUSTOM_CA_CERTS_DIR=certs
  +COPY ${CUSTOM_CA_CERTS_DIR}/ /etc/pki/ca-trust/source/anchors/
  +RUN update-ca-trust
  +RUN dnf install -y gcc make kmod pciutils procps-ng && dnf clean all
  +ENTRYPOINT ["nvidia-driver", "init"]
  ```
  </details>
- **发行版矩阵瘦身/换代**:`.nvidia-ci.yml` 删掉 `release:ngc-rhcos4.14/4.15/4.16/4.17` 四个发布 job,只保留 rhcos4.18;`Makefile` 的 `RHCOS_VERSIONS` 从 `rhcos4.14…4.18 rhel9.6` 收成 `rhcos4.18 rhel9.6 rhel9.8`(下线 EOL rhcos、新增 rhel9.8)。`DISTRIBUTIONS` 里 rhel10/rocky10/ubuntu26.04 已在列。
  <details><summary>代码依据 Makefile / .nvidia-ci.yml</summary>

  ```diff
  - RHCOS_VERSIONS := rhcos4.14 rhcos4.15 rhcos4.16 rhcos4.17 rhcos4.18 rhel9.6
  + RHCOS_VERSIONS := rhcos4.18 rhel9.6 rhel9.8

  - release:ngc-rhcos4.14: ... OUT_DIST: "rhcos4.14"
  - release:ngc-rhcos4.15: ... (4.16 / 4.17 同删)
  ```
  </details>
- 其余为 CI 依赖 bump(`docker/login-action` 4.5.2→4.6.0),无功能影响。
### 后续发展方向 [AI]
- vGPU(KVM 直通/时分)驱动镜像正随 RHEL10/UBI10 铺开;结合 rhel10/rocky10/ubuntu26.04 已进 `DISTRIBUTIONS`,driver 容器的 OS 基线在整体上移。证据只覆盖构建矩阵与 vGPU Manager Dockerfile,未见运行时/驱动版本号变化。

## NVIDIA/nvidia-container-toolkit: 828fc6ce -> f8614837
- 比较: 828fc6ce -> f8614837 | ahead=2 | files=2 | Release: v1.20.0-rc.1
### AI 总结重点(源码 diff 为据)
- **`Config.AddRuntimeWithOptions` 补 runtime_type 缺省回填**:当新 runtime 从 runc 复制来的 `runtime_type` 为空、而 `c.RuntimeType` 非空时,写入 `c.RuntimeType`(如 `io.containerd.runc.v2`)。避免注册的 nvidia runtime 因 `runtime_type=""` 被 containerd 忽略。
  <details><summary>代码依据 pkg/config/engine/containerd/config.go</summary>

  ```diff
  + if runtimeType, _ := config.GetPath([]string{"plugins", c.CRIRuntimePluginName, "containerd", "runtimes", name, "runtime_type"}).(string); runtimeType == "" && c.RuntimeType != "" {
  +   config.SetPath([]string{"plugins", c.CRIRuntimePluginName, "containerd", "runtimes", name, "runtime_type"}, c.RuntimeType)
  + }
  ```
  </details>
- 配套 `config_test.go` 加用例 "empty runtime_type copied from runc options is replaced with default" 固化该行为。
### 后续发展方向 [AI]
- 属稳健性修复,面向 containerd runtime 注入路径;无 CDI/DRA 相关信号。证据仅覆盖 containerd 引擎,未见 crio/docker 引擎同步改动。

## 本期无实质改动(折叠)
- **NVIDIA/gpu-operator**:仅 nvidia-fs(GDS)镜像版本 bump `2.28.2`→`2.29.4`(renovate #2715),`values.yaml` 一行,无 ClusterPolicy CRD 字段变更。https://github.com/NVIDIA/gpu-operator/pull/2715
- **kai-scheduler/KAI-Scheduler**:仅 scale 测试环境资源上调(binder/pod-grouper CPU/mem)+ CI backport 保留 DCO 签名,非能力变更。#1998 / #2015
- **NVIDIA/mig-parted**:仅 bump/CI。
- **NVIDIA/k8s-device-plugin / kubernetes-sigs/dra-driver-nvidia-gpu / NVIDIA/dcgm-exporter / NVIDIA/DCGM**:无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=736fdfb8f4064a2eb6f45f8af3a4809f3a4da800 branch=main release=v26.3.3 scanned=2026-08-06 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=f86148376a4fa0fd89e360274916aff057416fbc branch=main release=v1.20.0-rc.1 scanned=2026-08-06 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=ba907417925834a1ffa4db6fb20a39e82e0e88af branch=main release=— scanned=2026-08-06 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=c648e14098589a4a917796596bc4f96908b54433 branch=main release=v0.19.3 scanned=2026-08-06 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9c52a7d50994adbf2fbb5f1ce2f6466fa3f9936f branch=main release=v0.4.1 scanned=2026-08-06 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-06 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-06 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9020443d2187a2d994b22d8ba17ceb9ab3f3999d branch=main release=v0.14.4 scanned=2026-08-06 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=3ce5dcfa16495af2c893b6b657d37d915c8dda47 branch=main release=v0.17.0 scanned=2026-08-06 -->
