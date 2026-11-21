# 昇腾算力栈 diff 雷达 2026-11-22

## 摘要
- 本日无实质改动:Ascend/mind-cluster(含 ascend-device-plugin / ascend-docker-runtime / ascend-for-volcano / ascend-operator / npu-exporter / noded / clusterd / infer-operator / ascend-dynamic-resource-allocation / ascend-common / ascend-clusterops-agent / ascend-faultdiag 全部 component)及 openFuyao 全部 8 仓,自上期(2026-11-21)锚点以来均无新提交,HEAD SHA 与锚点逐仓一致。
- 已核对 mind-cluster 当前 HEAD 仍是 94d21ad9(`!5319 merge feature/https-05-runtime-deploy into master`,提交时间 2026-11-21 01:12 +08:00),即上期那批 clusterops-agent / HTTPS 双监听改动的收尾合入,之后 master 未再动;openFuyao 侧最近一次实质提交仍停在 10 月(npu-operator `!121 feat: update the component to adapt A5 machine`,2026-10-10;vNPU `!96 update design for support vNPU Priority Preemption`,2026-10-28)。
- 空日仅归档保锚点链,不推飞书。

## 当日重要改变
- 无

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- mind-cluster:无新提交(tag v26.3.0-beta.2,HEAD 94d21ad9 未动)
- npu-operator:无新提交(tag v26.9.0)
- npu-container-toolkit:无新提交(tag v26.9.0)
- npu-driver-installer:无新提交(tag v26.9.0)
- vNPU:无新提交(tag v26.9.0)
- npu-node-provision:无新提交(tag v26.6.0)
- npu-dra-plugin:无新提交(tag v26.9.0)
- volcano-ext:无新提交(tag v1.9.0)
- ub-network-device-plugin:无新提交(tag v26.9.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=94d21ad9355295041392d28e73704f3e0a04bda8 tag=v26.3.0-beta.2 scanned=2026-11-22 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f0654355fb65ac3ffca9a41357100a82fde4fc10 tag=v26.9.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=37a1d669b4f5ad815110d509c541d321c0c4fab5 tag=v26.9.0 scanned=2026-11-22 -->
