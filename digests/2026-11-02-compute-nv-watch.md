# NVIDIA 算力栈 diff 雷达 2026-11-02

## 摘要

- 本日 NVIDIA 算力栈 9 仓**全部无实质代码改动**,空日只归档保锚点,不推飞书。
- 仅 2 仓有新提交,经 diff 核实均为依赖升级,无能力/API/CRD 变化:gpu-operator 1 个 dependabot bump(operator-framework/api → 0.46.0,仅 go.mod/go.sum + vendor protobuf);KAI-Scheduler 1 个 CVE 修复 bump(grpc 与 golang.org/x/crypto,仅 go.mod/go.sum)。
- 其余 7 仓(nvidia-container-toolkit / gpu-driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)自上次锚点以来无新提交,锚点原位续链。

## 当日重要改变

无。

## 本期无实质改动(折叠)

<details><summary>全部 9 仓 EMPTY(展开看原因)</summary>

- `NVIDIA/gpu-operator` — ahead=2,仅 1 条 `build(deps): Bump github.com/operator-framework/api` 到 0.46.0 + merge,改动集中在 go.mod/go.sum 与 vendor/protobuf,无 ClusterPolicy CRD 或控制器逻辑改动。
- `NVIDIA/nvidia-container-toolkit` — 无新提交。
- `NVIDIA/gpu-driver-container` — 无新提交。
- `NVIDIA/k8s-device-plugin` — 无新提交。
- `kubernetes-sigs/dra-driver-nvidia-gpu` — 无新提交。
- `NVIDIA/dcgm-exporter` — 无新提交。
- `NVIDIA/DCGM` — 无新提交。
- `NVIDIA/mig-parted` — 无新提交。
- `kai-scheduler/KAI-Scheduler` — ahead=1,仅 1 条 `chore(deps): bump grpc and x/crypto for CVEs (#2553)`,仅 go.mod/go.sum,无调度逻辑改动。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)

<!-- ANCHOR repo=NVIDIA/gpu-operator sha=af4995c9103d4ea4936fe8658f96a6db81321fdf branch=main release=v26.7.2 scanned=2026-11-02 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=f18b57912a20e967c5f045475f512191d24ef821 branch=main release=v1.20.1 scanned=2026-11-02 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=c9baa54d84c1e41c1c5ba3af82676fc7f0b0549d branch=main release=— scanned=2026-11-02 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=62cd70687d62b27e0dd28943c2be7a9d7967c1d2 branch=main release=v0.20.1 scanned=2026-11-02 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=c22815de796dd8af176fb536846e513ca3189112 branch=main release=v0.5.1 scanned=2026-11-02 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-11-02 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-02 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=080132489de972ec5f7ae63be2150931c02aa79b branch=main release=v0.15.1 scanned=2026-11-02 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=4e6fcbd30ce4eea1405e1f2845ee0c876869b147 branch=main release=v0.16.14 scanned=2026-11-02 -->
