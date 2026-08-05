# 昇腾算力栈 diff 雷达 2026-08-06

## 摘要
- **npu-dra-plugin 收紧默认安全姿态**:softShareMounts 三个 host 库/工具挂载权限从 `rw` 一律改 `ro`(只读 rbind),同时把 values.yaml 里内置的 `nodes` 切分示例清空为 `nodes: {}`——默认不切分、由用户按需配置后重启驱动 Pod 生效。属"默认关 vNPU 切分 + 最小权限挂载"的产品化收敛,非 CRD/架构改动。
- **vNPU 修空 ContainerID panic**:runtime service 用统一的 `stripContainerIDPrefix()` 替代裸切片剥前缀,避免 ContainerID 为空时越界 panic(#88)。纯健壮性修复。
- 其余 7 仓无新提交(mind-cluster 仅文档更新,未落 component/)。

## 当日重要改变(命中信号才列;无则写"无")
- 无(本期两处改动均为 config 默认收敛 / bugfix,未命中弃用/API-CRD/架构方向/版本跨档/新能力信号)。

## npu-dra-plugin: dff4fa7d -> ae80e4f1
- 比较 / 最新 Release:dff4fa7d..ae80e4f1 | tag: v26.6.0 | commits=3
### AI 总结重点(源码 diff 为据)
- **softShareMounts 三处挂载从可写降为只读**:`libboundscheck.so` / `npu-monitor`(挂到 vcann-rt 的 enpu-monitor)/ `systemd-detect-virt` 的 `options` 从 `[rw, rbind]` 统一改 `[ro, rbind]`。软切分场景下容器只需读这些 host 侧库/工具,去掉写权限收窄攻击面。values.yaml(Helm)与 manifests/deploy/01-configmap.yaml(裸 YAML)两处同改,保持部署两路径一致。
  <details><summary>代码依据 Ascend-npu-dra-plugin/charts/npu-dra-driver/values.yaml</summary>

  ```diff
     softShareMounts:
     - hostPath: /opt/xpu/lib/libboundscheck.so
       containerPath: /lib/libboundscheck.so
  -    options: [rw, rbind]
  +    options: [ro, rbind]
     - hostPath: /opt/xpu/bin/npu-monitor
       containerPath: /opt/enpu/vcann-rt/tools/enpu-monitor
  -    options: [rw, rbind]
  +    options: [ro, rbind]
     - hostPath: /opt/xpu/bin/systemd-detect-virt
       containerPath: /usr/bin/systemd-detect-virt
  -    options: [rw, rbind]
  +    options: [ro, rbind]
  ```
  </details>
- **values.yaml 内置 nodes 切分示例清空为 `nodes: {}`**:原来 values.yaml 硬编码了一份 `k8s-master` 节点的 vNPU 切分配置(physicalId 0/1 full、2 hard、3 soft+elastic),现全部注释成示例、实际值改空 map,并加注"默认为空,需要切分功能时由用户按需配置,配置后重启驱动 Pod 生效"。含义:DRA 插件出厂默认不对任何节点做 NPU 切分,避免示例配置误应用到真实节点。注意 configmap.yaml 里的 `nodes:`(n1/physicalId 0…)本次未清空,仍留测试样例。
  <details><summary>代码依据 Ascend-npu-dra-plugin/charts/npu-dra-driver/values.yaml</summary>

  ```diff
  -  nodes:
  -    k8s-master:
  -    - physicalId: 0
  -      vnpuMode: full
  -    - physicalId: 1
  -      vnpuMode: full
  -    - physicalId: 2
  -      vnpuMode: hard
  -    - physicalId: 3
  -      vnpuMode: soft
  -      schedulingPolicy: elastic
  +  # 默认为空, 需要切分功能时由用户按需配置, 配置后重启驱动 Pod 生效
  +  # 示例: ...(physicalId/vnpuMode: full|hard|soft, schedulingPolicy: elastic)
  +  nodes: {}
  ```
  </details>
### 后续发展方向 [AI]
- vNPU 切分模型仍是 per-node、per-physicalId 声明式(vnpuMode ∈ full/hard/soft,soft 可带 schedulingPolicy: elastic),这次只调默认值与挂载权限,未动切分语义/schema——证据只覆盖 values.yaml 与 configmap.yaml,未见 DRA ResourceClaim/DeviceClass 侧改动。方向是"出厂安全默认 + 最小权限",非能力扩展。

## vNPU: 109f4d14 -> f5869cd1
- 比较 / 最新 Release:109f4d14..f5869cd1 | tag: v0.1.0 | commits=2
### AI 总结重点(源码 diff 为据)
- **xpu-device-plugin runtime 用 `stripContainerIDPrefix()` 统一剥 ContainerID 前缀**:`getContainerName()` 里原来对每个 Pod 的 ContainerStatus 分别裸切片 `cs.ContainerID[len(containerd前缀):]` 和 `cs.ContainerID[len(docker前缀):]` 比对,当 ContainerID 为空(短于前缀长度)时切片越界会 panic;改为调 `stripContainerIDPrefix(cs.ContainerID)` 统一处理,避免空 ContainerID 触发 panic(#88)。运行时按 cgroup 路径反查容器名的健壮性修复。
  <details><summary>代码依据 xpu-device-plugin/pkg/api/runtime/service/service_impl.go</summary>

  ```diff
   		for _, cs := range pod.Status.ContainerStatuses {
  -			if cs.ContainerID[len(containerIdPrefixInContainerd):] != containerId &&
  -				cs.ContainerID[len(containerIdPrefixInDocker):] != containerId {
  +			if stripContainerIDPrefix(cs.ContainerID) != containerId {
   				continue
   			}
   			return podId, cs.Name, nil
  ```
  </details>
### 后续发展方向 [AI]
- 纯 bugfix,不改切分/调度语义;证据仅覆盖 service_impl.go 一处,未见 stripContainerIDPrefix 的实现体(应在同包新增/已存在),也未见其他调用点是否同步收敛。

## 本期无实质改动(折叠)
- mind-cluster:4 commits 但仅文档更新(参考链接/规范),component/ 子目录无代码改动
- npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / volcano-ext / ub-network-device-plugin:无新提交

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=ea8943af0e2d3d3508c9f50c91ad73a9b40ca14e tag=v26.1.0 scanned=2026-08-06 -->
<!-- ANCHOR repo=npu-operator sha=7cddacb58841f285c6f719e2d7a5cb235be32cdb tag=v26.6.0 scanned=2026-08-06 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-06 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-06 -->
<!-- ANCHOR repo=vNPU sha=f5869cd17c57b8392b97fc76a7879a1a9a1eb81f tag=v0.1.0 scanned=2026-08-06 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-06 -->
<!-- ANCHOR repo=npu-dra-plugin sha=ae80e4f176f0797ac9e38f043f6cc6cef87cc006 tag=v26.6.0 scanned=2026-08-06 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-06 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-06 -->
