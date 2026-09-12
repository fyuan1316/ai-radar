# 昇腾算力栈 diff 雷达 2026-09-13

## 摘要(3 条内)
- 本日**扫描范围内无实质改动**:9 个仓中 8 个无新提交,mind-cluster 仅有的 4 条提交全部落在 `component/ascend-faultdiag/`(故障诊断知识库),不在本 task 关注的算力栈组件(device-plugin / runtime / for-volcano 调度 / operator / npu-exporter / noded / clusterd / infer-operator)范围内。
- 按硬约束:全 EMPTY 空日只归档保锚点链,**不推飞书**。

## 当日重要改变(命中信号才列;无则写"无")
- 无

## 本期无实质改动(折叠)
- **mind-cluster**:区间内 4 条提交(commits=4, truncated=false),但按 `component/` 算力栈前缀过滤后信号文件为 0。实际改动仅 `component/ascend-faultdiag/src/ascend_fd/configuration/kg-config.json`(93+/148-)与 `.../utils/constant/ub_const.py`(3+/6-),提交标题为"ub 故障模式库适配旧的关键字匹配方式/去掉重复的故障"——属故障诊断知识库的数据/关键字匹配调优,不在本 task 的算力栈(驱动/插件/调度/监控/operator)代码视角内,按 task 第 4 条以 PATHPREFIX 限定的信号集为准,判为扫描范围内无实质改动。
- **npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin**:本期无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=7537ed628111e89f82e4823cd36b2c983d86ab6b tag=v26.2.0.beta.1 scanned=2026-09-13 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=vNPU sha=d88907ed4061c5d63babbb79b453a368b55f14d6 tag=v0.1.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-13 -->
