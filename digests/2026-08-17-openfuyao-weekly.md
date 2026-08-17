# OpenFuyao 周报 2026-08-17

> 扫描窗口:2026-08-10 ~ 2026-08-17。主仓 GitCode `openFuyao` 组织 + 昇腾 upstream `ascend/mind-cluster` + 官方 CSDN。本周非发版周(v26.06 已于 07.09 发布,下一季度版待定),但推理栈(InferNex)与昇腾运行时(mind-cluster)提交密集,且冒出两个"AI 原生/Agent 基础设施"新仓,信息量足够,故正常出报。

## 摘要(3 条以内)
- **昇腾运行时全面转向 CDI**:`ascend/mind-cluster` 本周一次性合入 CDI(Container Device Interface)注入模式全套 —— spec builder、设备节点生成、mount FileProvider、Ascend Docker Runtime CDI runtime,并新增 cri-o 引擎支持。这是把昇腾设备注入对齐 CNCF 标准(NVIDIA container toolkit 早已走 CDI)的关键一步,和 DRA 是配套的。
- **InferNex 推理栈持续高频迭代**(仓库 43 分钟前还在提交):本周聚焦 Mooncake 分布式 KVCache 解耦(支持外部 Mooncake master、端口隔离)和 proxy-server 服务发现健壮性(pod readiness + 实时 K8s watch)。其路由层 hermes-router 明确基于上游 GIE(Gateway API Inference Extension)框架,与 llm-d 同源。
- **两个 AI 原生新仓浮现**:`flux-sandbox`(E2B 运行时沙箱 + 增量快照,面向 Agent 代码执行)和 `rootpv`(容器 rootfs 持久化 + admission webhook)。OpenFuyao 正从"推理服务"向"Agent 基础设施 + 有状态容器"扩边界。

## 新功能 / 能力

- [mind-cluster: Ascend Docker Runtime CDI 注入模式](https://gitcode.com/ascend/mind-cluster) — 本周合入 4 个 CDI 相关 MR:CDI spec builder(带校验、per-claim 文件生成)、覆盖所有 Ascend DevType 的设备节点生成、`.list` 文件 mount 的 FileProvider 子包、runtime 侧 CDI 注入;另加 cri-o 容器引擎支持。
  - 启示:CDI 是 CNCF 标准设备注入接口,也是 K8s DRA 落地设备的官方载体。昇腾把 Docker Runtime 从"魔改 hook 注入"迁到 CDI,等于承认 NVIDIA container toolkit 的技术路线,并为 DRA(`npu-dra-plugin`)铺路。这是**通用路线**,不是昇腾私有 trick —— 我们如果做异构设备接入,CDI + DRA 是同一套底座,可直接参考它的 per-claim 文件生成方式。cri-o 支持则意味着它在向 OpenShift 生态兼容靠拢。

- [npu-dra-plugin 打出 v26.6.0 tag,DRA 接入趋稳](https://gitcode.com/openFuyao/npu-dra-plugin) — 本周修 DestroyVDevice 错误处理、启用 static-pie 构建、修 builder 镜像 ONBUILD 导致的 dcmi_init 段错误。配合 `npu-operator` 侧新增 soft-dra、DeviceClass status 处理、组件冲突检测。
  - 启示:这是**跟我们 DRA 选型最强相关**的一条。昇腾已把 DRA 从实验推到有正式 tag + vNPU(vDevice)动态分配的阶段,架构路径和 NVIDIA/Intel 的 DRA driver 一致(ResourceClaim/DeviceClass)。"soft-dra" 值得深挖 —— 大概率是在集群未开 DRA feature gate 时的软降级兼容层,对我们做渐进式 DRA 迁移有参考。

- [flux-sandbox:E2B 运行时沙箱](https://gitcode.com/openFuyao/flux-sandbox) — 07-31 新建仓。本周合入 Template Manager 集成、E2B runtime 重构,提交"支持 E2B 运行时沙箱增量快照"提案(0005),并附一份 30000 沙箱规模性能验证报告。
  - 启示:E2B 是 Agent/代码解释器领域的标准沙箱运行时。OpenFuyao 建独立仓做 E2B + 增量快照(快速冷启动大量沙箱),说明它把**Agent 代码执行基础设施**当成一等方向,和推理服务并列。这块和我们的产品方向(云原生 AI 基础设施)有潜在竞争面 —— 如果客户要跑 Agent workload,沙箱冷启/快照是硬需求,建议评估其增量快照方案。**通用能力,非昇腾专用。**

- [rootpv:容器根目录持久化](https://gitcode.com/openFuyao/rootpv) — 07-22 新建仓。本周加入持久化 rootfs 的 pod admission webhook、node runtime inventory 与适配器、rootfs HTTP API。
  - 启示:给容器 rootfs 提供持久卷,典型场景是需要"可持久、可迁移"的有状态容器(如长跑训练/调试环境、Agent 沙箱的持久工作区)。通过 admission webhook 注入,对用户透明。与 flux-sandbox 可能是一套:沙箱要持久工作区。**通用能力**,可借鉴其 webhook 注入模型。

- [openfuyao-powers:AI 辅助研发 skill 套件](https://gitcode.com/openFuyao/openfuyao-powers) — 本周更新 e2e-failure-analyzer(CI 流水线上下文分析)、新增 ofep 安全自检 skill。
  - 启示:社区自建"给自己用"的 AI DevOps skill 库(类似 Claude Code skill 形态),把 e2e 失败归因、安全检查做成可复用 skill。对我们:这是"AI 辅助平台运维"的具体落地样例,值得看它 skill 的封装粒度。

## AI 推理栈(InferNex / hermes-router / Mooncake)

本周 InferNex 是全组织最活跃的仓(持续到扫描时仍在提交),主线是**把 Mooncake 分布式 KVCache 做成可解耦的外部依赖**并加固服务发现:

- **Mooncake 解耦**:`feat(helm): allow external mooncake master` —— 允许接入外部 Mooncake master,不再强绑内置实例;`fix: move mooncake zmq kv_port out of te port range` —— 把 zmq KV 端口移出 transfer engine 端口段,避免端口冲突。
- **proxy-server 服务发现健壮性**:改用 pod readiness + 实时 K8s watch 做推理节点发现,优雅处理瞬时不可用 endpoint;并把后端 HTTP 错误透传给客户端(此前被吞)。
- **部署前校验优化**:`perf: reuse npu-smi output between H-03 and H-04 checks` —— Helm 前置校验工具复用 npu-smi 输出减少开销(v26.06 新增的 NPU 驱动/硬件/网络环境预检)。
- **hermes-router**:`Tokenizer 初始化失败改为有界退避 + 重试窗口后降级运行`,不再无限重试。

架构对比(据 InferNex README 26-06 版):
- **hermes-router 明确基于上游 GIE(Gateway API Inference Extension)框架实现**,支持算力饱和度感知、KV 命中感知、请求压力/长度感知、语义感知,内置 KVCache-aware 与 PD 长短请求分桶策略。→ 这与 **llm-d / kgateway 同源**(都建在 GIE 上),是**可直接借鉴的通用路线**,不是昇腾私活。
- **cache-indexer**:基于 vLLM KV Event 机制构建分布式全局 KVCache 元数据前缀树(RESTful),26-06 做到 L3 级 KV-aware,与 Mooncake 联动。→ 思路等同 llm-d 的 KV-cache-aware routing / vLLM production-stack,通用。
- **PD-Orchestrator / elastic-scaler**:26-06 新增 APA 扩缩算法,支持多指标 + 事件驱动的 PD 组弹性伸缩。→ 对标 llm-d / Dynamo 的 P/D 分离自动伸缩。
- **分布式 KVCache 传输走 Mooncake HCCL Transfer Engine**。→ 传输层用 HCCL(昇腾集合通信)是**昇腾专用**,但上层 KVCache 池化/索引/路由思路通用。
- **eagle-eye**:26-06 新增权重分发与"灵衢(UB)网络"动态指标采集,走 NATS 做毫秒级可观测。→ 灵衢/UB 网络指标是昇腾专用。

小结:InferNex ≈ 昇腾版 llm-d。路由/KVCache 索引/PD 弹性伸缩三层是**通用可借鉴**的;传输(HCCL)、网络指标(UB/灵衢)、后端引擎(vLLM-Ascend)是昇腾绑定。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- **CDI 化(见上"新功能")** 是本周 mind-cluster 主线,配合 cri-o 支持、A800I A3 新 boardId(0xb4)、hccn2dcmi、NUMA 相关提交。
- **npu-operator**:本周多为 DRA 相关加固 —— 删除 DeviceClass 与 soft-dra 的冗余 status、`getInstance` 保留错误链以支持 `IsNotFound` 判断、组件冲突检测、updateStatus 错误传播修复。均为质量/健壮性提交,无新特性,但说明 DRA 路径在"从能跑到可靠"阶段。
- **npu-dra-plugin** 见上,已出 v26.6.0 tag。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- 本周 `volcano-ext`、`ub-network-device-plugin`、`kae-operator`、`mooncake` 仓在窗口内**无实质提交**,跳过(volcano-ext 最新 tag 仍是 v1.10.0)。
- 集群侧动作集中在 `cluster-api-provider-bke`:新增 YamlInstaller 引擎 / YamlComponentExecutor(用声明式 YAML 装配集群组件)、cluster 管理重试逻辑修复、对异常 worker 节点新增 NeedSkip 跳过能力。→ 这是 OpenFuyao 基于 Cluster API 做企业级集群纳管的部分,YamlInstaller 类似 addon/component 声明式安装器。

## 官方动态

- **[社区 2026 年 6-7 月运作报告](https://blog.csdn.net/openFuyao)**(CSDN,08.11 发布):核心数据 —— v26.06 推理加速 TTFT 降 55%、平均总吞吐 +32%(剥离宣传后,对应上面 LWS 编排 + APA 弹性伸缩 + cache-indexer L3 KV-aware 的合力);NPU DRA 设备扩展;新增 KubeVirt 统一容器与虚机管理。社区规模 300+ 开发者、30+ 成员单位、16 个 SIG、40+ 商用落地。
- **[通过 KubeVirt 实现容器与虚机统一管理](https://blog.csdn.net/openFuyao)**(CSDN,08.11):把传统虚机 workload 纳入 K8s 统一编排。→ 对标 OpenShift Virtualization,同为 KubeVirt 上游路线,通用。
- 官网(openfuyao.cn)news/blog/活动栏目仍为空,08/13 有一场直播(19:30-20:00),内容未公开;官方内容目前仍以 CSDN 为主发布口。

## 跟我们产品的对比

| 能力维度 | OpenFuyao 现状 | 与上游/我们的关系 |
|---|---|---|
| 推理网关路由 | hermes-router 建在 GIE 上,多维感知 + KVCache-aware | 与 llm-d/kgateway **同源同路**;我们若走 GIE 可对齐,其分桶/算力饱和度策略可借鉴 |
| 全局 KVCache | cache-indexer 前缀树 + Mooncake 池化 | 思路通用(≈ llm-d KV-aware),传输层 HCCL 昇腾专用 |
| P/D 分离弹性 | PD-Orchestrator + APA 多指标伸缩 | 对标 Dynamo/llm-d,通用 |
| 设备接入 | CDI 注入 + DRA(npu-dra-plugin v26.6.0)+ vNPU | **与 K8s 官方 DRA/CDI 路线一致**,直接可比,soft-dra 降级层值得看 |
| 容器运行时 | Ascend Docker Runtime + 新增 cri-o | 向 OpenShift/CRI-O 生态兼容靠拢 |
| Agent 沙箱 | flux-sandbox(E2B + 增量快照) | **潜在竞争面**,我们目前空白,需评估 |
| 有状态容器 | rootpv(rootfs 持久化 + webhook) | 通用能力,可借鉴注入模型 |
| 容器+虚机统一 | KubeVirt 集成 | 对标 OpenShift Virtualization |

**我们该补 / 该警惕**:
- Agent 代码执行沙箱(flux-sandbox / E2B 增量快照)是我们目前的空白点,而 OpenFuyao 已把它独立立仓推进,建议纳入路线评估。
- CDI + DRA 的组合(设备注入标准化 + 声明式资源分配)昇腾这边推进速度快,若我们 DRA 还在选型,可直接借它的 per-claim 文件生成 / soft-dra 降级设计少走弯路。

## 值得跟进
- [ ] 读 `ascend/mind-cluster` CDI 系列 MR(feat/cdi-spec、feat/cdi-devnode、feat/cdi-mount、feat/cdi-runtime),对照 NVIDIA container toolkit 的 CDI 实现,评估我们设备注入是否直接上 CDI:https://gitcode.com/ascend/mind-cluster
- [ ] 评估 `npu-operator` 的 "soft-dra":确认是否为 DRA feature gate 未开时的软降级兼容层,对我们渐进式启用 DRA 有无参考:https://gitcode.com/openFuyao/npu-operator
- [ ] 看 `flux-sandbox` 提案 0005(E2B 增量快照)+ 30000 沙箱性能报告,判断 Agent 沙箱冷启方案成熟度:https://gitcode.com/openFuyao/flux-sandbox
- [ ] 跟 InferNex `allow external mooncake master` 这条线,看 Mooncake 能否作为独立 KVCache 服务被复用(而非绑死 InferNex):https://gitcode.com/openFuyao/InferNex

## 原始材料

<details>
<summary>本次扫描清单</summary>

**扫描窗口**:2026-08-10 ~ 2026-08-17

**有实质更新的仓**:
- `openFuyao/InferNex`(最活跃):Mooncake external master、zmq 端口隔离、proxy-server 服务发现(pod readiness + K8s watch)、后端 HTTP 错误透传、npu-smi 预检复用、日志降噪
- `openFuyao/hermes-router`:Tokenizer 初始化有界退避 + 降级
- `openFuyao/npu-operator`:soft-dra / DeviceClass status / 组件冲突检测 / 错误链保留
- `openFuyao/npu-dra-plugin`:v26.6.0 tag、static-pie、DestroyVDevice 错误处理、dcmi_init 段错误修复
- `ascend/mind-cluster`:CDI 全套(spec/devnode/mount/runtime)、cri-o 支持、A800I A3 boardId、NUMA、hccn2dcmi
- `openFuyao/flux-sandbox`(07-31 新建):E2B runtime + Template Manager + 增量快照提案 0005 + 30000 沙箱性能报告
- `openFuyao/rootpv`(07-22 新建):rootfs 持久化、admission webhook、node runtime inventory、rootfs HTTP API
- `openFuyao/openfuyao-powers`:e2e-failure-analyzer、ofep 安全自检 skill
- `openFuyao/cluster-api-provider-bke`:YamlInstaller 引擎、cluster 管理重试、NeedSkip 异常节点

**窗口内无实质提交(跳过)**:`volcano-ext`、`ub-network-device-plugin`、`kae-operator`、`mooncake`(仓)、`juicefs`、`env-check`、`bkecommon`

**官方源**:
- CSDN 社区 6-7 月运作报告(08.11):v26.06 TTFT-55%/吞吐+32%、NPU DRA 扩展、KubeVirt 统一容器虚机 —— https://blog.csdn.net/openFuyao
- 官网 openfuyao.cn news/blog/活动栏目为空;08/13 直播(内容未公开)

**抓取方式**:GitCode 走 `git clone --depth 120` + 本地 `git log --since`;官方走 WebFetch/WebSearch(CSDN 列表页)。GitCode raw/blob 页仍为 JS 壳,未用 WebFetch。

</details>
