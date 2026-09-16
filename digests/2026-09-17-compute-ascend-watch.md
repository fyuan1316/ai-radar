# 昇腾算力栈 diff 雷达 2026-09-17

## 摘要
- 本日无实质改动:8 个 openFuyao 仓全部无新提交;`Ascend/mind-cluster` 虽有 4 条新提交,但全部落在 `component/` 之外(集群切换流水线代码化、FD 光模块阈值配置),不在本 task 的昇腾算力栈组件范围内。
- 按空日约定:只归档保锚点链,不推飞书。

## 当日重要改变
- 无

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- `mind-cluster`:区间 ea073966..062c4382 有 4 条提交(`cluster切换流水线代码化actions`、`[Bug][FD]Configuring thresholds by optical module type part3` 等),但按 `component/{ascend-device-plugin,ascend-docker-runtime,ascend-for-volcano,ascend-operator,npu-exporter,noded,clusterd,infer-operator}` 前缀过滤后**无信号文件命中**——改动均在 FD(故障诊断)/光模块阈值与集群切换 CI 流水线,属组件栈之外,本 task 不研判。tag 仍 v26.1.1。
- `npu-operator`:无新提交(v26.6.0)
- `npu-container-toolkit`:无新提交(v26.6.0)
- `npu-driver-installer`:无新提交(v26.6.0)
- `vNPU`:无新提交(v0.1.0)
- `npu-node-provision`:无新提交(v26.6.0)
- `npu-dra-plugin`:无新提交(v26.6.0)
- `volcano-ext`:无新提交(v1.9.0)
- `ub-network-device-plugin`:无新提交(1.0.2)

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=062c438225f78a31264784488a1f121b2a65f88f tag=v26.1.1 scanned=2026-09-17 -->
<!-- ANCHOR repo=npu-operator sha=802e269728d3528e7864b4d8c04a915c12d1169b tag=v26.6.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-17 -->
