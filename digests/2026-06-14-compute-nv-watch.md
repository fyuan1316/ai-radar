# NVIDIA 算力栈 diff 雷达 2026-06-14

## 摘要
- 本日无实质改动:9 仓全部 EMPTY(仅 bump/CI/merge 或无新提交),无 NVIDIA 算力栈一方代码变化。
- 唯二有新提交的仓均为依赖 bump:`k8s-device-plugin`(2 提交,仅 CI/merge)、`dra-driver-nvidia-gpu`(仅 vendored go-nvlib v0.11.0 升级,无一方代码改动)。
- 按空日约定:只归档保锚点,不推飞书。

## 当日重要改变
无。

## 本期无实质改动(折叠)
<details><summary>9 仓全 EMPTY,逐仓一行</summary>

- `NVIDIA/gpu-operator`:无新提交(HEAD 仍 fed0b2a6,Release v26.3.2)。
- `NVIDIA/nvidia-container-toolkit`:无新提交(HEAD 仍 59c04208,Release v1.19.1)。
- `NVIDIA/gpu-driver-container`:无新提交(HEAD 仍 5c00b0e6)。
- `NVIDIA/k8s-device-plugin`:ahead=2,仅 bump/CI/merge,无一方代码改动(HEAD 684cbd96 → 8993bf00,Release v0.19.2 不变)。
- `kubernetes-sigs/dra-driver-nvidia-gpu`:ahead=2,仅 vendored 依赖升级 go-nvlib → v0.11.0(PR #1195),无 `apis/`/CRD/一方源码改动;Release 标签新出 v0.4.1-rc.1(相对 v0.4.0 为 patch RC,非 major/minor 跨档,且本次区间无对应一方代码 diff)。HEAD 749a743c → dccc5fee。证据:https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/pull/1195
- `NVIDIA/dcgm-exporter`:无新提交(HEAD 仍 d5e5f510,Release 4.5.3-4.8.2)。
- `NVIDIA/DCGM`:无新提交(HEAD 仍 d646460f,master)。
- `NVIDIA/mig-parted`:无新提交(HEAD 仍 abc8f3b6,Release v0.14.2)。
- `kai-scheduler/KAI-Scheduler`:无新提交(HEAD 仍 964bf470,Release v0.15.2)。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=fed0b2a686a2b305d9cb485cd3f7bb343aae5296 branch=main release=v26.3.2 scanned=2026-06-14 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=59c042086ec213caba72dc7570facffc911f38dd branch=main release=v1.19.1 scanned=2026-06-14 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=5c00b0e6bdb2ddc35a9ebd96e1221abe25049798 branch=main release=— scanned=2026-06-14 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=8993bf00afc77b8d4e7e076dd27de45b71b6b9e7 branch=main release=v0.19.2 scanned=2026-06-14 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=dccc5fee48302b3522369acd598af57420fbd6a1 branch=main release=v0.4.1-rc.1 scanned=2026-06-14 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-14 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-14 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=abc8f3b67eea982370a8d0f60838feec0691e051 branch=main release=v0.14.2 scanned=2026-06-14 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=964bf470d46e31f5869de01efba7e69c10bd8dd5 branch=main release=v0.15.2 scanned=2026-06-14 -->
