# NVIDIA 算力栈 diff 雷达 2026-11-19

## 摘要
- 本日无实质改动:9 个仓库全部 `__EMPTY__`(8 个无新提交,gpu-operator 仅依赖 bump)。按规范空日只归档、不推飞书。

## 当日重要改变
- 无

## 本期无实质改动(折叠)
<details><summary>9 个仓库</summary>

- NVIDIA/gpu-operator:246a9ca6 -> 9e39c654,ahead=2,只有一个依赖 bump `k8s-operator-libs` 到 2026-10-20(42ee2fff224f),改动全在 go.mod/go.sum/vendor,helper 判为噪声。顺带看了 vendor hunk,`pkg/upgrade` 里驱动升级状态机的变化只有两点:按 DaemonSet 归属批量给 Pod 建索引(`GetPodsByDSOwner`);判定"孤儿 Pod"的条件从"没有任何 ownerReference"改成"没有 controller ownerReference"。ClusterPolicy 没有变化。Release 从 v26.7.2 升到 v26.7.3,只是 patch,不算跨档。 https://github.com/NVIDIA/gpu-operator/pull/3263 https://github.com/NVIDIA/gpu-operator/releases/tag/v26.7.3
- NVIDIA/nvidia-container-toolkit:无新提交(v1.20.2)
- NVIDIA/gpu-driver-container:无新提交
- NVIDIA/k8s-device-plugin:无新提交(v0.20.2)
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交(v0.5.1)
- NVIDIA/dcgm-exporter:无新提交(4.9.0)
- NVIDIA/DCGM:无新提交
- NVIDIA/mig-parted:无新提交(v0.15.2)
- kai-scheduler/KAI-Scheduler:无新提交。releases 列表里最大的 semver 仍是 v0.19.0(11-11),helper 报的 v0.16.18 是旧分支 backport,不算跨档。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=3ac6796228bda663fef350bda0f768d1bc5b35da branch=main release=— scanned=2026-11-19 -->
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9e39c6544380a8aa486951b13adcd567066b3a59 branch=main release=v26.7.3 scanned=2026-11-19 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=07b6bee0b6e45ed5848375aa6ab613353e8d3fb6 branch=main release=v1.20.2 scanned=2026-11-19 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-19 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=f348ba244ce9ac5cbd0858e71beb8f3ef6353279 branch=main release=v0.16.18 scanned=2026-11-19 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-19 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=69439afcc740f6ea85a9f7f5a449c93e395deb73 branch=main release=v0.20.2 scanned=2026-11-19 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=e775fdb63e593a121b40fc1cc4c9a9c89955e635 branch=main release=v0.5.1 scanned=2026-11-19 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=ea1cf1d0bab07cd430c1568667c9c6f69a06ca14 branch=main release=v0.15.2 scanned=2026-11-19 -->
