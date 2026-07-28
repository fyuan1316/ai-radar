# 昇腾算力栈 diff 雷达 2026-07-29

## 摘要
- 本日无实质代码改动:8 个 openFuyao 仓自 2026-07-28 锚点起均无新提交;mind-cluster 区间内有 10 个提交,但按 `component/` 限定过滤后**零信号文件**——改动全在文档/离线资料与非 component 构建代码,昇腾算力栈组件代码未变。保锚点链、不推飞书。

## 当日重要改变
- 无

## 本期无实质改动(折叠)
<details><summary>mind-cluster:有提交但 component/ 组件代码未变(仅文档/非组件)</summary>

mind-cluster 锚点从 `8c6371e3` 推进到 `868f2774`(区间 10 commits),但按 8 个 `component/` 前缀过滤后信号文件为空,均落在文档/资料与非 component 目录,不在本 task 代码范围内。样例提交标题:
- 独占模式1825rdma 构建代码(非 component/ 路径)
- [Docs] 补充 dp 离线热复位支持 A5 标卡、Server 及 PoD 设备形态的资料描述
- 【docx】资料修改-增加亚健康说明 / <docs>【docs】资料问题修改
- [mindio tft] mindx 通知全局异常 rank 时新增一次交互,上报新增故障(资料/说明侧)

判据:task 步骤 4 明确"信号文件/patch 节选已按 PATHPREFIX 限定,以后者为准写研判"。component/ 过滤后无 patch,故不写符号级研判,仅更新锚点。
</details>

<details><summary>全部 8 个 openFuyao 仓 EMPTY(自 07-28 锚点无新提交)</summary>

- npu-operator — 无新提交
- npu-container-toolkit — 无新提交
- npu-driver-installer — 无新提交
- vNPU — 无新提交
- npu-node-provision — 无新提交
- npu-dra-plugin — 无新提交
- volcano-ext — 无新提交
- ub-network-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=868f277495ec279c165847600dc566fc821ca9f0 tag=v26.1.0.beta.2 scanned=2026-07-29 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-29 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-07-29 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-07-29 -->
<!-- ANCHOR repo=vNPU sha=79931f49395007d6ede88492ea3bbd48bedb6758 tag=v0.1.0 scanned=2026-07-29 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-29 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-29 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-29 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-29 -->
