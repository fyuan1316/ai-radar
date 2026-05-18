# OpenFuyao 周报 2026-05-18

窗口:2026-05-11 → 2026-05-18(7 天)

## 摘要

- **v26.06-rc.1 进入发布通道**,组件清单较 v25.12-rc.3 减一加一:不再单独打包 `AIAllInOne`,新增独立的 `PDOrchestrator`(elastic-scaler / resource-scaling-group / tidal 三合一),`RayPackage` 继续保留;InferNex 主集成跟到 `vllm-ascend v0.13.0`。
- **InferNex 上线 KServe Bridge**:新组件 `InferNex-Bridge` 直接 import `github.com/kserve/kserve v0.17.0`,通过 webhook 把 KServe 的 `LLMInferenceService`(serving.kserve.io/v1alpha1)翻译成 `InferNexService` CRD,同时拉起 PD/聚合两种部署模板。这是 OpenFuyao 第一次明确"由 KServe 控制面驱动"的对接点。
- **Hermes-router 紧跟上游 GIE v1.3.0**:PD 路由重构为可复用插件(`pd_route.go` + picker/scorer/prerequest 各一份 PD 变体),修复 Envoy destination 多 leader 抢路问题;CSDN 同步放出技术讲堂讲清 EPP+InferencePool+HTTPRoute 模式,跟 llm-d 一条路。

## 新功能 / 能力

- [InferNex KServe Bridge(InferNexService CRD + LLMInferenceService 适配)](https://gitcode.com/openFuyao/InferNex/-/commit/3e86f93) — 200+ 文件、5 万行 CRD YAML,新增 `component/InferNex-Bridge/`,内含 Bridge 控制器、webhook、Helm chart、aggregate / PD 两套部署模板;`buildInferNexServiceFromLLMInferenceService` 把 KServe `LLMInferenceService` 转为 InferNexService,Pod 模板上保留 `kserve.io/component=llminferenceservice-workload[-prefill]` 标签以兼容 KServe 选择器
  - 启示:OpenFuyao 走的不是"自己造一套推理 CR + 控制台"而是**两层架构** — 用户面继续用 KServe `LLMInferenceService` 作为入口,Bridge 层翻译成厂内的 `InferNexService`,最终拉起 vLLM-Ascend + hermes-router + mooncake + cache-indexer 的全家桶。这跟 OAI 的"odh-model-controller → KServe InferenceService"是同一种解耦模式,只是 OAI 还停留在 v1beta1 InferenceService,OpenFuyao 直接对接 v1alpha1 LLMInferenceService(KServe 0.17 新引入的 LLM 专用 CR)。我们如果做 KServe 驱动的推理产品,需要评估是否同样押注 LLMInferenceService 路径
- [v26.06-rc.1 release manifest 落地](https://gitcode.com/openFuyao/release-management/-/commit/31ec815) — 15 个组件 VersionConfig YAML,1652 行新增;两天后 [zuozongyuan 又微调了 Core / HermesRouter / InferNex / PDOrchestrator](https://gitcode.com/openFuyao/release-management/-/commit/adae4bb),节奏明显在赶 06 季度版
  - 启示:**`PDOrchestrator` 独立出包**意味着 PD 弹性编排能力被从 InferNex 拆出,可作为通用组件单独消费(elastic-scaler 0.21.2 + resource-scaling-group 0.21.2 + tidal 0.21.2);对照 OAI 这一块完全空白,KServe 自带的 autoscaler 也没有"按 PD 角色组扩缩"的概念。**这是我们可以借鉴的能力建模**(不是抄实现,而是抄"把 PD 角色组当成一等公民扩缩单位"的思路)
- [mind-cluster infer-operator 优先级调度](https://gitcode.com/Ascend/mind-cluster/-/commit/2d48f89) — `pkg/controller/schedule/priority_scheduling.go` 新增 182 行,`InferService` / `InstanceSet` CRD 增加 priority 字段;InferenceService 控制器引入按优先级裁决创建/驱逐 InstanceSet 的逻辑(957 行 diff)
  - 启示:**注意这是 mind-cluster 内的 `infer-operator`,不是 InferNex** — OpenFuyao 体系里同时存在两套推理控制面(参见 [2026-04-17 deep-dive](../2026-04-17-openfuyao-infer-operator-vs-infernex.md))。Ascend 侧的 infer-operator 走"NPU 设备 + 实例池"细粒度调度,InferNex 走"KServe-style 推理服务化"。我们的产品如果做单一路径,要明确是 KServe LLMInferenceService 入口还是设备亲和入口
- [npu-dra-plugin 设计文档归档](https://gitcode.com/openFuyao/npu-dra-plugin/-/commit/4fd3c32) — `br_init_dev` 分支新增设计文档,代码仍未发版(tag 还是 1.0.0)
  - 启示:DRA 接入昇腾仍停留在文档阶段;K8s 1.32 DRA GA 之后,OpenFuyao 这条线没看到加速,跟我们 DRA 选型评估的优先级保持原判断(短期内仍是 device-plugin 主路径)

## AI 推理栈(InferNex / hermes-router / ...)

- [hermes-router 重构 PD 路由插件公共逻辑](https://gitcode.com/openFuyao/hermes-router/-/commit/132ba6f) — `pkg/plugins/common/pd_route.go` 新增 112 行,3 个 picker(`picker_pd_kv_cache_aware` / `picker_random_pd` / `picker_pd_bucket`)的 PD 配对逻辑统一收敛;commit message 直白:"keep Envoy destination single leader in PD routing",修了 EPP 给同一对 prefill/decode 请求选到不同 leader 的并发问题
- [hermes-router 修 modelname label 格式](https://gitcode.com/openFuyao/hermes-router/-/commit/ef4f1db) — 单行 helm template 修复,影响 InferencePool 标签匹配
- [hermes-router 同步上游 GIE 到 v1.3.0](https://gitcode.com/openFuyao/InferNex/-/commit/3e86f93#diff-go.mod) — InferNex-Bridge 的 go.mod 锁定 `sigs.k8s.io/gateway-api-inference-extension v1.3.0`,比上次 digest 时期(v1.1.0 README 徽章)又升一档;README 仍标 v1.1.0,实际代码已经走在前面
- [CSDN 技术讲堂:Hermes-router](https://blog.csdn.net/openFuyao/article/details/161117370)(2026-05-15)— 明确路由架构:EPP(Endpoint Picker)插件 + Gateway 上 HTTPRoute 路由到 InferencePool,Filter→Scorer→Picker 三段;路由策略列表:`kv-cache-aware`(聚合/PD 均支持)、`pd-bucket`、`pd-random-bucket`、`pd-kv-cache-aware`
- [CSDN 技术讲堂:Mooncake Store 热点缓存优化](https://blog.csdn.net/openFuyao/article/details/161117635)(2026-05-15)— 客户端缓存热点 KVCache 切片,减少跨节点 RDMA 传输;Prefill / Decode 集群解耦,Mooncake Store 作为中间 KVCache 池

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [mind-cluster 支持 A2/A3 动态算力切分 + vNPU 指标上报](https://gitcode.com/Ascend/mind-cluster/-/commit/3877a03) — vnpu 路径从 `ascend910b` 子包重构提到 `ascend910/vnpu`(后续 A2/A3 共用);Volcano 插件新增 vnode 处理,npu-exporter 新增 vnpu 维度 metrics(prometheus 文档同步)
  - 启示:vNPU 切分能力从"910b 专用"变"机型通用",细粒度配额的可观测性补齐;对照我们的 GPU MIG/vGPU 路径,这条是昇腾专属能力,通用 K8s AI 栈无对应物,但**架构上"以扩展调度器 + device plugin + exporter 一致打通"值得对照实现**
- [mind-cluster 去掉 vNPU 静态虚拟化"每次仅启动一个 Pod"限制](https://gitcode.com/Ascend/mind-cluster/-/commit/2128f1a) — `test-master-issue-291-20260512` 分支落地,静态虚拟化场景的并行度限制解除
- [mind-cluster 修复 Volcano log 中废弃字段 tp-block](https://gitcode.com/Ascend/mind-cluster/-/commit/13978cb) — `tp-blcok`→`ra-block`,Volcano 1.10+ 字段对齐(对应上周 Volcano v1.10 GA)
- [mind-cluster device-plugin 适配 EID 方案变更](https://gitcode.com/Ascend/mind-cluster/-/commit/1df4596) — Atlas 950 故障码新增/修改;故障诊断维度持续打磨
- [ub-network-device-plugin 升级策略优化 + 不健康设备批量告警](https://gitcode.com/openFuyao/ub-network-device-plugin/-/commit/6700e35) — UB/URMA 网络设备 plugin 在 `br_noncom_container_20260228` 分支继续迭代,本周 2 次更新

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- [cluster-api-provider-bke 多个安装期修复](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/99560d0) — etcd 版本注入、kube-proxy 升级、kubelet 启动后镜像 ensure、bkeagent 架构识别两次连续修复;社区运作博客 4-28 那篇 Cluster API 安装指导对应的实操层代码
- [community 新建分支批量](https://gitcode.com/openFuyao/community/commits/master) — 一周内新建/登记的仓位:`infernex-bridge`(已合入 InferNex)、`elastic-scaler`、`hermes-router` 新分支、`cache-indexer` 新分支、`many-core-orchestrator`、`olc-python`(高并发过载控制库)、`openfuyao-sandbox`、`br_UnifiedBus` 分支
  - 启示:**`olc-python`(overload control)和 `many-core-orchestrator`(众核编排)是新出现的方向**,前者是面向 Python 服务的过载保护库(疑似为 vLLM/inference 引擎前置保护),后者跟"鲲鹏多核 / 昇腾众核"硬件编排相关。可以下周单独跟,看是否进入 v26.06 主线
- volcano-ext 仓库本周仍无 commit,确认 OpenFuyao 对 Volcano 的扩展现在主要走 mind-cluster 内的 `component/ascend-for-volcano/`,volcano-ext 是历史仓位(沿用上周判断)

## 官方动态

- **v26.06-rc.1 release manifest 5-15 入库**(release-management 仓),这是首个非 LTS 季度版的 rc 标记;按 OpenFuyao YY.MM 命名节奏,正式版本预计在 6 月底前发出
- 官网 `https://www.openfuyao.cn` news / release / blogs 三个板块 WebFetch 仍显示"暂无内容",大概率是页面 SSR 配置问题而非真无更新
- docs.openfuyao.cn 没有 release notes 公开路径(WebFetch 直接 404)
- CSDN 5-15 发的两篇技术讲堂是本周主要的官方传播动作

## 跟我们产品的对比

| 维度 | OpenFuyao v26.06-rc.1 | OAI / KServe / 通用 K8s 栈 | 我们应该怎么做 |
|------|---------|---------------------------|----------------|
| 推理服务 CR 入口 | KServe `LLMInferenceService` v1alpha1(经 Bridge 翻译) | OAI 仍走 KServe `InferenceService` v1beta1 | 评估是否押注 `LLMInferenceService`(KServe 0.17+)作为下一代入口,先期不要写死在 v1beta1 |
| 智能路由 | hermes-router 基于上游 GIE v1.3.0,4 种策略 | KServe Gateway + GIE 上游本身;llm-d 项目走同一路 | 路由层应直接采纳 GIE EPP 模式,不要自造一套 — 这条 OpenFuyao 和 llm-d 已经形成事实标准 |
| PD 弹性编排 | `PDOrchestrator` 独立组件(elastic-scaler + resource-scaling-group + tidal) | KServe Autoscaler 不知道 PD 角色;OAI 无此能力 | **直接借鉴抽象** — "按 PD 角色组扩缩"是模型层抽象,与昇腾无关,对 H100 / GPU 集群同样适用 |
| KVCache 池化 | Mooncake Store + cache-indexer(全局前缀树,基于 vLLM KV Event) | KServe + llm-d 也在做 KVCache aware 路由,无成熟池化方案 | KVCache 池化是 OpenFuyao 走得最快的部分,我们如果不做自研,可考虑 vendor 接入 LMCache 或 Mooncake |
| 推理控制面 | 两套并存(InferNex + mind-cluster infer-operator) | OAI 单一路径(KServe) | 我们应保持单路径,避免重蹈 OpenFuyao 双控制面问题 |
| DRA | npu-dra-plugin 仍在文档阶段 | KServe / 通用 K8s 1.32 DRA GA | 跟我们当前判断一致,DRA 短期不进主路径 |
| Ray 集成 | RayPackage 持续保留 | OAI / Kubeflow 也都有 | 标配,无新信号 |

## 值得跟进

- [ ] **读 `InferNex-Bridge` 的 `infernexservice_builder.go` 完整逻辑**,确认 KServe `LLMInferenceService` → `InferNexService` 的字段映射,特别是 PD 模式下 Bridge 怎么处理 KServe 端定义的 prefill/decode workloads 跟 InferNex 自带模板的冲突
- [ ] 跟 KServe v0.17.0 的 `LLMInferenceService` CRD 定义对比,判断 OpenFuyao 是否完全实现还是仅子集
- [ ] **跑一遍 v26.06-rc.1 的 PDOrchestrator chart**(pd-orchestrator-0.21.2.tgz),拆解 elastic-scaler 的扩缩信号源 / 决策模型 / 执行路径,判断对 GPU 集群可移植性
- [ ] 关注 `many-core-orchestrator` 和 `olc-python` 仓位是否进入 v26.06 GA 清单 — 前者疑似面向众核 NUMA 调度,后者是 Python 服务过载控制库,可能用于 vLLM 前置保护
- [ ] mind-cluster 的 infer-operator 与 InferNex 的边界:同一团队在维护两套推理控制面的动机是什么(组织内不同 SIG?还是定位差异?)— 下周看 community 仓的 SIG 文档变化
- [ ] hermes-router GIE 版本徽章对外标 v1.1.0、代码实际跟到 v1.3.0,值得提醒同步;同时验证我们自家路由层是否能跟 GIE v1.3.0 兼容

## 原始材料

<details>
<summary>本周扫描清单</summary>

**openFuyao 主组织活跃仓**(commits in 2026-05-11..2026-05-18):
- `InferNex`:2 commits,核心 `3e86f93 feat: kserve adaptor for deploying infernex`(2026-05-15)
- `hermes-router`:6 commits,核心 `132ba6f fix: keep Envoy destination single leader in PD routing`(2026-05-14)、`ef4f1db fix: fix modelname label format`(2026-05-14)
- `npu-dra-plugin`:2 commits,`4fd3c32 归档设计文档`(2026-05-15)
- `ub-network-device-plugin`:2 commits,`6700e35 fix: add batch warning log for unhealthy devices with HwResId`(2026-05-12)
- `cluster-api-provider-bke`:多 commits(kubelet/etcd/bkeagent 修复)
- `release-management`:5 commits,`31ec815 feat: add 26.06-rc.1`(2026-05-15)、`adae4bb feat(v26.06-rc.1): update Core, HermesRouter, InferNex, PDOrchestrator`(2026-05-16)
- `community`:20+ commits,新仓 olc-python / many-core-orchestrator / openfuyao-sandbox 登记
- `olc-python`:initial commit(2026-05-12)

**openFuyao 主组织无活动仓**(窗口内 0 commit):
- `npu-operator`、`volcano-ext`、`kae-operator`、`openfuyao-system-controller`

**上游 Ascend/mind-cluster**:~50 commits,核心特性:
- `2d48f89 【infer-operator】优先级调度`(2026-05-16)
- `3877a03 【修改说明】支持A2/A3动态算力切分和vnpu指标上报`(2026-05-13)
- `1df4596 dp适配EID方案变更`(2026-05-16)
- `2128f1a 去除静态虚拟化每次只能启动一个pod限制`(2026-05-14)
- `13978cb 修改volcano log中的废弃字段tp-blcok为ra-block`(2026-05-13)

**官方信息源**:
- 官网 `https://www.openfuyao.cn`(news/release/blogs 仍显示"暂无内容")
- 文档站 `https://docs.openfuyao.cn`(无 release notes 公开路径)
- CSDN `https://blog.csdn.net/openFuyao` 2 篇:
  - 2026-05-15 [openFuyao技术讲堂| AI推理赫尔墨斯路由（Hermes-router）](https://blog.csdn.net/openFuyao/article/details/161117370)
  - 2026-05-15 [openFuyao技术讲堂 | Mooncake Store热点缓存优化](https://blog.csdn.net/openFuyao/article/details/161117635)

**v26.06-rc.1 组件清单**(release-management 仓 openFuyao-26.06/rc.1/):
ColocationPackage、Core、EagleEye、**HermesRouter**、**InferNex**、KaeOperator、LargeScaleCluster、LoggingPackage、ManyCoreScheduler、MonitoringDashboard、MultiClusterService、NpuOperator、NumaAffinityPackage、**PDOrchestrator(新独立)**、RayPackage

</details>
