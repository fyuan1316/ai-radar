# OpenFuyao 周报 2026-09-21

> 扫描窗口:2026-09-14 ~ 2026-09-21。主仓 GitCode `openFuyao` 组织 + 昇腾 upstream `ascend/mind-cluster`(本周 124 MR,继续最高频)+ 官方 CSDN/官网/OFEP。**非发版周,但推理栈落地一个方向性大特性**:`hermes-router` + `InferNex` 联合分 3 个 RFC PR 实现 **Decode-first 的 PD 分离(prefill/decode 解耦)智能路由**(对应 oFEP-0025)——在上游 GIE(Gateway API Inference Extension)之上加了一整套"是否分离决策器 + 分离档位处理器 + decode-KV-aware 打分器",是明确对标 llm-d / Dynamo PD 分离路由的一步,且**路由逻辑通用可借鉴**(只有 vLLM-Ascend 引擎绑昇腾)。其余主线:新组件 `ub-ssu-csi`(UB SSU 存储的 K8s CSI 驱动——UB fabric 从"网络"扩到"存储")、clusterops-agent 把 pathmap/relcache 做 **ConfigMap 分片**以撑大规模集群、bke/bkeadm **密码密钥改从 Secret 加载**的安全加固、npu-exporter 指标分组拆分与可靠性、volcano 一批健壮性 bugfix(按 base-device-info 清理幽灵卡 id、CDI 无昇腾设备跳过注入)。官方无新 release、无新博客(仍停在 08-25 Agent Sandbox SIG)。新功能非空,正常出报并推送。

## 摘要(3 条以内)

- **Decode-first PD 分离路由落地:hermes-router + InferNex 联合 3 个 RFC PR 实现"是否分离决策 + 分离档位 + decode-KV-aware 打分"**。`hermes-router` PR1(`Decode-first 核心调度能力`,+1598 行)在 GIE 的 EPP 插件框架里新增:`profilehandler/decider/`(每请求决定是否走 PD 分离——`alwaysdisagg` 恒分离 vs `prefixbased` 按前缀/prompt 动态决定)、`profilehandler/disagg/plugin.go`(分离档位处理器,产出 prefill+decode 候选对)、`scorer/decodekvaware/plugin.go`(按 decode 实例 KV 命中打分)、PDGroup 候选模型;PR2(`D/PD routing adaptation + 配置集成`)加 `examples/profiles/pd-decode-first.yaml` 与 prerequest_pd 请求控制生命周期;`InferNex` PR3 在 proxy-server 侧编排 Decode-first D/PD 路由 + cache-indexer decode KV 发现 + Mooncake 资源改 namespace 单例 + vllm-ascend 镜像 bump 到 v0.23.0。**对标视角**:这条路等于 **llm-d / NVIDIA Dynamo 的 PD 分离 + KV-aware 路由**,建在**上游 GIE(InferencePool/InferenceExtension)**上;"Decode-first"= 先调度 decode 实例(长驻、显存受限的瓶颈段)再放 prefill;**`prefixbased` 决策器**尤其值得记——按请求前缀/长度动态决定要不要分离(短 prompt 不付分离开销),比静态 PD 拆分更细。**路由逻辑通用可抄,仅引擎(vLLM-Ascend)绑昇腾**。 https://gitcode.com/openFuyao/hermes-router
- **新组件 ub-ssu-csi:UB fabric 从"网络"扩到"存储"**。`ub-ssu-csi`(14 提交,本周新活跃)是 UB SSU 存储的 K8s CSI 驱动,适配 UBSE(Unified Bus 存储引擎)SDK:CSI socket 与 kubelet 注册隔离(!22)、node 侧连接/挂载生命周期与失败回滚、controller 侧不确定分配的恢复与请求重放、UBSE 连接与规范化设备生命周期、请求上下文透传保留 UBSE 错误。**对标视角**:这是**纯昇腾/超节点(灵衢 UB)专用**——OpenFuyao 把 UB 统一总线从此前的 `ub-network-device-plugin`(容器网络)延伸到**存储 CSI**,补齐 UB fabric 上的块/文件存储直通。通用 K8s AI 栈无直接对应(我们用标准 CSI + RDMA/NVLink),但"把专用互联做成 CSI 后端"的分层思路可记。 https://gitcode.com/openFuyao/ub-ssu-csi
- **clusterops-agent 做 CM 分片撑大规模 + bke/bkeadm 密码密钥入 Secret 的安全加固**。`ascend/mind-cluster`:上周新立的运维诊断 Agent 本周把 **pathmap 与 relcache 做 ConfigMap 分片**(!4698/!4711 `support CM sharding of pathmap and relcache`)——ConfigMap 有 1MB 上限,分片是为了在大规模集群下承载采集契约/任务映射,信号=诊断 Agent 在往超大规模集群硬化;同期修 agent-core service、Plog collector bug。`cluster-api-provider-bke`(18)+`bkeadm`(8)的 v26.09 收尾里,**密码加密密钥改为经 API/client-go 从 Secret 加载**(不再落配置)是本周安全主线;另有静态 pod 热更新的 hash 等待跳过 + 重试失效恢复(config-update)、mbkenode webhook 免独立 phase 注册。**对标视角**:CM 分片是通用 K8s 规模化工程细节(可借鉴);密钥入 Secret 是企业级安全刚需(对标 OpenShift);静态 pod 热更新承接上周,继续向 OpenShift OTA/Day-2 平滑看齐。 https://gitcode.com/ascend/mind-cluster

## 新功能 / 能力

- [hermes-router:Decode-first PD 分离路由核心调度能力(oFEP-0025)](https://gitcode.com/openFuyao/hermes-router) — PR1 `Decode-first 核心调度能力（RFC PR1）`(+1598/-135)在 GIE EPP 插件体系新增四块:①`profilehandler/decider/`——`decider.go` 抽象 + `alwaysdisagg`(恒走 PD 分离)与 `prefixbased`(按前缀/prompt 决定是否分离,165 行)两种决策器;②`profilehandler/disagg/plugin.go`(272 行)——分离档位处理器,产出 prefill/decode 候选;③`scorer/decodekvaware/plugin.go`(194 行)——decode 实例 KV 感知打分器;④`pdgroup/pdcandidate` + `score/weights` 把 PD 权重内嵌进插件 Config(!93 refactor,收敛 PDGroup 签名)。PR2 `D/PD routing adaptation + 配置集成`(+488)加 `pd-decode-first.yaml` 示例 profile、prerequest_pd 请求控制、charts `_routing.tpl`/values 的 PD 路由配置项。
  - 启示:**本周最有产品价值的信号,通用可对标 llm-d/Dynamo**。三个可直接借鉴点:①**决策器/档位处理器/打分器的三段插件分层**——把"要不要分离(decider)→ 怎么配 prefill+decode 对(disagg profile)→ decode 选谁(decodekvaware scorer)"拆成可插拔 EPP 插件,建在**上游 GIE(InferencePool/InferenceExtension)**上,和我们如果基于 GIE 做路由是同一根;②**`prefixbased` 动态分离决策**——不是静态"所有请求都 PD 分离",而是按请求前缀/长度决定,短 prompt 免付分离的跨实例开销,这是比 llm-d 早期静态分离更细的一手;③**"Decode-first"调度序**——先定 decode(长驻、HBM 受限的瓶颈)再放 prefill,与 cache-indexer 上周"decode pod 纳入 L1 索引"配套,构成 PD 分离感知的完整路由。**路由决策/打分逻辑全通用可抄,仅底层引擎 vLLM-Ascend 绑昇腾**。
- [InferNex:proxy-server 编排 Decode-first D/PD 路由 + Mooncake 资源单例化](https://gitcode.com/openFuyao/InferNex) — PR3 `support Decode-first D/PD route orchestration（RFC PR3）` 在 InferNex proxy-server 侧对接 hermes-router 的 PD 分离路由;`support decode KV cache discovery`(09-09,cache-indexer 侧 decode KV 发现的 InferNex 集成);`fix: make Mooncake resources namespace singletons`(Mooncake KVCache 资源改为 namespace 内单例,避免多实例冲突);`bump example vllm-ascend image to v0.23.0`(!240);`build: optimize build performance with cache-mount`。
  - 启示:InferNex 是"一键部署 + proxy 编排"总集,本周把 **Decode-first 路由从 hermes-router 打通到 InferNex 部署面**——即这套 PD 分离路由不是孤立组件,而是被拉进 InferNex 的一键推理栈。"Mooncake 资源 namespace 单例"值得记:多租户/多实例下共享 KVCache 池(Mooncake Store)的资源需要单例约束防冲突,我们做池化 KVCache 时会遇到同类问题。vLLM-Ascend 升到 v0.23.0 说明引擎侧持续跟上游 vLLM 对齐。
- [ub-ssu-csi:UB SSU 存储的 K8s CSI 驱动(新组件)](https://gitcode.com/openFuyao/ub-ssu-csi) — 本周新活跃(14 提交),适配 UBSE(Unified Bus 存储引擎)SDK。关键提交:`isolate CSI sockets and kubelet registration`(!22,CSI socket 与 kubelet 注册隔离)、`recover uncertain allocation and replay requests`(controller 恢复不确定分配 + 重放)、`adapt UBSE connections and canonical device lifecycle`(node 侧 UBSE 连接与规范设备生命周期)、`roll back failed stage connections and mounts`(挂载/连接失败回滚)、`propagate request context and preserve UBSE errors`(请求上下文透传)、UBSE 依赖更新到 br_UnifiedBus revision。
  - 启示:**纯昇腾/超节点(灵衢 UB)专用,信号价值大于借鉴价值**。OpenFuyao 把 UB 统一总线从**网络**(`ub-network-device-plugin` 超低时延容器网络)延伸到**存储**(CSI over UB SSU)——UB fabric 正在被做成"一张网跑网络+存储"的完整数据面。这与我们(标准 CSI + RDMA/NVLink,网络存储分栈)是分叉路线,不能直接抄;可记的是"把专用互联做成标准 CSI 后端 + controller 侧分配恢复/重放"的容错设计模式。

## AI 推理栈(InferNex / hermes-router / cache-indexer)

本周推理栈**是全组织最热的方向,核心就是 Decode-first PD 分离路由这一条线**(见"新功能"),分层格局进一步清晰:

- **hermes-router**(5 提交):Decode-first PD 分离路由三件套(decider/disagg/decodekvaware)+ PD 权重内嵌 Config——**本周推理栈最有架构含义的动作**。建在上游 GIE 上,对标 llm-d/Dynamo。
- **InferNex**(9 提交):proxy-server 编排 Decode-first D/PD 路由 + Mooncake 资源单例 + vllm-ascend v0.23.0 + 构建缓存优化——把路由打通到一键部署面。
- **cache-indexer**:窗口内**无新提交**(最近 09-09 `include decode pods kv cache`,上周已报道)。索引层本周消化期,路由层(hermes-router)接棒推进。

分层格局:cache-indexer(L1 vLLM ZMQ / L3 Mooncake)= 全局 KV 索引层,hermes-router(GIE + PD 分离 decider/scorer)= 路由/调度层,InferNex = 部署编排层。**本周三层里"路由层"是主战场**——从上周的"索引感知 decode"推进到"路由层真正做 PD 分离决策与 decode-first 调度"。整体路线与 llm-d 高度同向,且路由逻辑通用。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- **clusterops-agent 为大规模集群做 CM 分片**(见"新功能"):pathmap/relcache 拆 ConfigMap 分片(!4698/!4711),撑破 1MB CM 上限;修 agent-core service、Plog collector bug、修文档。承接上周新立的运维诊断 Agent,本周主题=**规模化硬化**。
- **UB 链路诊断继续**:`ub链路故障支持hccn_tool icrc指标解析`(!4716)——UB 链路故障用 hccn_tool 的 ICRC 指标做判定(与 ascend-watch 侧 ICRC 采集器呼应);FD 侧 `Remove ply`、python 版本兼容、`按光模块类型配置阈值 part1/2/3`(不同光模块型号用不同故障阈值)、L/C 判定逻辑、ssh 认证超时、hccl 建链信息提取兼容。**纯昇腾/超节点专用**,本周偏 bug 收敛 + 光模块阈值精细化。
- **npu-exporter 指标工程化**:`network 分组拆分为 network-bandwidth + network-link`(!4685,网络指标按带宽/链路拆组)、`dcmi 接口超时场景可靠性`(!4722)、`node_base_info 增加 dcmiVersion 标签`、`软切分场景 npu_container_info/显存/利用率指标不上报修复`(!4662)、Atlas 950 SuperPoD Flex 光模块指标、自定义指标限制特殊字符。**指标模型持续拆细 + dcmi 调用可靠性**,通用可观测性工程可参考。
- **volcano 一批健壮性 bugfix**:`按 base-device-info 清理 npu.topology 中不存在的卡 id`(prune-chip-topo,清幽灵卡 id)、`CDI 模式无 Ascend 设备时跳过 CDI 注入`(!4654,避免系统 Pod 被误注入昇腾驱动 bind-mount——重要修复)、`整卡调度 pod 被调度到软切节点问题修复`(!4643)、`支持非 NPU 资源类型的 node annotation 更新`(!4653)、`pg annotation 修改后未生效修复`。**调度器健壮性收敛**,"整卡 vs 软切节点隔离""CDI 注入边界"两个 bug 对多形态设备混部有普适意义。
- **ascend-docker-runtime**:`删除默认挂载 hccl_rootinfo.json 逻辑`(!4691)、容器快照使用优化、补 CRI-O 支持说明。
- **coordinator/container-manager**:去除重复 JobId/CtrId + 修正故障容器跳过条件(!4659)、协调模块完善(!4605)。
- **DRA / npu-dra-plugin**:本周**无新提交**(最近 09-10 grpc CVE 升级)。上周的静态 vNPU DRA 发布后进入消化期。
- **npu-operator**:仅 !117 `adapt volcano scheduler plugin arch`(09-14,窗口边界),无新增。

## 调度 & 集群(volcano-ext / 超大规模 / 超节点)

- **cluster-api-provider-bke(18)+ bkeadm(8):v26.09 集群侧收尾 + 安全加固**(见"新功能"):**密码加密密钥改从 Secret 经 API/client-go 加载**(bke `feat(security)` + bkeadm `feat(security)`)、静态 pod 热更新的 `config-update skip pod hash wait + retry hash invalidation 恢复`、`mbkenode webhook 免独立 phase 注册`、`RepoUpdate 加速 + Reset 关停范围卸载 bkeagent`;bkeadm 另有 `charts tarball 改从 openhitls OBS 下载`、full node wipe 时清 bkeagent。**通用可对标 OpenShift**:密钥入 Secret + 静态 pod 热更新 + 升级路径打磨是企业级集群生命周期刚需。
- **ubs-k8s-enable(10)+ ubs-openstack-enable(7):超节点 UB 使能 + 编译期安全加固**:ubs-k8s 用 `Servers 结构体收敛 gRPC 服务注册`、补 Go/C++ **编译期安全加固与告警选项**、修 C++ strerror 线程安全/共享内存引用转移/IPC 消息边界校验、Go UT 覆盖率至 85%;ubs-openstack `拒绝非法 H2N 配置类型`、`补 H2N 可观测性日志 + 超时回滚`、`延长 UB 设备分配请求超时`、type131 适配。**纯超节点专用**,承接上周 H2N 链路健康,本周偏安全加固 + 可观测性。
- **volcano 健壮性 bugfix**(见昇腾资源管理):幽灵卡 id 清理、CDI 注入边界、整卡/软切隔离、PC16 超节点单机场景(!4665)。
- **volcano-ext(独立仓)**:窗口内**无提交**(最近 09-07 docs typo)。独立仓与 mind-cluster 内 volcano 分工仍待厘清。
- **在离线混部**:`colocation` 相关仓窗口内**无实质提交**,**本周仍无进展**。

## 官方动态

- **无新版本 release**:v26.06(07-09)仍是最新公开季度版;官网 openfuyao.cn news/活动/博客栏目均"暂无内容"。v26.09 发版信号继续来自代码侧(bke 静态 pod 热更新 + 密钥入 Secret + e2e FIT 对齐),**官方尚无公告**。
- **无新官方博客**:CSDN `openFuyao` 最近一篇仍是 08-25 Agent Sandbox SIG、08-19 InferNex TTFT 优化(均已报道)。—— https://blog.csdn.net/openFuyao
- **OFEP 侧**:Decode-first PD 分离路由对应 `oFEP-0025 AI推理智能路由增强`(status: provisional,see-also oFEP-0011 hermes-router,作者 qinwenzh/lileqi)——OFEP 仓本周无新提交,**设计已定、正在代码侧实现**。—— https://gitcode.com/openFuyao/ofep
- **仓库观察**:`ub-ssu-csi`(UB 存储 CSI)本周新活跃;`flux-sandbox`(Agent Sandbox,18 提交)持续 e2e/调度器硬化。未见其它全新立仓。

## 跟我们产品的对比

| 能力维度 | OpenFuyao 现状(本周) | 与上游/我们的关系 |
|---|---|---|
| **PD 分离推理路由** | hermes-router Decode-first:decider(alwaysdisagg/prefixbased)+ disagg 档位 + decodekvaware 打分,建在上游 GIE 上;InferNex proxy 编排 | **≈ llm-d / Dynamo PD 分离 + KV-aware 路由**;路由逻辑通用可抄,`prefixbased` 动态分离决策比静态更细,仅引擎绑昇腾 |
| **UB 存储 CSI** | ub-ssu-csi 新组件:UBSE SDK,CSI socket 隔离 + 分配恢复/重放 + 设备生命周期 | 纯昇腾/超节点专用;UB fabric 从网络扩到存储;我们走标准 CSI+RDMA,分叉路线,仅容错模式可记 |
| **AI 集群运维 Agent** | clusterops-agent pathmap/relcache CM 分片撑大规模;修 agent-core/Plog collector | 编排框架通用可抄(上周已判);CM 分片是规模化工程细节可借鉴 |
| **集群生命周期 + 安全** | bke/bkeadm 密码密钥入 Secret + 静态 pod 热更新 hash 恢复 + mbkenode webhook | **≈ OpenShift OTA/Day-2 + 密钥管理**;密钥入 Secret、静态 pod 热更新值得对齐 |
| 超节点 UB 使能 | ubs-k8s/openstack H2N 可观测 + 编译期安全加固 + type131 | 昇腾专用;安全加固工程纪律可参考 |
| 统一调度健壮性 | volcano 幽灵卡 id 清理、CDI 注入边界、整卡/软切隔离 bugfix | 多形态设备混部的边界处理通用可借鉴 |
| 可观测性 | npu-exporter network 指标拆 bandwidth/link、dcmi 超时可靠性、软切指标修复 | 指标模型拆细 + 采集可靠性,通用可参考 |
| Agent Sandbox | flux-sandbox e2e/调度器高水位防重建 + charts 兼容 | ≈ MicroVM 隔离 AI Agent 沙箱;产品化收尾 |
| DRA / cache-indexer | 本周均无新提交(消化期) | — |
| 在离线混部 | 本周无实质进展 | — |

**我们该补 / 该警惕**:
- **Decode-first PD 分离路由是本周最该对标的一条**:hermes-router 把"是否分离(decider)→ 分离档位(disagg)→ decode 选谁(decodekvaware)"做成建在**上游 GIE** 上的三段可插拔 EPP 插件——与我们若基于 GIE 做路由同根。**`prefixbased` 动态分离决策**(短 prompt 免分离开销)是可直接借鉴的一手,别只做静态 PD 拆分。
- **KVCache 池化的资源单例约束要记**:InferNex 把 Mooncake 资源改 namespace 单例——多实例共享 KV 池会有资源冲突,我们做池化 KVCache 时同类约束需前置设计。
- **多形态设备的调度/注入边界**:volcano 本周两个 bug(整卡 pod 误落软切节点、CDI 无昇腾设备仍注入驱动)在提醒——整卡/切分/无卡三态混部时,调度隔离与设备注入边界要严格,我们做 GPU 整卡+MIG+无卡混部会遇到同类坑。
- **密钥入 Secret + 静态 pod 热更新**:企业级集群安全与 Day-2 平滑刚需,若我们控制面仍把密钥落配置/变更需重启,值得对齐 bke 的做法。

## 值得跟进
- [ ] 读 hermes-router `Decode-first RFC PR1/PR2`:`profilehandler/decider`(alwaysdisagg vs prefixbased)、`disagg/plugin.go`、`scorer/decodekvaware/plugin.go`,抽取"GIE 上做 PD 分离决策/档位/打分"的三段插件分层,对齐我们 GIE 路由选型:https://gitcode.com/openFuyao/hermes-router
- [ ] 读 oFEP-0025 `AI推理智能路由增强` 全文,理解 Decode-first + prefixbased 动态分离的设计动机与降级路径:https://gitcode.com/openFuyao/ofep
- [ ] 看 InferNex PR3 proxy-server 如何编排 Decode-first D/PD 路由 + Mooncake 资源 namespace 单例约束,评估池化 KVCache 的多实例冲突设计:https://gitcode.com/openFuyao/InferNex
- [ ] 观察 ub-ssu-csi(新组件)后续:UB fabric 网络+存储双数据面的完整度,判断昇腾"一张 UB 网跑全栈"的成熟度:https://gitcode.com/openFuyao/ub-ssu-csi
- [ ] 盯 v26.09 发版:bke 密钥入 Secret + 静态 pod 热更新 + e2e FIT 对齐,评估集群生命周期对标 OpenShift 的进度:https://gitcode.com/openFuyao/cluster-api-provider-bke

## 原始材料

<details>
<summary>本次扫描清单</summary>

**扫描窗口**:2026-09-14 ~ 2026-09-21

**有实质更新的仓**:
- `ascend/mind-cluster`(最高频,124 MR):**clusterops-agent pathmap/relcache CM 分片(!4698/!4711)** + 修 agent-core service/Plog collector/doc、**UB 链路 hccn_tool icrc 指标解析(!4716)**、FD Remove ply/python 版本兼容/按光模块类型配阈值 part1-3/L-C 判定/ssh 认证超时/hccl 建链兼容、faultdomain 故障级别排除 PreSeparateNPU、**npu-exporter network 拆 bandwidth+link(!4685)/dcmi 超时可靠性(!4722)/dcmiVersion 标签/软切指标不上报修复(!4662)/Atlas 950 Flex 光模块/自定义指标限特殊字符**、**volcano 按 base-device-info 清幽灵卡 id(prune-chip-topo)/CDI 无昇腾设备跳过注入(!4654)/整卡调度落软切节点修复(!4643)/非 NPU 资源 node annotation 更新(!4653)/pg annotation 未生效修复/PC16 超节点单机(!4665)**、ascend-docker-runtime 删默认挂载 hccl_rootinfo.json(!4691)/容器快照优化/CRI-O 支持、coordinator 去重 JobId+CtrId(!4659)、container-manager 协调完善(!4605)、安全编译选项插件版本、多机调度/verl/MindIO TFT/亲和性调度 docs
- `openFuyao/e2e-auto-test`(51 commit,高频):推理栈 Decode-first/PD 路由 e2e + bke 静态 pod 热更新/密钥 Secret 测试 + flux-sandbox e2e 对齐(v26.09 FIT 门禁持续对齐新特性)
- `openFuyao/cluster-api-provider-bke`(18):**feat(security) 密码密钥从 Secret 经 API 加载**、config-update skip pod hash wait + retry hash 失效恢复、mbkenode webhook 免独立 phase 注册、RepoUpdate 加速 + Reset 卸载 bkeagent、静态 pod 热更新代码评审修复、添加 chartRepo、codecheck/UT
- `openFuyao/flux-sandbox`(18):agentEnv 容量保留名语义、e2e 022/023 删实际承载沙箱 agent pod、--log-level 支持、SSG agent pod 高水位防同名重建 + 心跳未过期才计数、charts kubeVersion 兼容 openFuyao + home 链接修正、控制面三处失败用例修复 + 一键全量、ClusterRole 加 nodes get/list、快照预热 e2e、watcher 清理链路 + endpoints 可观测(!42)
- `openFuyao/ub-ssu-csi`(14,新活跃):**UB SSU 存储 CSI 驱动**——CSI socket 与 kubelet 注册隔离(!22)、controller 恢复不确定分配 + 重放、node UBSE 连接与规范设备生命周期、挂载/连接失败回滚、请求上下文透传保留 UBSE 错误、UBSE 依赖更新 br_UnifiedBus、Docker Hub openEuler 基础镜像、部署与 UBSE API 文档
- `openFuyao/ubs-k8s-enable`(10):Servers 结构体收敛 gRPC 注册、gomonkey 刷缓存测试 arm64 崩溃修复、镜像用户配置静态化、C++ strerror 线程安全/共享内存引用转移/IPC 消息边界校验、Go/C++ 编译期安全加固与告警选项、Go UT 覆盖率至 85%(!90)
- `openFuyao/InferNex`(9):**Decode-first D/PD route orchestration(RFC PR3)**、decode KV cache discovery、Mooncake 资源 namespace 单例、vllm-ascend 镜像 v0.23.0(!240)、cache-mount 构建优化、codecheck
- `openFuyao/bkeadm`(8):**feat(security) 密码密钥从 Secret 经 client-go 加载**、full node wipe 清 bkeagent、charts tarball 改从 openhitls OBS 下载、codecheck
- `openFuyao/ubs-openstack-enable`(7):延长 UB 设备分配请求超时 + H2N 超时回滚日志、H2N 可观测性日志、拒绝非法 H2N 配置类型、type131 适配代码(!69)
- `openFuyao/hermes-router`(5):**Decode-first 核心调度能力(RFC PR1,decider/disagg/decodekvaware)**、**D/PD routing adaptation + 配置集成(RFC PR2)**、PD 权重内嵌插件 Config 收敛 PDGroup 签名(!93)
- `openFuyao/kae-operator`(1):UT 覆盖率提升(!71)
- `openFuyao/npu-feature-discovery`(1):codecheck(!21)

**窗口内无实质提交(跳过)**:`openFuyao/cache-indexer`(最近 09-09)、`openFuyao/npu-dra-plugin`(09-10 grpc CVE)、`openFuyao/compliance-operator`(09-12)、`openFuyao/volcano-ext`(09-07)、`openFuyao/ub-network-device-plugin`(09-10)、`openFuyao/npu-operator`(仅 !117 于 09-14)、`colocation` 在离线混部(无进展)、`ofep`(ai-inference 无新提交)

**官方源**:
- 无新版本 release(v26.06 07-09 仍为最新);官网 openfuyao.cn news/活动/博客栏目"暂无内容"
- CSDN openFuyao 最近一篇仍是 08-25 Agent Sandbox SIG、08-19 InferNex TTFT(均已报道)—— https://blog.csdn.net/openFuyao
- Decode-first PD 路由对应 oFEP-0025(provisional,see-also oFEP-0011),OFEP 仓本周无新提交,设计已定、代码侧实现中
- v26.09 发版信号来自代码侧(bke 密钥入 Secret + 静态 pod 热更新 + e2e FIT 对齐),非官方公告

**抓取方式**:GitCode 走 `git clone --filter=blob:none --shallow-since=2026-09-12`(部分无窗口内提交的仓 shallow-since 报空、改 `--depth 60` 重试确认冷仓)+ 本地 `git log --since=2026-09-14 --until=2026-09-22 --no-merges`;组织仓清单 + CSDN + 官网走 WebFetch(组织首页 SSR 只返最近活跃 ~11 仓,repo 详情靠 clone);GitCode raw/blob 页仍为 JS 壳,文件读取走 clone 后本地 `git show`/`ls`;hermes-router RFC 内容靠 `git log --stat` + 目录结构判读;OFEP 走 clone 后本地读。

</details>
