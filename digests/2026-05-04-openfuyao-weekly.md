# OpenFuyao 周报 2026-05-04

窗口:2026-04-27 → 2026-05-04(7 天)

## 摘要

**本周 OpenFuyao 核心仓库无重大更新**:扫描的 7 个 OpenFuyao 仓库(InferNex / hermes-router / npu-operator / volcano-ext / npu-dra-plugin / ub-network-device-plugin / kae-operator)在窗口内**全部无新 commit、无新 tag、无新 release**;最近活动均在 2026-04-21 之前(InferNex 4-21、hermes-router 4-10、npu-operator 3-05)。官方网站 news / release / blogs 三个板块当前显示"暂无内容"。

唯一有持续提交的是上游 `Ascend/mind-cluster`(昇腾官方上游,OpenFuyao 整合源),窗口内 26 个 commit,基本是 device-plugin / operator / docker 镜像标准化 / mindio 维护。

按 task 的"空周跳过规则",本期 digest **只归档,不推飞书**。

## 新功能 / 能力
本周 OpenFuyao 仓库无新功能合入,无新 release。

## AI 推理栈(InferNex / hermes-router / ...)
- InferNex 最新 commit `6a75e66` 在 2026-04-21,本窗口无变化
- hermes-router 最新 commit `6fb1aba` 在 2026-04-10,本窗口无变化

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

### Ascend/mind-cluster(上游)— 唯一活跃
窗口内 26 个 commit,核心信号(去除 merge 类提交):

- 2026-04-30 [`a6a47cf` 【ascend-for-volcano】调度策略修改](https://gitcode.com/Ascend/mind-cluster/-/commit/a6a47cf) — 昇腾 Volcano 调度策略调整
  - 启示:Volcano 在昇腾上的调度策略仍在反复打磨,与上游 Volcano 1.10+ 适配同步推进
- 2026-04-30 [`87767b1` device-plugin 上报网卡故障错误修复](https://gitcode.com/Ascend/mind-cluster/-/commit/87767b1)
- 2026-04-30 [`ccdddae` operator 更新 pod rank index 添加重试](https://gitcode.com/Ascend/mind-cluster/-/commit/ccdddae) — 训练 rank 分配的健壮性
- 2026-04-29 [`92e437d` ascend-fd-tk bit error rate 修改](https://gitcode.com/Ascend/mind-cluster/-/commit/92e437d) — 故障诊断 bit error rate 阈值
- 2026-04-29 [`eff4112` mindio TFT 日志模块 coredump 修复](https://gitcode.com/Ascend/mind-cluster/-/commit/eff4112)
- 2026-04-29 [`ca4705f` ascend-docker-runtime 驱动目录 owner 一致情况下允许软链接](https://gitcode.com/Ascend/mind-cluster/-/commit/ca4705f) — runtime 安全约束放宽
- 2026-04-28 [`94097e4` 支持构建 1.10+ 版本的 volcano](https://gitcode.com/Ascend/mind-cluster/-/commit/94097e4) — Volcano 主线对齐(对应上周 Volcano v1.10.0 预发)
- 文档/部署侧:故障诊断拆分使用指导和工具内容、安装部署拆分多 MD 文件、镜像标准化 OVERVIEW 开发、Dockerfile 标准化

### npu-dra-plugin
- 最新 commit `8f69d12` 在 2026-04-20,DRA 接入仍在 `br_init_dev` 分支开发,本窗口无活动;tag 仍是 `1.0.0`

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)
- volcano-ext 仓库最新 commit 实际是 2024-09-30(`c9be5c4c`),tag 已到 `v1.10.0` 但代码长期未更;本任务的认知偏差需要修正 — volcano-ext 当前可能已迁出或合并,后续扫描周期需重新核实仓库归属
  - 跟进:确认 OpenFuyao 当前对 Volcano 的扩展是否仍走这个仓库,或已并入 mind-cluster 的 ascend-for-volcano 路径

## 官方动态
官网 https://www.openfuyao.cn 的 news / release / blogs 三个板块在 WebFetch 抓取中均显示"暂无内容"。CSDN 官方博客 https://blog.csdn.net/openFuyao 本窗口仅 1 篇:
- 2026-04-28 [Cluster API 安装指导](https://blog.csdn.net/openFuyao/article/details/160594986) — 通用 Cluster API 普及内容,非 OpenFuyao 自身能力发布

略早于窗口的 2026-04-22 一篇 [openFuyao 技术讲堂 | AI 推理鹰眼(Eagle Eye)](https://blog.csdn.net/openFuyao/article/details/160415504),阐述 Eagle Eye 多层观测体系(从业务到硬件),仍属于 v25.12 LTS 的能力宣讲,无新功能。

## 跟我们产品的对比
本周无足够新内容做对比。仅一条结构性观察:OpenFuyao 在 NPU 设备/runtime 层的迭代主要发生在上游 Ascend/mind-cluster,而 OpenFuyao 主组织(gitcode.com/openFuyao)下的 InferNex / npu-operator 等仓近 2 周静默;说明 OpenFuyao 的开发节奏有"上游集中 + 下游季度集成"的特点,周扫描应**优先观察 Ascend/mind-cluster** 而非只看 openFuyao 主组织。

## 值得跟进
- [ ] 核实 volcano-ext 仓库当前活跃度(是否被 mind-cluster 内的 ascend-for-volcano 取代),修正下次扫描清单
- [ ] 关注 mind-cluster 当前在做的"Volcano 1.10+ 构建支持"何时回流到 OpenFuyao 主组织 InferNex / npu-operator 的发布
- [ ] OpenFuyao 下季度 v26.03(假设保持 YY.MM 命名)预计 6 月发布,临近时单独扫一轮
- [ ] 官网"暂无内容"是否是数据源问题而非真无更新,下周交叉用 https://docs.openfuyao.cn 验证

## 原始材料

<details>
<summary>本周扫描清单</summary>

- 主组织 gitcode.com/openFuyao 下:InferNex / hermes-router / npu-operator / volcano-ext / npu-dra-plugin / ub-network-device-plugin / kae-operator 全部 0 commit
- 上游 gitcode.com/Ascend/mind-cluster:26 commit(详见上方)
- 官网 https://www.openfuyao.cn(news/release/blogs 暂无内容)
- CSDN https://blog.csdn.net/openFuyao(1 篇 Cluster API 普及文)

跳过推飞书(空周规则)。
</details>
