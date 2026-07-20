# 昇腾算力栈 diff 雷达 2026-07-21

## 摘要
- 本日 2 仓有实质代码改动,其余 7 仓无新提交。
  - **mind-cluster / clusterd**:扩充 NPU 故障隔离码表——`SeparateNPUCodes`(触发即隔离 NPU)新增 4 个码 `020001004 / 020001003 / 120001002 / 120001003`。故障自愈策略「即隔离」范围扩面(提交:新增clusterD隔离NPU故障码)。
  - **vNPU / xpu-device-plugin**:`DecodeContainerDevices` 5 处解析错误分支把 `log.Fatalln` 改成 `log.Errorln`——格式非法的容器设备注解不再令 device-plugin 进程整体退出崩溃(!76,防进程崩溃健壮性修复)。
- mind-cluster 本区间另有 npu-exporter 一处纯文案改动(flag help 里 `prometheus`→`Prometheus`)及若干 docs/前冒烟提交,不计信号。

## 当日重要改变
- **[故障自愈] clusterd 新增 4 个「即隔离」NPU 故障码**(`component/clusterd/build/publicFaultConfiguration.json`):
  - `SeparateNPUCodes` 由 9 个码扩到 13 个,新增 `020001004`、`020001003`、`120001002`、`120001003`;`PreSeparateNPUCodes`/`SubHealthFaultCodes` 未动。
  - 语义:命中这些码的 NPU 直接被 clusterd 从可调度池摘除(而非降级为亚健康/预隔离)。`0200/1200` 前缀成对新增,像是把某类硬件/固件故障从"观察"提级到"即隔离"。
  - 对我们产品的启示:昇腾侧的**设备健康→隔离**是一张可运营的故障码表(JSON 配置,非硬编码),故障分级=`NotHandle / SubHealth / PreSeparate / Separate` 四档。做 NPU 纳管/自愈时可直接对齐这张表的分级语义,并把"码表可热更新"作为产品化能力点。
- **[健壮性] vNPU DecodeContainerDevices 去 Fatalln,避免 device-plugin 崩溃**(`xpu-device-plugin/pkg/plugin/util/util.go`):
  - 解码容器设备串(`index,uuid,type,usedmem,usedcores,vid,...`)时,字段数不符或 `strconv.Atoi` 失败的 5 个分支原先调 `log.Fatalln`(=os.Exit,整进程退出),现改 `log.Errorln` + 返回空 `ContainerDevices{}`。
  - 该串来源于 Pod 注解/环境变量,属**用户可控输入**;旧逻辑下一个格式错误的注解即可打崩 xpu-device-plugin。与近期 nv-watch 侧「用户可控输入加固」同一主题(参见 KAI DRA 计数溢出修复)。
  - 对我们产品的启示:自研/纳管 device-plugin 时,凡解析用户可控设备串的路径都不应 fatal-exit;这是稳定性红线,值得做成 lint/review 检查项。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓(7 仓)</summary>

- openFuyao/npu-operator — 无新提交(HEAD 53299373 未动,tag v26.6.0)
- openFuyao/npu-container-toolkit — 无新提交(HEAD d54256e0 未动,tag v26.6.0)
- openFuyao/npu-driver-installer — 无新提交(HEAD c898c929 未动,tag v26.6.0)
- openFuyao/npu-node-provision — 无新提交(HEAD 717ef777 未动,tag v26.6.0)
- openFuyao/npu-dra-plugin — 无新提交(HEAD 98f8fa5e 未动,tag v26.6.0)
- openFuyao/volcano-ext — 无新提交(HEAD c9be5c4c 未动,tag v1.9.0)
- openFuyao/ub-network-device-plugin — 无新提交(HEAD 263d6387 未动,tag v26.6.0)

</details>

## 源链接
- mind-cluster compare: https://gitcode.com/Ascend/mind-cluster/compare/7983f9e1ada8d326f5832401b4ced317b81cd999...9dbe2a115da434fc0b5ab724f5c3b7d4b26d5790
- vNPU compare: https://gitcode.com/openFuyao/vNPU/compare/0a081832850f64b192f6787a8b87f63cb1bf9e92...29117ffcf0d144543dd4c0336c77f9abe6a612cd

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=9dbe2a115da434fc0b5ab724f5c3b7d4b26d5790 tag=v26.1.0.beta.2 scanned=2026-07-21 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-21 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-21 -->
<!-- ANCHOR repo=npu-driver-installer sha=c898c929187bba8051e2ebed87f609bc820ead68 tag=v26.6.0 scanned=2026-07-21 -->
<!-- ANCHOR repo=vNPU sha=29117ffcf0d144543dd4c0336c77f9abe6a612cd tag=v0.1.0 scanned=2026-07-21 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-21 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-21 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-21 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-21 -->
