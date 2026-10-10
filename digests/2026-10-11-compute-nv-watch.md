# NVIDIA 算力栈 diff 雷达 2026-10-11

## 摘要
- 9 仓仅 `gpu-operator` 1 commit 有实质改动,且是一处确定性修复:driver 的 nodePool 渲染结果从 map 遍历(顺序随机)改为按 pool 名排序输出,消除 reconcile 之间因顺序抖动导致的无谓 DaemonSet/资源 diff。无 API/CRD/能力变更,属稳定性收尾。
- 其余 8 仓(container-toolkit / driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted / KAI-Scheduler)本期无新提交,HEAD 与上期锚点一致。

## 当日重要改变
- 无(本期无命中弃用/API/CRD/架构/版本跨档/新能力信号;gpu-operator 的改动是渲染顺序稳定化,非行为/接口变更)

## NVIDIA/gpu-operator: 57378e9c -> 8c53abeb
- 比较: 57378e9c2bcc707fb5f30e78cbfa745d361bb14b -> 8c53abeb | ahead=2 | files=2 | Release: v26.7.1
### AI 总结重点(源码 diff 为据)
- `getNodePools()` 原先直接 `range nodePoolMap`(Go map 遍历顺序不确定)后返回切片,导致每次 reconcile 渲染出的 node pool 列表顺序可能不同;本次抽出 `sortedNodePools()`,在返回前用 `sort.Slice` 按 `nodePool.name` 升序排序。效果:driver 相关渲染产物(按 OS tag 分组的 node pool)在多次调谐间保持稳定顺序,避免顺序抖动造成的"假 diff"与下游资源无谓更新。新增两个单测固化:`TestGetNodePoolsReturnsStableOrder`(rhel/ubuntu 两节点固定返回 `[rhel9, ubuntu22.04]`)与 `TestSortedNodePoolsSortsMapEntriesByName`(直接验证排序函数)。
  <details><summary>代码依据 internal/state/nodepool.go</summary>

  ```diff
  +	"sort"

  @@ func getNodePools(...)
  +	return sortedNodePools(nodePoolMap), nil
  +}
  +
  +func sortedNodePools(nodePoolMap map[string]nodePool) []nodePool {
   	var nodePools []nodePool
   	for _, nodePool := range nodePoolMap {
   		nodePools = append(nodePools, nodePool)
   	}
  -
  -	return nodePools, nil
  +	sort.Slice(nodePools, func(i, j int) bool {
  +		return nodePools[i].name < nodePools[j].name
  +	})
  +	return nodePools
  }
  ```
  </details>
### 后续发展方向 [AI]
- 这是 operator 内部渲染幂等性的小修,证据只覆盖 nodePool 排序这一处,未见其触及 ClusterPolicy/NVIDIADriver CRD 字段或 driver OS 矩阵本身。方向上延续 gpu-operator 近期把 "多 OS/多 node pool driver 编排" 做稳(消除调谐噪声),非新增能力。

## 本期无实质改动(折叠)
- NVIDIA/nvidia-container-toolkit — 无新提交(release v1.20.1)
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交(release v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(release v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(release 4.8.4)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — 无新提交(release v0.15.1)
- kai-scheduler/KAI-Scheduler — 无新提交(release v0.18.3)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=8c53abeb93930dfe62d697292523654c77649476 branch=main release=v26.7.1 scanned=2026-10-11 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-11 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9287a5418573da037ba0d287e059812aa4740e45 branch=main release=— scanned=2026-10-11 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=bd98fbd6b676c655d235857574bdca29ab562dbc branch=main release=v0.20.1 scanned=2026-10-11 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=fb8b9674749c15b35f3bc7535c2e796c86463397 branch=main release=v0.5.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-11 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-11 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=87f9e3c6be56020a346e9d25379734291cfc9cca branch=main release=v0.15.1 scanned=2026-10-11 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=469ad7efa3a601f01f6f213458e040f7c03f6b24 branch=main release=v0.18.3 scanned=2026-10-11 -->
