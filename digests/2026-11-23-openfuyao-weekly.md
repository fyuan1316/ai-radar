# OpenFuyao 周报 2026-11-23

窗口:2026-11-16 -> 2026-11-23(7 天)

> 覆盖说明:本 task 上次运行是 2026-11-02,11-03~11-15 未出周报。本期按 7 天口径,不回溯补写。缺口期间 mind-cluster 和 openFuyao 昇腾侧 8 仓已由 compute-ascend-watch 日报覆盖(最重要的是 11-18 期记录的「昇腾 DRA 驱动收缩为仅支持 A5/Ascend 950,删除 `ascend910.ext.huawei.com` DeviceClass」,改动约在 11-10)。缺口期间的官方文章只在「官方动态」末尾列标题。
>
> 取数说明:GitCode v5 API 本次返回 429(匿名请求共用的 `p_repoRobot` 账号超出每小时阈值),因此全部改用 `git clone --bare --filter=blob:none` 本地读。仓库清单用 GitCode 组织首页交叉核对,新发现 `agent-sched-nex`、`ubs-k8s-enable`、`sig-agent-sandbox`、`bke-manifests` 四个在活跃的仓,本期一并纳入。

## 摘要(3 条以内)
- **hermes-router 的 KV 感知路由换了数据源,接入全局 KV 索引服务 kv-conductor,覆盖聚合、PD 分离、DP rank 三层**。本周合入三个 GIE EPP 插件:聚合模式 scorer、PD 模式 scorer(给 PD group leader 打分时汇总其 prefill/decode 成员的命中率),以及一个 PreRequest 插件,它把命中最热的 DP rank 写进 `X-data-parallel-rank` 请求头,交给 vLLM 的 DP 负载均衡钉到具体 rank。配套的 cache-indexer 新增 registrar sidecar:watch 引擎 Pod,把每个 `(instance, dp_rank)` 的 vLLM KV-events ZMQ 端点注册到 conductor,Mooncake master 的池事件端点也自动注册。命中按 NPU/CPU/Disk 三级介质加权(默认 1/1/0)。整体与 llm-d 的「vLLM KV events → 全局索引 → EPP precise-prefix scorer」是同一条路,但多做了两层:DP rank 级钉选和分级介质加权。
- **Agent 基础设施成为本周提交最密集的方向**。SandboxSched 7 天 59 个提交:支持 amd64/arm64 混合池调度,打通 E2B 兼容的快照 API(快照 ID 可直接当 templateID 起新沙箱),新增可选的节点资源感知调度(CPU/内存/大页软硬水位 + PSI 风险分,按 SandboxGroup 开启)。新纳入的 `agent-sched-nex`(ASN)是 Agent 运行治理平台:A2A 北向、「创建/注入/快照/销毁」四操作沙箱契约、用户自带 Harness,本周补齐了 orchestrator 的快照/销毁生命周期。
- **mind-cluster 本窗口是 26.3.0 收尾期**(打出 `v26.3.0-beta.2` tag,不是社区发版),主要改动有四项:软切分 vNPU 接入节点侧 enpu-manager 守护进程,并输出 vNPU 级指标;Volcano 亲和性降级退避改为全局默认开启(默认 120s);clusterops-agent 做成随包发布的 LLM 运维 Agent(ReAct + 只读查询工具 + HTTPS 双监听);FD 掉卡跨 BMC/host 联合诊断。官方 CSDN 本窗口只有 11-16 的三篇合作伙伴商用发布稿(昆仑技术、优刻得、中科弘云),没有版本公告和运作报告。

## 新功能 / 能力

- [hermes-router:kv-conductor 聚合模式 KV 感知 scorer !106](https://gitcode.com/openFuyao/hermes-router/commit/c955fea3e5561b3d81a1ae19b22d438a16bfe292)(2026-11-18):新插件 `kv-conductor-kv-aware-scorer`。数据来自上游的 `kv-conductor-producer`(11-12 !97 合入,窗口外),它带着请求的 token ids 去 POST kv-conductor 的 `/query`,把每个 endpoint 的 `MatchTokens/PromptTokens` 写成 endpoint attribute。scorer 用「1 − 亲和度」作为 KV-miss 信号,与 KV cache 使用率、等待队列、在途 token 三个负载信号线性合成 badness(四项权重默认都是 1.0),所以「缓存很热但已过载」的 endpoint 不会只凭命中率胜出。
  - 实现细节:conductor 地址写在引擎 Pod 的 label `openfuyao.com/kv-conductor` 里(只填 Service DNS 名,端口固定为配置项,默认 13333)。共用一个 conductor 的 endpoint 只查询一次。conductor 没有注册 worker 时,该请求不做亲和打分(fail-open)、退回纯负载路由,并对告警限频。查询超时 500ms,最大并发 16。
  - 介质加权:`weightedTokens = (npuBlocks×npuW + cpuBlocks×cpuW + diskBlocks×diskW) × blockSize`,默认 NPU/CPU/Disk = 1/1/0,即**默认把 CPU 池(Mooncake)命中算作与显存命中等价,磁盘命中不计**。
  - 对比:框架是上游 GIE(gateway-api-inference-extension)EPP 插件体系,与 llm-d 同一个底座。思路对应 llm-d 的 precise prefix-cache scorer(订阅 vLLM KV events 建全局索引),不是 GIE 默认那种按请求前缀哈希估算的近似命中。**分叉点在介质加权**:llm-d 的索引主要追踪 GPU 上的块,这里显式区分 NPU/CPU/Disk 三级并允许调权重,是给「KV 池化(Mooncake/YuanRong)+ 分级存储」设计的打分模型。
  - 启示:如果我们的推理网关要接 KV offload/池化(LMCache、Mooncake),打分模型不能只认「HBM 前缀命中」,要把**命中所在介质**作为一维信号:从 CPU 池回填的代价远低于重算,又明显高于 HBM 命中。默认 CPU=1 的取法偏激进,我们落地时应按回填带宽实测定权,不宜照抄。

- [hermes-router:kv-conductor PD 模式 scorer !107 + DP rank 请求头插件 !108](https://gitcode.com/openFuyao/hermes-router/commit/209a9dfee159c2f94986a9b3d18fe8bacea37a4f)(2026-11-19 / 11-23,[PD scorer 提交](https://gitcode.com/openFuyao/hermes-router/commit/9c079044d006790ff59bc064ad6cef69adc15fd5)):PD 部署下 EPP 的路由目标是 PD group leader(proxy server),leader 本身没有 KV。新的 `kv-conductor-pd-kv-aware-scorer` 汇总 leader 所属 prefill/decode 成员 Pod 的 conductor 亲和度,给 leader 打分;prefill、decode、group 三组权重与原有 `pdkvaware` 共用一套校验和默认值流水线(新文件 `score/weights.go`)。`kv-conductor-dp-rank-header` 在选定 Pod 后,从 conductor 返回的 per-rank 命中里挑出最热的 DP rank,把 `rank - PodStartRank` 写进请求头:聚合模式用 `X-data-parallel-rank`(vLLM 原生识别的 DP rank 头);PD 模式用 `x-openfuyao-prefill-dp-rank`,由 proxy 转成前者发给 prefill 引擎。没有值得钉的命中时不写头,交给引擎自行做 DP 负载均衡。另附 `examples/profiles/{aggregate,pd}-kv-conductor.yaml` 两份完整的 EndpointPickerConfig。
  - 对比:**DP rank 级路由是相对 llm-d / GIE 的分叉增强**。上游 EPP 把一个 Pod 当作一个缓存域,但 vLLM 开 `data_parallel_size_local>1` 时,同一 Pod 内各 DP rank 的 KV 互不共享,Pod 级命中会被稀释。hermes-router 借 conductor 的 per-rank 索引把粒度下推到 rank。
  - 启示:我们的推理网关如果支持「单 Pod 多 DP rank」部署(MoE 大 EP 场景常见),KV 感知路由必须能感知 rank,否则命中率在网关层看着高、在引擎里却是 miss。做法可以照抄:索引按 `(instance, dp_rank)` 存,选 Pod 之后再用 vLLM 原生头钉 rank,不必改引擎。

- [cache-indexer:kv-conductor registrar sidecar + Mooncake 池自动注册 !55](https://gitcode.com/openFuyao/cache-indexer/commit/8ee4f1ee3e8d8dfb349b412a69dabe665d09221e)(2026-11-20,+3103 行):与 kv-conductor 同 Pod 部署的 sidecar。它 watch 本 namespace 中带 `openfuyao.com/engine=vllm` 的引擎 Pod,按 `openfuyao.com/pdRole` 和 `openfuyao.com/dpSizeLocal` 两个 label 推导出 `(instance, dp_rank)`,把每个 rank 的 vLLM KV-events ZMQ 端点(base 端口 5557,rank r 用 5557+r)`/register` 到 conductor。带 `openfuyao.com/kvmanager=mooncake` 的 Mooncake master 按单 endpoint 形态注册为「池订阅」,端口从容器参数 `--kv_events_bind_endpoint` 解析;没开 `--enable_kv_events` 的 master 直接跳过,避免注册死端口。对账走两条通道:Pod 事件 300ms 去抖,外加 30s 周期 ticker(兜底 conductor 重启丢失内存注册);以 `GET /workers` 为准做差集注册/反注册;反注册只动 `vllm-`/`mooncake-pool-` 前缀的自有实例,手工注册的不碰。配置缺失或非法直接启动失败,不会静默回落默认值。`STORE_BACKEND` 支持 Mooncake / YuanRong。
  - 对比:llm-d 的 kv-cache-manager 依赖 vLLM 主动往固定地址发布 KV events,没有「按 Pod label 自动发现 + 对账注册」这一层。这里把它做成 K8s 原生的声明式对账,conductor 和引擎重启都能自动收敛。
  - 启示:全局 KV 索引在生产上最容易出问题的不是算法,而是**注册表漂移**(引擎重建、rank 数变化、索引服务重启)。我们做 KV 索引组件时,「label 驱动发现 + 事件去抖 + 周期全量对账 + 所有权前缀隔离」这四件套应作为默认设计。

- [SandboxSched:节点资源感知调度(文档 !20,默认关)](https://gitcode.com/openFuyao/sig-agent-sandbox/commit/3c2c3d58d0ffbabc40c734d58a4811d3b0606307)(2026-11-23 文档合入):按 SandboxGroup 用 `spec.resourceAwareness.enabled` 开启。sandboxlet DaemonSet 增加 `node-metrics` 容器,只读挂载宿主机 `/proc` 和 `/sys` 采样(默认 5s,经共享 Redis 上报)。放置时 CPU/内存按「放置后预计占用」评估,大页按当前占用评估,默认软水位 50%、硬水位 85%、系统预留 5%。超过硬水位的候选直接过滤;超过软水位的累加风险分(每超 1 个百分点:内存/CPU 各 100、大页 50,总和上限 5000),PSI 风险项默认关闭。指标缺失、过期或处于首样本阶段时,对应候选退回原有选点逻辑。E2B 从快照恢复时按快照里的实际规格评估。
  - 对比:这是在 kube-scheduler **之外**、对「已就绪 Agent Pod 槽位」做的二级放置(K8s 只负责调度 Agent Pod,沙箱放到哪个 Pod 由 SandboxSched 决定),思路接近 Koordinator 的负载感知调度,但作用对象是沙箱而不是 Pod。文档也写明它不改变 K8s 对 Agent Pod 的调度规则,不迁移已运行的沙箱。
  - 启示:做 agent 沙箱资源面时,**「requests 装箱」不够**:沙箱实际内存/CPU 波动大,大页是 Firecracker/Kata 类 VMM 的硬依赖。需要「实测水位 + 软硬阈值 + 风险分」,并显式定义指标不可用时的回退路径。

- [SandboxSched:amd64/arm64 异构混合池调度](https://gitcode.com/openFuyao/SandboxSched/commit/258e830260499ed0325f793aaf37124fc7463bed)(2026-11-16)+ [E2B 快照端到端 !155](https://gitcode.com/openFuyao/SandboxSched/commit/5593ae3715f636b5596c12ad9133dd3d67c68614)(2026-11-19):混合池调度方面,目标架构的优先级是「调用方显式 arch > E2B 模板注解」,两者冲突返回 400;零存量的混合架构池无法推断 arch 时返回 400,不会猜。SandboxGroup status 新增 `platforms` 架构清单(仅用于观测,不作为约束)。快照方面实现了 E2B SDK 兼容的 `POST /sandboxes/{id}/snapshots`、`GET /snapshots`,删除沿用 E2B 的 `DELETE /templates/{id}` 路径;返回的 `snapshotID` 是注册表 ID 而不是镜像 URI,创建沙箱时 `templateID` 会先当作快照 ID 查找。同期还有 [!153 创建路径串行化、减少账本往返](https://gitcode.com/openFuyao/SandboxSched/commit/6fa5dab4b58529921dc9c1a9a6489eb34865430c)(附 E2B 压测工具)和 [!164 SandboxGroup / Agent Pod 槽位观测指标](https://gitcode.com/openFuyao/SandboxSched/commit/fb71537fee3ccbd985adab662b84c2f4b0f31250)。
  - 对比:北向直接兼容 **E2B SDK 协议**,不走 K8s CRD(上游 kubernetes-sigs/agent-sandbox 的 Sandbox/SandboxClaim 走的是 CRD)。OpenFuyao 选的是「生态 SDK 兼容 + 自研控制面」。混合架构调度对应的是鲲鹏 + x86 混部的现实需求。
  - 启示:做 agent 沙箱产品,北向协议要早定:兼容 E2B SDK,存量 agent 框架可以零改造接入;走 CRD,则与 K8s 生态的一致性更好。OpenFuyao 押了前者。快照「ID 不暴露镜像 URI」的契约设计值得照搬,可以避免客户端绑定存储实现。

- [agent-sched-nex(ASN):Agent 运行治理平台,orchestrator 快照/销毁生命周期](https://gitcode.com/openFuyao/agent-sched-nex/commit/ecc258f9128c081587e83fb0961fb6fc6b08dc26)(2026-11-18,本周 52 个提交;仓库 8 月建,首次纳入扫描):定位是「你带 Harness,平台给运行环境」。架构分三层:控制面、编排与执法面、沙箱系统(沙箱系统不在本仓,可对接 SandboxSched/E2B)。三条契约分别是 A2A 北向、「创建/注入/快照/销毁」四操作沙箱契约(配有 `asn-sandbox-tck` 一致性套件),以及「声明编译成不可变 Revision,越界拒绝」。组件包括 Rust 写的 asn-router/asn-egress(出网裁决 + 凭证注入)、Go 写的 asn-identity(SVID/NHI 目录)和三账本观测。本周:orchestrator 加入幂等操作键、分阶段销毁记录、崩溃安全存储,以及 pause/resume/delete/observe;[Session 生命周期 REST 迁到 Management API](https://gitcode.com/openFuyao/agent-sched-nex/commit/dee0d1002897260bca20e7141ca41c38a2c497aa);byoh-shim 接入 approval/spool/遥测断点。
  - 对比:对标对象是 AWS Bedrock AgentCore Runtime、E2B + 自建 harness 这一类,**不是 KServe/OAI 模型服务**。用 A2A 而非自定义 RPC 作为平台↔Harness 的唯一接口,与 Google A2A 生态同路。
  - 启示:OpenFuyao 的 agent 栈已经分成「沙箱调度(SandboxSched)/ 运行治理(ASN)/ 推理(InferNex)」三层,并靠契约解耦。我们如果做 agent runtime,最值得参考的是「沙箱四操作 + TCK 一致性套件」:它让多家沙箱后端可替换,是平台化的关键。

- [ubs-k8s-enable:cgroup v2 节点上动态共享内存设备的非特权授权](https://gitcode.com/openFuyao/ubs-k8s-enable/commit/82764a5bd5057dab4cf1654b0d760c37947861d1)(2026-11-20,首次纳入扫描):问题背景是 cgroup v2 取消了 `devices.allow`,设备访问由 runc/containerd 在容器创建时挂载的 BPF_CGROUP_DEVICE 程序决定,**创建后动态出现的共享内存设备进不去非特权容器**。新增 `deviceperm` 模块,attach 时授权、detach 时无条件回收;kubelet 用 systemd 驱动时,改走 systemd dbus `SetUnitProperties` 写设备规则,避免 systemd reload 重新生成 eBPF 程序时冲掉授权。授权状态会持久化,CSI driver 重启后仍能回收。后续还有 [shmFlowMu 统一串行化 attach/detach/recycle 流程](https://gitcode.com/openFuyao/ubs-k8s-enable/commit/94da652fc820f25e14e5cbda53c1a29e51100072) 等加固(11-21~23)。
  - 对比/区分:业务属于 UB 共享内存(matrixshm CSI),**昇腾/UB 专用**,但「cgroup v2 下给运行中容器追加设备权限,并与 systemd 驱动保持一致」是**通用 K8s 问题**:GPU 热插拔、vGPU 动态挂载、RDMA 设备晚绑定都会遇到。上游的正规解法是 DRA + CDI 在容器创建前注入设备,这里属于「创建后追加」的旁路。
  - 启示:我们若有任何「运行时动态挂设备」需求,cgroup v2 是硬坑。要么前移到 DRA/CDI 创建期注入(推荐),要么像这里一样走 systemd dbus,并做好持久化和回收,不能直接改 cgroup 文件或 eBPF。

## AI 推理栈(InferNex / hermes-router / cache-indexer / eagle-eye)
- **kv-conductor 链路本周成形**(详见上一节):producer(11-12,窗口外)→ 聚合 scorer(11-18)→ PD scorer(11-19)→ DP rank 头(11-23),加上 cache-indexer registrar(11-20)。尚未看到 InferNex chart 把 kv-conductor 子 chart 合入(InferNex 树里还没有 conductor 相关文件),目前 hermes-router 的两份 example profile 要求 conductor「带外部署」。预计下一步是 InferNex 一键部署纳入 conductor + registrar。
- [hermes-router session-foundation !114](https://gitcode.com/openFuyao/hermes-router/commit/096155930ea0c2232b5caaab19a89184e04b565d)(2026-11-20,+1159 行,目前仅有 internal 包,未接入插件):进程内会话绑定表(会话 ID 上限 256 字节,超长退化为不绑定;容量满时先淘汰过期条目,再淘汰最久空闲的;用 Lease 防止旧绑定覆盖新绑定),以及保守的「可否改绑」分类器 `CanRebind`:只有「自包含的生成请求」(完整历史随请求携带)才允许把会话改绑到别的 endpoint;带后端状态引用或未知控制字段的请求一律 fail-closed。这是给多轮/agent 会话做粘性路由的地基。与 llm-d 当前以前缀命中隐式实现会话亲和不同,这里是显式绑定 + 安全改绑判定。值得跟进它接入 scorer 之后的形态。
- [hermes-router !103 恢复 chart 默认 data layer 指标](https://gitcode.com/openFuyao/hermes-router)(11-19):修复 chart 渲染问题。
- [InferNex !284 硬件检查器小缺陷修复](https://gitcode.com/openFuyao/InferNex/commit/7d5801a1aa28c727e460f4bcf4220a04f5f7fa9d)(11-20):部署前硬件预检修复,无能力变化。
- [eagle-eye !44 时钟检测单样本误报修复](https://gitcode.com/openFuyao/eagle-eye)(11-19)、[sig-ai-inference !230 InferNex 健康检查聚合器使用指南](https://gitcode.com/openFuyao/sig-ai-inference)(11-16):可观测侧的完善,健康聚合器(health-aggregator,InferNex 11-10 合入配置)开始出用户文档。
- `weight-dispatcher`、`elastic-scaler` 本窗口无提交。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)
> 以下均为昇腾专用;mind-cluster 的逐 commit 细节见 compute-ascend-watch 11-18~11-21 日报,这里只列与本 task 对标视角相关的部分。

- [软切分 vNPU 接入节点侧 enpu-manager](https://gitcode.com/Ascend/mind-cluster/commit/dea383756611b0cacb4cae0f402bfc6d3bac8059)(2026-11-18,part1~3):device-plugin 检测到 `/run/enpu/enpu-manager.sock` 时,软切分分配改由该守护进程完成(AI Core 配额 1~100%、HBM 配额、调度策略),每 30s 回收孤儿分配;npu-exporter 新增 `enpu` 指标组(默认关),输出 vNPU 级利用率、HBM 用量和配额。对比:与 HAMi 的 HAMi-core(容器内 LD_PRELOAD 拦截)不同,这是**节点守护进程集中管理切分配额**的路线,更接近 NVIDIA MPS control daemon 的形态。启示:软切分要做成「可观测、可回收」,需要一个节点级权威账本,不能只靠容器内拦截库自报。
- [DRA 新增 `deviceResetTimeout` 参数校验 [10,600]](https://gitcode.com/Ascend/mind-cluster/commit/6b52d9a5a21ca0ba90b114d0bd019a4c0bf7335b)(11-16):小改动。DRA 主线的大变化(收缩为仅支持 A5)发生在缺口期,见文首说明。openFuyao 侧 `npu-dra-plugin` 本窗口零提交(HEAD 仍是 11-02 的 !42)。
- [rdma-shared-dev-plugin 改为把 RDMA 设备交给 ascend-docker-runtime 注入](https://gitcode.com/Ascend/mind-cluster/commit/5381f5f421b615d02e498a87dd6ea757b3d8872c)(11-18):写 `ASCEND_RDMA_DEVICES` 环境变量,由 runtime hook 挂载 1825 RoCE 设备,同时删除「按 NPU 关联分配 DPU」的逻辑。注意该链路**只走 legacy 模式,CDI 模式下会被忽略**,与上游 CDI 方向相反。
- [DCMI 错误码结构化 + 分类](https://gitcode.com/Ascend/mind-cluster/commit/7c98a89868acf5afebe7e5e410c544a306bdaa2e)(11-19):把「不支持/需升级驱动」从真实故障里区分出来,减少 A3/A5 混部时的误告警。今日(11-23)又合入 [device-plugin 容器扫描区分「未运行」与「解析失败」](https://gitcode.com/Ascend/mind-cluster/commit/bccebcc17018c79de3941eb4505d72ed9c126e81),同属降误报。
- `npu-operator`、`vNPU`、`npu-container-toolkit`、`kae-operator`、`npu-feature-discovery`、`ub-network-device-plugin`、`ub-network-bandwidth-operator` 本窗口零提交。`equivalent-compute-unit` 11-18 建仓,只有 Initial commit。

## 调度 & 集群(volcano / 故障运维 / 集群生命周期)
- [Volcano 亲和性降级退避改为全局默认开启,并支持 A5 与多级调度](https://gitcode.com/Ascend/mind-cluster/commit/d590d43fab18438bb9ad5b190d563cd306b1b809)(11-18):删除作业级开关注解 `huawei.com/scheduler.downgrade`,改为全局窗口(默认 120s),作业级用 `huawei.com/scheduler.downgrade.timeout` 覆盖(-1 关闭)。配合 [pod error 退避改用 volcano 主机时钟](https://gitcode.com/Ascend/mind-cluster/commit/7f51aac6da6b422bff37ebddccf7b74e5458a38d)(11-19,消除节点间时钟偏差)。对比:上游 Kueue/Volcano 的拓扑感知调度在拓扑约束不满足时一般是一直 pending,或靠 TAS 的 `preferred` 语义一次性放宽;昇腾这里是**带时长窗口的分级降级**,等够窗口时间就逐级放宽拓扑要求。启示:我们的拓扑感知调度应提供「等多久再降级」的时间维度,并且默认开启,否则大作业会在碎片化集群里无限等待。
- [ascend-clusterops-agent:随包 LLM 运维 Agent](https://gitcode.com/Ascend/mind-cluster/commit/196d56e682e8bce938d9a379752f5386486ba0ad)(11-19~21,约 121 文件):ReAct 对话(langchain + langgraph)、SSE WebUI、技能宿主,加上四类**只读**查询工具(故障设备/隔离设备/集群资源/任务状态,全部经一个没有写动作的 KubernetesReadGateway 访问);注册期强制「查询类工具只读」的配对约束;[9743 端口认证 HTTPS 第二监听](https://gitcode.com/Ascend/mind-cluster/commit/3a4ccb9f7f393b29de58074bf41302d333d9dbf3)(自签证书 + 共享 token 走 Secret 引导,TLS 1.2 下限)。对比:OAI/OpenShift 侧对应的是 OpenShift Lightspeed(集群级运维助手,外挂式)。这里把领域专用 Agent **随加速卡运维组件一起发**,只读数据面直接读 ClusterD 的 ConfigMap。启示:我们做 GPU 集群运维助手时,「工具注册期强制只读/写入分级」和「只读网关从类型上杜绝写动词」两条护栏值得照抄。
- [ascend-faultdiag 掉卡联合诊断](https://gitcode.com/Ascend/mind-cluster/commit/9c4d76956d2d5eaebc09442ea7b66aa95bcf7dc8)(11-20):以 BMC `sel.txt` 掉卡告警为时间锚点,比对前 1 分钟内的 host 侧 kernel/bbox 证据,按模式表判定 UCE_PANIC、HBM OOM、SMMU 超时等根因。偏硬件专用,通用可借鉴的是「带外(BMC)事件锚定 + 带内日志时间窗关联」这一诊断范式。
- [cluster-api-provider-bke !520 自管理集群迁移](https://gitcode.com/openFuyao/cluster-api-provider-bke/commit/1d775fc53e99f63a664f7af2245374bc1db1f2af)(11-21)和 [!530 状态机保留 DAG 失败态以便人工介入](https://gitcode.com/openFuyao/cluster-api-provider-bke/commit/4f63b38500e56fcca209be133eb3aa10a0b3fed5)(11-19):BKECluster 迁移成自管理集群(Spec 克隆 + status 选择性迁移);DAG 失败后不再自动回滚覆盖失败现场。另有 !525 worker kubeconfig 指向 HA 端点。属通用 Cluster API 实践,与 OpenShift 的 Hive/HyperShift 同类问题。
- `volcano-ext` 零提交;`sig-orchestration-engine` 只更新 KubeVirt 镜像构造文档;`bke-manifests` 只有一处 victoriametrics-operator 固定到控制面节点。

## 官方动态
- **本窗口无版本发布,也无社区运作报告**。CSDN 最新的版本公告仍是 v26.09(10-08),运作报告仍是 8-9 月(10-18)。按季度节奏,下一版是 v26.12(年底 LTS 窗口)。代码侧 mind-cluster 在 11-18 打了 `v26.3.0-beta.2`(上游 MindCluster 自身的 beta,不是 openFuyao 发版);openFuyao 各仓 tag 仍停在 `v26.9.0`。
- 11-16 CSDN 发了三篇**下游商用发行稿**:[KunLun AI 解决方案融合 openFuyao](https://blog.csdn.net/openFuyao/article/details/170865118)(河南昆仑技术,基于社区版的商用发行版,覆盖通算/智算统一编排含虚机容器共管、鲲鹏+昇腾异构算力池化调度、轻量推理;文中没有给版本号或组件名)、[优刻得孔明智算平台携手 openFuyao](https://blog.csdn.net/openFuyao/article/details/170864769)、[中科弘云 HyperLM V2.5](https://blog.csdn.net/openFuyao/article/details/170864134)(后两篇抓取失败,只有标题)。连同 11-02 的品高 BingoAIInfra V2.0-FY,**一个月内已有 4 家 ISV/云厂商宣布基于 openFuyao 出商用版**。这说明 OpenFuyao 正在复制「社区上游 + 多家商业发行版」的 OpenShift/OKD 式生态,我们在这些厂商客户里遇到的竞品,底座会越来越多是 openFuyao。
- 官网 www.openfuyao.cn 新闻/博客/活动三个板块仍显示「暂无内容」,发布信息以 CSDN 为准。
- 缺口期(11-03~11-15)的官方文章,只列标题不展开:11-12 [技术讲堂:AI 推理 KVCache 索引管理](https://blog.csdn.net/openFuyao/article/details/168341945)(对应本周 cache-indexer/kv-conductor 链路)、11-13 [技术讲堂:vNPU 算力切分与动态调度](https://blog.csdn.net/openFuyao/article/details/170707606)、11-12 [openFuyao x 联通云 Meetup:Agent 规模化走向生产](https://blog.csdn.net/openFuyao/article/details/170603253)、11-12 [基于 KubeVirt 的容器与虚拟机统一编排](https://blog.csdn.net/openFuyao/article/details/163672444)。

## 跟我们产品的对比
- **同一路线(应对齐)**:
  - 推理网关基于 GIE EPP 插件体系做 KV 感知路由,数据源从近似前缀哈希升级为「引擎 KV events → 全局索引」。这和 llm-d 走的是同一条路,我们的推理网关也应以 GIE EPP 为底座。
  - 软切分配额由节点守护进程集中管理,并输出 vNPU 级指标(延续上期「消费者粒度可观测」的结论)。
  - 故障/降级相关默认值逐步改为「默认开启 + 时长窗口」:静默故障检测、亲和性降级退避都已默认开启。
- **OpenFuyao 独有 / 分叉(可借鉴的通用部分)**:
  - **DP rank 级 KV 路由**、**NPU/CPU/Disk 分级介质加权**:都是 llm-d 目前没有的维度,与 KV 池化强绑定。
  - **KV 索引注册的 K8s 原生对账**(label 发现 + 去抖 + 周期全量对账 + 所有权前缀)。
  - **Agent 三层栈**:SandboxSched(E2B 兼容 + 资源水位 + 混合架构)/ ASN(A2A + 四操作 TCK)/ 随包运维 Agent。OAI 目前没有对等的 agent 沙箱资源面。
- **昇腾/UB 专用(记录,不照抄)**:enpu-manager、1825 RoCE 设备注入(legacy-only,与 CDI 相反)、UB 共享内存 CSI、DCMI 错误分类、BMC 掉卡诊断。
- **我们该补的**:
  1. 推理网关 KV 打分模型加入**介质**维度和 **DP rank** 维度(前提是支持 KV offload,以及单 Pod 多 DP rank 部署)。
  2. 拓扑感知调度提供「降级等待窗口」,并默认开启。
  3. 如果要做 agent 沙箱:先决定北向协议(E2B SDK 兼容还是 CRD),并定义沙箱后端的四操作契约和一致性套件。
  4. 运行时动态挂设备的需求统一前移到 DRA/CDI 创建期,避开 cgroup v2 下追加授权的坑。

## 值得跟进
- [ ] 读 hermes-router `examples/profiles/pd-kv-conductor.yaml` 和 `kvconductor/plugin.go` 的 `flattenMatches`/`weightedTokens`,对照 llm-d precise-prefix-cache-scorer,评估我们网关加「介质权重 + DP rank 头」的改造量。
- [ ] 确认 kv-conductor 本体来自哪个仓(hermes-router 和 cache-indexer 都只有客户端/registrar,服务端未在已扫仓库中出现),以及它与 Mooncake/YuanRong 的事件订阅协议。
- [ ] 跟踪 hermes-router session-foundation 接入 scorer 后的会话粘性/改绑语义,与 llm-d 的会话亲和方案对比。
- [ ] 用 E2B Python SDK 试跑 SandboxSched 的 e2b-face(create / snapshot / create-from-snapshot),验证其 E2B 兼容度,作为我们 agent 沙箱北向协议选型的输入。
- [ ] 读 agent-sched-nex 的 `asn-sandbox-tck`,看四操作契约的具体断言,评估能否作为我们沙箱后端抽象的参考。
- [ ] 持续监测 CSDN 上 v26.12 发版公告(年底 LTS 窗口),以及 `equivalent-compute-unit`(算力等效单元)出代码。
- [ ] 申请/配置 `GITCODE_TOKEN` 写入 `.env`:本期 GitCode v5 匿名 API 因共享账号超限返回 429,依赖 API 的 compute-ascend-watch 也会受影响。

## 原始材料

<details>
<summary>本次扫描清单(2026-11-16 -> 2026-11-23)</summary>

取数方式:GitCode v5 API 返回 429(`p_repoRobot` 共享账号超阈值),全部改用 `git clone --bare --filter=blob:none` 本地读 `git log --since=2026-11-16`;组织清单用 https://gitcode.com/openFuyao 首页交叉核对(页面显示共 128 个仓,只展示部分)。

有信息量:
- https://gitcode.com/openFuyao/hermes-router(8 个提交)
  - 11-18 !106 c955fea kv-conductor 聚合模式 KV 感知 scorer
  - 11-19 !107 9c07904 kv-conductor PD 模式 scorer + score/weights.go 共享 PD 权重流水线
  - 11-19 !103 c375010 chart 恢复默认 data layer 指标
  - 11-20 !114 0961559 session-foundation(classifier.go + store.go,+1159,未接插件)
  - 11-23 !108 209a9df/d1ca440 kv-conductor dp-rank 请求头插件 + aggregate/pd 两份 example profile
  - (窗口外 11-12 !97 c7e7e42 kv-conductor data producer)
- https://gitcode.com/openFuyao/cache-indexer
  - 11-20 !55 8ee4f1e registrar sidecar:引擎 per-rank 注册 + Mooncake 池自动注册(+3103)
- https://gitcode.com/openFuyao/SandboxSched(59 个提交)
  - 11-16 258e830 异构(amd64/arm64)混合池调度(PlatformSpec / targetPlatform / SandboxGroup status.platforms)
  - 11-17 !153 6fa5dab 创建路径串行化、减少账本往返 + E2B 压测工具
  - 11-19 !155 5593ae3 E2B 快照端到端(snapshot_service.proto,e2b-api-guide.md)
  - 11-19 !163 sandboxlet 在 runtime socket 重建后存活(issue #43);11-20 !166 镜像亲和排序修复
  - 11-22 !164 fb71537 SandboxGroup / Agent Pod 槽位观测指标
- https://gitcode.com/openFuyao/sig-agent-sandbox
  - 11-23 !20 3c2c3d5 SandboxSched 节点资源感知调度配置与使用说明
- https://gitcode.com/openFuyao/agent-sched-nex(首次纳入;52 个提交)
  - 11-18 ecc258f orchestrator 快照/销毁生命周期(幂等操作键、分阶段销毁、崩溃安全存储)
  - 11-19 dee0d10 Session 生命周期 REST 迁到 Management API;11-17 byoh-shim 四项运行期断点接线;11-18 website + 沙箱库存统一部署
- https://gitcode.com/openFuyao/ubs-k8s-enable(首次纳入;12 个提交)
  - 11-20 82764a5 cgroup v2 节点共享内存设备授权(deviceperm,systemd dbus SetUnitProperties)
  - 11-21 94da652 shmFlowMu 串行化 attach/detach/recycle;11-21~23 回滚/回收一致性修复若干
- https://gitcode.com/Ascend/mind-cluster(11-16 起 126 个提交,含 merge;tag v26.3.0-beta.2 @ f3bfc6c 11-18)
  - 11-16 6b52d9a DRA deviceResetTimeout [10,600] 校验
  - 11-18 25b77b0/dea3837/cde7c47 软切分接入 enpu-manager + npu-exporter enpu 指标
  - 11-18 d590d43 volcano 亲和性降级退避支持 A5 与多级调度,改为全局默认开启
  - 11-18 5381f5f rdma-shared-dev-plugin 改由 docker-runtime 注入 1825 设备
  - 11-19 7c98a89 DCMI 错误码结构化分类;11-19 7f51aac pod error 退避改用 volcano 主机时钟;11-19 8923063 存在 vNPU 时 NetworkUnhealthy 同步修复
  - 11-19~21 ascend-clusterops-agent:5a47065 查询契约 / bbbbabf ClusterD 解析 / 040d093 工具化汇总 / dcc1937 五类运维技能 / 196d56e ReAct + WebUI / d035c43~3a4ccb9 HTTPS 双监听 5 连发
  - 11-17~20 FD 掉卡故障模式库 Part1~10、35309eb 诊断底座、a5b1c5d BMC/kernel 解析、9c4d769 lost_device 诊断与 prechecker;11-19 6db4c21/a7e98a2 UB 链路诊断改用 kernel.log 数据源
  - 11-20 c6430a3 交换机故障查询失败时保留上次结果;11-23 bccebcc 容器扫描区分「未运行」与「解析失败」
- https://gitcode.com/openFuyao/cluster-api-provider-bke
  - 11-17 !527 wait 超时错误包装;11-19 !525 worker kubeconfig 指向 HA 端点;11-19 !530 状态机保留 DAG 失败态;11-21 !520 自管理集群迁移
- https://gitcode.com/openFuyao/InferNex:11-20 !284 硬件检查器修复
- https://gitcode.com/openFuyao/eagle-eye:11-19 !44 时钟检测单样本误报修复
- https://gitcode.com/openFuyao/sig-ai-inference:11-16 !230 eagle-eye 健康聚合器使用指南
- https://gitcode.com/openFuyao/openfuyao-powers:11-18 !85/!87/!91~!94 技能安装器/文档一致性检查/技能治理的修复(无新技能)
- https://gitcode.com/openFuyao/docs:约 12 个 MR,全是拼写/示例修正;!1515 健康聚合器通信矩阵
- https://gitcode.com/openFuyao/sig-installation:!283 local-harbor 迁移 FAQ、!284 bke 调试日志级别(文档)
- https://gitcode.com/openFuyao/sig-orchestration-engine:!157 KubeVirt 镜像构造说明(文档)
- https://gitcode.com/openFuyao/bke-manifests:11-17 victoriametrics-operator 固定到控制面节点

官方源:
- https://blog.csdn.net/openFuyao:窗口内只有 11-16 三篇合作伙伴稿(170865118 / 170864769 / 170864134);无发版、无运作报告
- https://www.openfuyao.cn/zh/:新闻/博客/活动三个板块「暂无内容」

本窗口零提交(HEAD 日期):
- npu-dra-plugin(11-02)、vNPU(10-28)、npu-operator(10-10)、npu-container-toolkit(10-10)、npu-feature-discovery(10-09)、kae-operator(09-20)、elastic-scaler(09-16)、volcano-ext(09-07)、weight-dispatcher(08-25)、npu-driver-installer(07-23)、ub-network-bandwidth-operator(06-15)、npu-node-provision(05-27)、ub-network-device-plugin(11-10)
- equivalent-compute-unit:11-18 只有 Initial commit

tag:openFuyao 各仓最大 tag 仍为 v26.9.0;mind-cluster v26.3.0-beta.2(11-18,MindCluster 自身 beta)。
</details>
