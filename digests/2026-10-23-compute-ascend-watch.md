# 昇腾算力栈 diff 雷达 2026-10-23

## 摘要
- 本日无实质代码改动:mind-cluster 及 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)相对上期(2026-10-22)锚点**全部无新提交**,HEAD SHA 逐一比对完全一致,compare base..HEAD 均返回空。
- **唯一信号(非代码 diff)**:多个仓的最新 release tag 从 v26.6.0 跳到 **v26.9.0**(npu-operator / npu-container-toolkit / npu-driver-installer / npu-dra-plugin / ub-network-device-plugin;vNPU 从 v0.1.0 直接对齐到 v26.9.0)。但 HEAD SHA 均未变——说明这批 tag 打在已扫描过的既有提交上(一次统一的发版切线/版本号对齐),**本期无任何新 hunk 可读**,故不计入"当日重要改变"(本 task 硬要求以代码 diff 为据)。下期若这些 tag 对应的提交推入默认分支,会在增量里显现。
- npu-node-provision 仍停在 v26.6.0,未跟进这批 v26.9.0 对齐;mind-cluster 仍 v26.2.0、volcano-ext 仍 v1.9.0(独立版本线)。

## 当日重要改变
- 无(全仓无新提交;v26.9.0 tag 跳档无对应代码 diff,见摘要)

## 本期无实质改动(折叠)
<details><summary>mind-cluster + 8 个仓均无新提交</summary>

- mind-cluster:HEAD 仍为 2240d93d(v26.2.0),PATHPREFIX(含 DRA/common 两目录,参见 [[ascend-dra-pathprefix-gap]])限定下无代码改动。
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:compare base..HEAD 无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=2240d93db1810b0230b453db14d925f4d517ba71 tag=v26.2.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v26.9.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=npu-dra-plugin sha=031dc691f082fdb90610f77eab3bcf91ad8e9aa3 tag=v26.9.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-10-23 -->
