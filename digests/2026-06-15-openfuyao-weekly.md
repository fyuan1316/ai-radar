# OpenFuyao 周报 2026-06-15

窗口:2026-06-08 → 2026-06-15(7 天)

## 摘要

- **hermes-router 落地"学习型(ML)时延预测路由打分器"——从启发式 KVCache-aware 路由跨到训练出来的 TTFT/TPOT 预测器**:本周合入完整的离线训练流水线(XGBoost/LightGBM 后端、单调约束、排队特征内化、Qwen3-32B 制品样例)+ 预测 sidecar(Unix socket、批量 slot 推理、worker 线程池)+ Helm `modelVolume` 挂载,并新增 **shadow mode** 在线采数。打分器拿"预测每个目标的首 token / 逐 token 时延"排序,预测不可用时 **fail-open** 回退到快照打分。**这是本周最重要的通用借鉴信号**:它对标的是 llm-d / Gateway API Inference Extension(GIE)的 EPP 打分器,但 GIE/llm-d 目前以启发式信号(KV 利用率、队列深度、prefix 命中)为主,hermes 在其上叠了一层**离线训练 + 在线影子采数**的学习型延迟预测器——且整条链路与昇腾无关,可直接搬到 GPU 栈。
- **InferNex-Bridge 继续"向 KServe 生命周期语义收敛":联动 `serving.kserve.io/stop` + 新增 `infernex.io/disabled-components` 组件级 opt-out**:Bridge 现在读源 `LLMInferenceService` 上的 KServe stop 注解,KServe 停服时同步释放自己挂的增强组件(eagle-eye / mooncake / cache-indexer 等);并支持按服务用注解关掉单个增强组件;singleton 的 Service / ServiceAccount 改用 **non-controller OwnerRef** 在多实例间共享。延续上周 OFEP-0040 "退到旁路增强编排器、不分叉 KServe 用户 API"的路线——本周把"生命周期/资源归属"也对齐到 KServe。(注:这批 Bridge 提交由 `yuanfang@alauda.io` 共同署名,是我们团队在上游直接推进的工作)
- **战略面:OpenFuyao 同周新设两个 Agent 方向 SIG——AgenticOps SIG(OFEP-0005,智能体自主运维)+ Agent Sandbox SIG(MicroVM 级隔离跑 Agent 代码)**:AgenticOps 聚焦"智能体闭环定位 AI 训推故障"(把硬件原厂/引擎社区/企业的运维经验沉淀成可复用知识),Agent Sandbox 提供"基于 K8s 的 MicroVM 隔离环境跑不可控 LLM 生成代码"(新建 `opensandbox` / `flux-sandbox` 私有仓)。后者对标 E2B / Daytona / Kata / gVisor 这类 agent 代码沙箱,**通用且方向正热**。v26.06 仍在测试期,**rc.3(计划 6-17~19)本周未切**,GA 仍标 6-29~30。

## 新功能 / 能力

- [hermes-router:学习型时延预测路由打分器(训练流水线 + 预测 sidecar + shadow mode)](https://gitcode.com/openFuyao/hermes-router/-/commit/1184bde) — 06-15 `feat(prediction): training pipeline rework, sidecar perf, and Helm modelVolume deployment`,重做离线训练(统一 queue slot、按目标特征、单调约束、排序诊断、Qwen3-32B 样例 bundle)、优化 Predict 热路径(批量 slot 推理、向量化特征、worker 线程池)、Helm 加 `modelVolume` 挂载;06-11 [暴露 scorer 权重 + shadow mode 采数](https://gitcode.com/openFuyao/hermes-router/-/commit/63b3498)。制品按 `artifactRoot/<targetModel>/<modelVersion>/` 组织,含 `aggregate_ttft` / `aggregate_tpot` 两个 slot(disaggregated PD 的 slot 尚未含),sidecar 走 `unix:///var/run/hermes/prediction.sock`,预测失败 fail-open 回退快照打分。
  - 启示:**这是本周对我们最直接的通用借鉴点**。我们做推理网关/路由层时,业界(llm-d EPP、GIE)主流仍是启发式打分(KV 利用率、队列深度、prefix 命中);hermes 这套"**离线训练 XGBoost 预测 TTFT/TPOT → 当 scorer → fail-open 回退启发式**"是更进一步的学习型路由。三个工程决策值得抄:① **shadow mode**——新策略先并行采数不影响线上决策,攒够数据再训模型再切流,是上线学习型组件的安全姿势;② **制品 bundle 化 + 按 targetModel/version 寻址 + 运行时校验**,模型与服务解耦、可灰度;③ **预测层 fail-open**——预测不可用绝不阻断路由,降级到启发式。整条与昇腾无关,可直接落到 GPU 栈
- [InferNex-Bridge:联动 KServe `serving.kserve.io/stop` + 组件级 opt-out 注解](https://gitcode.com/openFuyao/InferNex/-/commit/fe1f954) — 06-15 `feat(controller): lifecycle linkage with KServe stop annotation + per-service component opt-out`。新增 `kserveStopAnnotationKey = serving.kserve.io/stop`:sourceRef 托管的 `InferNexService` 读源 LLMISVC 的 stop 注解,KServe 停服时同步清空/释放自己挂的增强组件(镜像 KServe 的 delete-on-stop);新增 `infernex.io/disabled-components`(如 `eagle-eye,mooncake`)按服务关单个增强组件。**裸 `InferNexService`(无 sourceRef)不认这两个注解**,只有 Bridge 联动路径认——耦合边界划得很清。配套 06-15 [singleton Service/SA 用 non-controller OwnerRef 共享](https://gitcode.com/openFuyao/InferNex/-/commit/448860d)。
  - 启示:延续上周 OFEP-0040 判断——**这周把"生命周期 + 资源归属"也对齐到 KServe**。stop 注解联动是"上游控制服务起停、增强层跟随"的正确从属关系;`disabled-components` 注解是一个干净的可组合开关(用户可逐服务裁剪增强能力而不动 CRD schema)。**我们在 KServe llmisvc 上叠差异化能力时,这套"注解驱动的生命周期联动 + 组件级 opt-out + 共享单例资源用非控制 OwnerRef"模式可直接复用**;尤其 non-controller OwnerRef 让多个 InferNexService 共享同一 Service/SA 又不互相抢 GC,是多租/共享场景的实用细节。注:本批为我们团队(alauda)在上游推进
- [OFEP-0005:设立 AgenticOps SIG(智能体自主运维)](https://gitcode.com/openFuyao/ofep/blob/main/ofeps/sig-top/ofep-0005-%E8%AE%BE%E7%AB%8BAgenticOpsSIG.md) — 面向异构算力集群做"智能体闭环定位 AI 训推故障",主攻智能体自主运维 / 观测分析工具增强 / 运维经验沉淀共享三方向,痛点直指"故障横跨硬件+引擎+模型运行时、MTTR 数小时到天级、经验散落难复用、迭代快传统 AIOps 追不上"。同周 community 新建 [Agent Sandbox SIG](https://gitcode.com/openFuyao/community/-/commit/104078a)——"K8s 上 MicroVM 级隔离跑 Agent 不可控代码",新建 `opensandbox` / `flux-sandbox` 仓。
  - 启示:**两个方向都通用、都对标得上**。AgenticOps 对标 OpenShift Lightspeed / 各家 AIOps 但定位更激进("智能体自主运维"而非辅助);其"把硬件原厂/引擎/企业运维经验沉淀成可复用知识库"思路,和 mind-cluster 这周做的 [CANN Fault Mode Library](https://gitcode.com/Ascend/mind-cluster/-/commit/466da19)(故障模式知识图谱)是上下游配套——**故障知识库 + 智能体推理**是异构故障自治的下一步,值得我们对照自家故障自愈路线。Agent Sandbox 对标 E2B / Daytona / Kata / gVisor,**AI Agent 代码执行沙箱是当前热点**,如果我们的平台要承载 agentic 工作负载,"K8s 原生 + MicroVM 隔离"是绕不开的能力项
- [mind-cluster:故障重建的 pod 优先调度回原节点(previous_node 缓存)+ 多级调度支持调度到历史节点](https://gitcode.com/Ascend/mind-cluster/-/commit/d459202) — 06-10 ascend-for-volcano 新增 `common/cache/previous_node.go`(+186 行)缓存 pod 上次落点,重建时优先回原节点;06-13 [补 superpod 部分](https://gitcode.com/Ascend/mind-cluster/-/commit/3071eb0);06-10 [多级调度支持调度到历史节点](https://gitcode.com/Ascend/mind-cluster/-/commit/708368c)(multilevelscheduling/frame.go +576 行);06-11 [默认关闭"优先调度回原节点"](https://gitcode.com/Ascend/mind-cluster/-/commit/bcc0716)(特性门控,默认 off)。
  - 启示:延续上周"进程级重调度"线——故障重建时**让 pod 回到原节点**以复用本地态(KV cache / checkpoint / 权重缓存),减少跨节点重传。这是**通用调度思路**:GPU 大模型训练/推理同样吃"恢复局部性"(原节点上 checkpoint/KV 还在)。值得借鉴的两点:① 把"上次落点"做成调度器可查的缓存而非临时状态;② **默认关闭、门控开启**——回原节点会牺牲负载均衡,作为可选策略而非默认行为,是对的产品决策

## AI 推理栈(InferNex / hermes-router / cache-indexer / weight-dispatcher)

- [InferNex:proxy-server 聚合 /health 与 /metrics](https://gitcode.com/openFuyao/InferNex/-/commit/4450117) — 06-14,增强组件的健康/指标端点收敛到 proxy-server 单点暴露;配套 06-13 [Bridge 修 KServe LWS(LeaderWorkerSet)label 发现、网关路由、示例矩阵](https://gitcode.com/openFuyao/InferNex/-/commit/55f1e2c)、06-12 [更新 vLLM-Ascend 镜像版本与驱动兼容性矩阵](https://gitcode.com/openFuyao/InferNex/-/commit/d1c0f42)。LWS label 发现说明 PD/多机分布式实例走的是 K8s LeaderWorkerSet,与 llm-d 的多机编排选型一致
- [hermes-router:把 `KVCacheUsagePercent` 当 0-1 分数而非百分比](https://gitcode.com/openFuyao/hermes-router/-/commit/5878583) — 06-11,修一个值得记的坑:`vllm:kv_cache_usage_perc` 原始就是 [0,1] 分数,但特征提取和 badness 打分又除了 100,把 10-90% 的真实利用率压成 0.001-0.009,**等于 KV 利用率这个路由信号被废掉**(kvaware/autokvaware/pdkvaware 几条 baseline 全受影响);NPU 利用率字段仍保留 /100(exporter 报 0-100)。改后需重训模型。**我们对接 vLLM 指标做路由时同类单位坑要警惕**(`_perc` 后缀的指标 vLLM 给的是分数不是百分数)
- [cache-indexer:mooncake segment 缺失时不阻塞 L1 刷新](https://gitcode.com/openFuyao/cache-indexer/-/commit/9898635) — 06-09,discovery 容错;06-11 补 [核心模块全量 UT](https://gitcode.com/openFuyao/cache-indexer/-/commit/4cd96c4)。KVCache 索引发现的健壮性硬化,Go 版进入稳定期
- [weight-dispatcher:pipeline TCP 按文件做目录级 fanout](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/4afcf78) — 06-12,权重分发 TCP 通路按文件并行分发;本周仅此一条,RDMA/P2P 数据面延续上周稳定化

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- **mind-cluster 故障诊断(FD)持续加重,本周重点是知识库化**:[CANN Fault Mode Library](https://gitcode.com/Ascend/mind-cluster/-/commit/466da19)(06-15,kg-config.json +400 行,故障模式知识图谱)、[支持解析 + 诊断 MindIE-PyMotor / vLLM 日志](https://gitcode.com/Ascend/mind-cluster/-/commit/1c936ed)(把推理引擎日志纳入故障诊断)、[新增 kg_config](https://gitcode.com/Ascend/mind-cluster/-/commit/954f068)、[A5 故障诊断逻辑](https://gitcode.com/Ascend/mind-cluster/-/commit/04a54c9)、[npu_info 同时支持 ipv4/ipv6 诊断](https://gitcode.com/Ascend/mind-cluster/-/commit/a64c50b)。**FD 从"日志正则匹配"走向"故障模式知识图谱 + 跨层(硬件/引擎)日志关联"**,正是 AgenticOps SIG 的数据底座
- [k8s-rdma-shared-dev-plugin:掉卡故障上报 + 组件存活探针](https://gitcode.com/Ascend/mind-cluster/-/commit/8315e66) — 06-15 掉卡(card drop)故障上报、06-12 [加存活探针](https://gitcode.com/Ascend/mind-cluster/-/commit/7859dc3)、06-11 [信号驱动同步更新故障检测 HCAList](https://gitcode.com/Ascend/mind-cluster/-/commit/e7cedd0)。RDMA DP 的故障检测与自愈延续
- [npu-exporter:采集周期按分组配置 + 动态加载配置](https://gitcode.com/Ascend/mind-cluster/-/commit/0e97b48) — 06-10 分三个 PR 落地,不同指标分组可配不同采集周期、configmap 改动动态生效。**通用监控工程优化**:高频指标(利用率)与低频指标(温度/固件)分组采集,降 exporter 开销
- [device-plugin:A5 离线热复位适配 + 启动/复位后主动查询上报 UBOE 状态](https://gitcode.com/Ascend/mind-cluster/-/commit/da5a8e3) — 06-10 A5 离线热复位、[UBOE 状态主动上报](https://gitcode.com/Ascend/mind-cluster/-/commit/55b11ac)、06-11 [修标卡场景误报 UBOE 故障](https://gitcode.com/Ascend/mind-cluster/-/commit/d579504)。昇腾专属(UBOE = UB on-chip error)
- [删除 DPU 相关代码](https://gitcode.com/Ascend/mind-cluster/-/commit/d1c1556) — 06-09 device-plugin/volcano/clusterd 清理 DPU 代码;[ascend-common 增 1s 利用率接口 + 自动适配](https://gitcode.com/Ascend/mind-cluster/-/commit/3b7bb5d)(为高频利用率监控/hang detection 供数)
- [vNPU:支持 cgroup v2(findCgroupPath 重构兼容 v1/v2)](https://gitcode.com/openFuyao/vNPU/-/commit/b641a45) — 06-08,容器内 NPU 切分适配 cgroup v2(现代发行版默认),[XPUDevice 字段 Index/Id 改名 PhysicID/DieID](https://gitcode.com/openFuyao/vNPU/-/commit/5bbce46)语义更清。cgroup v2 适配是通用容器运行时层面的必要功课
- [npu-operator](https://gitcode.com/openFuyao/npu-operator) 本周仅文档(安装说明);[npu-dra-plugin](https://gitcode.com/openFuyao/npu-dra-plugin)、[volcano-ext](https://gitcode.com/openFuyao/volcano-ext)、[kae-operator](https://gitcode.com/openFuyao/kae-operator)、[ub-network-device-plugin](https://gitcode.com/openFuyao/ub-network-device-plugin) 本周无提交。**DRA 接入昇腾仍冷,沿用既往判断短期不进我们 DRA 路线优先级**

## 调度 & 集群(volcano / cluster-api-provider-bke / 众核 / UB)

- **mind-cluster ascend-for-volcano 适配 volcano v1.12.0 + action 增强前置适配**:[适配 v1.12.0](https://gitcode.com/Ascend/mind-cluster/-/commit/d5b8477) + [新增原始部署 yaml](https://gitcode.com/Ascend/mind-cluster/-/commit/c9f1b9f)、[action 增强需求前置适配](https://gitcode.com/Ascend/mind-cluster/-/commit/da720c8) + [适配-2](https://gitcode.com/Ascend/mind-cluster/-/commit/55bb4a5)、[jobPipelined 增加 pod 就绪数量判断](https://gitcode.com/Ascend/mind-cluster/-/commit/13c861a)、[MinResource 中 NPU 为 0 适配软切分场景](https://gitcode.com/Ascend/mind-cluster/-/commit/191bba0)。延续上周"抢占/回收从 gang 迁到 volcano-npu 插件"的 action 增强线
- [cluster-api-provider-bke:缩容/扩容链路硬化](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/b2cb85c) — 06-13 [缩容节点时移除 kubeconfig](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/b2cb85c)、[分发 ca.crt](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/4412927)、06-12 [修扩容 agent 状态 + bkeagent 升级 URL](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/561eef8)、[manifests 组件加执行条件](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/8d6461a)。上周进主干的升级框架本周进入扩缩容/证书分发的工程打磨
- [elastic-scaler(PD-Orchestrator):RSG webhook 证书动态生成](https://gitcode.com/openFuyao/elastic-scaler/-/commit/a986e24) — 06-14,resource-scaling-group 的 admission webhook 不再依赖外部证书签发、自己动态生成;06-12 [externalserver 加查询前缀](https://gitcode.com/openFuyao/elastic-scaler/-/commit/db82dfa)。PD-Orchestrator 三件套进入稳定化
- [ubs-k8s-enable:修健康探针返回值超长导致 kubelet 报错](https://gitcode.com/openFuyao/ubs-k8s-enable/-/commit/cf992c9) — 06-11;UB 专属内存借用/共享,沿用"昇腾 UB 专属,通用栈不可借鉴"判断
- **community 新增公开仓 [ub-ssu-csi](https://gitcode.com/openFuyao/community/-/commit/7460b6a)(06-12 转公开,UB Shared Storage Unit CSI 驱动)**、新增 [serverlessdb-operator 仓](https://gitcode.com/openFuyao/community/-/commit/0247740)(06-15)。ub-ssu-csi 是 UB 共享存储单元的 CSI 接入(昇腾/UB 专属);serverlessdb-operator 方向待观察

## 官方动态

- **v26.06 仍在全量测试期,rc.3 本周未切**:release-management 本周**无新提交**(最后一次 06-06 加 bkeagent download)。按 release-plan,rc.3 计划 6-17~19,**已逾期未到的是 rc.3 而非已发的 rc.2**;GA 仍标 6-29~30。下周看 rc.3 是否如期、测试期暴露了哪些回归
- **官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/) news/release/blogs 三板块仍"暂无内容"**,发布节奏依旧靠 CSDN + GitCode 驱动(沿用既往判断)
- **CSDN [blog.csdn.net/openFuyao](https://blog.csdn.net/openFuyao) 本周 2 篇,均为组件介绍/营销稿,无新 release note**:06-12 InferNex 套件介绍、06-12 灵衢(UB)超节点使能——剥离营销话术后无新增可验证技术指标,实质内容以本周 GitCode 提交为准
- **本周新设 2 个 SIG**:AgenticOps SIG(OFEP-0005)、Agent Sandbox SIG;**新增公开仓** ub-ssu-csi(6-12),新建仓 opensandbox / flux-sandbox(Agent 沙箱,私有)、serverlessdb-operator。组织 SIG 数从 16 个继续扩张,方向明显往 **Agent 基础设施**(运维 + 沙箱)延伸

## 跟我们产品的对比

| 维度 | OpenFuyao 本周变化 | OAI / KServe / llm-d / 通用栈 | 我们应该怎么做 |
|------|-------------------|------------------------------|----------------|
| 推理路由 | **(本周新增)**hermes-router 学习型时延预测打分器(XGBoost TTFT/TPOT + shadow mode + fail-open) | llm-d / GIE EPP 以启发式打分为主(KV 利用率、队列、prefix) | **可直接借鉴**:学习型路由 + shadow mode 安全上线 + 制品 bundle 化 + 预测层 fail-open;与昇腾无关,搬到 GPU 栈 |
| 推理生命周期 | **(本周新增)**InferNex-Bridge 联动 `serving.kserve.io/stop` + `infernex.io/disabled-components` 组件 opt-out + 共享单例资源(non-controller OwnerRef) | KServe llmisvc 有 stop 注解;增强层从属关系业界少见 | **照搬**:注解驱动生命周期联动 + 组件级 opt-out;多租共享单例用非控制 OwnerRef。本批为我方(alauda)上游工作 |
| Agent 运维 | **(本周新增)**AgenticOps SIG(智能体闭环定位训推故障)+ CANN 故障模式知识图谱 | OpenShift Lightspeed / 各家 AIOps(多为辅助) | **对照自家故障自愈路线**:故障知识库 + 智能体推理是异构故障自治下一步 |
| Agent 沙箱 | **(本周新增)**Agent Sandbox SIG(K8s 上 MicroVM 隔离跑 Agent 代码,opensandbox/flux-sandbox) | E2B / Daytona / Kata / gVisor | **若承载 agentic 负载需补**:K8s 原生 + MicroVM 隔离是绕不开的能力项 |
| 故障恢复调度 | **(本周新增)**重建 pod 优先回原节点(previous_node 缓存)+ 多级调度到历史节点(默认 off,门控) | gang 调度有重启,缺"回原节点复用本地态"显式策略 | **借鉴**:把"上次落点"做成调度器可查缓存复用 KV/checkpoint;默认 off 门控开启 |
| FD 监控 | **(本周)**FD 知识库化 + 解析推理引擎日志;npu-exporter 指标分组采集周期 | 无对等 | 借鉴:高/低频指标分组采集降 exporter 开销;故障诊断纳入引擎日志 |
| 集群扩缩/升级 | **(本周)**bke 缩容移除 kubeconfig + ca.crt 分发 + 升级框架打磨 | OAI 靠 CVO/MachineSet | 沿用上周判断:升级图谱单一来源 + DAG 阶段化 |
| 容器运行时 | **(本周)**vNPU 适配 cgroup v2 | 通用早已 cgroup v2 | 提示:设备插件类组件别落下 cgroup v2 适配 |
| DRA | npu-dra-plugin 无提交 | K8s 1.34 DRA 已 GA | 沿用既往判断,DRA 短期不进主路径 |

## 值得跟进

- [ ] **精读 hermes-router prediction sidecar 训练与运行时**(`sidecar/prediction/src/training/*`、`runtime/artifact_predictor.py`、`pkg/epp/plugins/scheduling/scorer/prediction/plugin.go`):弄清特征集(排队特征如何内化)、单调约束怎么设、shadow mode 采数到模型晋升(promotion 阈值)的完整闭环;评估能否在我们 GPU 推理网关复刻"学习型 scorer + fail-open"
- [ ] **读 OFEP-0005 AgenticOps SIG 全文 + 对照 mind-cluster CANN Fault Mode Library 的 kg-config.json 结构**:看"故障模式知识图谱"的 schema(故障码→根因→恢复动作映射),评估能否用于我们 GPU 故障自愈的知识库底座
- [ ] **跟踪 Agent Sandbox SIG 的 opensandbox / flux-sandbox 何时转公开**:看其 MicroVM 隔离实现(Kata?Cloud Hypervisor?自研?)与 K8s 集成方式;agentic 负载隔离是我们平台的潜在能力缺口
- [ ] **跑通 hermes prediction 的 Qwen3-32B 制品样例**:`examples/prediction-model/` 挂载 + Helm `prediction.enabled=true`,验证 sidecar 加载 + scorer 用预测结果排序的端到端;确认 `KVCacheUsagePercent` 单位修复后路由信号是否恢复
- [ ] **关注 v26.06 rc.3(6-17~19)**:本周 release-management 静默,rc.3 是否如期切;若延期,关注是否影响 6-29~30 GA 节奏与 InferNex-Bridge / hermes prediction / PD-Orchestrator 进 LTS 后续版本

## 原始材料

<details>
<summary>本次扫描清单(commits in 2026-06-08..2026-06-15)</summary>

**openFuyao 主组织活跃仓**:
- `InferNex`:`fe1f954 feat(controller): lifecycle linkage with KServe stop annotation + per-service component opt-out`(06-15)、`448860d fix(controller): share singleton Services and ServiceAccounts via non-controller OwnerRef`(06-15)、`4450117 feat: aggregate /health and /metrics in proxy-server`(06-14)、`d1c0f42 update vLLM Ascend image version and driver compatibility matrix`(06-12)、`55f1e2c fix(bridge): KServe LWS label discovery, gateway route, and example matrix`(06-13)、`8a378aa feat: add infernex checker readme`(06-12)、`863b8bc/76bfd3f docs(bridge) README`(co-author 含 yuanfang@alauda.io)
- `hermes-router`:`1184bde feat(prediction): training pipeline rework, sidecar perf, and Helm modelVolume deployment`(06-15)、`63b3498 feat(prediction): expose scorer weights and add shadow mode for data collection`(06-11)、`5878583 fix(prediction): treat KVCacheUsagePercent as a 0-1 fraction, not a percent`(06-11)、`ea16b94 fix(helm): align routing picker wiring with scorer semantics`(06-10)
- `cache-indexer`:`9898635 fix(discovery): do not block L1 refresh when mooncake segments are missing`(06-09)、`4cd96c4 feat(ut): add comprehensive unit tests`(06-11)
- `weight-dispatcher`:`4afcf78 fix: pipeline tcp directory fanout by file`(06-12)
- `vNPU`:`b641a45 Support cgroup v2: refactor findCgroupPath`(06-08)、`5bbce46 refactor: rename XPUDevice fields Index/Id to PhysicID/DieID`(06-10)、`bcf44ff fix: explicitly invoke bash interpreter for volcano webhook manager entrypoint`(06-12)、pipeline config ×4
- `elastic-scaler`:`a986e24 fix: generate RSG webhook certs dynamically`(06-14)、`db82dfa add externalserver query prefix`(06-12)
- `cluster-api-provider-bke`:`b2cb85c fix: remove kubeconfig when downscaling nodes`(06-13)、`4412927 add ca.crt distribute`(06-13)、`561eef8 fix scaleup agent status and upgrade bkeagent upgrade url`(06-12)、`8d6461a add manifests component need execute condition`(06-11)、`7b5bd6e fix ri store and use`(06-08)
- `ubs-k8s-enable`:`cf992c9 fix: 修正健康探针返回值超长引起 kubelet 报错`(06-11)、`de1a25f fix: 增加 go 编译选项`、`6760d34 fix: 修改配置说明错误字段`(06-08)
- `npu-operator`:`918a39f fix: add part of installation`(06-14,纯文档)
- `community`:`0247740 feat: add serverlessdb-operator repo`(06-15)、`7460b6a feat: switch ub-ssu-csi repo type to public`(06-12)、`cda9073 feat: add ub-ssu-csi repo`(06-12)、`104078a 创建Agent沙箱SIG`(06-10)
- `ofep`:`dfcb76a 新增 OFEP-0005: 设立AgenticOpsSIG`(06-05,本周 06-15 合入 master)
- `e2e-auto-test`:大量新增 — `005b843 cache-indexer P2/P3 E2E`、`e662015 declarative upgrade e2e`、`ebecba0 upgradepath e2e`、`d8feafe CR/CRD management e2e`、`241a4d5 network_performance_exporter`、`d51b35e F2/F4/F5 e2e`、`f7985dc/06e0a03 infernex-checker`、`2914f05 sandbox restore e2e`(对应 Agent Sandbox)、`f1df2f4 analyzer test cases`
- `release-management`:**本周无新提交**(最后 06-06 `e7bed5e add bkeagent download`);rc.3 计划 6-17~19 未切,GA 6-29~30

**openFuyao 主组织无活动仓**(窗口内无实质 commit):`npu-dra-plugin`、`volcano-ext`、`kae-operator`、`ub-network-device-plugin`

**上游 Ascend/mind-cluster**:本窗口百余 commits(含大量 docs/merge),核心:
- 调度:`d459202 重建pod调度回原节点` + `3071eb0 superpod部分` + `708368c 多级调度支持调度到历史节点`(+576 行)、`bcc0716 默认关闭优先调度回原节点`、`d5b8477 适配volcano-v1.12.0` + `c9f1b9f 原始部署yaml`、`da720c8/55bb4a5 volcano action增强前置适配`、`13c861a jobPipelined增加pod就绪数量判断`、`191bba0 MinResource中NPU为0适配软切分`
- 故障诊断(FD):`466da19/d6d9809 CANN Fault Mode Library`(06-15,kg-config +400 行)、`1c936ed 支持解析诊断 pymotor_vllm 日志`、`954f068 add new kg_config`、`04a54c9 a5 fault diag logic`、`a64c50b npu_info 支持 ipv4/ipv6 诊断`、`14221a0 故障模式库修复`
- 故障检测/自愈:`8315e66 k8s-rdma-shared-dev-plugin 掉卡故障上报`(06-15)、`7859dc3 添加组件存活探针`(06-12)、`e7cedd0 信号驱动同步更新故障检测HCAList`、`da5a8e3 A5离线热复位适配`、`55b11ac device-plugin主动查询上报UBOE状态`、`d579504 修标卡误报UBOE`
- 监控/数据接口:`0e97b48/b12ab5b/f1aa6c0 npu-exporter 采集周期按分组配置+动态加载`(3 PR)、`b26f3e2 nodeBase默认配置一致+修configmap检测失效`、`3b7bb5d ascend-common 增1s利用率接口+自动适配`
- 清理:`d1c1556 删除DPU相关代码`(device-plugin/volcano/clusterd)、`2c141d4 dcmi接口数据结构与驱动头文件保持一致`
- 大量 docs/虚拟化/断点续训资料修改(略)

**官方信息源**:
- 官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/)(news/release/blogs 仍"暂无内容")
- CSDN [blog.csdn.net/openFuyao](https://blog.csdn.net/openFuyao):2 篇(06-12 InferNex 套件介绍、06-12 灵衢 UB 超节点使能),均营销/介绍稿,无新 release note
- 新 SIG:AgenticOps SIG(OFEP-0005)、Agent Sandbox SIG;新公开仓 ub-ssu-csi;新建仓 opensandbox / flux-sandbox / serverlessdb-operator

</details>
