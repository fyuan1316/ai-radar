# OpenFuyao 周报 2026-10-12

窗口:2026-10-06 -> 2026-10-12(7 天)

## 摘要(3 条以内)
- **官方发版:v26.09 社区发行版上线(10-08 CSDN 公告),主打"新增 Agent 沙箱调度能力"**。这是上期(非发版周)之后的首个官方版本动作;官网 openfuyao.cn 仍显示"暂无内容",公告只走 CSDN。代码侧对应 flux-sandbox 本周补齐 E2B 扩展参数 + hostport 网络(10-08),与"Agent 沙箱调度"主线对齐。
- **npu-operator 长出一个 KServe 级的推理 serving 控制面:MR !121(10-10)新增 infer-operator,带 InferService / InferServiceSet / InstanceSet 三个 CRD(`mindcluster.huawei.com`)**,是"InferServiceSet → roles[](每个 role 一个 InstanceSet)"的角色化、可 PD 拆分的部署模型——和 KServe 新版 LLMInferenceService / Kubernetes LeaderWorkerSet / llm-d 的 role 模型走同一条路。但它是 MindX DL 口径(namespace `mindx-dl`、带 `fault_handling`),**与 openFuyao 社区自家的 InferNex(vLLM-Ascend + hermes-router)是两套并行的 serving 栈**——华为内部出现双推理控制面,值得盯是否会收敛。
- **本周技术主线是"A5 新机型上线适配"**:npu-operator、mind-cluster clusterd / ascend-operator / ascend-for-volcano 一连串提交都在修 A5 场景下取不到 NPU 设备 id/类型/数量的问题(昇腾专用,非通用能力)。

## 新功能 / 能力

- [npu-operator MR !121](https://gitcode.com/openFuyao/npu-operator) — 2026-10-10 `feat: update the component to adapt A5 machine`。表面是 A5 机型适配,实则一次性把 npu-operator 扩成 MindCluster 全组件编排器:`NPUClusterPolicy` 新增两个被管组件 `inferOperator` / `rdmaDevicePlugin`(均 "Disabled unless explicitly managed"),并落了 `assets/infer-operator/` 整套清单——
  - **三个新 CRD(`mindcluster.huawei.com/v1`)**:`InferService`(单推理服务,带 replicas/readyReplicas 状态)、`InferServiceSet`(`spec.template.roles[]` = 一组 `InstanceSet` 规格,每个 role 有独立 name/priority/replicas/services[] + pod 模板/labelSelector)、`InstanceSet`(role 级工作负载)。配套 `infer-operator-config` ConfigMap 仅 `fault_handling: "true"`。
  - **对比:这就是 KServe 新版多角色 serving(LLMInferenceService)/ Kubernetes LeaderWorkerSet / llm-d 角色模型的同构物**——用"一个 Set 展开成多个带优先级的角色工作负载"来表达 prefill/decode 拆分和多副本编排。差异:① 绑死 MindCluster/昇腾(`fault_handling` 面向 NPU 故障、A5 适配、rdma-shared-dp);② 它跟 InferNex 是**两套不同的推理控制面**,不是 InferNex 的下沉实现。
  - **启示**:角色化 CRD(InstanceSet 作为"带优先级 + services 的可复用单角色工作负载")这层抽象是**硬件无关、可借鉴**的——我们的 serving 编排若要支持 PD 拆分/多角色,应把"Service(聚合入口)→ Set(多角色)→ 单角色工作负载"做成和 LWS 对齐的三层 CRD,而不是给每种拓扑写死一个 Deployment。昇腾专用的是 `fault_handling`/rdma-shared-dp/A5 这些。另外要警惕:**同一厂商出现 InferNex 与 infer-operator 双 serving 栈**是典型的内部路线未收敛,选型时别被"哪个是正统"带偏。
- [flux-sandbox](https://gitcode.com/openFuyao/flux-sandbox) — 2026-10-08 `feat: 支持传入扩展参数给 E2B 运行时 + 支持 E2B 沙箱 hostport 网络`(+1247/-246,改 `sandbox_types.go` / `e2b.go` / scheduler 一大片)。给 microVM 沙箱补了"向 E2B 运行时透传扩展参数"和"hostport 网络暴露"两项部署能力,正是 v26.09"Agent 沙箱调度"官宣背后的工程落地。
  - **对比/启示**:仍是 E2B/Firecracker microVM 赛道(对标 E2B、Kata、K8s agent-sandbox)。可借鉴的是**通用**部分——沙箱声明式参数透传 + hostport 暴露是让 Agent 执行沙箱在 K8s 上可路由/可定制的基础设施能力,与具体 microVM 后端无关;E2B 后端本身可替换。

## AI 推理栈(InferNex / hermes-router / cache-indexer)
- **InferNex、hermes-router 本周均无 in-window 提交**(InferNex master HEAD 仍停在 09-30 `!261` Bridge 文档)。推理栈的能力信号本周落在 npu-operator 侧的 infer-operator(见上),而非 openFuyao 社区自家 InferNex。
- 新纳入观察:[cache-indexer](https://gitcode.com/openFuyao/cache-indexer)(oFEP-0053)——LLM 推理的**全局 KVCache 索引组件**,维护 L1(实例本地 HBM,订阅 vLLM ZMQ KV-events)+ L3(Mooncake 的内存/SSD 缓存)两级索引,给路由面做**请求级、全局的 KVCache 命中率查询**。本周无 in-window 提交(最近实质更新停在 09 月的 decode 节点 KVCache 感知 + 兼容 vLLM 0.24.0 map 编码 KV events),但它是 hermes-router "kv-cache-aware 路由"默认档位背后的索引底座。
  - **对比**:cache-indexer 的定位 = llm-d 的 KV-cache indexer / vLLM 生产栈 KV 路由 / NVIDIA Dynamo KV router 的同类——在 Go 侧复刻 vLLM 的 block hash 计算(对齐 `token_ids`/`block_size`/`cache_salt`/`PYTHONHASHSEED`),用 K8s label 动态发现 prefill/decode/aggregate 与 Mooncake Master。这条思路**硬件无关、是我们最该对齐的通用件**:请求级 KVCache 命中率要成为路由决策的一等输入,且 L1(HBM)/L3(Mooncake)分级索引 + 复刻引擎 hash 以保证命中率一致,是比简单"亲和 label"更准的做法。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)
- **A5 新机型适配主线(昇腾专用)**,本周集中落地:
  - [mind-cluster](https://gitcode.com/ascend/mind-cluster) clusterd(10-09)修 A5 场景取 pod 使用设备 id 列表为空:`GetPodUsedDev` 在 `Pod910DeviceAnno` 缺失时回退读 `PodNPUDeviceAnno` 注解。
  - mind-cluster ascend-operator(10-12)修 operator 获取 NPU 类型和数量问题(改 `env.go`/`ranktable`/新增 strings 工具,带较全单测)。
  - mind-cluster ascend-for-volcano(10-12)修 volcano 获取 NPU 任务类型和数量问题(`plugin/job.go`/`type.go`)。
  - npu-operator infer-operator/rdma-shared-dp 清单也是跟 A5 适配同一 MR 落地。
  - 判读:A5 是昇腾新一代机型,这批全是**昇腾专用**的设备发现/ranktable/调度解析修正,对通用 K8s AI 栈无直接借鉴意义,但说明 OpenFuyao/MindCluster 正在做新硬件代次的上架收敛。
- [npu-container-toolkit MR !17](https://gitcode.com/openFuyao/npu-container-toolkit) — 2026-10-10 更新 `ascend-docker-runtime.dockerfile`(构建/基础镜像调整,无能力级变更)。
- [ubs-k8s-enable MR !95](https://gitcode.com/openFuyao/ubs-k8s-enable) — 2026-10-10 `fix: cgroup v2 场景跳过 devices.allow/deny 写入`,规避 cgroup v2 下文件接口缺失导致的挂载失败。通用性修复(cgroup v2 兼容),但范围限于 UB 存储使能链路。
- mind-cluster(10-10)升级 `golang.org/x/net` 至 v0.60.0 修 x/net 系列 CVE——例行安全依赖升级。
- `npu-dra-plugin`、`vNPU`、`kae-operator`、`npu-driver-installer` 本周无 in-window 实质提交。

## 调度 & 集群(volcano-ext / 超大规模 / DRA)
- [mind-cluster 文档](https://gitcode.com/ascend/mind-cluster)(10-10)新增**逻辑框(rack)亲和性调度方案介绍 + DRA 实践**(`docs/rack_scheduling_and_dra_entries_bold`,文档级)。虽只是文档,但两个方向值得记:① "逻辑框亲和性"= 机架/超节点级拓扑亲和调度,对应超大规模训练的 rack-aware 放置;② DRA 实践文档同步更新,说明昇腾接 K8s DRA 的用法在持续补全——跟我们 DRA 选型强相关,后续要盯 `npu-dra-plugin` 的代码跟进。
- ascend-for-volcano 的 NPU 任务类型/数量修正(见上)属 A5 适配,非调度策略变化。
- [sig-installation](https://gitcode.com/openFuyao/sig-installation)(10-10/10-12,文档)把 bkecluster 示例升到 `v1.34.3-of.1` 并新增离线/自定义仓库场景指南;修 env-check 链接。属部署运维文档打磨。
- `volcano-ext`、`ub-network-device-plugin`、`sig-orchestration-engine` 本周无 in-window 实质提交(上期关注的 many-core-orchestrator 干扰检测+重调度、pod-live-migration 本周无代码推进)。

## 官方动态
- **v26.09 社区发行版发布(2026-10-08,CSDN 官方博客公告)**:["新增 Agent 沙箱调度能力!openFuyao v26.09 社区发行版上线,AI 原生基础设施能力进一步升级"](https://blog.csdn.net/openFuyao)。头条能力是 Agent 沙箱调度(对应 flux-sandbox / sig-agent-sandbox 本周工程落地)。**注意**:官网 openfuyao.cn 的 news/blog/活动三板块仍"暂无内容",版本公告只在 CSDN 出现,官网与社区博客的发布渠道不同步。
- CSDN 官方博客时间线:08-11(6-7 月运作报告、KubeVirt)→ 08-19(InferNex TTFT 优化)→ 08-25(Agent Sandbox SIG 招募)→ **10-08(v26.09 发行)**;9 月整月无公告。
- 本周各仓无新 release/tag,版本号基线未统一跳动(发行以社区发行版打包为准,非单仓 tag 驱动)。
- console-website(10-08/10-09)升级 axios / i18next-http-backend 修 CVE,并修了一批 code review 发现的崩溃级/健壮性缺陷——控制台在做发版前质量收敛。

## 跟我们产品的对比
- **同一路线(该对齐)**:① npu-operator infer-operator 的"InferServiceSet → roles[] → InstanceSet"角色化 serving CRD,和 KServe LLMInferenceService / LWS / llm-d 同构——我们的 serving 编排要把多角色(PD 拆分)做成和 LWS 对齐的三层 CRD 抽象,而非每种拓扑写死 Deployment;② cache-indexer 的"请求级全局 KVCache 命中率(L1 HBM + L3 Mooncake 分级索引、Go 侧复刻引擎 block hash)"是比"亲和 label"更准的路由输入,硬件无关,最该抄;③ flux-sandbox 的沙箱参数透传 + hostport 暴露,是 Agent 执行沙箱可路由/可定制的通用件。
- **分叉/昇腾专用(记录不照抄)**:A5 机型适配、ranktable/设备发现修正、rdma-shared-dp、`fault_handling`、UB 存储 cgroup、逻辑框亲和性(昇腾超节点)——均为昇腾硬件专用。
- **我们该补 / 该警惕**:① serving 的多角色 CRD 抽象(对齐 LWS)+ 请求级 KVCache 命中率路由输入;② **警惕厂商内部双 serving 栈**:openFuyao 社区 InferNex 与 MindX DL infer-operator 并存,选型/集成时要确认哪套是对外主推,避免押错控制面;③ DRA 接入要跟进 npu-dra-plugin 的代码(本周只有 mind-cluster 侧 DRA 文档动),对齐我们的 DRA 选型。

## 值得跟进
- [ ] 精读 npu-operator `assets/infer-operator/` 三个 CRD 的完整 schema(尤其 `InstanceSetSpec` 的 services[]、priority、pod 模板字段),判断它与 KServe LLMInferenceService / LWS 的字段级异同,以及 `fault_handling` 在 role 级的故障处理语义。
- [ ] 搞清 infer-operator 与 InferNex 的边界:是竞争关系、还是 infer-operator 面向 MindX DL 商发、InferNex 面向社区?是否共用 hermes-router / cache-indexer 路由面。
- [ ] 读 cache-indexer(oFEP-0053)的 L1/L3 索引实现与 block hash 复刻细节,评估能否在我们(通用 GPU)栈上用同样思路做请求级 KVCache 命中率路由。
- [ ] 找 v26.09 完整 release note(目前只拿到 CSDN 标题级公告,官网 release 页 404),核对 Agent 沙箱调度之外是否还有推理/调度能力并入。
- [ ] 跟进 mind-cluster "逻辑框亲和性调度 + DRA 实践"文档对应的代码(npu-dra-plugin / ascend-for-volcano),对齐 rack-aware 放置与 DRA 字段。

## 原始材料

<details>
<summary>本次扫描清单(2026-10-06 -> 2026-10-12)</summary>

有信息量:
- https://gitcode.com/openFuyao/npu-operator
  - 2026-10-10 MR !121 `feat: update the component to adapt A5 machine`(新增 infer-operator:InferService/InferServiceSet/InstanceSet CRD + rdma-shared-dp + volcano controller 清单;NPUClusterPolicy 加 inferOperator/rdmaDevicePlugin)
- https://gitcode.com/openFuyao/flux-sandbox
  - 2026-10-08 `feat: 支持传入扩展参数给 E2B 运行时 + E2B 沙箱 hostport 网络`(MR !3,+1247/-246)
  - 2026-10-08 docs: 同步资源超分/hugepages;新增 V1 用户使用指导
- https://gitcode.com/openFuyao/sig-agent-sandbox
  - 2026-10-12 MR !10 `docs: sync English embedded E2B guidance`
- https://gitcode.com/ascend/mind-cluster
  - 2026-10-09 clusterd:A5 场景取 pod 设备 id 列表为空修复(GetPodUsedDev 回退读 PodNPUDeviceAnno)
  - 2026-10-12 ascend-operator:修 operator 获取 NPU 类型/数量问题
  - 2026-10-12 ascend-for-volcano:修 volcano 获取 NPU 任务类型/数量问题
  - 2026-10-10 docs:逻辑框亲和性调度方案介绍 + DRA 实践
  - 2026-10-10 升级 golang.org/x/net v0.60.0 修 CVE;dpu-exporter dockerfile 适配
- https://gitcode.com/openFuyao/npu-container-toolkit
  - 2026-10-10 MR !17 更新 ascend-docker-runtime.dockerfile
- https://gitcode.com/openFuyao/ubs-k8s-enable
  - 2026-10-10 MR !95 cgroup v2 场景跳过 devices.allow/deny 写入
- https://gitcode.com/openFuyao/sig-installation
  - 2026-10-10/12 文档:bkecluster 示例升 v1.34.3-of.1 + 离线/自定义仓库场景指南(MR !271/!269)
- https://gitcode.com/openFuyao/console-website
  - 2026-10-08/09 升级 axios/i18next 修 CVE + code review 崩溃级缺陷修复(MR !873/!874/!875)
- https://gitcode.com/openFuyao/ub-ssu-csi
  - 2026-10-09/10 UBSE 卷重复删除/已分离按成功处理(幂等)(MR !29/!30)

新纳入观察(本周无 in-window 提交,仅登记架构定位):
- https://gitcode.com/openFuyao/cache-indexer(oFEP-0053,全局 L1/L3 KVCache 索引;最近实质更新停在 09 月)
- https://gitcode.com/openFuyao/ofep(enhancement proposals,最近提交 09-08)

本轮无实质增量(未见 2026-10-06 后实质提交):
- https://gitcode.com/openFuyao/InferNex(HEAD 停在 09-30)
- https://gitcode.com/openFuyao/hermes-router
- https://gitcode.com/openFuyao/npu-dra-plugin
- https://gitcode.com/openFuyao/vNPU
- https://gitcode.com/openFuyao/volcano-ext
- https://gitcode.com/openFuyao/sig-orchestration-engine
- https://gitcode.com/openFuyao/ub-network-device-plugin
- https://gitcode.com/openFuyao/kae-operator
- https://gitcode.com/openFuyao/npu-driver-installer
- https://gitcode.com/openFuyao/bkeadm, bke-manifests, CubeSandbox, docs

官方源:
- https://blog.csdn.net/openFuyao(2026-10-08 v26.09 社区发行版公告,头条 Agent 沙箱调度)
- https://www.openfuyao.cn/zh/(news/blog/活动 仍"暂无内容",与 CSDN 发布不同步)
</details>
