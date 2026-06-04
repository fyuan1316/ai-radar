# 昇腾(Ascend)算力栈 diff 雷达 2026-06-03（基线）

本次为任务首跑:仅建立各仓锚点(记录今日 HEAD),不补历史 diff。**从下一次(6/4)起,以下方锚点为 base 做增量对比。**

## 摘要
- 基线已建立,覆盖昇腾算力栈 9 个仓:mind-cluster umbrella + openFuyao 8 个(operator / container-toolkit / driver-installer / vNPU / node-provision / dra-plugin / volcano-ext / ub-network)。
- 自底向上对标 NVIDIA 已补齐:driver 容器化(npu-driver-installer / npu-container-toolkit)、虚拟化(vNPU 对标 HAMi vGPU)、网络 fabric(ub-network)。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=4d0dde8601e715acc313f913fb0c442f59657171 tag=v26.0.0 scanned=2026-06-03 -->
<!-- ANCHOR repo=npu-operator sha=83270337c25487948cbf56685561e273730f9bbf tag=1.2.0 scanned=2026-06-03 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-03 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-03 -->
<!-- ANCHOR repo=vNPU sha=5dc0751eefdb922d48ee653a10b52c7aa02ddcc6 tag=v0.1.0 scanned=2026-06-03 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-03 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-03 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-03 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-03 -->
