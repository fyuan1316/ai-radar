# 昇腾算力栈 diff 雷达 2026-07-31

## 摘要
- **本日无实质代码改动**:9 个跟踪仓中 8 个(全部 openFuyao 侧)相对上期锚点零新提交;`Ascend/mind-cluster` 有 2 条提交但均落在 `component/` 之外(仅一处调度文档补充),按本 task 边界(component 子目录代码 diff)不计入正文。
- 空日,仅归档保锚点链,**不推飞书**。

## 当日重要改变
无。

## 本期无实质改动(折叠)
- **mind-cluster**:区间 `4e219436..68cce2d6`,commits=2,唯一实质提交「【资料】docker-runtime默认挂载项说明补充」只改 `docs/zh/scheduling/07_references/05_appendix.md`(docker-runtime 默认挂载项的中文文档说明),**未触及 `component/` 下任何代码**,按 PATHPREFIX 过滤后信号文件为 0。故 out-of-scope,不写研判。
- **npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin**:相对上期锚点均无新提交(`__EMPTY__`)。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=68cce2d667052820b17381aa9ad6751e3c459df1 tag=v26.1.0.beta.2 scanned=2026-07-31 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-31 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-07-31 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-07-31 -->
<!-- ANCHOR repo=vNPU sha=49ad0e7c2faccd942fb181be17256d9451b7776d tag=v0.1.0 scanned=2026-07-31 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-31 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-31 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-31 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-31 -->
