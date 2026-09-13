# NVIDIA 算力栈 diff 雷达 2026-09-14

## 摘要
- 本日无实质改动:9 个仓库中 8 个自上期锚点后无新提交,唯一有新提交的 k8s-device-plugin 也只是 CI 维护(dependabot 目标分支从 release-0.19 切到 release-0.20 + 一处注释拼写修正),无功能/API/代码变化。空日,只归档保锚点,不推飞书。

## 当日重要改变
无

## 本期无实质改动(折叠)
<details><summary>9 个 repo 均无实质改动</summary>

- NVIDIA/gpu-operator(无新提交,锚点停在 3fc63e23 / v26.7.0)
- NVIDIA/nvidia-container-toolkit(ahead=2,19 文件均为 bump/CI/merge)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(ahead=1,唯一提交为 `chore: update target release-branch to release-0.20` #2014,仅改 .github/dependabot.yml 的 target-branch 与一处 Github→GitHub 注释,无代码改动) https://github.com/NVIDIA/k8s-device-plugin/pull/2014
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
- kai-scheduler/KAI-Scheduler(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=3fc63e234ea12cd1de83d0ef698d438805f86aa7 branch=main release=v26.7.0 scanned=2026-09-14 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=b4df771174daa9485036a8ee2fa535dbbbffe2bf branch=main release=v1.20.0 scanned=2026-09-14 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=dcbb9031dbb95da2e449fbb632e4b69e5c3d1ba1 branch=main release=— scanned=2026-09-14 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d415f49223cb9344081cf167461ea0eada141695 branch=main release=v0.20.0 scanned=2026-09-14 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=5baf08f63bd266129dbdd27b28e77bb0ad91fd28 branch=main release=v0.5.0 scanned=2026-09-14 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-14 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-14 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=377f931e2d64f1a7e716d57e4084257f4cc09757 branch=main release=v0.15.0 scanned=2026-09-14 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=30c25346ee013e67d2e14df0429bec52f1885131 branch=main release=v0.17.1 scanned=2026-09-14 -->
