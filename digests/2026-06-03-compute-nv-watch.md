# NVIDIA 算力栈 diff 雷达 2026-06-03（基线）

本次为任务首跑:仅建立各仓锚点(记录今日 HEAD),不补历史 diff。**从下一次(6/4)起,以下方锚点为 base 做增量对比。**

## 摘要
- 基线已建立,覆盖 NVIDIA 算力栈 9 个仓(驱动容器化 / device-plugin / DRA / 监控 / 调度)。下次跑直接出代码级对比。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=b10eeb6329731ee5db2b3f6ca85eebda0ae2cfb2 branch=main release=v26.3.2 scanned=2026-06-03 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=fc098e74b35202ff85925c415d4bcbbeb8065ae4 branch=main release=v1.19.1 scanned=2026-06-03 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=880c6dc19ca620fd0011de056829798b83a63c77 branch=main release=— scanned=2026-06-03 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=db1ea9481054448d97ae43bd082147e7d6ba5501 branch=main release=v0.19.2 scanned=2026-06-03 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=414b18ce8650f75c27439c724c66fa93449c9ae4 branch=main release=v0.4.0 scanned=2026-06-03 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-03 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=0869351a7d89ff24e68c93b92a50d981cea15580 branch=master release=— scanned=2026-06-03 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=79b64e96ae8041ce533452e9cd89595339c7ed0e branch=main release=v0.14.2 scanned=2026-06-03 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=3247e2114aa2ed60c2ac61d49580a306cb9b98d7 branch=main release=v0.14.5 scanned=2026-06-03 -->
