# 昇腾算力栈 diff 雷达 2026-10-22

## 摘要
- 本日无实质改动:mind-cluster 及 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)相对上期锚点**全部无新提交**(HEAD SHA 与 2026-10-21 完全一致)。
- 本次 mind-cluster 已按 [[ascend-dra-pathprefix-gap]] 的教训,PATHPREFIX 补上 `component/ascend-dynamic-resource-allocation`(DRA 驱动)和 `component/ascend-common`(devmanager/CDI 公共库);因 HEAD 未动,无差异可查。
- 昨日落地的 npu-dra-plugin 两份 DRA 设计文档(软切分 vNPU 算力优先级抢占 / DRA driver 内嵌 vNPU 指标)本期**未见后续 .go 实现 diff**,核心依赖 `third_party/ubs-virt` 子模块仍未 bump。

## 当日重要改变
- 无

## 本期无实质改动(折叠)
<details><summary>mind-cluster + 8 个仓均无新提交</summary>

- mind-cluster:HEAD 仍为 2240d93d(v26.2.0),PATHPREFIX(含本次新增的 DRA/common 两目录)限定下无代码改动。
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:比较 base..HEAD 无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=2240d93db1810b0230b453db14d925f4d517ba71 tag=v26.2.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.6.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.6.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=npu-dra-plugin sha=031dc691f082fdb90610f77eab3bcf91ad8e9aa3 tag=v26.6.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=1.0.2 scanned=2026-10-22 -->
</content>
</invoke>
