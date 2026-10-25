# NVIDIA 算力栈 diff 雷达 2026-10-26

## 摘要
- 近乎静默日:9 仓中 8 仓相对 10-25 锚点无新提交,dra-driver-nvidia-gpu 本期 2 提交全为 merge/bump,仅 KAI-Scheduler 有 1 条实质代码改动。
- 唯一改动是 KAI-Scheduler podgrouper 的健壮性补丁:PyTorchJob 的 `kai.scheduler/segment-size` 注解收到非正值(`0`/负数)时直接报错拒绝,而非带着非正 segment 继续分组(此前解析成功即放行,下游按该值切分会触发除零/异常)。
- 无 API/CRD/弃用/版本跨档信号,当日重要改变为"无"。

## 当日重要改变
- 无

## kai-scheduler/KAI-Scheduler: 96eb3764 -> 0276a9e8
- 比较: 96eb3764caadc87dfb1508af848970868dfbb8b4 -> 0276a9e8 | ahead=1 | files=3 | Release: v0.16.13
- 比较链接 https://github.com/kai-scheduler/KAI-Scheduler/compare/96eb3764caadc87dfb1508af848970868dfbb8b4...0276a9e87bf3b24d5ec0a4bf03e4c4a9376adc18

### AI 总结重点(源码 diff 为据)
- **`getSegmentSize` 增加非正值守卫**:在既有"解析失败则报错"之后,新增 `segmentSize <= 0` 判断,命中则返回 `segment size ... needs to be a positive integer` 错误。即把 Pod 上 `kai.scheduler/segment-size` 注解的合法值域从"任意可解析整数"收窄为"正整数",堵住 `0`(后续按 segment 数均分 replica 时会除零)和负数这类畸形输入。改动点在 kubeflow PyTorchJob 的 podgrouper plugin,非调度核心路径;配套单测覆盖 `"0"` 与 `"-2"` 两例。
  <details><summary>代码依据 pkg/podgrouper/podgrouper/plugins/kubeflow/pytorch/pytorch_grouper.go</summary>

  ```diff
   		if err != nil {
   			return 0, false, fmt.Errorf("invalid segment size %s on pod %s/%s, err: %w", sizeStr, pod.Namespace, pod.Name, err)
   		}
  +		if segmentSize <= 0 {
  +			return 0, false, fmt.Errorf("segment size %s on pod %s/%s needs to be a positive integer", sizeStr, pod.Namespace, pod.Name)
  +		}
   		return segmentSize, true, nil
  ```
  </details>
- 提交 https://github.com/kai-scheduler/KAI-Scheduler/commit/0276a9e87bf3b24d5ec0a4bf03e4c4a9376adc18 (fix #2468,作者 blacksoxx)

### 后续发展方向 [AI]
- 纯缺陷修复,无能力/架构含义:仅收紧 PyTorchJob segment 分组的输入校验。证据仅覆盖 `getSegmentSize` 一处与其单测,未见 segment 调度语义本身变化,也未动任何 CRD/API。无趋势可外推。

## 本期无实质改动(折叠)
<details><summary>8 仓无新提交 + dra-driver 仅 merge/bump</summary>

- NVIDIA/gpu-operator(无新提交,v26.7.2)
- NVIDIA/nvidia-container-toolkit(无新提交,v1.20.1)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交,v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu(2 提交全为 merge/bump,无实质代码改动,v0.5.1)
- NVIDIA/dcgm-exporter(无新提交,4.8.4)
- NVIDIA/DCGM(无新提交,master)
- NVIDIA/mig-parted(无新提交,v0.15.1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=0fbefd5ec6a6235c4ed887298602498506cff6ce branch=main release=v26.7.2 scanned=2026-10-26 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=bb93a6b00e965191bed3fbdb8e15d51f5af949a1 branch=main release=v1.20.1 scanned=2026-10-26 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=16ec7fee338536f900ceee015f3991459f2a323b branch=main release=— scanned=2026-10-26 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-26 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=43ce288759a2748748b5c9cacd7a34a8b4e89648 branch=main release=v0.5.1 scanned=2026-10-26 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-26 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-26 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-26 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=0276a9e87bf3b24d5ec0a4bf03e4c4a9376adc18 branch=main release=v0.16.13 scanned=2026-10-26 -->
</content>
