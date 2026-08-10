# OpenFuyao 周报 2026-08-10

窗口:2026-08-03 -> 2026-08-10(7 天)

## 摘要(3 条以内)
- 上周一次性合入的 **vNPU + DRA 切分全栈([npu-operator !109](https://gitcode.com/openFuyao/npu-operator))本周进入"打磨硬化期"**:无新架构,全是产品化收口——[npu-dra-plugin](https://gitcode.com/openFuyao/npu-dra-plugin) 补 Ascend910C 硬切分模板、把劫持库挂载改成只读(`ro,rbind`)、修正 vCANN-RT 安装器镜像地址;[vNPU](https://gitcode.com/openFuyao/vNPU) 修硬切资源核算(AiCpu 误加成 AiCore)和空 ContainerID panic。**这是"能跑"到"能上生产"之间的典型清单**,值得我们做 GPU 共享时对照。
- 唯一战略级信号在官方:**[openFuyao 成立 Agentic Ops SIG](https://blog.csdn.net/openFuyao)(08-04)**,把"面向 AI 云原生的智能运维(AIOps → Agentic AIOps)"列为独立技术方向。这是继 sig-ai-inference / sig-large-scale-cluster 之后,社区第一次把"运维智能体"提到 SIG 一级——对标趋势是 AIOps 向 agent 化演进,OAI 侧目前无对等的独立方向。
- 代码活跃仓收敛到 **npu-dra-plugin / vNPU / InferNex 三家**,均为 bugfix/健壮性;hermes-router、volcano-ext、ub-network-device-plugin、kae-operator 本窗口**无新提交**;官方无新版本(v26.06 仍最新)。非发版周,属正常冷清节奏。

## 新功能 / 能力

- [Ascend910C 硬切分模板补齐(npu-dra-plugin)](https://gitcode.com/openFuyao/npu-dra-plugin) — `chipCapabilities` 新增 910C 单 die 硬切模板:整卡 `totalAiCore:20 / totalAiCpu:6 / totalMemoryMi:32768`,两档 profile `vir05_1c_16g`(AiCore 5/AiCpu 1/16G)、`vir10_3c_32g`(AiCore 10/AiCpu 3/32G);同步落到 Helm `values.yaml` 与 `manifests/deploy/01-configmap.yaml`。
  - 对比:这就是昇腾版的 **MIG profile 表**——把每种芯片支持的硬切规格做成 configmap 数据,而非代码硬编码。昇腾专用(具体规格数字对我们无意义),但**数据驱动的切分 profile 表**是通用做法:我们做 GPU 硬切(MIG)/软切档位时,芯片型号 → 可用 profile 的映射也应该是可热更新的配置数据,新增卡型只改 configmap 不改代码。
- [Agentic Ops SIG 成立(官方,08-04)](https://blog.csdn.net/openFuyao) — 社区新设 SIG,目标"组队构建面向 AI 云原生的智能运维技术体系",定位是 AIOps 向 Agentic(运维智能体)演进。当前公开材料只有方向宣示,尚无子项目/repo 落地。
  - 启示:这是把"运维智能体"当作**与推理、调度并列的一等方向**来立项,而不是塞进某个现有 SIG 的运维模块。对标业界 AIOps → Agentic AIOps 的转向(故障自诊断/自愈、集群操作由 agent 编排)。对我们:OAI/ODH 侧目前没有对等的"agentic ops"独立方向,若这条线跑出真实 repo(而非只停在 SIG 公告),会是差异化能力,值得挂一个持续跟踪位——重点看它是做"LLM 辅助排障"还是"agent 直接操作集群"(后者的准入/权限边界才是难点)。

## AI 推理栈(InferNex / hermes-router / ...)

- [InferNex controller 区分永久配置错误 vs 瞬时错误(!203)](https://gitcode.com/openFuyao/InferNex) — `reconcileWorkloadsAndRBAC` 遇到 `baseRefs` 模板(InferNexServiceConfig)`NotFound` 时,新增 `ErrTemplateNotFound` 哨兵错误,识别为**永久配置错误**:更新 CR status 把错误暴露出来后**停止重试**,而非无限 reconcile。
  - 对比:这是标准的 controller 健壮性收口——**不可恢复的配置错误不该进重试队列空转**,要么 surface 到 status 让用户改配置,要么等 watch 到模板创建再触发。通用启示直接适用:我们的 InferenceService/operator 也应把"引用了不存在的模板/密钥/配额"这类持久错误与"API server 抖动"这类瞬时错误分开处理,前者写 status + 停重试,后者退避重试。
- [InferNex 预检器收敛误报项(!210)](https://gitcode.com/openFuyao/InferNex) — 上周新上的 `infernex-checker` 本周做减法:**删掉 H-06 子网一致性检查**(hccn.go 直接删 45 行),并改进 H-07 的建议文案。
  - 对比:预检项上线后立刻发现"子网一致性"是个过严/误杀的检查项就砍掉——**预检器的价值在准入门槛的准确率,过严的 hard check 会误杀正常集群**。通用启示:我们若做分布式推理/训练开服前预检(上期建议过),预检项要分 hard(不通过就拦)和 soft(只告警),并保留快速下线单个检查项的能力,避免一个误报项挡住所有作业。
- hermes-router:本窗口**无新提交**(仍 v26.6.0),KVCache-aware / prediction 路由处于发版后静默期,连续两周无算法级更新。InferNex 本周也无路由算法变更,全是 controller/checker 健壮性。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [vNPU 修硬切分资源核算 bug(!87)](https://gitcode.com/openFuyao/vNPU) — `volcano-xpu-plugin` 的 `applyHardModeDevice` 里,`device.UsedCpu` 原来错加了 `template.AiCore`,改为正确的 `template.AiCPU`。
  - 对比:硬切分下 **AiCore(算力核)和 AiCpu(控制核)是两个独立配额维度**,核算时混用会导致设备可用量算错、进而超分或拒调度。通用启示:切分资源的多维核算(算力/显存/控制核)每一维都要独立记账,别用一个维度的值顶替另一个——GPU 侧对应 SM/显存/编解码器多维配额同理。
- [vNPU 防空 ContainerID panic(!88)](https://gitcode.com/openFuyao/vNPU) — device-plugin runtime service 用 `stripContainerIDPrefix` 处理 ContainerID,避免空值导致 panic。
  - 昇腾专用路径的健壮性小修,通用启示有限:device-plugin 处理来自 runtime 的 ContainerID 要做空值/前缀防御,属边界处理常识。
- [npu-dra-plugin 安全与部署收口](https://gitcode.com/openFuyao/npu-dra-plugin) — 本周最活跃仓,4 处硬化:(1) `softShareMounts` 挂载权限改**只读** `ro,rbind`(容器内只读劫持库,防篡改);(2) vCANN-RT 安装器**镜像地址修正为实际仓库路径**(上周刚集成的 vcannrt-installer 镜像引用是错的);(3) `values.yaml` 的 `nodes` 默认改空(避免默认配置误下发到无关节点);(4) 清理 DRA 插件废弃文档。
  - 对比:**劫持库只读挂载**是通用安全实践——LD_PRELOAD/CDI 注进容器的运行时劫持库若可写,容器内进程能篡改它逃逸隔离;HAMi 的 `libvgpu.so`、我们做 GPU 软切注库时同样应 `ro` 挂载。其余是上周 !109 一次性合入后的必然善后(镜像地址、默认值、废弃文档),印证"大 MR 一次合入 + 一周收尾"的节奏。
- ascend/mind-cluster:本周提交以**工程化为主**——发布 26.1.0 镜像概述文档、三方依赖消减、流水线代码化(新增 `.gitcode/workflows` 把 CodeCheck/Build/DT 从 CodeArts 迁到 gitcode workflows)。无 vNPU/TFT 等能力级变更,不展开。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- volcano-ext 独立仓本窗口**无新 tag/提交**(仍 v1.10.0)。调度侧唯一相关变更是 vNPU 仓的 `volcano-xpu-plugin` 硬切核算修复(见上),属 vNPU 主线,非拓扑亲和/混部的独立进展。
- 在离线混部(sig-Colocation)、NUMA 亲和(sig-numa-affinity)、超大规模集群本窗口无可见代码活动。

## 官方动态
- **08-04:成立 Agentic Ops SIG**(见"新功能/能力"),面向 AI 云原生智能运维,当前仅方向宣示无落地 repo。
- **版本**:v26.06(2026-07-09)仍是最新 openFuyao 版本,本窗口无新 release、无路线图公告。ascend/mind-cluster 侧有 26.1.0 版本发布文档更新(昇腾 MindCluster 自有版本号,非 openFuyao 版本)。
- CSDN 07-23 的三篇生态/市场文(LEAP East、超节点白皮书、统信 V3.0)已在上期覆盖,本窗口官方博客仅新增 Agentic Ops SIG 一篇。

## 跟我们产品的对比
- **同构、可直接借鉴(换成 GPU/CUDA 即用)**:(1) 劫持库**只读挂载** `ro,rbind` 防篡改逃逸;(2) 硬切 profile 表做成**可热更新的 configmap 数据**,新增卡型不改代码;(3) operator/controller 区分**永久配置错误(写 status + 停重试)vs 瞬时错误(退避重试)**;(4) 开服前预检项分 **hard/soft**,并能快速下线误报项;(5) 切分资源**多维配额独立记账**(算力/显存/控制核别混用)。
- **昇腾专用(仅了解)**:910C 具体硬切规格数字、vCANN-RT/CANN ACL 劫持、mind-cluster 三方依赖消减与流水线代码化。
- **值得决策/跟踪的新变量**:**Agentic Ops SIG**——OAI/ODH 侧无对等的独立"agentic ops"方向。若它跑出真实 repo,是 OpenFuyao 相对上游生态的一个差异化下注;我们要判断这是营销站位还是真投入,关键看它做"LLM 辅助排障"还是"agent 直接操作集群"。

## 值得跟进
- [ ] 盯 [openFuyao GitCode 组织](https://gitcode.com/openFuyao) 是否新增 Agentic Ops SIG 相关 repo(如 `agent-ops` / `aiops` 类),一旦有代码落地立即评估其操作集群的权限模型与准入边界——这是我们判断"agentic ops 是否可借鉴"的关键。
- [ ] 借鉴 [InferNex !203](https://gitcode.com/openFuyao/InferNex) 的 `ErrTemplateNotFound` 模式,盘一遍我们 operator 的 reconcile 循环:哪些"引用不存在的模板/密钥/配额"的持久错误目前在无限重试空转,改为写 status + 停重试。
- [ ] 检查我们 GPU 软切/劫持库注入路径的挂载权限,是否已按 [npu-dra-plugin](https://gitcode.com/openFuyao/npu-dra-plugin) 的做法用 `ro` 只读挂载(防容器内篡改劫持库逃逸隔离)。
- [ ] 若我们落地分布式推理/训练开服前预检,参照 [infernex-checker](https://gitcode.com/openFuyao/InferNex) 的 hard/soft 分级与可下线设计,避免过严检查项(如子网一致性)误杀正常集群。

## 原始材料

<details>
<summary>本次扫描清单(2026-08-03 ~ 2026-08-10)</summary>

官方源:
- https://blog.csdn.net/openFuyao — 新增 1 篇:openFuyao 社区 Agentic Ops SIG 正式成立(08-04);v26.06(07-09)仍最新版
- https://www.openfuyao.cn/zh/ — 首页无新 release/blog 时间戳(SSR 内容有限)

GitCode 浅克隆日志(--depth 100,--since=2026-08-03,已滤 bot merge 空壳):
- `openFuyao/npu-dra-plugin`(本周最活跃):
  - 2026-08-07 !33 fix: vCANN-RT 安装器镜像地址修正为实际仓库路径
  - 2026-08-06 fix: chipCapabilities 补充 Ascend910C 硬切分模板(vir05_1c_16g / vir10_3c_32g)
  - 2026-08-05 !32 refactor: values.yaml 中 nodes 默认改为空
  - 2026-08-05 fix: softShareMounts 挂载权限改为只读(ro, rbind)
  - 2026-08-04 !31 DRA 插件废弃文档清理
- `openFuyao/vNPU`:
  - 2026-08-05 !88 fix: use stripContainerIDPrefix to avoid empty ContainerID panic
  - 2026-08-04 !87 fix: use AiCPU instead of AiCore in applyHardModeDevice(volcano-xpu-plugin 硬切资源核算)
- `openFuyao/InferNex`:
  - 2026-08-07 !210 fix: drop H-06 subnet consistency check and improve H-07 suggestion(checker 收敛误报项)
  - 2026-08-05 !203 fix: handle NotFound error in reconcileWorkloadsAndRBAC to avoid infinite retry(ErrTemplateNotFound 哨兵,持久错误停重试)
  - 2026-08-03 !206(改进慢卡检测解析,已在上期覆盖)
- `ascend/mind-cluster`(工程化为主,滤 docs/merge 后实质项):
  - 2026-08-07 【docker】26.1.0 版本发布镜像概述更新
  - 2026-08-06 【MindCluster】三方依赖消减
  - 2026-08-06 !4283 mindCluster 流水线代码化,新增 .gitcode/workflows(CodeCheck/Build/DT,从 CodeArts 迁移)
  - 2026-08-03 【helm-deploy-tool】添加版本替换、清理步骤
- `openFuyao/npu-operator`:窗口内仅 08-03 !109(vNPU+DRA 全栈,已在上期覆盖),本窗口无新提交
- `openFuyao/hermes-router`、`openFuyao/volcano-ext`(v1.10.0)、`openFuyao/ub-network-device-plugin`(v26.6.0)、`openFuyao/kae-operator`:本窗口**无新提交**

关键代码事实交叉印证:
- 910C 硬切模板:整卡 AiCore20/AiCpu6/32768Mi;profile vir05_1c_16g(5/1/16384)、vir10_3c_32g(10/3/32768)
- vNPU 硬切核算修复:applyHardModeDevice 中 `device.UsedCpu += template.AiCPU`(原误用 AiCore)
- InferNex 持久错误:`ErrTemplateNotFound` → persistReconcileFailureStatus + 停重试
- softShareMounts 由 rw 改 `ro,rbind`(劫持库容器内只读)

</details>
