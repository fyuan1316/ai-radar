# OpenFuyao 周报 2026-10-19

窗口:2026-10-13 -> 2026-10-19(7 天)

## 摘要(3 条以内)
- **昇腾 DRA 长出"动态 vNPU(硬切分)调度"能力:mind-cluster !4956(10-16)合入基础版**。用户通过 `ResourceClaim` YAML 声明切分模板 + AI Core 需求,DRA driver 自动用 DCMI 创建 vNPU、生成 CDI 配置注入 Pod、释放时回收;新增 `presetVirtualDevice=false` 动态模式与第三个 `dynamic-vnpu.huawei.com` DeviceClass(前两个是 `physical-npu` / `static-vnpu`)。**这是昇腾接 K8s DRA 从"物理 NPU + 预建静态 vNPU"迈向"运行时按需切分"的实质一步,跟我们 DRA 选型强相关**——走的是上游 DRA 标准路径(ResourceClaim/DeviceClass/CEL selector/CDI),分叉只在设备侧(DCMI、AI Core 容量)。
- **hermes-router 补齐 decode-first 路由策略(通用、可借鉴)**:!95(10-14)文档确认 PD 分离下的新档位——**先选 Decode 实例,再按 prefix cache 命中率决定是否跑 Prefill**:命中足够高走纯 Decode(D)路径,否则走完整 PD 路径,由 ProfileHandler 插件在 Decode 打分后决定是否继续调度 PD profile。这是硬件无关的路由思路,区别于常规 prefill-first。
- **官方侧密集:CSDN 10-18 连发 3 篇技术讲堂 + 8-9 月运作报告**。运作报告披露 v26.09 Agent 沙箱并发创建 >3000 实例/s、InferNex 多轮对话 TTFT 最高降 45.8%、新增 6 家商发伙伴(麒麟软件、浪潮云等)、**CNCF 同意将 InferNex 与 SandboxSched 纳入 CNCF Landscape、NPU DRA 推进进 K8s 社区**。但同周 flux-sandbox 把上期 v26.09 旗舰工程"E2B 扩展参数 + hostport"**整体回退**(!5,10-13),是旗舰能力的回滚信号。

## 新功能 / 能力

- [mind-cluster DRA 动态 vNPU !4956](https://gitcode.com/Ascend/mind-cluster)(2026-10-16,`feat(dra): add basic dynamic vNPU scheduling`,31 文件 +978/-296)——关联 issue #1234。核心:
  - 新增 `presetVirtualDevice` 模式参数,默认 `true` 保留物理 NPU + 静态 vNPU 分配路径;设为 `false` 启用动态模式,发布 `deviceKind=dynamic-vnpu` 和可消费的 `aicore` 容量,**支持同一物理设备在容量允许时承载多个 Claim**。
  - 新增动态 vNPU 管理器封装 DCMI 创建/销毁;模板由配置显式指定,创建后查询硬件实际 AI Core 数并与申请容量比对,不匹配则回收(不靠模板名推算核数)。
  - `DeviceState` 接入动态 Prepare/Unprepare,保存 vDevID/逻辑设备 ID/ShareID,为每个返回设备填 CDI ID,处理重复 Prepare、进程内失败回滚、释放重试;部署侧新增 `dynamic-vnpu.huawei.com` DeviceClass(CEL `device.attributes['npu.huawei.com'].deviceKind == 'dynamic-vnpu'`)。
  - 本 PR 只做"创建/注入/重复 Prepare/正常释放";**重启恢复、启动对账、中断处理在后续 !4957**。用户继续用 K8s YAML 申请,不引入 Python 脚本。
  - **对比**:这是 K8s DRA 标准范式在昇腾上的落地——ResourceClaim 声明设备参数、DeviceClass + CEL 选设备、CDI 注入,与 NVIDIA DRA driver(k8s-dra-driver 的 MIG 动态切分)**同构**。差异是切分走 DCMI、容量单位是 AI Core。
  - **启示**:我们 GPU 侧的 MIG/MPS 动态切分应优先对齐这套 DRA 范式——"用户在 ResourceClaim 里声明切分模板 + 算力需求,driver 运行时建实例并 CDI 注入,释放即回收",而不是预建固定规格 + device-plugin 静态暴露。尤其值得抄的工程细节:**创建后回查硬件实际核数并与申请量比对、不匹配即回收**(避免模板名与真实切分漂移),以及同一物理卡承载多 Claim 的容量账本。异常恢复/启动对账能力要盯 !4957 是否补齐——这往往是 DRA 生产可用性的真正门槛。
- [hermes-router decode-first !95](https://gitcode.com/openFuyao/hermes-router)(2026-10-14,README 补文档;策略本体 2026-09 并入)——PD 分离部署的新路由档位,与既有 `kv-cache-aware`/`prediction`/`bucket` 并列。机制:Scheduling 层先对 Decode 实例打分选定,再由 **ProfileHandler** 按 prefix cache 命中率决定走纯 D 还是完整 PD。
  - **对比/启示**:**硬件无关、可直接借鉴**。常规 PD 路由是"prefill-first"(先定 Prefill 再找 Decode);decode-first 反过来,把"已有足够 KV 前缀就跳过 Prefill"做成一等路由决策——等价于把 prefix-cache 命中当作"能否省掉 prefill 阶段"的开关,而非仅用于选实例。我们的推理网关若已做 PD 分离,应把 decode-first 作为一个可选 profile,对长系统提示 / 多轮对话场景(高前缀复用)能省一整段 prefill 算力。

## AI 推理栈(InferNex / hermes-router / weight-dispatcher)
- **decode-first 路由策略**(见上),是本周推理栈最有借鉴价值的通用信号。
- [weight-dispatcher(ModelWarmupJob)](https://gitcode.com/openFuyao/weight-dispatcher) — 本周无 in-window 提交(HEAD 停在 08-25),但 10-18 技术讲堂《AI 推理权重分发加速》把它作为 v26.06 组件系统讲了一遍,登记其架构:`ModelWarmupJob` CRD(`warmup.openfuyao.com`)声明权重预热任务,Controller 做校验/目标节点解析/分发计划,node-agent(DaemonSet)执行拉取与发布,数据面适配器支持 **RDMA/TCP 切换**,并用"多源并行拉取(striping)+ manifest 校验布局一致性"加速。**明确非昇腾专用**。
  - **启示**:这是解决 LLM 冷启动(数十~数百 GB 权重下载、多节点重复拉取打满带宽)的**通用件**,思路与 run:ai model-streamer / KServe modelcache / Fluid 同类。可借鉴点:把"权重预热"升成声明式 CRD(而非塞进 initContainer),配 node 级缓存状态机(加载/发布/失败清理/命中复用)+ 多源条带化;RDMA/TCP 双路径适配值得我们在高带宽集群复用。
- **InferNex 本周无 in-window 提交**。推理控制面侧的变化本周落在 mind-cluster 的 infer-operator(MindX DL 口径,上期新增),均为健壮性修补而非能力新增:
  - 10-14 !5027 修 `instanceSpec.replicas` 为空时快照控制器 panic;10-15 !5031 修 `role.replicas` 为空时重调度路径更新状态 panic;10-15 !5033 init 容器把日志目录属主设为 root。说明 infer-operator 这套角色化 serving CRD 正在做上线前的空值/权限加固。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)
- **DRA 动态 vNPU 硬切分(!4956,见上)——本周昇腾侧最重要变更**。
- [mind-cluster](https://gitcode.com/Ascend/mind-cluster) 一批 device-plugin / DPU 运维加固(昇腾专用):
  - 10-13 !4981 `npu 改名问题`排查修复(device-plugin + clusterd);10-13 !4991 移除无业务使用的 `linkdownTimeout` 启动参数。
  - 10-13 !5019 `rdma-dp` 手动安装后无法被 helm 接管;10-13 !5013 `dpu-exporter` 支持 helm 接管;10-13 !5001 dpu-exporter 采集周期参数增加取值范围校验。均为 helm 化纳管与参数校验收敛。
  - 10-14 !5021 Go module 版本提到 1.26.0(CVE 相关);10-14 hyper plane 故障事件处理新增"设备不健康超过 5 分钟"补偿逻辑(昇腾故障容错)。
- `npu-dra-plugin`(openFuyao 侧)、`vNPU`、`kae-operator`、`npu-container-toolkit`、`ub-network-device-plugin`、`ubs-k8s-enable` 本周均无 in-window 实质提交。

## 调度 & 集群(volcano / 超节点 / 故障容错)
- [mind-cluster !4909 静默故障节点降级 + Pod fail 节点降级](https://gitcode.com/Ascend/mind-cluster)(2026-10-13,volcano)——**基于时间的容忍降级机制**:新增作业级注解 `huawei.com/silent.unhealthy-tolerance.after-time` 与 `huawei.com/pod.failure-tolerance.after-time`,写入 NPUJob 的对应字段;重调度阶段新增 `SilentFault`/`ToleranceForbidden(-1)` 常量与 `FaultNode.SilentUnhealthyNPU`,**按作业已 pending 时长决定是否解除对静默故障节点/Pod 失败节点的调度限制**。
  - **对比/启示**:机制绑昇腾故障域(静默故障 = NPU 层面的 silent data corruption 感知),但"**按作业排队时长动态放宽故障节点容忍**"这个调度思路是通用的——宁可把作业排在已知有风险的节点上,也不让它无限 pending。我们做 GPU 作业调度的故障节点隔离时,可借鉴这种"隔离有超时、超时后降级准入"的二段式策略,避免因健康门槛过严导致作业饿死。
- [mind-cluster super-pod-affinity Atlas 950 SuperPoD Flex !5007](https://gitcode.com/Ascend/mind-cluster)(2026-10-13,文档)——super-pod-affinity 补齐对 Atlas 950 SuperPoD Flex 超节点的支持说明。昇腾超节点(灵衢)拓扑亲和专用,记录不照抄。
- `volcano-ext`(openFuyao 侧)、`sig-orchestration-engine` 本周无 in-window 实质提交。

## 官方动态
- **CSDN 10-18 连发 3 篇技术讲堂(均为既有能力的深度解读,非新发版)**:
  - 《AI 推理权重分发加速》——讲 weight-dispatcher / ModelWarmupJob(见 AI 推理栈,非昇腾专用)。
  - 《众核编排(Many-Core Orchestrator)》——对应 sig-orchestration-engine 的众核编排(此前关注过干扰检测 + 重调度)。
  - 《容器虚拟机共管》——对应基于 KubeVirt 的容器/虚拟机统一编排。
- **[openFuyao 社区 2026 年 8-9 月运作报告](https://blog.csdn.net/openFuyao/article/details/168341772)**(10-18)关键事实:
  - v26.09 Agent 沙箱并发创建吞吐 >3000 实例/s;InferNex 多轮对话场景 TTFT 最高降 45.8%。
  - 新增 6 家商发伙伴(含麒麟软件、浪潮云),已在金融/航空/汽车落地。
  - KubeCon China 2026 亮相;**CNCF 同意将 InferNex 与 SandboxSched 纳入 CNCF Landscape**;推进 NPU DRA 进入 K8s 社区。
  - 近 20 个提案合入/提出,覆盖 K8s 组件升级、沙箱网络设计、动态存储挂载。
- **flux-sandbox 旗舰工程回退**:[!5 revert](https://gitcode.com/openFuyao/flux-sandbox)(10-13)整体回退上期 v26.09 头条对应的 `feat/e2b-extensions-and-hostport`(!3);随后 !6(10-17)修"创建高峰 + CPU 超分场景下 Agent 心跳过期误判沙箱 CR 为 Lost"。说明 Agent 沙箱调度虽是 v26.09 官宣头条,工程侧仍在反复——扩展参数/hostport 能力被撤回待重做,心跳/误判稳定性也在补。
- [console-website](https://gitcode.com/openFuyao/console-website)(10-13~10-19,!876~!880)启用 eslint + consistent-return 等规则、console.error 换成 antd 错误 toast、修 code review 健壮性问题——控制台发版后持续质量收敛,无能力级变更。
- 本周各仓无新 release/tag;官网 openfuyao.cn 发布渠道仍以 CSDN 为准(沿用历史情况)。

## 跟我们产品的对比
- **同一路线(该对齐)**:
  - **DRA 动态 vNPU** 走 K8s 上游标准(ResourceClaim/DeviceClass/CEL/CDI),与 NVIDIA DRA driver 同构——我们 GPU 侧 MIG/MPS 动态切分应对齐同一范式,而非静态 device-plugin。
  - **hermes decode-first** 路由(硬件无关),PD 分离下把"前缀命中够高就跳过 prefill"做成一等路由决策。
  - **weight-dispatcher / ModelWarmupJob** 声明式权重预热 + 节点缓存状态机 + 多源 striping + RDMA/TCP 双路径(硬件无关,解冷启动)。
  - **volcano 故障节点二段式容忍降级**(按作业 pending 时长放宽准入)——通用调度思路。
- **分叉 / 昇腾专用(记录不照抄)**:DCMI vNPU 切分与 AI Core 容量账本、静默故障(silent data corruption)感知、Atlas 950 SuperPoD Flex 超节点亲和、灵衢/UB、rdma-dp / dpu-exporter helm 化。
- **我们该补 / 该警惕**:
  - DRA 动态切分的**异常恢复 / 启动对账**(!4957)是生产门槛,做我们自己的 DRA driver 时别只做 happy path。
  - decode-first 可作为推理网关的一个可选 profile,针对高前缀复用场景省 prefill 算力。
  - **警惕"官宣能力 ≠ 工程稳定"**:v26.09 头条 Agent 沙箱,代码侧本周把扩展参数/hostport 整体回退、还在修心跳误判——对标沙箱调度时应以代码实际状态而非发行公告为准。
  - CNCF Landscape 收录 InferNex/SandboxSched 是生态信号,说明 OpenFuyao 推理栈在走向上游曝光,值得跟踪其是否进一步贡献上游(如 GIE / DRA)。

## 值得跟进
- [ ] 读 mind-cluster `!4957`(DRA 动态 vNPU 的重启恢复 / 启动对账 / 中断处理),判断昇腾 DRA 生产可用度,对照我们 DRA driver 的恢复语义设计。
- [ ] 读 hermes-router decode-first 的 `ProfileHandler` 实现(`pkg/` 下),看"是否跳过 prefill"的判定阈值与 prefix-cache 命中率如何取数,评估能否移植到我们的 EPP。
- [ ] 读 weight-dispatcher 的 `ModelWarmupJob` CRD schema 与 node-agent striping / RDMA 适配,评估通用 GPU 栈冷启动权重分发的可借鉴度。
- [ ] 跟踪 flux-sandbox 回退后的 extensions/hostport 何时以新设计重新落地,判断 Agent 沙箱调度真实成熟度。
- [ ] 跟进 "NPU DRA 进入 K8s 社区" 的具体提案(运作报告提及),看是否推动上游 DRA 规范(与我们选型相关)。

## 原始材料

<details>
<summary>本次扫描清单(2026-10-13 -> 2026-10-19)</summary>

有信息量:
- https://gitcode.com/Ascend/mind-cluster
  - 2026-10-16 !4956 `feat(dra): add basic dynamic vNPU scheduling`(动态 vNPU 硬切分:presetVirtualDevice 模式、dynamic-vnpu DeviceClass、DCMI 管理器、CDI 注入;后续 !4957 补恢复/对账)
  - 2026-10-13 !4909 volcano 静默故障节点降级 + Pod fail 节点降级(作业级时间容忍注解)
  - 2026-10-14 infer-operator 两处 nil replicas panic 修复(!5027/!5031)+ 10-15 init 容器日志目录属主 root(!5033)
  - 2026-10-13 !4981 npu 改名 bugfix(device-plugin/clusterd)、!4991 移除 linkdownTimeout 参数
  - 2026-10-13 !5019 rdma-dp helm 接管、!5013 dpu-exporter helm 接管、!5001 dpu-exporter 采集周期校验
  - 2026-10-13 !5007 super-pod-affinity Atlas 950 SuperPoD Flex 文档
  - 2026-10-14 !5021 Go module 1.26.0(CVE)、hyper plane 故障 5 分钟补偿逻辑
  - 其余多为文档整改(README/版本说明书/devcontainer/profiling/TaskD/NodeD 等)
- https://gitcode.com/openFuyao/hermes-router
  - 2026-10-14 !95 README 补 decode-first 路由策略(策略本体 2026-09 并入)
- https://gitcode.com/openFuyao/flux-sandbox
  - 2026-10-13 !5 revert 回退上期 e2b-extensions-and-hostport(!3)
  - 2026-10-17 !6 修创建高峰 + CPU 超分下 Agent 心跳过期误判沙箱 CR 为 Lost
- https://gitcode.com/openFuyao/console-website
  - 2026-10-13~19 !876~!880 eslint/质量收敛(无能力变更)
- https://gitcode.com/openFuyao/sig-installation
  - 2026-10-19 !273 共部署场景 kubelet GC 导致 pod 日志丢失 FAQ(文档)
- https://gitcode.com/openFuyao/sig-agent-sandbox
  - 2026-10-14 !17 docs: update project name

官方源(CSDN,2026-10-18):
- https://blog.csdn.net/openFuyao/article/details/168341925 技术讲堂《AI 推理权重分发加速》(weight-dispatcher/ModelWarmupJob,v26.06 能力解读)
- https://blog.csdn.net/openFuyao/article/details/168341911 技术讲堂《众核编排 Many-Core Orchestrator》
- https://blog.csdn.net/openFuyao/article/details/168341878 技术讲堂《容器虚拟机共管》
- https://blog.csdn.net/openFuyao/article/details/168341772 2026 年 8-9 月运作报告(>3000 实例/s、TTFT -45.8%、6 商发伙伴、CNCF Landscape 收录 InferNex/SandboxSched、NPU DRA 进 K8s 社区)

本轮无实质增量(未见 2026-10-13 后实质提交):
- https://gitcode.com/openFuyao/InferNex(HEAD 仍在 09-30)
- https://gitcode.com/openFuyao/cache-indexer
- https://gitcode.com/openFuyao/weight-dispatcher(HEAD 08-25,仅被讲堂文章解读)
- https://gitcode.com/openFuyao/npu-dra-plugin、vNPU、kae-operator、volcano-ext
- https://gitcode.com/openFuyao/npu-container-toolkit、ub-network-device-plugin、ubs-k8s-enable
- https://gitcode.com/openFuyao/sig-orchestration-engine、ofep、npu-operator(openFuyao 侧;MindX 口径 infer-operator 在 mind-cluster)
</details>
