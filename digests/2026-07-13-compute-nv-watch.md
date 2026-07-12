# NVIDIA 算力栈 diff 雷达 2026-07-13

## 摘要
- 本日无实质改动:9 个跟踪仓(gpu-operator / container-toolkit / gpu-driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted / KAI-Scheduler)自上期锚点起均无新提交(HEAD SHA 全部未前移)。
- 唯一变化在版本标签面:KAI-Scheduler 最新 Release 从 v0.14.7 跳到 v0.16.4(跨 minor),但 main HEAD 仍停在 b63badc9 未动,说明这批 tag 打在已扫描过或更早的提交上,窗口内无新代码可研判——待其 main 出现新提交再看实际内容。

## 当日重要改变
- 无(全 EMPTY,无信号命中)

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓(全部 9 仓)</summary>

- NVIDIA/gpu-operator — 无新提交(HEAD be25c4f2 未动,Release v26.3.3)
- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 3db41dec 未动,Release v1.20.0-rc.1)
- NVIDIA/gpu-driver-container — 无新提交(HEAD 65b0904e 未动)
- NVIDIA/k8s-device-plugin — 无新提交(HEAD 3e20b855 未动,Release v0.19.3)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(HEAD 9001f17e 未动,Release v0.4.1)
- NVIDIA/dcgm-exporter — 无新提交(HEAD d5e5f510 未动,Release 4.5.3-4.8.2)
- NVIDIA/DCGM(master)— 无新提交(HEAD 72fa3fea 未动)
- NVIDIA/mig-parted — 无新提交(HEAD b52cf9c9 未动,Release v0.14.3)
- kai-scheduler/KAI-Scheduler — 无新提交(HEAD b63badc9 未动),仅 Release 由 v0.14.7 → v0.16.4 跨 minor(tag 打在旧提交上,窗口内无代码)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=be25c4f20c3b09d8eb15458897e56c4643e83176 branch=main release=v26.3.3 scanned=2026-07-13 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3db41dec03bf1179b4f7259f6a7037f7f158d39b branch=main release=v1.20.0-rc.1 scanned=2026-07-13 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=65b0904e77aa95ac77f62a735d8a7aff2e276148 branch=main release=— scanned=2026-07-13 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=3e20b8550803574f3df394a9c291cdc73329244c branch=main release=v0.19.3 scanned=2026-07-13 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9001f17e513115a9366987bf5fd9f7850ac52368 branch=main release=v0.4.1 scanned=2026-07-13 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-13 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=b52cf9c9ec9f904a5cf73974fd8fcd2a9e097c0a branch=main release=v0.14.3 scanned=2026-07-13 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=b63badc941faf424756d2e4e0d2348fccbca4793 branch=main release=v0.16.4 scanned=2026-07-13 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-13 -->
