# OpenFuyao 周报 2026-04-17

扫描窗口:2026-04-10 至 2026-04-17

## 摘要

- **昇腾侧要做自己的推理 operator**:`ascend/mind-cluster` 合入 26.0.0 版 `infer-operator` RFC(442 行设计),意味着昇腾栈内将出现跟 OpenFuyao InferNex 并行的 K8s operator 级推理抽象,两条路线的边界和配合关系是本周最值得深挖的信号
- **`elastic-scaler` 已独立成 repo**,并加了 webhook 证书自管;OpenFuyao 推理系统正在从单体 InferNex 拆分,向组件化 / 生产就绪演进
- **DRA 路线实装**:`npu-dra-plugin` 适配 Ascend910 + dcmi 接口,K8s Dynamic Resource Allocation 接入昇腾已从设计走向产线验证
- 官方渠道本周零公告(距 v26.03 发版正好一周),处于消化期

## 新功能 / 能力

### AI 推理栈

- **[`elastic-scaler` 独立 repo + webhook 证书自管](https://gitcode.com/openFuyao/elastic-scaler/commits/master)** —— commit `a58f180`(2026-04-16,MR !39)实现 webhook cert 自签自管,此前这块是 InferNex 内部子模块
  - 启示:OpenFuyao 正在把 InferNex 里"弹性 / 路由 / KVCache / 可观测"四大块拆成独立组件。我们如果要做推理弹性,同样应该从推理框架解耦,避免绑死在某一个推理栈(vLLM / SGLang)里。KServe 的 InferenceService + KPA 是一种解法,这里是另一种。
- **[InferNex 新增 perf scripts](https://gitcode.com/openFuyao/InferNex/commits/master)** —— commit `195a2be`,配套 0.22.2 README 更新。说明 InferNex 的性能基准正在固化,可用于跟 vLLM vanilla 做对比(v26.03 发版稿声称首 token 延迟 -30%、端到端 -10% 应该是基于这套脚本)
- **hermes-router 本周仅 README 更新**,无实质代码变化

### 昇腾资源管理(mind-cluster upstream)

- **[`infer-operator` RFC 合入 26.0.0 方向](https://gitcode.com/Ascend/mind-cluster)** —— `docs/rfc/26.0.0/features-inference-workload.md`(commit `4db91ae`,442 行)。这是一份新的**推理负载 K8s operator 设计**,走传统 operator 路线(CRD + controller),跟 OpenFuyao InferNex 的"应用层推理系统"路线并不在一个抽象层
  - 启示:**这是本周最关键的不确定性**。需要读完这份 RFC 才能判断:(a) 它跟 InferNex 是分层关系(operator 负责编排,InferNex 负责推理面)还是替代关系;(b) 它是否借鉴 KServe / KubeAI 的 CRD 设计;(c) 如果是替代关系,说明华为内部对"推理负载怎么抽象"还没统一,我们选型时要看清楚它们各自的主推方向
- **[`npu-dra-plugin` 适配 Ascend910](https://gitcode.com/openFuyao/npu-dra-plugin/commits/br_init_dev)** —— commit `5c4d3f3`(Ascend910)+ `537b0eb`(dcmi 适配),MR !10/!11。从"概念验证"走向"多机型产线支持"
  - 启示:对标 NVIDIA/k8s-dra-driver,昇腾 DRA 生态已非纸面。我们做 DRA 选型时,NPU 覆盖能力可以作为对比参考点,而不只看 NVIDIA。

### 集群与调度

- **[ascend-for-volcano: Atlas 950 PoD 超节点调度修正](https://gitcode.com/Ascend/mind-cluster)** —— commit `6f2c551`(MR !3231),仅多物理超节点调度场景下才过滤网络故障卡,避免单超节点内误杀可用卡
  - 启示:超大规模集群(1.6w+ 节点是他们家卖点)的实战问题修复。故障域 / 网络故障卡识别这类能力是超节点架构的专属痛点,通用 K8s 调度器没人管,我们如果有同量级场景要有类似的故障域感知调度
- **[npu-exporter 新增 `npu_card_num` 指标 + collector 重构](https://gitcode.com/Ascend/mind-cluster)** —— commit `dab095b`(MR !3289,自定义插件上报机器级 NPU 卡数量)+ `eed660b`(废弃 `collector_for_network_v2`)
  - 启示:资源拓扑粒度的指标在向上暴露。我们做成本 / 容量规划类功能时,需要类似的"卡级"而非"节点级"指标

### 其他

- **[`ub-network-device-plugin` 健康检查接口](https://gitcode.com/openFuyao/ub-network-device-plugin/commits/br_noncom_container_20260228)** —— MR !42/!45,校验 ubse socket 可用性,ubse SDK 升到 v0.0.9。UB 网络是昇腾专用低时延互联,跟我们产品无直接对标意义
- **[taskd 训练退出时 C++ 析构崩溃 fix](https://gitcode.com/Ascend/mind-cluster)** —— commit `69d9a05`(MR !3294),昇腾训练栈稳定性 fix,跟踪参考价值
- **两篇故障相关 RFC 入库**:人工故障隔离准确性增强(`1dee68b`,465 行)+ 故障升级原因记录(`5438cd0`)。26.0.0 方向里"故障处理"是显式课题

## 官方动态

- **本周无官方公告 / 博客 / 月报**。最近一次是 2026-04-08 的 v26.03 发版稿(窗口外)
- 按双月节奏,下一份社区运作报告预计 2026-05 初
- v26.06 preview / 功能预告本周未披露

## 跟我们产品的对比

| 维度 | OpenFuyao / 昇腾栈 | 我们 | 差异 / 需要补的 |
|------|-------------------|------|----------------|
| 推理抽象层 | **双轨并行**:InferNex(应用层系统) + infer-operator RFC(K8s operator) | 对标 OAI → KServe | 我们应该明确自己走哪条路,不要两条都做 |
| 推理弹性 | elastic-scaler 独立组件,跟推理框架解耦 | - | 值得借鉴"弹性与推理框架解耦"的组件化思路 |
| DRA 接入 | npu-dra-plugin 已进产线验证(Ascend910) | - | 评估 DRA 落地时,可以把它当参考实现 |
| 超节点故障域 | Atlas 950 级网络故障卡识别 | 无相关能力 | 若触达同量级场景需要补故障域感知调度 |
| 指标体系 | 卡级 `npu_card_num` + 拓扑感知 | 节点级指标为主 | 成本/容量类功能需要卡级粒度 |

## 值得跟进

- [x] **读 `docs/rfc/26.0.0/features-inference-workload.md`(infer-operator RFC,442 行)**,回答三个问题:与 InferNex 的抽象关系、是否借鉴 KServe、主推方向是哪个 → 结论见专题 [`2026-04-17-openfuyao-infer-operator-vs-infernex.md`](2026-04-17-openfuyao-infer-operator-vs-infernex.md):两者是不同抽象层的并行品,归属不同团队,infer-operator 不提 KServe,InferNex 26-X 规划对接 KServe
- [ ] 跟一次 `openFuyao/elastic-scaler` 的完整能力,列出它的 scaling 决策维度(是否用 KVCache 使用率 / 首 token 延迟作为 signal),对比 KServe KPA + 我们自己的弹性方案
- [ ] 关注 `npu-dra-plugin` 后续 commits,看 Ascend910 之后是否快速补齐其他机型,判断昇腾 DRA 方案的成熟度曲线
- [ ] 4 月底~5 月初盯一次 CSDN `openFuyao` 号,等 v26.06 功能预告或社区运作报告

## 原始材料

<details>
<summary>本周扫描清单(点开)</summary>

**openFuyao 组织(GitCode)**
- 有实质变化:InferNex(perf scripts)、elastic-scaler(webhook 证书)、npu-dra-plugin(Ascend910/dcmi)、ub-network-device-plugin(健康检查 + SDK bump)
- 仅 readme / 空周:hermes-router、npu-operator、kae-operator、volcano-ext、npu-driver-installer、npu-node-provision、ray-service、eagle-eye
- 新发现 repo:ray-service、eagle-eye、elastic-scaler(独立于 InferNex)

**ascend/mind-cluster(GitCode)**
- npu-exporter:`dab095b`(npu_card_num 指标)、`eed660b`(collector 合并)
- ascend-for-volcano:`6f2c551`(Atlas 950 超节点调度)
- devmanager/dcmiv2:`04ee9e2`(dcmiv2_get_all_device)、`2fe7d9f`(带超时错误码)、`5128ecb`(接口改名)
- taskd:`69d9a05`(训练退出析构崩溃 fix)
- RFC:`4db91ae`(infer-operator 推理负载)、`1dee68b`(人工故障隔离)、`5438cd0`(故障升级原因)
- 文档:`7dd17b1`(NPU 软切分说明)
- 本周无新 tag / release

**官方信息源**
- 官网 openfuyao.cn(news/blogs)、docs 站、CSDN openFuyao 号:窗口内零更新
- 参考窗口外锚点:v26.03 发版稿 2026-04-08;最近运作报告 2026-03-09

</details>
