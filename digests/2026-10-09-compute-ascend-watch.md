# 昇腾算力栈 diff 雷达 2026-10-09

## 摘要
- 本日全栈无实质算力栈改动:mind-cluster 的 HEAD 虽前移(3779de1d → 965fd82c,区间 2 commit),但改动仅为"单元测试文件补充",且经 `component/` 路径前缀过滤后**零信号文件命中**——即 ascend-device-plugin / docker-runtime / for-volcano / operator / npu-exporter / noded / clusterd / infer-operator 八个受跟踪组件目录本期一字未动。
- openFuyao 全部 8 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)自上期(2026-10-08)锚点以来均无新提交,HEAD SHA 与锚点逐仓一致。
- 空日仅归档保锚点链,不推飞书。

## 当日重要改变
- 无

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- mind-cluster:HEAD 前移 3779de1d → 965fd82c(2 commit,"单元测试文件补充"),但 `component/` 受跟踪目录无信号文件命中、无代码 diff,组件层视为无实质改动(tag v26.1.1 未动)
- npu-operator:无新提交(tag v26.6.0)
- npu-container-toolkit:无新提交(tag v26.6.0)
- npu-driver-installer:无新提交(tag v26.6.0)
- vNPU:无新提交(tag v0.1.0)
- npu-node-provision:无新提交(tag v26.6.0)
- npu-dra-plugin:无新提交(tag v26.6.0)
- volcano-ext:无新提交(tag v1.9.0)
- ub-network-device-plugin:无新提交(tag 1.0.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=965fd82cec1e0fafd6c96ffca419d74c5b0339a4 tag=v26.1.1 scanned=2026-10-09 -->
<!-- ANCHOR repo=npu-operator sha=c806e3c8e0ef6a8a271293497d08fdf848dd0e1a tag=v26.6.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-10-09 -->
