# OpenFuyao 周报 2026-05-25

窗口:2026-05-18 → 2026-05-25(7 天)

## 摘要

- **InferNex-Bridge 正式合入 master**(2026-05-22),上周还在 feature 分支的 KServe `LLMInferenceService` → `InferNexService` 翻译层落地;同时把 InferNex 自带 CRD 改为压缩存储、解除 Git LFS 跟踪。这意味着 v26.06 主线推理控制面以"KServe 入口 + InferNex 厂内 CR"双层架构定稿。
- **cluster-api-provider-bke 启动 OpenShift 式集群升级模型**(`feat/upgrade-530` 分支):2026-05-18~25 一周内连续落 `ClusterVersion` / `UpgradePath` / `ReleaseImage` / `ComponentVersion` 四个 CRD,UpgradePath 走 OCI artifact 加载升级图、配 PreCheck 规则、单实例 webhook 约束 — 结构跟 OpenShift CVO + Cincinnati 几乎 1:1。这是 OAI 对比维度上**第一次出现成型的平台级升级控制面**。
- **cache-indexer 悄悄从 Python 重写到 Go**(`feat/go-refactor` 分支),L1(vLLM KV event 本地索引)+ L3(Mooncake HTTP poller)两级架构成型,本周对齐 Mooncake admin wire format / 完成 segments 反查 / 实现 L3 hit-rate=1 的端到端验证。同期 InferNex 主仓修 Mooncake master 资源限额、prefill/decode/aggregated 节点亲和。

## 新功能 / 能力

- [InferNex-Bridge 合入 master](https://gitcode.com/openFuyao/InferNex/-/commit/176eff8) — KServe `LLMInferenceService` 适配器、Mutating/Validating Webhook、InferNexService/Config 全套落到 `component/InferNex-Bridge/`;CRD 压缩存储、去 LFS 跟踪规则;chart/RBAC、eagle-eye 修复一并合入
  - 启示:**双层架构正式定稿** — 用户面用 KServe `LLMInferenceService`(v1alpha1)进集群,Bridge 翻译成 `InferNexService` 拉起 vLLM-Ascend + hermes-router + Mooncake + cache-indexer 全家桶。这等价于 OAI 的 `odh-model-controller → KServe InferenceService` 解耦,但 OpenFuyao 提前押注了 KServe 0.17 新引入的 `LLMInferenceService`,**比 OAI 当前主用的 v1beta1 `InferenceService` 早一代**。我们做 KServe 驱动的推理产品,这是判断"是否跟进 LLMInferenceService 路径"的时间窗口
- [cluster-api-provider-bke 引入 ClusterVersion / UpgradePath / ReleaseImage / ComponentVersion 四 CRD](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/244e9c1) — `feat/upgrade-530` 分支 2026-05-18 起连续推:ClusterVersion 跟踪 desired/current 版本与升级历史(Pending/Installing/PreChecking/Upgrading/Blocked/Failed 等 10 个 phase);UpgradePath 从 OCI artifact 加载升级图(From/To/Blocked/Deprecated/PreCheck);[ReleaseImage](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/9fa3d11)、[ComponentVersion](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/295f050)、[UpgradePath webhook 限定单实例](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/59540b9)
  - 启示:**这是上周对比表里 OAI 强、OpenFuyao 空白的"集群生命周期管理"被补齐的信号**。模型几乎是 OpenShift CVO + Cincinnati 移植:OCIRef 拉升级图 + PreCheck 必/选项 + Blocked/Deprecated 边、单 webhook 约束唯一性。我们如果要做"产品化的 K8s AI 平台",**升级控制面是绕不过的一环**,这套抽象可以直接借鉴(尤其 OCI artifact 作为升级图分发载体的做法,比自建 API 服务更轻)。注意分支名 `upgrade-530` 暗示目标版本(可能对应 26.05.30 或某个内部里程碑),需要在下一个 release-management 发版周期里验证是否进入 v26.06 GA
- [cache-indexer 启用 Go 重写主线 feat/go-refactor](https://gitcode.com/openFuyao/cache-indexer/-/commits/feat/go-refactor) — L1(本地索引,消费 vLLM KV event)+ L3(Mooncake HTTP poller 远端池)两级架构;本周关键 commit:[L3 hit-rate=1 端到端](https://gitcode.com/openFuyao/cache-indexer/-/commit/7bacfff)(segments 反查 + URL escape + hash 截断 + ctx 对齐)、[discovery 支持 pdRole aggregate](https://gitcode.com/openFuyao/cache-indexer/-/commit/6a7424e)、[prefill/decode pod 识别 label 统一到 pdRole](https://gitcode.com/openFuyao/cache-indexer/-/commit/c0869bf)、[加入 Mulan 协议头与测试](https://gitcode.com/openFuyao/cache-indexer/-/commit/03e30a9)
  - 启示:**KVCache 池化从"原型 Python"演进到"产品级 Go"**,且新结构明确拆 L1/L3 分层(L1 本地内存索引、L3 走 Mooncake 远端池),把"按 prefill/decode/aggregated 角色聚合发现实例"做成一等公民。这条架构思路**通用 GPU 集群同样能用**:GPU + LMCache 或 LMQ 替换 Mooncake,L1/L3 抽象不变。对照我们的 KVCache 策略选型,如果走自研路线,可以直接参考这个 L1+L3 二级模型;如果走 vendor 接入,本周 `feat/go-refactor` 分支的 `pkg/index/` 是值得通读的实现范本
- [weight-dispatcher 新仓建立](https://gitcode.com/openFuyao/weight-dispatcher) — sig-ai-inference 下新公仓,描述"加速推理场景中模型权重下载、分发的速度",分支 `feat/node-warm-up` 已建,代码仅 README 占位
  - 启示:**模型权重分发**(P2P / 节点预热 / 异步推送)是一直缺位的能力 — KServe `StorageInitializer` 仅做单点拉取,vLLM 也只有本地缓存。OpenFuyao 把这个能力做成独立组件而不是塞进 InferNex,意味着可被独立消费。下周看实际代码进展,如果落地的是 P2P / pre-warm 之类思路,通用 K8s AI 栈可以借鉴;如果只是 Volcano-job-style 的拉取作业,价值有限
- [社区新增 sig-dongting(洞庭)](https://gitcode.com/openFuyao/community/-/commit/446e359) — 新 SIG "负责计算、存储、查询组件的设计和实现",登记 7 个私仓:`dongting-compute`、`hofs-client/proxy/osd`(HOFS 存储集群三件套)、`uql-parser/core/service`(UQL 查询语言),仓位均标 `type: private`,代码未公开
  - 启示:**OpenFuyao 范围超出 AI 推理/训练,正在把大数据栈(计算引擎 + 分布式存储 + 查询语言)纳入** — 这跟 K8s + AI 不同维度。短期对我们产品**无直接借鉴**,但提示 OpenFuyao 定位在向"统一 K8s 集群软件栈"扩张,后续可能跟 AI 工作负载在同一集群内混部(对照下面 sig-Colocation 的 feat/dev-630 分支动作)
- [olc-python 准入策略算法框架成型](https://gitcode.com/openFuyao/olc-python/-/commit/5dab22a) — 2026-05-20~21 连续 PR:`olc/alg/admission/` 目录引入并发准入算法 + 默认 [APA 算法](https://gitcode.com/openFuyao/olc-python/-/commit/e330fd0);本周修了令牌桶回滚、速率更新、单机流控不依赖 redis 等多个 bug
  - 启示:olc(overload control)是面向 Python 服务的过载保护库,**适用场景就是 vLLM/inference 引擎前置保护**(看名字一致是上周登记的 `olc-python` 占位仓在补能力)。准入算法 + 令牌桶 + 单机/分布式双模式,跟通用网关层做请求级速率限制的思路一致,但放在引擎进程内可以拿到更精细的并发上下文(prompt 长度、KV 占用)。我们如果在自家网关层做 LLM 过载保护,**APA + 并发准入这两个算法的实现可以直接读**

## AI 推理栈(InferNex / hermes-router / ...)

- [InferNex 修 Mooncake master/metadata server 资源限额](https://gitcode.com/openFuyao/InferNex/-/commit/5fde610) — `inference-backend` chart 补 mooncake-master / mooncake-metadata-server 的 resource limits,proxy-server 同步调整;前置铺垫生产部署
- [InferNex 节点亲和按 prefill/decode/aggregated 三档分别配置](https://gitcode.com/openFuyao/InferNex/-/commit/37fba09) — 三个 deployment 模板分别支持独立的 nodeAffinity 表达式,意味着部署上可以把 prefill 钉到大显存节点、decode 钉到高带宽节点
- [InferNex proxy-server 锁死 kubernetes client 35.0.0](https://gitcode.com/openFuyao/InferNex/-/commit/c559cc8) — 上游 client 36.x 要求手动注入 token,降级回 35;**这是个值得我们引以为戒的兼容性坑**(K8s client 库 36.x.x 行为变化对 in-cluster proxy 不友好)
- [hermes-router](https://gitcode.com/openFuyao/hermes-router/commits/master) — 主仓本周 0 commit;上周大改后进入"稳定观察"模式,GIE v1.3.0 已经落,等下游消费

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [mind-cluster infer-operator 实例级重调度:故障感知与记录](https://gitcode.com/Ascend/mind-cluster/-/commit/1c34e708b) — 新增 `pkg/controller/rescheduling/rescheduling.go`(285 行)+ 测试(577 行),`InstanceSet` 控制器接入故障感知;另有 [statefulset workload 接口](https://gitcode.com/Ascend/mind-cluster/-/commit/8b48dc45f)(deployment_handler + statefulset_handler + workload_handler/reconciler,~1400 行)— infer-operator 从"InstanceSet 单体"升级到"按 workload 抽象的实例级调度"
  - 启示:**注意这是 mind-cluster 的 infer-operator 而非 InferNex**(参见 [2026-04-17 双控制面 deep-dive](./2026-04-17-openfuyao-infer-operator-vs-infernex.md))— 这一侧持续在补"故障驱动的实例级重调度"能力,跟昇腾 NPU 故障码深度耦合;而 InferNex 侧借助 KServe 自动伸缩走的是"声明式状态"路径。两套并存的局面持续到 v26.06 没解
- [mind-cluster k8s-rdma-shared-dev-plugin 原生开源化 + UB 支持](https://gitcode.com/Ascend/mind-cluster/-/commit/b9a7e9d0a) — 直接把 Mellanox 上游 [k8s-rdma-shared-dev-plugin](https://github.com/Mellanox/k8s-rdma-shared-dev-plugin) 镜像到 `component/k8s-rdma-shared-dev-plugin/`(完整 GitHub Actions / Dockerfile / 文档),后续 [k8s-rdma-dp 新增 UB 支持](https://gitcode.com/Ascend/mind-cluster/-/commit/e7558ad05);**这是 UB(超低时延)网络第一次和通用 RDMA 在同一 DP 里同时支持的迹象**
  - 启示:UB 是昇腾专属网络,但和 Mellanox RDMA 走同一 device-plugin 接口意味着两类硬件可以统一接入 Volcano/KServe 的网络资源调度。**对我们而言**,这条路径暗示"网络也作为可调度资源"是正确建模 — 后续如果做 GPU + InfiniBand 拓扑感知调度,可以参考 mind-cluster `k8s-rdma-shared-dev-plugin` + Volcano hypernode 的协同方式
- [mind-cluster device-plugin 对接 Volcano hypernode 增加 serverid topo 标签](https://gitcode.com/Ascend/mind-cluster/-/commit/967444f10) — `ascend-device-plugin/pkg/server/manager.go` 上报 NPU 拓扑时增加 serverid 维度,Volcano hypernode 调度可以按服务器层级亲和;对应上周 mind-cluster v1.10 适配
- [mind-cluster Volcano 热切失败回退至 Job 重调度时清理调度缓存](https://gitcode.com/Ascend/mind-cluster/-/commit/4068d4c68) — 热切(hot-swap)是昇腾断点续训关键能力,本次修的是 hot-swap 失败 fallback 到 Job rescheduling 路径上的缓存残留;[亚健康热切多级调度适配](https://gitcode.com/Ascend/mind-cluster/-/commit/6cda4d287) 同步落入
- [mind-cluster 添加 CANN 故障模式库 + OS/HBM 故障码](https://gitcode.com/Ascend/mind-cluster/-/commit/021ec6b88) — [ClusterD 新增故障码处理 OS 与 HBM 问题](https://gitcode.com/Ascend/mind-cluster/-/commit/1db9731b9),故障诊断维度持续扩张到 OS 层与 HBM 显存层
- [mind-cluster Atlas A5 设备适配启动](https://gitcode.com/Ascend/mind-cluster/-/commit/f72ac6be5) — 解析基础信息 + 故障诊断(FD)增加 A5 的 plog 清洗/诊断;A5 是 Atlas 下一代,本周首次出现适配代码,意味着硬件支持线已对齐
- [mind-cluster 文档侧移除静态 vNPU 调度内容](https://gitcode.com/Ascend/mind-cluster/-/commit/1cd8aa373) — 配合上周"取消静态虚拟化每次仅启动一个 Pod 限制",静态虚拟化作为推荐路径正在淡出,动态 vNPU 切分(A2/A3 共用)成为主线
- [npu-dra-plugin](https://gitcode.com/openFuyao/npu-dra-plugin/commits/br_init_dev) — 本周 0 commit;DRA 接入昇腾仍停留在上周归档的设计文档阶段(tag 仍是 1.0.0),节奏未加快
- [npu-operator](https://gitcode.com/openFuyao/npu-operator/commits/master) — 本周仅 1 个 PR 合并,无实质功能变更;[ub-network-device-plugin](https://gitcode.com/openFuyao/ub-network-device-plugin) 本周 0 commit

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- [cluster-api-provider-bke feat/upgrade-530 集群升级线](https://gitcode.com/openFuyao/cluster-api-provider-bke/commits/feat/upgrade-530) — 见"新功能"章节;附带 [logging 全量迁到 ologger](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/905f589) — 整个 controller 日志栈统一替换
- [cluster-api-provider-bke master fix](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/c5b8e62) — 修 BKE apt/yum 仓库 source 配置(common/source 大改 178/194 行)、修 kubelet.service 优先用 environment + 默认 hostname 用 kct 命令(对应上周 hostname 识别 bug)
- [elastic-scaler tidal 控制器修状态更新冲突](https://gitcode.com/openFuyao/elastic-scaler/-/commit/91fdb53) — `tidalscheduler_controller.go` 改 209 行 + 78 行测试,处理 status update conflict retry;tidal(潮汐调度,弹性扩缩单元之一)进入稳定化阶段;[同期 feat/ctx-metrics 落 APA 默认算法](https://gitcode.com/openFuyao/elastic-scaler/-/commit/e330fd0)
- [社区 sig-Colocation 新建 feat/dev-630 分支](https://gitcode.com/openFuyao/community/-/commit/c193ee8) — `colocation-management` 仓登记 6.30(June 30?)目标分支,在离线混部组件可能在 6 月底前出新版
- [volcano-ext](https://gitcode.com/openFuyao/volcano-ext)、[npu-dra-plugin](https://gitcode.com/openFuyao/npu-dra-plugin) — 本周仍 0 commit,沿用既有判断(volcano 扩展走 mind-cluster `component/ascend-for-volcano/`,volcano-ext 是历史仓位)

## 官方动态

- **开源一周年宣传文**(2026-05-22,CSDN):[以开源之力,突破多样化算力困局](https://blog.csdn.net/openFuyao/article/details/161304225) — 公开了若干**可验证的能力指标**(剥离营销话术):
  - 社区:300+ 开发者、30+ 成员单位、16 个 SIG
  - 商业发行版:40+ 项目落地
  - InferNex 推理性能:TTFT 降 40%、TPS 提 20%(未公布基线模型/硬件,需保留怀疑)
  - 大规模集群存储成本下降 70%(同上未公布基线)
  - 行业案例:京东训练利用率 97%、工行核心交易性能 +20%、移动云 CPU 利用率 +30%、联通 CSK Turbo 基线
- **v26.06 仍停在 rc.1**:[release-management 仓](https://gitcode.com/openFuyao/release-management/commits/main) 本周 0 实质 commit(5-18 typos 修复后无动作),未见 rc.2 或 GA 信号;按季度发版节奏,6 月底是 GA 窗口
- 官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/) news/release/blogs 三板块仍"暂无内容"(沿用上周判断,SSR 配置问题非真无更新);[docs.openfuyao.cn](https://docs.openfuyao.cn/zh/) 无 release notes 公开路径
- 上周登记的 `many-core-orchestrator` / `openfuyao-sandbox` 仓位本周需要鉴权访问,匿名 clone 失败 — 仍未公开

## 跟我们产品的对比

| 维度 | OpenFuyao 本周变化 | OAI / KServe / 通用 K8s 栈 | 我们应该怎么做 |
|------|-------------------|---------------------------|----------------|
| 推理服务 CR 入口 | InferNex-Bridge 合入 master,KServe LLMInferenceService v1alpha1 路径定稿 | OAI 仍走 KServe `InferenceService` v1beta1 | 评估是否押注 `LLMInferenceService`(KServe 0.17+);如果跟进,Bridge 翻译层的字段映射可以直接参考 |
| 集群生命周期 | **(本周新增)**`ClusterVersion` + `UpgradePath`(OCI artifact)+ `ReleaseImage` + `ComponentVersion` 四 CRD | OAI 有 OpenShift CVO + Cincinnati(平台级,非 OAI 自带) | **直接借鉴抽象** — OCI artifact 承载升级图是比自建 update server 更轻量的方案;PreCheck/Blocked/Deprecated 边的模型可以直接照搬 |
| KVCache 池化 | cache-indexer 从 Python 重写到 Go,L1(KV event)/ L3(Mooncake)分层成型 | KServe + llm-d 在做 KVCache aware 路由,无成熟池化分层模型 | **L1+L3 分层模型可以直接借鉴**;Mooncake 可被替换为 LMCache 等通用方案,接口不变 |
| 模型权重分发 | **(本周新增)**`weight-dispatcher` 新仓(sig-ai-inference),`feat/node-warm-up` 分支占位 | KServe StorageInitializer 仅单点拉取;无 P2P/预热 | 等 OpenFuyao 出代码再判断是否借鉴;无论如何,这条能力线是行业空白,产品上值得提前调研 |
| 推理控制面 | InferNex(KServe-style)+ mind-cluster infer-operator(实例级)双线持续 | OAI 单一路径(KServe) | 我们应保持单路径,避免 OpenFuyao 双控制面的组织/概念分裂 |
| 故障感知重调度 | mind-cluster infer-operator 实例级重调度落地(故障感知 + workload 接口) | KServe Liveness/Readiness + Pod 重启;无显式的"实例级故障感知" | 借鉴"workload-handler 抽象 + 故障码驱动重调度"的模式,可应用于 GPU 故障(NVML 事件、ECC 错误) |
| 网络资源调度 | k8s-rdma-shared-dev-plugin 原生开源 + UB 支持,Volcano hypernode serverid 拓扑 | Multus / SR-IOV operator 各做各的 | "网络作为可调度资源" + topology label 是值得对照的统一抽象 |
| 过载保护 | `olc-python` 准入算法框架(APA + 并发准入) | API gateway 层 RPM/TPM 限制,引擎内无并发感知准入 | 引擎进程内做并发准入(感知 KV 占用、prompt 长度)是有价值的差异化;参考 olc-python 算法实现 |
| 平台范围扩张 | sig-dongting 新 SIG:计算/存储/查询(HOFS + UQL) | 各自独立(KServe / KubeFlow / Trino 分开部署) | 短期不跟进;长期注意 OpenFuyao 在做"统一集群软件栈"的产品定位 |
| DRA | npu-dra-plugin 仍 0 commit(无加速) | K8s 1.32 DRA GA | 沿用上周判断,DRA 短期不进主路径 |

## 值得跟进

- [ ] **读 `cluster-api-provider-bke` feat/upgrade-530 分支的 webhook 与 controller 代码**,弄清 OCIRef 拉升级图的具体格式(OCI artifact mediaType?manifest 结构?)— 这是评估能否直接复用这套模型的关键
- [ ] **跑通 cache-indexer feat/go-refactor 的 L1+L3 端到端**:用本地 vLLM 模拟 KV event,Mooncake 用 docker 起 standalone,验证 hit-rate 数字,判断"Mooncake admin wire format"是否稳定可对接其他后端
- [ ] **关注 weight-dispatcher 下周代码进展**:看 `feat/node-warm-up` 分支会落 P2P / 预热 / 还是简单拉取作业 — 决定这条能力线的借鉴价值
- [ ] **再次验证 KServe `LLMInferenceService` v1alpha1 字段定义稳定性**:InferNex-Bridge 现在锁 v0.17.0,但 KServe 0.18/0.19 是否会有 break change?这影响"是否押注"的判断
- [ ] mind-cluster infer-operator 的 `pkg/controller/rescheduling/rescheduling.go` 完整读一遍,确认"故障驱动重调度"的决策算法(看是否仅查 NPU 故障码、还是有更通用的健康度评估)
- [ ] olc-python 的 APA 算法论文/出处 — 名字像是 Adaptive Permission Algorithm 之类,值得查源头看是否有学术背景
- [ ] 等 v26.06 rc.2 或 GA 出来(预计 6 月底前),核对最终组件清单是否包含 cluster-api-provider-bke 的升级 CRD 与 weight-dispatcher

## 原始材料

<details>
<summary>本周扫描清单</summary>

**openFuyao 主组织活跃仓**(commits in 2026-05-18..2026-05-25):
- `InferNex`:6 commits,核心 `176eff8 feat(infernex-bridge): InferNex-Bridge 合入 master`(2026-05-22)、`37fba09 node affinity prefill/decode/aggregated`(2026-05-24)、`5fde610 mooncake resource limit`(2026-05-24)、`c559cc8 kubernetes client 35.0.0`(2026-05-23)
- `cache-indexer`(feat/go-refactor):10+ commits,核心 `7bacfff fix(l3): end-to-end L3 hit-rate=1`、`6a7424e fix: discovery now supports pdrole aggregate`(2026-05-24)、`c0869bf 统一 pdRole label`(2026-05-20)
- `cluster-api-provider-bke`:master 2 commits + `feat/upgrade-530` 10+ commits,核心 `244e9c1 add clusterversion crd`(2026-05-18)、`5340696 add upgradepath crd`(2026-05-18)、`9fa3d11 add releaseimage crd`(2026-05-18)、`295f050 add componentversion crd`(2026-05-19)、`59540b9 only one upgradepath webhook`(2026-05-25)、`905f589 migrate logging to ologger`(2026-05-25)、`c5b8e62 fix BKE apt/yum repo`(2026-05-22)
- `elastic-scaler`:2 commits,`91fdb53 fix tidal status update failure`(2026-05-24)、`e330fd0 feat: add default algorithm apa`(2026-05-22)
- `olc-python`:20+ commits,集中 5-20~21,框架级 `5dab22a feat:添加准入策略算法框架及并发准入算法`(2026-05-20)、`6a57e87 fix: 规则默认值`(2026-05-21)
- `community`:多 commits,`446e359 初始化洞庭sig`(2026-05-20)、`dd5ecb4 feat: add weight-dispatcher repo`(2026-05-19)、`c193ee8 update colocation-management feat/dev-630`(2026-05-25)
- `weight-dispatcher`:1 commit,`dd29344 Initial commit`(2026-05-25,仅 README)
- `npu-operator`:1 PR merge,无实质功能
- `release-management`:0 commit

**openFuyao 主组织无活动仓**(窗口内 0 commit):
- `hermes-router`(主仓和所有 release 分支)
- `npu-dra-plugin`、`ub-network-device-plugin`、`volcano-ext`、`kae-operator`

**openFuyao 仍非公开仓**(匿名 clone 403):`many-core-orchestrator`、`openfuyao-sandbox`、洞庭 SIG 全部 7 个仓位(`dongting-compute`、`hofs-client/proxy/osd`、`uql-parser/core/service`)

**上游 Ascend/mind-cluster**:~50 substantive commits,核心:
- `1c34e708b 【infer-operator】实例级重调度:故障感知与记录`(2026-05-25,~860 lines)
- `8b48dc45f 【infer-operator】实例级重调度:statefulset workload 接口实现及 ut`(2026-05-25,~1400 lines)
- `b9a7e9d0a k8s-rdma-dp 原生开源版`(2026-05-21,Mellanox 上游镜像 + UB 扩展)
- `e7558ad05 k8s-rdma-dp 新增 UB 支持`(2026-05-21)
- `967444f10 [dp]对接 volcano hypernode 增加 serverid 的 topo 标签`(2026-05-20)
- `4068d4c68 [volcano]热切失败回退至 Job 重调度时清理调度缓存`(2026-05-23)
- `1db9731b9 【ClusterD】【故障快恢】新增故障码用于处理 OS 问题和 HBM 问题`(2026-05-22)
- `021ec6b88 添加故障模式库`+ `e3c30b259 添加 CANN 故障模式库`(2026-05-20)
- `f72ac6be5 a5 基础信息解析增加 dt`(2026-05-21,Atlas A5 首次适配)
- `1cd8aa373 【DOC】docs: 移除静态 vNPU 调度相关文档内容`(2026-05-21)

**官方信息源**:
- 官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/)(news/release/blogs 仍"暂无内容")
- 文档站 [docs.openfuyao.cn](https://docs.openfuyao.cn/zh/)(无 release notes 公开路径)
- CSDN [blog.csdn.net/openFuyao](https://blog.csdn.net/openFuyao) 1 篇新文(5-15 两篇已在上周覆盖):
  - 2026-05-22 [以开源之力,突破多样化算力困局——openFuyao开源一周年背后的故事](https://blog.csdn.net/openFuyao/article/details/161304225)

**v26.06 状态**:仍停在 rc.1(release-management/openFuyao-26.06/rc.1),无 rc.2 或 GA 信号

</details>
