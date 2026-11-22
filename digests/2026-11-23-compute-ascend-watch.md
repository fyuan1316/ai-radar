# 昇腾算力栈 diff 雷达 2026-11-23

## 摘要
- **本日无实质改动(连续第 2 个空日)**:mind-cluster 全 12 个 component + openFuyao 原 8 仓自 2026-11-22 锚点以来零新提交,逐仓 HEAD 与锚点逐字符一致(已用 `commits?per_page=3` 直查 API 复核,非 helper 误判)。mind-cluster HEAD 仍是 `94d21ad9`(`!5319 merge feature/https-05-runtime-deploy into master`,2026-11-21 01:12 +08:00),即 HTTPS 双监听批次的收尾合入;openFuyao 侧最近实质提交仍停在 10 月底(npu-operator `!121` 适配 A5 机型 / 2026-10-10,vNPU `!96` vNPU 优先级抢占设计 / 2026-10-28,npu-dra-plugin `!42` 整卡独占多 Claim pending 修复 / 2026-11-02)。
- **补齐一处源覆盖缺口**:趁空日核对 openFuyao 组织全量仓库清单(`orgs/openFuyao/repos`,3 页),发现 `npu-feature-discovery` 是在活跃的昇腾栈组件却一直不在本 task 数据源里 —— 它是昇腾侧的 NFD 对等物(发现 NPU 型号并打节点标签,`!22 feat: add the capability of discovering A5 and labeling` / 2026-10-09),是 npu-operator → 调度器之间的标签来源,漏掉它等于漏掉"新机型纳管从哪一环开始落地"的最早信号。今日已建锚点,**从 2026-11-24 起跟踪增量**;同时把 `ub-network-bandwidth-operator`(UB 带宽配置 operator,与已有 P2 `ub-network-device-plugin` 同一 fabric 主线)一并补入 P2 并建锚点。
- **两个空壳新仓待观察**:`equivalent-compute-unit`(2026-11-18 建仓)与 `compute-fusion`(2026-10-23 建仓)目前**仅有 Initial commit、无任何代码**,故未纳入扫描清单。前者名字("算力等效单元")指向异构算力折算/配额等效这一层抽象,与我们产品的多厂商算力统一计量直接相关,一旦出代码应第一时间纳管。

## 当日重要改变
- 无(零新提交,无信号可映射)

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

## 本期新建基线(首跑,仅建锚点无 diff)
- npu-feature-discovery:P1 新增源,锚点 4ba6e58e(tag v26.9.0)
- ub-network-bandwidth-operator:P2 新增源,锚点 d4ee1a47(无 tag)

## 后续发展方向 [AI]
- **证据边界声明**:本日零 diff,以下仅是对"数据源覆盖面"的判断,不是对代码趋势的判断 —— 没有新 hunk 可据。
- 昇腾栈的活跃度中心明显在 `Ascend/mind-cluster`(11 月持续产出 HTTPS 双监听、clusterops-agent、DRA 等批次),openFuyao 侧 8 个 NPU 仓已近一个月静默。若这一分布继续,可考虑把 openFuyao 组的扫描频率降到隔日、把 mind-cluster 的 component 粒度拆得更细,减少空日噪声。该判断只覆盖 11 月的提交时间分布,未核查各仓是否在非 master 分支上开发(GitCode compare 只跟默认分支,**分支侧开发会被整体漏掉**,这是当前取数方式的已知盲区)。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=94d21ad9355295041392d28e73704f3e0a04bda8 tag=v26.3.0-beta.2 scanned=2026-11-23 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f0654355fb65ac3ffca9a41357100a82fde4fc10 tag=v26.9.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=37a1d669b4f5ad815110d509c541d321c0c4fab5 tag=v26.9.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=npu-feature-discovery sha=4ba6e58e3e132f61936ae2c619f91d9e75c5ec90 tag=v26.9.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=ub-network-bandwidth-operator sha=d4ee1a478ec50c0c543b73f01a00944467e8018d tag=— scanned=2026-11-23 -->
