# OpenFuyao 周报 2026-08-03

窗口:2026-07-27 -> 2026-08-03(7 天)

## 摘要(3 条以内)
- 本周主线是 **soft/hard vNPU 从子项目走向产品化**:[npu-operator !109](https://gitcode.com/openFuyao/npu-operator) 把整条 DRA + vNPU 栈(DeviceClass、DRA kubelet-plugin、vcannrt-installer、webhook、vNPU device-plugin/exporter、Volcano vnpu-admission/controller/CRD)一次性纳入 operator,`NpuClusterPolicy` 新增 `vnpu:`/`dra:` 两个 spec、Volcano 新增 `vnpu` flavor——从此一个 CR 声明式拉起昇腾算力切分全栈。
- 软切分的底层机制这周被 [npu-dra-plugin](https://gitcode.com/openFuyao/npu-dra-plugin) 和 [vNPU 主仓](https://gitcode.com/openFuyao/vNPU) 讲清楚了:基于 **CANN Runtime API 劫持**(`libvruntime.so` 走 `ld.so.preload`,劫持库源自 openEuler [ubs-virt](https://gitcode.com/openeuler/ubs-virt))的用户态虚拟化,最大 1 切 20、AICore 1% / 显存 1Gi 粒度、三种 AICore 调度策略(固定配额 / 弹性 / 争抢),性能损耗 <5%。**这就是昇腾版 HAMi**,且同时提供 Volcano-plugin 与 K8s DRA 两条接入路径。
- [InferNex](https://gitcode.com/openFuyao/InferNex) 补分布式推理的开服前预检与可用性:新增 `infernex-checker`(HCCN 跨节点连通、慢卡检测、配置/硬件/k8s 预检),proxy-server 允许 **PD 组部分就绪即对外服务**。官方无新版本(v26.06 仍最新,CSDN 停在 07-23,本窗口无新公告)。

## 新功能 / 能力

- [npu-operator 纳管 vNPU + DRA 全栈(!109)](https://gitcode.com/openFuyao/npu-operator) — `NpuClusterPolicy` 新增 `VNPUSpec`/`DRASpec`,把 40+ 份 asset 收进 operator:DRA 侧下发 5 个 DeviceClass(整卡 / soft-elastic / soft-fixed / soft-best-effort / hard)、kubelet-plugin DaemonSet、vcannrt-installer、validating webhook;vNPU 侧下发 device-plugin / exporter(带 ServiceMonitor)/ client-update;Volcano 侧新增 `VolcanoFlavor` 枚举(`mindcluster` / `vnpu` / `external`),`vnpu` flavor 会装 vnpu-admission(一堆 mutating/validating webhook)+ vnpu-controller + vNPU 版 Volcano CRD。
  - 启示:这是 OpenFuyao 把"异构算力切分"做成**一个 operator CR 管全栈**的关键一步,对标我们:昇腾 vNPU 的形态和 GPU(MIG/HAMi/MPS)高度同构——soft(时分复用软切)、hard(固件硬切)、full(整卡),以及"同节点部分容器整卡部分容器共卡"的混部。我们的 GPU/NPU operator 若还在用多份 Helm chart 分别装 device-plugin / 调度扩展 / 切分库,应该学这个思路收敛到单一策略 CR,并把 Volcano flavor(通用 vs 切分增强)做成可切换项。
- [软切分基于 CANN Runtime 劫持(npu-dra-plugin 集成 vCANN-RT)](https://gitcode.com/openFuyao/npu-dra-plugin) — 新增 `build/vcannrt` 镜像:从 openEuler ubs-virt 子模块编译 `libvruntime.so` + `enpu-monitor`,由 vcannrt-installer DaemonSet 落到宿主 `/opt/xpu/lib`,再由 DRA driver 把 `libvruntime.so` 和 `ld.so.preload`(映射成容器内 `/etc/ld.so.preload`)bind-mount 进业务容器;配 `acl-client-update.sh` 自愈守护(MD5 校验 + 5s 轮询)。DRA `dra.config` 用 `softShareMounts` + 逐节点 `physicalId → vnpuMode(full/hard/soft) + schedulingPolicy(elastic/fixed/best-effort)` 结构化配置。
  - 对比:机制上**和 HAMi 的 `libvgpu.so` LD_PRELOAD 劫持 CUDA 调用同构**,只是把拦截对象换成昇腾 ACL(CANN)运行时。差异在交付路径:HAMi 走 device-plugin + mutating webhook 注入,OpenFuyao 走 **K8s DRA**(ResourceClaim + DeviceClass + CEL selector),把"要哪种切分模式"表达成对 DeviceClass 的选择。这是我们做 DRA 选型时最值得对照的一个真实落地样本:soft 切分不是靠 DRA 分设备,而是靠 DRA 把劫持库和 preload 文件作为 CDI edit 注进容器。
- [三档 soft vNPU QoS 策略做成独立 DeviceClass](https://gitcode.com/openFuyao/npu-operator) — `elastic.npu.huawei.com` / `fixed.npu.huawei.com` / `best-effort.npu.huawei.com` 三个 DeviceClass,CEL 表达式按 `vnpuMode=="soft"` + `schedulingPolicy` 区分;对应 vNPU README 的"固定配额 / 弹性 / 争抢"三种 AICore 调度模式(显存严格隔离、AICore 时分复用非严格、波动 <10% 整卡)。
  - 启示:这套"固定配额 / 弹性借用 / 争抢"三档正是 GPU 共享的经典 QoS 谱系(MPS 固定 vs 时间片弹性 vs best-effort)。**把 QoS 策略提升成 DeviceClass 维度**是个好设计——用户在 ResourceClaim 里选 DeviceClass 就等于选了隔离强度,调度器无需理解厂商私有参数。我们的共享调度若要支持多档隔离,应照此把"隔离/超卖策略"编码进 DeviceClass 而不是 annotation。
- [InferNex 分布式推理预检器 infernex-checker](https://gitcode.com/openFuyao/InferNex) — 新增独立 Go 组件:硬件检查(HCCN 单机与跨节点连通性、慢卡 slowcard 检测,带模板化输出)、配置/环境检查、k8s 检查,统一 executor + parser + output。
  - 对比:这是分布式推理/训练开服前的**健康预检**,等价于 NVIDIA 生态的 DGX health check / NCCL all-reduce 连通性测试 + GPU 掉速检测。慢卡检测(识别性能劣化但未故障的卡)对大规模 PD 分离推理尤其关键——一张慢卡会拖垮整个集合通信。通用启示:我们的推理/训练平台在拉起分布式作业前应有一层拓扑+链路+掉速的自动预检,把"能通信、卡不慢"作为准入门槛,而不是等作业跑起来 TTFT 抖动才排查。
- [InferNex proxy-server 允许 PD 组部分就绪(!207)](https://gitcode.com/openFuyao/InferNex) — proxy-server 在 prefill/decode 组只有部分副本 ready 时也允许对外服务,而非要求全组就绪。
  - 启示:PD 分离部署下,把"服务可用"从"全副本就绪"松绑成"部分就绪即服务"是对的可用性权衡——否则一个 decode 副本重启会让整组 502。我们做 PD 分离网关时,健康判定要按角色分别看 min-ready,而不是整组 all-or-nothing。

## AI 推理栈(InferNex / hermes-router / ...)

- InferNex 本周聚焦**运维健壮性而非路由算法**:infernex-checker(预检)、slowcard 检测(!204/!206,含跨节点指标展示解析修复)、PD 组部分就绪(!207)、以及一批 CVE 修复。v26.06 已交付的 Mooncake/KVCache-aware/prediction 路由、elastic-scaler 本周无算法级新提交。
- hermes-router 本窗口**无新提交**(上周 prediction sidecar 训练文档后无跟进),路由预测能力处于发版后静默期。
- 对比:相比上游 KServe GIE / Envoy AI Gateway 仍在打磨路由决策,InferNex 这周把重心放在"分布式推理的物理层可靠性"(慢卡、跨节点 HCCN、PD 部分就绪)——这是昇腾大集群推理落地绕不开的一层,通用平台也该有对应的预检与角色级健康判定,只是我们的对象是 GPU/NCCL 而非 NPU/HCCN。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- npu-dra-plugin 本周是**最活跃的仓**:除上面的 vCANN-RT 集成外,还做了软/硬切分功能优化(重写 cmd 层 driver/state、profiles 层 soft_vnpu/hard_vnpu/vnpu_manager,补大量单测)、修 Ascend910 整卡与软切分误挂双 die 设备、加 Helm chart 包、把 draConfig 从不透明字符串重构成结构化 `softShareMounts + nodes` 逐节点配置(与 07-31 compute-ascend-watch 观察一致,本周已合入 !30)。
  - 对比:DRA 接入昇腾从"能跑 demo"进到"能声明式配、能 Helm 装、软硬切都覆盖",进度明显。这印证 DRA 作为异构设备接入面的可行性,我们 DRA 选型可持续跟踪其 CDI edit + CEL selector 的用法。
- [mind-cluster device-plugin 软切并发注解读写修复](https://gitcode.com/ascend/mind-cluster) — 修软切下发 pod 时并发读写 annotation map 的问题及 `vnpu_id` 取值问题。
  - 启示:说明软切 vNPU 也在 mind-cluster 的 device-plugin 路径同步落地(与 npu-dra-plugin 的 DRA 路径并行)。并发读写 annotation map 是 device-plugin 分配路径的经典竞态,通用启示:设备分配的 per-pod annotation 写入要串行化或用 patch 而非 read-modify-write。
- [mind-cluster mindio tft 全局异常 rank 上报增强](https://gitcode.com/ascend/mind-cluster) — MindX 通知全局异常 rank 时新增一次交互,补报"首次上报异常到全局通知之间新增的故障"。
  - 对比:这是训练容错(TFT / 断点续训)的故障收集完整性补丁——避免在故障传播窗口内新发生的故障被漏报。通用启示:分布式训练故障恢复要处理"故障上报"和"全局决策"之间的时间差,期间新增故障需二次采集,否则重调度决策基于过期快照。
- npu-operator 另有 `独占模式1825rdma`(mind-cluster 侧)等硬件形态构建代码,昇腾专用,略。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- 调度侧本周的重心都并入了 vNPU 主线:npu-operator 的 `vnpu` Volcano flavor 会部署 **vnpu-admission**(queues/jobs/podgroups/hypernodes/cronjobs 全套 mutating+validating webhook)和 **vnpu-controller**(带 sharding configmap),即 Volcano 为"切分资源"专门定制了一套准入与分片控制面。
  - 对比:这说明昇腾共卡调度不是简单在 Volcano 加个 NPU 插件,而是要一套 vNPU 专用的准入 webhook + 分片控制器来管"哪个 job 用哪片、怎么 binpack、整卡与共卡如何在同节点共存"。对标 Kueue + DRA:Kueue 目前对 DRA 的配额感知还在早期,OpenFuyao 这里是用 Volcano 自带的 vnpu-admission 兜住准入。我们若走 Kueue 路线,要评估共享设备的配额准入这块 Kueue/DRA 是否够用,还是也需要自定义 admission。
- volcano-ext 独立仓本窗口无新 tag/提交(仍 v1.10.0),NPU 拓扑亲和扩展本周无独立进展,活跃点集中在 npu-operator 打包的 Volcano vnpu 资产。

## 官方动态
- 本窗口(07-27 ~ 08-03)**官网与 CSDN 均无新版本、无新博客、无路线图公告**。v26.06(2026-07-09)仍是最新版;CSDN 最新三篇仍是 07-23 的生态/市场文(LEAP East、超节点白皮书、统信 V3.0),已在上期周报覆盖。本周为纯代码活跃周。

## 跟我们产品的对比
- **同构、方向一致(可直接借鉴)**:soft vNPU = 昇腾版 HAMi(LD_PRELOAD 劫持运行时 + 显存严格/算力时分隔离 + 固定/弹性/争抢三档 QoS);把切分栈收敛到单一 operator CR;把 QoS 策略编码进 DeviceClass;分布式推理开服前预检(慢卡/连通性);PD 分离按角色 min-ready 判定可用。这些换成 GPU/CUDA/NCCL 我们都能照搬。
- **昇腾专用(仅了解,不直接借鉴)**:vCANN-RT 劫持的是 CANN ACL(非 CUDA);hard 切走昇腾 HDK;HCCN 跨节点检查、mindio TFT、1825 RDMA 独占模式、chip4node8 拓扑。
- **我们该补/该决策**:(1) DRA 选型可把 OpenFuyao 当参考实现——**soft 切分靠 DRA 做 CDI edit 注劫持库,而非 DRA 分设备**,这个用法值得我们在 GPU 共享上验证;(2) 共享设备的多档隔离策略应做成 DeviceClass 维度而非 annotation;(3) 评估 Kueue+DRA 对"共卡配额准入"是否够用,还是也需要类似 vnpu-admission 的自定义准入;(4) 补分布式推理/训练的开服前预检(掉速卡 + 集合通信连通性)作为准入门槛;(5) 异构算力切分栈考虑收敛到单一策略 CR。

## 值得跟进
- [ ] 通读 [vNPU 主仓](https://gitcode.com/openFuyao/vNPU) 的 `client_update` 与 `volcano-xpu-plugin`,搞清软切劫持库如何做 AICore 时分复用与显存硬隔离,评估与 HAMi 架构的具体差异(尤其"只限显存不限算力""1 容器 1 vNPU 1 进程"这些约束的成因)。
- [ ] 读 [npu-dra-plugin](https://gitcode.com/openFuyao/npu-dra-plugin) 的 `internal/profiles/npu`(soft_vnpu.go / hard_vnpu.go / cdi_edits.go),确认 DRA 如何把劫持库作为 CDI edit 注入、软切设备不实际分配的处理方式——作为我们 GPU DRA soft-share 的参考。
- [ ] 对照 [npu-operator !109](https://gitcode.com/openFuyao/npu-operator) 的 `NpuClusterPolicy` vnpu/dra spec 结构,评估我们的异构 operator 是否值得引入 Volcano flavor(通用 vs 切分增强)可切换设计。
- [ ] 评估 Kueue + DRA 对共享/切分设备的配额准入能力,判断是否需要类似 vnpu-admission 的自定义准入 webhook 兜底。
- [ ] 借鉴 InferNex `infernex-checker` 的慢卡 + HCCN 跨节点预检,在我们分布式推理/训练平台加一层开服前物理链路预检(GPU 掉速 + NCCL 连通)。

## 原始材料

<details>
<summary>本次扫描清单(2026-07-27 ~ 2026-08-03)</summary>

官方源(本窗口无新内容):
- https://www.openfuyao.cn/zh/ — 无新 release/blog/公告
- https://blog.csdn.net/openFuyao — 最新仍为 07-23 三篇生态文,v26.06(07-09)仍最新版

GitCode 浅克隆日志(--depth 100/150,--since=2026-07-27,已滤 bot/merge/docs):
- `openFuyao/npu-operator`:
  - 2026-08-03 !109 feat: add vNPU and DRA component(NpuClusterPolicy 新增 vnpu/dra spec;下发 5 DeviceClass + DRA kubelet-plugin/webhook/vcannrt-installer + vNPU device-plugin/exporter + Volcano vnpu-admission/controller/CRD;新增 VolcanoFlavor mindcluster/vnpu/external)
- `openFuyao/npu-dra-plugin`:
  - 2026-08-01 !30 refactor: draConfig 节点配置改为结构化可配置(softShareMounts + nodes 逐节点)
  - 2026-07-31 !29 feat: 添加 Helm chart 包(npu-dra-driver chart)
  - 2026-07-31 !28 feat: 软/硬切分功能优化(重写 cmd driver/state + profiles soft/hard_vnpu + 大量单测)
  - 2026-07-29 fix: Ascend910 整卡和软切分移除双 die 设备挂载
  - 2026-07-28 feat: 集成 vCANN-RT 劫持库(build/vcannrt Dockerfile 从 openEuler ubs-virt 子模块编译 libvruntime.so;ld.so.preload + acl-client-update.sh 自愈)
- `openFuyao/InferNex`:
  - 2026-08-03 !206 fix: improve slow card detection parsing and cross-node metrics display
  - 2026-07-31 !207 fix(proxy-server): allow partially ready PD groups
  - 2026-07-30 !204 feat: add slowcard check + resolve issues/CVE(新增 infernex-checker 组件:HCCN 跨节点/慢卡/配置/硬件/k8s 预检)
- `openFuyao/vNPU`(主仓,README 定义软/硬切能力谱系):
  - 2026-07-30 fix: handle log.InitLogging error to ensure visibility(仅一处小修;README 明确 1切20/AICore 1%/显存 1Gi/三档 QoS/损耗<5%)
- `ascend/mind-cluster`(实质提交,已滤 merge/资料/docx):
  - 2026-08-03 [mindio tft] 删除测试用例中的私钥
  - 2026-07-29 [device-plugin] 软切下发 pod 并发读写 annotation map 问题及 vnpu_id 取值问题修改
  - 2026-07-28 [mindio tft] mindx 通知全局异常 rank 时新增一次交互(补报传播窗口内新增故障)
  - 2026-07-28 独占模式 1825rdma 构建代码
- `openFuyao/hermes-router`、`openFuyao/volcano-ext`、`openFuyao/ub-network-device-plugin`、`openFuyao/kae-operator`:本窗口无新提交(tag 仍 v26.6.0 / v1.10.0)

关键机制交叉印证:
- vCANN-RT 劫持库源自 openEuler https://gitcode.com/openeuler/ubs-virt(ubs-virt-enpu/vcann-rt),依赖 CANN 8.5.1 SDK + HDK 25.5.1 编译
- soft DeviceClass CEL:device.attributes["npu.huawei.com"].vnpuMode=="soft" && schedulingPolicy in {elastic, fixed-share, best-effort}

</details>
