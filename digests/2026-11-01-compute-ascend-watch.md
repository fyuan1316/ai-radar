# 昇腾算力栈 diff 雷达 2026-11-01

## 摘要
- 本日无实质代码改动。`Ascend/mind-cluster` 虽前进 2 个提交,但落在 PATHPREFIX 限定的 8 个 component 子目录内的改动为 0,唯一变更是一份调度文档(`docs/zh/.../07_silent_faults.md`,+4 行「external-force-pod-failed 场景不支持静默故障检测」的资料约束),无任何 Go/CRD 代码变化。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)全部无新提交,保锚点。
- 无 API/CRD 字段增删、无新顶层 package、无版本跨档(各仓 tag 不变)。

## 当日重要改变(命中信号才列;无则写"无")
- 无。

## 本期无实质改动(折叠)
<details><summary>mind-cluster 仅文档改动 + 8 个 openFuyao 仓无新提交</summary>

- mind-cluster(tag v26.3.0-beta.1,前进 2 commit 但 component/ 内 0 代码改动;唯一变更为文档 `docs/zh/scheduling/04_usage/04_fault_detection_and_diagnosis/02_fault_types/07_silent_faults.md`,补充 external-force-pod-failed 不支持静默故障检测的说明。呼应昨日 reschedule.go 对 external-force-pod-failed 的行为变更,属配套文档收尾)
- npu-operator(tag v26.9.0,无新提交)
- npu-container-toolkit(tag v26.9.0,无新提交)
- npu-driver-installer(tag v26.9.0,无新提交)
- vNPU(tag v26.9.0,无新提交)
- npu-node-provision(tag v26.6.0,无新提交)
- npu-dra-plugin(tag v26.9.0,无新提交)
- volcano-ext(tag v1.9.0,无新提交)
- ub-network-device-plugin(tag v26.9.0,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=0b37fe1adc52499a6c0b83fa8b1eaa1795827144 tag=v26.3.0-beta.1 scanned=2026-11-01 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-01 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-01 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-01 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-11-01 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-01 -->
<!-- ANCHOR repo=npu-dra-plugin sha=32fc8e917d59a26904b8025f97bf6e3eddeb56d3 tag=v26.9.0 scanned=2026-11-01 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-01 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-11-01 -->
