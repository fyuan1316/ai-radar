# OpenFuyao 周报 2026-04-21

扫描窗口:2026-04-14 至 2026-04-21(今天周二)

## 摘要

- **InferNex 性能叙述换骨**:README 把"KVCache aware / PD 分桶 / 可观测"三段拆法弃掉,改以**工具&智能体场景**和**系统提示复用场景**两类负载直接给百分数(TTFT −37%/−46%、E2EL −9%/−17%);chart 默认命名空间由 `istio-system` 改为 `ai-inference`,版本从 0.20.0 升到 0.22.1。对标 vLLM 上游的 bench 叙事(agentic workload)正在形成。
- **`npu-dra-plugin` 补上全量单元测试**(+10042 行,覆盖 kubeletplugin / webhook / dcmi / state / npu profile),从"4 月初刚适配 Ascend910"到"接近产线就绪"只隔两周。昇腾 DRA 的工程速率明显在加快。
- **昇腾栈本周无新 RFC**,全部是组件级 fix/重构:DP 故障升级策略可动态更新(fda5a70)、ascend-common AutoInit 重构(5893600)、Ascend950PR 系列 collector port 策略重构(05c4cb9)、containerd 场景 docker runtime 配置收敛(8c7d9f3);volcano 对 mindie 任务跳过网络健康检查(70364d1)。
- **官方 0 公告**:openfuyao.cn、docs.openfuyao.cn(Last-Modified 停在 4/10)、CSDN `openFuyao` 号窗口内无新文。距 v26.03 发版第 2 周、消化期延续。

## 新功能 / 能力

### AI 推理栈

- **[InferNex README 性能与部署描述重写](https://gitcode.com/openFuyao/InferNex/commits/master)** —— commit `df93b0d`(2026-04-21,MR !117)。三处实质变化:
  1. **性能基准叙述换骨**:旧版按"KVCache aware 路由 / PD 分桶 / 可观测"三段列,新版合并为"工具&智能体应用场景"(Mooncake toolagent trace,23608 请求,输入均值 8596 / 输出 182 token,聚合侧 TTFT −37%/E2EL −9%,PD 侧 TTFT −24%/E2EL −19%)和"多轮对话系统提示词复用"(32 用户 × 30 轮,system prompt 4096 token,聚合侧 TTFT −46%/E2EL −17%)两段,旧的"完全随机请求场景"被删掉
  2. **默认命名空间从 `istio-system` 改为 `ai-inference`**:chart 不再要求绑进 istio-system
  3. **chart 版本由示例的 0.20.0 升到 0.22.1**
  - 启示:**叙事变了才是重点**——OpenFuyao 在刻意向"agentic workload"基准靠拢,这正是 llm-d、vLLM 上游(PD disagg + prefix caching)近期推的角度;我们产品的推理性能叙事如果还停留在"vLLM vanilla vs. 我们"的单请求对比,是落后一代的讲法。另外把 inference-gateway 从 `istio-system` 解耦也是好实践,避免推理栈跟 mesh 控制面共享故障域。
- **[InferNex 移除 `hccn_tool` 宿主挂载](https://gitcode.com/openFuyao/InferNex/commits/master)** —— commit `768068a`(2026-04-18,MR !116)。`inference-backend/values.yaml` 删掉 `/usr/bin/hccn_tool` 的 hostPath 绑定
  - 启示:这是个 Day 2 运维修正。之前 inference-backend 容器挂宿主 `hccn_tool`(华为 HCCN 网络诊断工具),发现用不上就拿掉。信号是 InferNex 在**去掉对昇腾专有工具的硬依赖**,朝着更"标准 K8s pod"形态演进——这对通用化有利,也让我们未来适配时少一个耦合点。
- **[InferNex aggregated 示例修正 elastic-scaler target](https://gitcode.com/openFuyao/InferNex/commits/master)** —— commit `8fc1c02`(2026-04-17,MR !115)。`vllm-aggregated-random-values.yaml` 里 `targetResources` 原本错填了 PD 分离模式的 prefill+decode deployment,改为 aggregated 单 deployment。纯 example 修正
- **[elastic-scaler 修复 LWS leaderTemplate 缺失时误注入 label](https://gitcode.com/openFuyao/elastic-scaler/commits/master)** —— commit `05a7551`(2026-04-18,MR !40)。`resourcescalinggroup_controller.go` 新增 `mergeTemplateLabelsIfPresent`,当 `leaderWorkerTemplate.leaderTemplate` 未设置时不再强行合 label;UT 新增 `TestCreateGroupResourceLeaderWorkerSetDoesNotCreateMissingLeaderTemplate`
  - 启示:具体细节但指向一个明确结论——elastic-scaler 已在支持 **LeaderWorkerSet**(LWS,kubernetes-sigs 下的多角色工作负载 CRD,leader + worker 分模板)。LWS 是 K8s 社区为 LLM 多节点推理专门设计的抽象,vLLM + KServe 那边也在看它。OpenFuyao 把 LWS 纳入 elastic-scaler 的 target 形态,说明他们认可 LWS 作为"PD 分离 / MoE 分布式推理"的 K8s 原语。我们做弹性时对这类 workload 也要有原生支持,不能只支持 Deployment。
- **hermes-router / eagle-eye / cache-indexer:本周无提交**(hermes-router HEAD 停在 4/10,eagle-eye 停在 4/9,cache-indexer 停在 3/10)

### 昇腾资源管理

- **[`npu-dra-plugin` 全量单元测试](https://gitcode.com/openFuyao/npu-dra-plugin/commits/br_init_dev)** —— commit `d1533cc`(2026-04-20,MR !14)。+10042 / -498 行,16 个测试文件,覆盖:api(register、zz_deepcopy)、cmd/ascend-npu-dra-kubeletplugin(cdi、dcmi、driver、health、main、state)、cmd/ascend-npu-dra-webhook/main、internal/profiles/npu、pkg/dcmi、pkg/flags/kubeclient。并修了 health.go nil 检查防 panic,补了 `pkg/dcmi/dcmi_stub.go` 支持非 Linux 平台编译
  - 启示:**DRA 路线从 POC 走向生产就绪的明显信号**。工程化指标里"UT 覆盖率上去"意味着开始接 CI gate,模块趋于稳定。对我们 DRA 选型的意义:(a) 昇腾侧落地速度比想象快,做评估时不能拿"还没 UT、还不稳"当借口;(b) 他们的测试组织方式(模块分层测、mock dcmi、stub 非 Linux 平台)可以当参考实现。
- **[`npu-dra-plugin` Dockerfile 更新 + MR !11 双尾](https://gitcode.com/openFuyao/npu-dra-plugin)** —— `da80452`(2026-04-15)。配合上周 Ascend910 适配的收尾,无大变化
- **[DP 故障升级策略动态更新](https://gitcode.com/Ascend/mind-cluster)** —— `fda5a70`(2026-04-20,MR !3290)。`ascend-device-plugin/pkg/common/upgradefault.go` 新增 `checkAndUpdateExistingUpgradeFaults`:在故障策略配置更新时,遍历已有 upgrade fault 缓存并按新配置(FrequencyUpgradeType / DurationUpgradeType / AutofillUpgradeType)重算,fault level 变化时记录到日志。新增 `getUpdatedFrequencyFaultReason` 等 4 个辅助函数
  - 启示:配置热更新类修复,昇腾 device-plugin 在提升"运行中调整故障阈值无需重启"的能力。通用 K8s device-plugin 普遍没有这种细粒度故障等级框架,我们要做"节点故障自愈策略"时可以借鉴这种"分类 fault + 可热调阈值"的设计。
- **[`ascend-common` AutoInit 重构](https://gitcode.com/Ascend/mind-cluster)** —— `5893600`(2026-04-17,MR !3282)。`devmanager.go` 343 行重写,新增 a950mgr.go,devmanager_common.go 拆出公共逻辑,v2 接口简化(-220 行)。跨机型(910/910A3/950)的 devmanager 抽象收敛
  - 启示:这是"多机型支持"的工程化内功,没直接对外能力变化,但说明 Atlas 950 / 910 / 910A3 在同一 device manager 栈里的收敛正在进行——直接影响 device-plugin、npu-exporter、dra-plugin 对新机型的适配速度。
- **[`npu-exporter` Ascend950PR 系列 collector 端口策略重构](https://gitcode.com/Ascend/mind-cluster)** —— `05c4cb9`(2026-04-18,MR !3271)。`hccn/hccn_tool.go` +116 行,`collector/common` 新增 `NpuDevPortInfo{devPortMap, totalPort}` 类型;network / optical / ub 三类 collector 的端口范围策略全部从 metrics 目录上移到 common 目录
  - 启示:硬件指标采集的端口抽象在向"机型特化 + 公共层"分层。对我们做跨厂商 xPU 监控(NVIDIA DCGM、AMD、昇腾)时,"端口/链路/光模块 → 统一指标模型"是一个可以复用的思路。

### 调度 & 集群

- **[volcano 忽略 mindie 任务对网络健康状态检查](https://gitcode.com/Ascend/mind-cluster)** —— `70364d1`(2026-04-20,MR !3216)。`ascend-for-volcano/internal/npu/base/frame.go`(删 `IsInstanceOfJobGroup` + 简化 `CheckNodeNPUByTask` 参数),并在 Ascend910A3 module910a3x16 / superpod、Ascend910B module910bx16 三个机型 frame 同步调整
  - 启示:**mindie(昇腾推理引擎)任务绕过 Volcano 的网络故障卡过滤逻辑**。原因推测:推理任务对卡间互联(HCCL)的要求远低于训练,卡之间几乎不跨机通信,把训练态的"网络故障 → 不调度"逻辑硬套到推理上会导致推理实例没地方落。信号是**昇腾调度层面开始区分"训练任务"vs"推理任务"的策略**——我们做 batch/online 差异化调度时,这种基于 workload 类型豁免故障域检查的思路值得借鉴。
- **[containerd 场景 docker runtime 配置优化](https://gitcode.com/Ascend/mind-cluster)** —— `8c7d9f3`(2026-04-21,MR !3188)。`ascend-docker-runtime/install/process/containerd_process.go` 286 行重写,配套安装/卸载文档更新。这是昇腾容器运行时注入逻辑的重构,对 runC / containerd 的兼容性收敛
- **[taskd agent 故障上报时间增加超时](https://gitcode.com/Ascend/mind-cluster)** —— `b9e4f3d`(2026-04-20,MR !3305),cherry-pick。训练链路稳定性 fix
- **[taskd C++ 析构崩溃修复](https://gitcode.com/Ascend/mind-cluster)** —— `69d9a05`(2026-04-16,MR !3294)。已在上周报告中覆盖,此处不重复

### 网络 & 安装

- **[ub-network-device-plugin 健康检查实现](https://gitcode.com/openFuyao/ub-network-device-plugin/commits/br_noncom_container_20260228)** —— commit `50575b9`、`0b2ac16`、`c227449`(2026-04-15,MR !45)。`fix: 实现健康检查接口，校验ubse socket文件存在`。UB 网络专用,与通用 K8s AI 栈无对标
- **npu-driver-installer / npu-node-provision / kae-operator / npu-operator / volcano-ext / ray-service**:本周无提交

### mind-cluster 文档类 fix(合并收录,单列占字数不值)

- `ac9cf75`(2026-04-20): 软切分任务不支持分布式场景文档修正
- `c3dc210`(2026-04-20): pytorch 环境变量资料修正
- `a9ff897`(2026-04-17): mindio acp 编译链接优化

## 官方动态

- **openfuyao.cn 首页 / news / blog**:SPA 骨架无实质列表数据,通过 CSDN 镜像确认窗口内**零新文**
- **docs.openfuyao.cn**:Last-Modified 停在 `Fri, 10 Apr 2026 03:33:16 GMT`,窗口内无更新
- **CSDN blog.csdn.net/openFuyao**:最新文仍是 2026-04-08 v26.03 发版稿(窗口外)
- **本周社区层面零公告**。距 v26.03 发版正好 2 周,按历史节奏下一次官方动作预计 5 月初(月度运作报告 / v26.06 功能预告)

## 跟我们产品的对比

| 维度 | OpenFuyao / 昇腾栈 本周动向 | 我们 | 差异 / 要补的 |
|------|----------------------------|------|---------------|
| 推理性能叙事 | **工具&智能体场景 + 系统提示复用**,TTFT −37%/−46% 量化 | 偏"vs vLLM vanilla" | 应加 agentic workload、system prompt 缓存场景的 bench,跟 vLLM 上游 / llm-d 叙事对齐 |
| 弹性 target 形态 | elastic-scaler 支持 **LeaderWorkerSet**(LWS) | KServe InferenceService → Deployment | 评估 LWS 作为 PD 分离 / MoE 多角色推理的原语,我们弹性组件也要 LWS 原生支持 |
| DRA 成熟度 | npu-dra-plugin 全量 UT,16 文件 +10K 行,接近 CI gate | - | 昇腾 DRA 不再是"概念验证"阶段;我们做 xPU DRA 选型时要把它当可对标实现而非跟随参照 |
| 故障策略 | DP 热更新故障升级策略(频率/时长/Autofill 三类) | 节点级健康检查 | "多类 fault + 可热调阈值"是节点自愈框架的参考设计 |
| 推理 vs 训练调度差异化 | volcano 给 mindie 任务豁免网络故障卡过滤 | batch/online 分别按通用规则 | 考虑按 workload 类型定制化调度豁免规则 |
| 推理容器解耦 | InferNex 默认命名空间脱离 istio-system,移除 hccn_tool 挂载 | 推理栈与 mesh 耦合视情况 | 架构上把 gateway / mesh 与推理 pod 故障域隔开,避免共死 |

## 值得跟进

- [ ] **读一遍 InferNex v26.03 的 `InferNex整体性能测试报告-v26.03.md` 和 `eagle-eye性能测试报告-v26.03.md`**(在 `openFuyao/sig-ai-inference/reports/performance/` 目录),把"工具&智能体场景"和"系统提示复用场景"的测试配置、负载生成方式抠清楚,准备 mirror 一份同类 bench
- [ ] 跟 `elastic-scaler` 的 LWS 支持进展:读 `resourcescalinggroup_controller.go` 全文,列出它认可的 target kind(Deployment / StatefulSet / LeaderWorkerSet / ... ),判断跟 KServe KPA 的 scale target 抽象差异
- [ ] 下周看 `npu-dra-plugin` 是否发 v1.1 tag(当前 1.0.0 是 3 月初,全量 UT 一上,按节奏应有新 tag)
- [ ] 5 月初盯 CSDN openFuyao / openfuyao.cn,等 v26.06 预告或月度运作报告;下一份 infer-operator RFC 的增量变更(如果有的话,会落在 `mind-cluster/docs/rfc/26.0.0/features-inference-workload.md`)

## 原始材料

<details>
<summary>本周扫描清单(点开)</summary>

**openFuyao 组织(GitCode,`git clone --depth 100`)**
- 有提交:InferNex(3 commits)、elastic-scaler(1 commit)、npu-dra-plugin(2 commits,含全量 UT)、ub-network-device-plugin(3 commits,健康检查)、sig-ai-inference(1 commit,仅 4/14 chore)
- 本周无提交:hermes-router、eagle-eye、cache-indexer、npu-operator、kae-operator、volcano-ext、npu-driver-installer、npu-node-provision、ray-service
- 探测失败:`openFuyao/pd-orchestrator`(403,权限限制或未开源)、`openFuyao/openFuyao`(403)
- tag:本周 openFuyao 组下无新 tag;最新 tag 为 `npu-dra-plugin 1.0.0`(2026-03-02)、`volcano-ext v1.10.0`(2024-09-19,长期不动)

**ascend/mind-cluster(GitCode,`git clone --depth 100`)**
- 窗口内 19 个 merge MR,主要变更:
  - DP:`fda5a70`(故障升级策略更新)
  - ascend-common:`49b822a`(dcmiv2 适配)、`5893600`(AutoInit 重构)
  - npu-exporter:`05c4cb9`(Ascend950PR collector port)
  - ascend-for-volcano:`70364d1`(mindie 忽略网络健康)
  - ascend-docker-runtime:`8c7d9f3`(containerd 优化)
  - taskd:`b9e4f3d`(agent 故障上报超时)、`69d9a05`(析构崩溃,已计入上周)
  - ascend-faultdiag:`9f13eb2`(时间过滤)、`1db9126`(阈值)、`f947e8d`(link status 修改)
  - docs:`ac9cf75`、`c3dc210`
  - mindio:`a9ff897`、`9707e53`、`acfd830`
- **RFC 目录本周无新增**(仅 4/10 的 5 个 RFC,上周报告已覆盖)
- 本周无新 tag / release

**官方信息源**
- openfuyao.cn(news/blog)、docs.openfuyao.cn(HEAD Last-Modified 2026-04-10)、CSDN `openFuyao`:**零更新**
- Gitee 镜像(`gitee.com/openfuyao`):403 / Not Found Project(推断已下线或改为私有)

**抓取方式验证**
- GitCode 仓 `git clone --depth 100` 稳定可用(上周结论延续)
- WebFetch 对 GitCode 仓页面、openfuyao.cn SPA 仍返回 JS 壳,不可用
- CSDN blog WebFetch 可用,用于官方博客窗口探测

</details>
