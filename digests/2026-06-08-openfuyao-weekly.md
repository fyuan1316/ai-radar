# OpenFuyao 周报 2026-06-08

窗口:2026-06-01 → 2026-06-08(7 天)

## 摘要

- **InferNex 正式接入 KServe `LLMInferenceService`(OFEP-0040 / InferNex-Bridge),用户入口从自有 CRD 收敛到上游**:本周 InferNex 合入 `infernex-bridge` 组件,默认入口从 `InferNexService` 改成 **KServe 0.17 的 `LLMInferenceService`(`serving.kserve.io/v1alpha2`)**;engine + Hermes Router + 网关交还给 KServe llmisvc 控制器调和,InferNex 退化为"Bridge + 增强组件(proxy-server / cache-indexer / Mooncake / PD-Orchestrator / Eagle-Eye)"。OFEP-0040 明确写"把 InferNex、llm-d 等异构技术栈统一纳入 KServe 声明式部署规范"。**这是一次明确的"向上游收敛"的路线转向**,跟我们押注 KServe 的判断一致。
- **v26.06-rc.2(Beta)落地**(比 release-plan 的 5-27~29 略滑到 6-02~03,但已出 `rc.2/` 全套 VersionConfig):InferNex 升到 **0.24.0**、新增 `infernex-bridge` / `proxy-server` 镜像;**PD-Orchestrator 作为独立发布包**(`elastic-scaler` + `resource-scaling-group` + `tidal` 三件套 0.22.0)与 ManyCoreScheduler(众核调度)、RayPackage 一起成为 v26.06 一等组件。GA 仍标 6-29~30。
- **mind-cluster 上游一周 90+ commits,故障自治与弹性两条线同时加重**:新增 **NPU 卡死检测(hang detection)**、**DP 故障处理插件化**、**infer-operator 自定义资源弹性扩缩容**、跨组件**健康探针服务**、进程级恢复下"节点宕机 volcano 快速重调度"修复;另有 **KubeVirt 仓转公开 + vNPU 接 ubs-virt**,昇腾"VM 化 vNPU + 机密容器"虚拟化线开始成形。

## 新功能 / 能力

- [InferNex-Bridge:InferNex 接入 KServe LLMInferenceService 适配层](https://gitcode.com/openFuyao/InferNex/-/commit/9169bcb) — 2026-06-05 合入 `feat(bridge): align v26.06 components, cache-indexer discovery, Hermes EPP contract, and KServe v1alpha2`(+2068 行),06-08 补 [LLMISVC 部署示例](https://gitcode.com/openFuyao/InferNex/-/commit/863b8bc)(aggregate/PD 两套 `*_llmisvc_no_storage_initializer_example.yaml`)。设计依据 [OFEP-0040](https://gitcode.com/openFuyao/ofep/blob/main/ofeps/sig-ai-inference/0040-ofep-Infernex%E6%8E%A5%E5%85%A5kserve%E9%80%82%E9%85%8D%E5%B1%82.md)。双入口:① `LLMInferenceService` 打 `infernex.io/runtime=true` 标签 → Bridge 自动创建同名 `InferNexService` 挂增强组件,engine/router/网关由 KServe 调和;② 裸 `InferNexService`(无 `sourceRef`)→ Bridge 全托管。Bridge 用 Validating webhook 校验放行、Mutating webhook 对 `LLMInferenceServiceConfig` 做一次性模板改写(清 `drop: ALL`、清空 decode 侧 initContainers),注解门闩保证幂等。
  - 启示:**这是本周最重要的对标信号——OpenFuyao 选择不再用自有 CRD 跟 KServe 平行竞争,而是把 KServe `LLMInferenceService` 作为默认用户入口、自己退到"增强组件编排器"位置**。它对标的不是 KServe,而是"如何在 KServe 上叠加 NPU 专属的 PD 编排/KVCache/监控能力而不分叉用户 API"。OFEP 里"把 InferNex、llm-d 等统一纳入 KServe 规范"的措辞,跟 llm-d 社区把 KServe `LLMInferenceService` 当统一控制面的方向是同一条路。**我们如果也走 KServe llmisvc,这套"标签触发 + webhook 模板改写 + sidecar 增强组件经独立 controller 编排"的分层模式可以直接照搬**:好处是引擎/网关跟着上游升级,差异化能力(我们的调度/路由/监控)用一个不抢 reconcile 的旁路 controller 叠加,升级 KServe 时不破坏自家增强层。**非目标里写明"不侵入式改 KServe CRD、不强制迁移"——这是正确的耦合边界设计,值得抄**
- [PD-Orchestrator 成为独立发布组件:elastic-scaler + resource-scaling-group(RSG)+ tidal 三件套](https://gitcode.com/openFuyao/release-management/-/commit/9b5263f) — v26.06-rc.2 把 `pd-orchestrator-0.22.0.tgz` 作为独立 chart 包发布,含 elastic-scaler(HPA-like 稳定化扩缩)、resource-scaling-group(资源伸缩组,带 admission webhook)、tidal(潮汐/时间因素调度,对应 [OFEP-0033](https://gitcode.com/openFuyao/ofep/blob/main/ofeps/sig-ai-inference/0033-ofep-%E5%9F%BA%E4%BA%8E%E6%97%B6%E9%97%B4%E5%9B%A0%E7%B4%A0%E7%9A%84%E6%BD%AE%E6%B1%90%E8%B0%83%E5%BA%A6%E5%86%B3%E7%AD%96%E7%AE%97%E6%B3%95.md))三个 controller;Bridge 在 PD 模式下把它当增强组件挂载
  - 启示:**前几周散落的 elastic-scaler(ofep-0030 通用扩缩框架)、RSG(ofep-0029 PD 分离动态扩缩)、tidal(ofep-0033 潮汐)被打包成"PD 编排"产品单元**。这正好补上 KServe 的空白:KServe llmisvc 自身只有 replica/HPA,没有"PD 角色感知 + 资源伸缩组 + 时间潮汐"三层弹性。**对我们做 PD 解耦推理产品的启示**:弹性不该只是一个 HPA,而要拆成"决策框架(可插算法)+ 资源组抽象 + 时间维度策略"三层;tidal 这种"按业务时间段预扩容"的潮汐能力是 vLLM/KServe 上游都缺的,长尾/夜间负载场景值得借鉴(且与昇腾无关,通用)
- [mind-cluster 新增 NPU 卡死检测(hang detection)](https://gitcode.com/Ascend/mind-cluster/-/commit/97c2505) — 2026-06-03 part1(+292 行,`pkg/device/hangdetection`)、[part2](https://gitcode.com/Ascend/mind-cluster/-/commit/d98b20f)(+975 行,含 566 行 `hang_detector_test.go`);device-plugin 侧检测 NPU 进程卡死/无响应
  - 启示:**对标 NVIDIA 的 XID/卡 hang 检测 → 驱逐重调度闭环**。昇腾此前故障检测偏硬件(HBM/BMC/链路),hang detection 补的是"卡没掉但算子不前进"这类软故障。检测逻辑昇腾专属(dcmi 利用率/进程状态),**但产品形态通用**:device-plugin 内置 hang 探测、置卡不可用、触发上层重调度,GPU 集群(NVML + DCGM hang 检测)完全同构。我们如果做异构故障自治,**"卡死"应作为与"卡掉"并列的一等故障类型**
- [mind-cluster DP 故障处理插件化 + 跨组件健康探针服务](https://gitcode.com/Ascend/mind-cluster/-/commit/50ce737) — 2026-06-03 故障处理模块化(+1392 行,含 `pkg/server/token_bucket.go` 限流);配套 [健康探针检查服务公共代码](https://gitcode.com/Ascend/mind-cluster/-/commit/af81ef7)(+865 行,横跨 ascend-common/device-plugin/operator/clusterd/infer-operator/noded/npu-exporter 7 个组件)
  - 启示:**故障处理从"硬编码 if-else"重构成"插件化故障处理器 + token bucket 限流",健康探针抽成跨组件公共库**——这是平台工程成熟度的标志。**通用借鉴点**:① 故障处理插件化(每类故障一个 handler,新故障码不动主流程)是可移植的架构;② 给重调度/驱逐动作加 token bucket 限流,避免故障风暴时雪崩式重调度——这是生产级细节,我们做 GPU 故障自治时容易漏
- [mind-cluster infer-operator 支持自定义资源弹性扩缩容](https://gitcode.com/Ascend/mind-cluster/-/commit/24777c8) — 2026-06-03 part0(+970 行,instanceset_controller)、[part1](https://gitcode.com/Ascend/mind-cluster/-/commit/23e167c)(+806 行 scaling_manager 测试)、[自定义资源扩缩 bugfix](https://gitcode.com/Ascend/mind-cluster/-/commit/414702b)
  - 启示:[2026-04-17 双控制面 deep-dive](./2026-04-17-openfuyao-infer-operator-vs-infernex.md) 里 mind-cluster infer-operator 这条线本周给推理实例补上"按自定义指标弹性扩缩"。**注意双控制面格局**:InferNex 这边走 KServe llmisvc + PD-Orchestrator(elastic-scaler/RSG/tidal),mind-cluster infer-operator 那边自己也做一套弹性扩缩——**两套弹性方案仍并存**,沿用既往判断"我们保持单路径"
- [KubeVirt 仓转公开 + vNPU 接入 ubs-virt,昇腾虚拟化线成形](https://gitcode.com/openFuyao/community/-/commit/ca9fe69) — 2026-06-02 community 标记 [openFuyao/kubevirt](https://gitcode.com/openFuyao/kubevirt) 为公开;同期 [vNPU 把 ubs-virt 作为 submodule](https://gitcode.com/openFuyao/vNPU/-/commit/5dc0751)(`third_party/ubs-virt` 指向 `openeuler/ubs-virt`,另含 volcano v1.9.0 / mind-cluster v7.2.RC1.SPC1 submodule),并[删除 aicore 算力必须是 5 的倍数的限制](https://gitcode.com/openFuyao/vNPU/-/commit/f35c7f7)(切分粒度更细);e2e 仓新增 [KubeVirt 前端](https://gitcode.com/openFuyao/e2e-auto-test/-/commit/6ec2e7b)/[后端](https://gitcode.com/openFuyao/e2e-auto-test/-/commit/e5e2e04)测试
  - 启示:**昇腾在补"VM 化 NPU"路径**——vNPU(CANN ACL 用户态拦截做容器内切分)+ KubeVirt(VM 工作负载)+ ubs-virt 三者拼成"既能容器切分、也能 VM 直通/切分"的虚拟化全栈。**昇腾专属,不直接借鉴**;但提示一个对标维度:OAI/KServe 生态主流是容器化推理,VM 化推理是边缘/多租隔离强诉求场景,如果我们的客户有"VM 级隔离 + GPU 切分"诉求(金融/政务),KubeVirt + GPU passthrough/MIG 是对应物

## AI 推理栈(InferNex / hermes-router / weight-dispatcher / cache-indexer)

- [InferNex 对齐 v26.06 组件 + cache-indexer discovery + Hermes EPP 契约](https://gitcode.com/openFuyao/InferNex/-/commit/9169bcb) — 见上"新功能";同时新增 `infernexservice_cache_indexer_config.go`(+347 行)把 cache-indexer 的 endpoint discovery 配置纳入 Bridge reconcile,LLMISVC 示例里 Mooncake 走 `protocol: "ascend"` + `use_ascend_direct: true`(Ascend Direct 直连传输)
- [hermes-router 给 prefix-cache-producer 加 PD target selector](https://gitcode.com/openFuyao/hermes-router/-/commit/45ecac5) — 2026-06-03,prefix cache producer 可按 PD 角色选目标;本周 hermes 主要是 README + [epplib chart 版本/values 镜像格式修复](https://gitcode.com/openFuyao/hermes-router/-/commit/025fc24),上周的 GIE v1.5.0 大改造进入打磨期
- [weight-dispatcher 持续硬化 RDMA / P2P 接力数据面](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/32a482e) — 2026-06-03 [collective exchange chunk 重试](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/32a482e)、[支持 node URL + chunk CRC 复用](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/2eaf1f8)、[node agent 监听端口可配/从 helm 推导](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/6ba1ae5)、[post-write CRC 校验可选](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/3725403);上周建仓的 ModelWarmupJob P2P 权重分发进入稳定化(沿用上周"行业空白被独立组件填上"的判断)
- [cache-indexer 加架构 PlantUML 图 + 中英文 README](https://gitcode.com/openFuyao/cache-indexer/-/commit/9b5c5b3) — 本周仅文档,Go 版进入稳定期;e2e 仓补了 [cache-indexer P0/P1 用例](https://gitcode.com/openFuyao/e2e-auto-test/-/commit/626bb94)

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- **mind-cluster 故障诊断(FD)维度持续扩张**:[精确链路定位 part1](https://gitcode.com/Ascend/mind-cluster/-/commit/558b174) + [merge](https://gitcode.com/Ascend/mind-cluster/-/commit/07066f1)、[BMC fault 关键词更新](https://gitcode.com/Ascend/mind-cluster/-/commit/31ebe6e)、[IPv6 socket error 日志解析](https://gitcode.com/Ascend/mind-cluster/-/commit/df3a29b)、[移除 AISW_CANN_AICPU_08 故障码](https://gitcode.com/Ascend/mind-cluster/-/commit/9fee63f)、[npu-exporter 指标获取失败上报 unknown 状态](https://gitcode.com/Ascend/mind-cluster/-/commit/30fb5eb)
- [mind-cluster k8s-rdma-shared-dev-plugin 新增 1825 故障检测 + DPU faultcheck](https://gitcode.com/Ascend/mind-cluster/-/commit/b2c8e12) — RDMA DP 侧故障检测扩到 DPU;配套补多轮 UT([rdma dp ut 2](https://gitcode.com/Ascend/mind-cluster/-/commit/a41a00d)、[ut 3](https://gitcode.com/Ascend/mind-cluster/-/commit/d14751f))
- [mind-cluster device-plugin 按端口判断是否需要隔离 + A5 适配 IPv6](https://gitcode.com/Ascend/mind-cluster/-/commit/71d46c9) — DP 隔离粒度细化;[ascend-common 增 dcmi 多卡利用率周期接口](https://gitcode.com/Ascend/mind-cluster/-/commit/75c6afb)(`dcmi_get_device_multi_utilization_rate_period`,为 hang detection / 利用率监控供数)
- [mind-cluster 进程级恢复下"节点宕机 volcano 快速重调度"修复](https://gitcode.com/Ascend/mind-cluster/-/commit/6e6b102) — 2026-06-06,修复进程级恢复场景节点宕机时 volcano 不能快速重调度的问题(rescheduling/type.go),延续上周"进程级重调度"线
- [npu-dra-plugin 仅更新 Dockerfile](https://gitcode.com/openFuyao/npu-dra-plugin/-/commit/966afa3) — 2026-06-02,无功能进展,**仓位仍冷,DRA 接入昇腾短期不进我们 DRA 路线评估优先级**(沿用既往判断)
- [npu-operator](https://gitcode.com/openFuyao/npu-operator)、[ub-network-device-plugin](https://gitcode.com/openFuyao/ub-network-device-plugin)、[kae-operator](https://gitcode.com/openFuyao/kae-operator) — 本周无实质提交

## 调度 & 集群(cluster-api-provider-bke / 众核 / ubs)

- [cluster-api-provider-bke 升级流程(feat/upgrade-530)合入 master](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/87581f3) — 2026-06-05 `feat: sync upgrade code to master`,上周还在分支的 DAG 升级框架本周进主干;同步落地 [并行升级](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/7c8d467)、[k8s master/worker 节点组件升级](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/dc1e915)、[跳过未安装组件 + etcd 适配](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/c8d92fb)、[bkeagent 走 SSH 升级](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/b0975eb)、[删除 upgradePath/clusterVersion/releaseImage ociRef 引用](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/2d291a1)(升级图谱依赖收敛),从 bke-config 取 OCI 地址
  - 启示:上周给出的"phase framework + DAG 调度 + OCI artifact 升级图"本周**正式进主干并补齐并行升级与节点级编排**。删除 upgradePath/clusterVersion 多重 ref、统一从 bke-config 取 OCI 地址,是把"升级图谱来源"收敛到单一配置——比 OpenShift CVO + Cincinnati 的多对象图谱轻。**我们做平台级升级时,"升级图谱单一来源 + DAG 阶段化 + 组件级 skip-if-not-installed"这三点是值得照搬的工程决策**
- [release-management 加 bkeagent download](https://gitcode.com/openFuyao/release-management/-/commit/e7bed5e) — 配合 bke SSH 升级,bkeagent 二进制纳入发布件下载
- **ManyCoreScheduler(众核调度)在 v26.06 成为独立发布包**,e2e 仓新增[众核-调度插件自动化测试](https://gitcode.com/openFuyao/e2e-auto-test/-/commit/3c3c245);具体调度算法代码仓未在主组织 featured 暴露,下周待挖
- [ubs-k8s-enable 修 rmrs 接口 pid 存在但无内存分配场景的归还 bug](https://gitcode.com/openFuyao/ubs-k8s-enable/-/commit/e1ddb1f) — 2026-06-04;另[补架构设计的外部依赖表](https://gitcode.com/openFuyao/ubs-k8s-enable/-/commit/cfe800b)。UB 专属内存借用/共享(沿用既往"昇腾 UB 专属,通用栈不可借鉴"判断)
- [community 登记 openfuyao-sandbox 仓](https://gitcode.com/openFuyao/community/-/commit/082937b)(sig-orchestration-engine,2026-06-01)、[为 upgrade-path 建分支](https://gitcode.com/openFuyao/community/-/commit/ed77419)、[刷新 sig-ai-inference / sig-orchestration-engine SIG 描述](https://gitcode.com/openFuyao/community/-/commit/46367ce)

## 官方动态

- **v26.06-rc.2(Beta)已发布**:[release-management rc.2 全套 VersionConfig](https://gitcode.com/openFuyao/release-management/-/commit/9b5263f)(Core / EagleEye / HermesRouter / InferNex / ManyCoreScheduler / NpuOperator / PDOrchestrator 等 16 个组件包)落地,**比 release-plan 计划的 5-27~29 略滑到 6-02~03**。当前进入"全量测试期 6-01~6-15",下一步 rc.3 6-17~19,GA 仍标 **6-29~30**。InferNex 包升到 `infernex-0.24.0.tgz`,新增 `infernex-bridge` / `proxy-server` 镜像
- **官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/) news/release/blogs 三板块仍"暂无内容"**(沿用既往判断,发布节奏仍靠 CSDN + GitCode 驱动)
- **CSDN [blog.csdn.net/openFuyao](https://blog.csdn.net/openFuyao) 本周 4 篇,均为观点/营销文,无新 release note**:
  - 2026-06-04 三连发 [AI Native 基础设施目标形态与挑战](https://blog.csdn.net/openFuyao/article/details/161695308) / [Agent 时代成本与性能权衡](https://blog.csdn.net/openFuyao/article/details/161695432) / [Agent 对今天技术的具体要求](https://blog.csdn.net/openFuyao/article/details/161695377) — thought-leadership,无可验证技术指标,剥离后无新信息
  - 2026-06-01 [openFuyao 深度参与 KADC 2026](https://blog.csdn.net/openFuyao/article/details/161600914) — 5-26 两篇 KADC 内容的汇总稿,无新增(上周已覆盖 Aether / V3 Cache / 联通 CSK Turbo 等)
- **新增公开仓**:[openFuyao/kubevirt](https://gitcode.com/openFuyao/kubevirt)(6-02 转公开,KubeVirt 昇腾适配)、首页可见 [confidential-containers-deployment](https://gitcode.com/openFuyao)(对应 KADC 的 Kata+NPU 机密容器,e2e 仓本周新增[鲲鹏机密容器 E2E](https://gitcode.com/openFuyao/e2e-auto-test/-/commit/05b62a3)),组织总仓数 106

## 跟我们产品的对比

| 维度 | OpenFuyao 本周变化 | OAI / KServe / 通用 K8s 栈 | 我们应该怎么做 |
|------|-------------------|---------------------------|----------------|
| 推理用户入口 | **(本周转向)**InferNex 接入 KServe `LLMInferenceService`(v1alpha2),自有 `InferNexService` 降为旁路;标签触发 + webhook 改写 + 增强组件独立 controller | KServe llmisvc 是上游 LLM-native 入口;llm-d 也收敛到 llmisvc | **验证我们押注 KServe 的判断** — 直接照搬"标签触发 + 非抢占式旁路 controller 叠加差异化能力"分层,升级 KServe 不破坏自家增强层 |
| PD 弹性编排 | **(本周打包)**PD-Orchestrator = elastic-scaler(通用扩缩框架)+ RSG(资源伸缩组)+ tidal(潮汐) 三件套独立发布 | KServe llmisvc 仅 replica/HPA;无角色感知三层弹性 | **弹性拆三层** — 决策框架(可插算法)+ 资源组抽象 + 时间潮汐;tidal 通用且上游缺,长尾/夜间负载可借鉴 |
| NPU/GPU 卡死 | **(本周新增)**mind-cluster hang detection(device-plugin 内置) | KServe 仅 Liveness/Readiness;无"卡未掉但算子卡死"检测 | **"卡死"应与"卡掉"并列为一等故障类型**,GPU 侧用 NVML+DCGM hang 检测同构 |
| 故障处理架构 | **(本周新增)**DP 故障处理插件化 + token bucket 限流 + 跨组件健康探针公共库 | 无对等抽象 | **借鉴**:故障处理插件化 + 重调度动作加限流(防故障风暴雪崩) |
| 推理控制面 | KServe llmisvc(+InferNex-Bridge)与 mind-cluster infer-operator(自带弹性扩缩)双线并存 | 单一路径(KServe) | 沿用既往判断 — **我们保持单路径**,避免概念分裂 |
| 集群升级 | cluster-api-provider-bke 升级框架进主干 + 并行升级 + 升级图谱来源收敛到 bke-config(OCI) | OAI 靠 CVO + Cincinnati(多对象图谱) | **借鉴**:升级图谱单一来源 + DAG 阶段化 + skip-if-not-installed,比 Cincinnati 轻 |
| NPU 虚拟化 | **(本周新增)**KubeVirt 转公开 + vNPU 接 ubs-virt(VM 化 vNPU);切分粒度去掉"5 倍数"限制 | OAI/KServe 主流容器化;VM 化推理非主路径 | 昇腾专属,**不直接借鉴**;若客户要"VM 级隔离 + GPU 切分"(金融/政务),对应物是 KubeVirt + MIG/passthrough |
| 机密容器 | confidential-containers-deployment 转公开 + 鲲鹏机密容器 e2e | OAI 有 OpenShift confidential containers(Kata + TEE) | 昇腾/鲲鹏专属实现;**对标维度成立**,企业多租隔离强诉求场景需评估我们的 TEE 路径 |
| 权重分发 | weight-dispatcher RDMA/P2P 接力数据面持续硬化(chunk 重试、CRC 复用、端口可配) | KServe StorageInitializer 单点拉取 | 沿用上周判断 — ModelWarmupJob CRD 抽象 + RDMA 换 NCCL/GDS/TCP 可移植 |
| DRA | npu-dra-plugin 仅 Dockerfile | K8s 1.34 DRA 已 GA | 沿用既往判断,DRA 短期不进主路径 |

## 值得跟进

- [ ] **完整读 OFEP-0040 + InferNex-Bridge 的 webhook 实现**(`webhook/v1alpha1/llmisvc_scheduler_patch.go`、`infernexservice_validation_webhook.go`):弄清 Mutating webhook 对 `LLMInferenceServiceConfig` 做了哪些"一次性模板改写"、注解门闩的幂等机制;评估我们在 KServe llmisvc 上叠加差异化能力时能否复用这套"非抢占式旁路增强"模式
- [ ] **跑通一次 LLMISVC PD 部署示例**(`pd_llmisvc_no_storage_initializer_example.yaml`):验证 KServe 0.17 llmisvc + InferNex-Bridge + Mooncake(`protocol: ascend` / `use_ascend_direct`)的端到端;确认 storageInitializer 被禁用后权重怎么进 pod(是否走 weight-dispatcher)
- [ ] **挖 ManyCoreScheduler(众核调度)代码仓**:v26.06 一等组件但主组织 featured 未暴露源码,从 e2e 用例反查仓位与调度算法(是否众核 CPU 亲和/NUMA 相关)
- [ ] **跟 PD-Orchestrator 三件套(elastic-scaler/RSG/tidal)的 ofep**(0029/0030/0033/0044):读通用扩缩框架的算法插件接口与 tidal 的时间窗配置模型,评估 tidal 潮汐预扩容是否值得纳入我们弹性设计
- [ ] **关注 v26.06 rc.3(6-17~19)与 GA(6-29~30)**:rc.2 已锁特性,rc.3 看测试期发现了哪些回归;GA 看 InferNex-Bridge / PD-Orchestrator / ManyCoreScheduler 是否如期进 LTS 后续版本节奏
- [ ] **mind-cluster hang detection + 故障处理插件化代码精读**:`pkg/device/hangdetection` 的卡死判定阈值/算法、`pkg/server/token_bucket.go` 的重调度限流参数;对照我们 GPU 故障自治设计

## 原始材料

<details>
<summary>本周扫描清单(commits in 2026-06-01..2026-06-08)</summary>

**openFuyao 主组织活跃仓**:
- `InferNex`:`9169bcb feat(bridge): align v26.06 components, cache-indexer discovery, Hermes EPP contract, and KServe v1alpha2`(2026-06-05,+2068 行,引入 infernex-bridge / LLMISVC v1alpha2 入口 / PD-Orchestrator 增强组件)、`863b8bc docs(bridge): add LLMISVC examples on master`(2026-06-08,+1093 行,aggregate/PD llmisvc 示例)、`c027a1b chore: update infernex deployment examples`、`8525e21 fix retryconfig`、`0949be5 fix image format`
- `hermes-router`:`45ecac5 helm: add PD target selector for prefix-cache-producer`(2026-06-03)、`025fc24 fix epplib version、values.yaml image format`(2026-06-02)、README ×3
- `cache-indexer`:`9b5c5b3 add architecture plantuml diagram`、`e9625dc 更新中英文 readme`(纯文档)
- `weight-dispatcher`:`32a482e retry collective exchange chunks`、`2eaf1f8 support node url and reuse chunk crc`、`6ba1ae5 make node agent port configurable`、`3725403 make post-write crc verification optional`、`4acfc0b change the volume type and default config`、`31308c7 add UT`(RDMA/P2P 数据面硬化)
- `elastic-scaler`:`631bb8b Revert "bump version to 0.22.0"`、`07f49c2 fix update limit memory`、README ×4(稳定化打磨)
- `cluster-api-provider-bke`:**feat/upgrade-530 合入 master**:`87581f3 sync upgrade code to master`(2026-06-05)、`7c8d467 add parallel upgrade`、`dc1e915 fix k8s master/worker node components upgrade`、`c8d92fb skip not-installed component and adapt etcd`、`b0975eb use ssh upgrade bkeagent`、`2d291a1 del upgradepath/clusterversion/releaseImage ociRef`、`7fa362b get upgrade oci addr from bke-config`、`0a3efe5 fix ri store and use`(2026-06-08)
- `vNPU`:`f35c7f7 删除 aicore 算力必须是 5 的倍数的限制`(2026-06-08)、`255d6b3 Update ubs-virt submodule`、`7fb6bfc vCANN 编译问题解决`、`b9f8288 补充英文 readme`
- `ubs-k8s-enable`:`e1ddb1f fix 适配 rmrs pid 存在但无内存分配场景归还`(2026-06-04)、`cfe800b docs: add external dependency table`、`6c71c5d 直接引用 openeuler 源 hcom 包`
- `npu-dra-plugin`:`966afa3 update Dockerfile`(2026-06-02,无功能)
- `release-management`:`9b5263f feat(v26.06-rc.2): update Core/EagleEye/HermesRouter/InferNex/ManyCoreScheduler/NpuOperator/PDOrchestrator`(2026-06-03)、`5b52963 feat(v26.06-rc.2): update InferNex`(2026-06-02,新建 rc.2 目录)、`3449ca7 fix 26.06-rc2 coreversionconfig`、`e7bed5e add bkeagent download`(2026-06-06)
- `community`:`082937b add openfuyao-sandbox repo`(2026-06-01)、`ca9fe69 mark kubevirt as public`(2026-06-02)、`46367ce 刷新部分 SIG 描述`、`ed77419 create branch for upgrade-path`
- `e2e-auto-test`:大量新增 — `b9285e9 infernex inference backend + integration e2e`、`489219a infernex-bridge FIT e2e`、`7d6720b/c91c674 infernex_checker e2e`、`7af664a weight-dispatcher e2e`、`f4795d1 npu-dra-plugin 后端 e2e`、`3c3c245 众核-调度插件自动化测试`、`05b62a3 鲲鹏机密容器 E2E`、`6ec2e7b/e5e2e04 KubeVirt 前/后端 e2e`、`626bb94 cache-indexer P0/P1 e2e`、`363a70e elastic-scaler e2e`、`ed671a4 checkpoint e2e`、`d421c98 kata 跳过逻辑`、`f1df2f4 analyzer test cases`(2026-06-08)
- `ofep`:0040(Infernex 接入 kserve 适配层)为本周 Bridge 落地的设计依据;关联 0029/0030/0033/0044(扩缩/潮汐)

**openFuyao 主组织无活动仓**(窗口内无实质 commit):`npu-operator`、`volcano-ext`、`kae-operator`、`ub-network-device-plugin`

**上游 Ascend/mind-cluster**:本窗口 90+ commits,核心:
- `97c2505 支持 NPU 卡死检测-part1`(2026-06-03,+292 行)、`d98b20f 支持 NPU 卡死检测-part2`(+975 行,hang_detector_test)
- `50ce737 故障处理模块化`(2026-06-03,+1392 行,含 token_bucket 限流)、`e4affc4 / 59f8150 DP 故障处理插件化补充 DT`
- `af81ef7 添加健康探针检查服务公共代码`(2026-06-03,+865 行,横跨 7 组件)、`de77a24 探针服务文档`
- `24777c8 Infer Operator 支持自定义资源弹性扩缩容-part0`(+970 行)、`23e167c part1`(+806 行)、`414702b bugfix 支持自定义资源扩缩容`
- `6e6b102 修复进程级恢复场景节点宕机 volcano 不能快速重调度`(2026-06-06)
- `07066f1/558b174 [FD] Precise link positioning(精确链路定位)`、`31ebe6e BMC keywords update`、`df3a29b IPv6 socket error 日志解析`、`9fee63f remove AISW_CANN_AICPU_08`、`30fb5eb npu-exporter 上报 unknown 状态`
- `b2c8e12/7cadc95 [rdma-dp] 1825 故障检测 + DPU faultcheck`、`a41a00d/d14751f rdma dp ut 2/3`
- `71d46c9 dp 根据端口判断是否需要隔离`、`9329d4c device-plugin A5 适配 ipv6`、`75c6afb ascend-common dcmi_get_device_multi_utilization_rate_period`
- `c50e13b infer-operator 并发调度命名修正为 Parallel`、`6559790 Infer Operator 抽出单独章节介绍优先级调度与实例级重调度`(文档)

**v26.06 状态**:rc.2 已发布(6-02~03,略滑窗);全量测试期 6-01~6-15;rc.3 6-17~19;GA 6-29~30。v26.06 组件清单(16 包):Core / InferNex(0.24.0)/ HermesRouter / EagleEye / PDOrchestrator(elastic-scaler+RSG+tidal)/ ManyCoreScheduler / NpuOperator / LargeScaleCluster / KaeOperator / NumaAffinityPackage / ColocationPackage / MultiClusterService / RayPackage / Logging / Monitoring / MonitoringDashboard

**官方信息源**:
- 官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/)(news/release/blogs 仍"暂无内容")
- CSDN [blog.csdn.net/openFuyao](https://blog.csdn.net/openFuyao):4 篇(6-04 三篇 AI Native/Agent 观点文 + 6-01 KADC 汇总稿),无新 release note
- 新增公开仓:`openFuyao/kubevirt`(6-02)、`confidential-containers-deployment`(首页可见)

</details>
