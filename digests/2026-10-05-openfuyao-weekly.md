# OpenFuyao 周报 2026-10-05

窗口:2026-09-29 -> 2026-10-05(7 天)

## 摘要(3 条以内)
- InferNex 把**默认路由策略从 `decode-first` 改成 `kv-cache-aware`**(MR !255,改 `charts/infernex/values.yaml` 一行)。开箱即用的默认行为从"优先 decode 实例"变成"KVCache 亲和路由",等于官方把 hermes-router 的 KVCache-aware 路由确立为推荐缺省——这条思路和 llm-d/Dynamo 的 KVCache 路由同向,且是硬件无关、我们可直接借鉴的那类。
- Agent 沙箱继续拆分收敛:`flux-sandbox` 已独立成单独 repo,本周 `feat(chart): embed E2B API in scheduler`(MR !1)把 E2B API 直接内嵌进 scheduler StatefulState,并补**沙箱资源超分 + hugepages**(MR !2)。方向从上期"新开战线"进入"工程化/可部署性收敛"。
- 本周**无新 release、官网/CSDN 无新公告**,属典型非发版周;npu-operator、sig-orchestration-engine、docs 等多为文档/镜像名修正(npu-operator 补齐 CRD 参考/design/CHANGELOG/CONTRIBUTING,像在为发版准备文档),无能力级增量。

## 新功能 / 能力

- [InferNex GitCode](https://gitcode.com/openFuyao/InferNex) — 2026-09-29 `fix(helm): default routing profile to kv-cache-aware`(MR !255)。`values.yaml` 的 `routing.profile` 默认值由 `decode-first` 改为 `kv-cache-aware`;该字段支持的档位为 `""`(关闭)/ `random` / `kv-cache-aware` / `bucket`(仅 PD)/ `decode-first`。
  - 对比:这跟 llm-d、NVIDIA Dynamo 的路由层**走同一条路**——把"按 KVCache 命中/亲和选实例"做成默认的 EPP/router 策略,而不是简单 round-robin/random。差异只在实现绑了 hermes-router + vLLM-Ascend。
  - 启示:这是**通用、硬件无关**的架构决策,值得直接对齐。我们的 LLM serving 网关应把 KVCache-aware 作为默认路由 profile(而非 random),并把 `decode-first`/`bucket(pd)` 等做成可切换档位,PD/聚合两种拓扑共用一套路由抽象。
- [flux-sandbox GitCode](https://gitcode.com/openFuyao/flux-sandbox) — 2026-09-28 `feat(chart): embed E2B API in scheduler`(MR !1,改 scheduler StatefulSet + 新增 e2b-external-service/scheduler-service + values 共 +359 行)、`feat: 沙箱资源超分与 hugepages 资源支持`(MR !2);配套 [sig-agent-sandbox](https://gitcode.com/openFuyao/sig-agent-sandbox) 更新 `flux_sandbox.md`(超分/hugepages 配置、带 namespace 安装 opensandbox)。
  - 对比:E2B API 内嵌 scheduler = 把"Agent 沙箱 API 面"和调度面合到一个组件里,降部署复杂度;资源超分 + hugepages 是让 microVM 沙箱在 K8s 上更省资源、跑大页内存负载。整体仍是 E2B/Firecracker microVM 赛道(对标 E2B、Kata、K8s agent-sandbox)。
  - 启示:可借鉴的是**通用**部分——沙箱资源超分(warm buffer + oversubscription 提密度)、声明式容量这套模型跟硬件无关;E2B/Firecracker 后端与 hugepages 调优是可替换/可选项。若我们做 Agent 执行沙箱,"超分 + 预热池"是提并发密度的关键杠杆。

## AI 推理栈(InferNex / hermes-router / ...)

- [InferNex GitCode](https://gitcode.com/openFuyao/InferNex) — 除上面的默认路由改动外,2026-09-29/30 的 `docs: sync 26.09 README and fix Bridge vllm-ascend tags`(MR !259/!261)把 InferNex-Bridge chart 模板里的 `vllm-ascend` 从 `v0.18.0` 统一拉到 `v0.23.0`,并把示例里的 `0.23.0`(缺 v 前缀)规整为 `v0.23.0`;另有 infernex-checker 新增 `--dns-check-image` 参数(MR !252)。
  - 启示:再次印证 InferNex↔vLLM-Ascend 强版本耦合,且 Bridge 之前还停在 v0.18.0 与顶层 chart 不一致——这类"多处镜像 tag 漂移"说明他们也在手动维护兼容矩阵。我们若支持昇腾,必须把 vLLM-Ascend × InferNex/Bridge × CANN 做成显式、单一来源的兼容矩阵,避免 chart 各处 tag 不一致。
- hermes-router 本周无新提交;路由能力的"信号"这周落在 InferNex 侧把 kv-cache-aware 设为默认(见上)。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [npu-operator GitCode](https://gitcode.com/openFuyao/npu-operator) — 2026-09-29 一批**纯文档**提交:补齐 CRD 参考文档并校正、新增 design/CHANGELOG/CONTRIBUTING、README 加文档索引(MR !118)。无代码/能力增量。
  - 判读:文档体系化(CRD reference + CHANGELOG + CONTRIBUTING)通常是**临近版本发布/对外推广**的准备动作,值得留意 v25.12 LTS 或季度版的发版节奏。
- `npu-dra-plugin`、`vNPU`、`npu-driver-installer`、`npu-container-toolkit`、`kae-operator` — 本轮浅克隆未见 2026-09-29 后实质提交(npu-dra-plugin 上期的标准 `resource.kubernetes.io/numaNode` 暴露仍是最近实质变更)。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- [sig-orchestration-engine GitCode](https://gitcode.com/openFuyao/sig-orchestration-engine) — 2026-09-28/29 仍是 serverlessdb_operator 文档更新、镜像版本/镜像名更新(含 `acl-client-update` 镜像名),无新能力。上期解读的 RoadMap(many-core-orchestrator 干扰检测+重调度、pod-live-migration 热迁移)本周无代码推进。
- [sig-installation GitCode](https://gitcode.com/openFuyao/sig-installation) — 2026-09-29 补"静态 pod 配置热更新指导手册"(MR !251),属部署运维文档。
- [cluster-api-provider-bke GitCode](https://gitcode.com/openFuyao/cluster-api-provider-bke) — 2026-09-30 `feat(worker-delete): log scale-in node list and machine-to-node mapping`(MR !501),缩容时记录节点清单与 machine→node 映射,属可观测性小改进。
  - 判读:BKECluster(Cluster API provider)是 OpenFuyao 的集群生命周期底座,走的是标准 Cluster API 路线(通用 K8s 生态做法),缩容日志完善是工程打磨,非架构变化。
- `volcano-ext`、`ub-network-device-plugin`、`ubs-k8s-enable`、`ub-ssu-csi` — 本轮未见 2026-09-29 后实质提交。

## 官方动态
- 官网(openfuyao.cn)news/blog/活动 三段仍"暂无内容";CSDN 官方博客最新停在 2026-08(Agent Sandbox SIG 招募、InferNex TTFT 优化、6-7 月运作报告、KubeVirt 容器-VM 统一编排),**9 月下旬至今无新公告**。
- 本周无 release/tag 更新,多数仓仍在 v26.6.0 基线。**非发版周**,信号全部来自代码仓。

## 跟我们产品的对比
- **同一路线(该抄)**:① InferNex 把 `kv-cache-aware` 设为默认路由 profile,和 llm-d/Dynamo 一致——我们的 serving 网关应同样把 KVCache 亲和路由作为默认、其余策略作为可切档位;② flux-sandbox 的"资源超分 + 预热池"提沙箱密度,这套模型硬件无关,可直接借鉴。
- **分叉/昇腾专用(记录不照抄)**:vLLM-Ascend 深绑、UB/vNPU 相关能力依旧是昇腾硬件专用,属竞品差异化。
- **我们该补**:① serving 路由默认值从 random 升到 KVCache-aware,并统一 PD/聚合的路由抽象;② 若做 Agent 沙箱,补"超分 + warm buffer"的密度杠杆;③ 建一张单一来源的"推理后端(vLLM-Ascend/vLLM)× 编排层 × 驱动"兼容矩阵,避免 chart 各处 tag 漂移(InferNex 本周就踩了 Bridge 停在 v0.18.0 的坑)。

## 值得跟进
- [ ] 读 InferNex `routing.profile` 的实现:确认 `kv-cache-aware` 默认档位依赖哪些 hermes-router 配置(tokenizer sidecar、KVCache 索引来源),以及 `bucket(pd)` 档位的适用边界,对齐我们的路由抽象。
- [ ] 跟踪 `flux-sandbox` 独立 repo 的演进:E2B API 内嵌 scheduler 后的组件边界、资源超分/hugepages 的调度语义,评估能否用 Kata/gVisor 替换 E2B 后端。
- [ ] 留意 `npu-operator` 文档体系化是否是发版前奏,关注 v25.12 LTS / 季度版 release 窗口。
- [ ] 继续盯 `sig-orchestration-engine` RoadMap 的 many-core-orchestrator(干扰检测+重调度)、pod-live-migration,本周无进展但仍是通用在离线混部/热迁移方向的重点。

## 原始材料

<details>
<summary>本次扫描清单(2026-09-29 -> 2026-10-05)</summary>

活跃/有信息量:
- https://gitcode.com/openFuyao/InferNex
  - 2026-09-29 `fix(helm): default routing profile to kv-cache-aware`(MR !255,decode-first → kv-cache-aware)
  - 2026-09-29/30 `docs: sync 26.09 README and fix Bridge vllm-ascend tags`(MR !259/!261,Bridge v0.18.0 → v0.23.0)
  - 2026-09-29 `docs: add --dns-check-image parameter ... infernex-checker`(MR !252)
- https://gitcode.com/openFuyao/flux-sandbox
  - 2026-09-28 `feat(chart): embed E2B API in scheduler`(MR !1,+359 行)
  - 2026-09-28 `feat: 沙箱资源超分与 hugepages 资源支持`(MR !2)
  - 2026-09-29 `chore(config): remove legacy manifests`(MR !4)
- https://gitcode.com/openFuyao/sig-agent-sandbox
  - 2026-09-28/29 `flux_sandbox.md` 新增超分/hugepages 配置、带 ns 安装 opensandbox(MR !11/!15)
- https://gitcode.com/openFuyao/npu-operator
  - 2026-09-29 补 CRD 参考/design/CHANGELOG/CONTRIBUTING + README 文档索引(MR !118,纯文档)
- https://gitcode.com/openFuyao/sig-orchestration-engine
  - 2026-09-28/29 serverlessdb_operator 文档、镜像版本/acl-client-update 镜像名更新(MR !145/!147/!148)
- https://gitcode.com/openFuyao/docs
  - 2026-09-28/29 TOC 对齐、acl-client-update 镜像仓变更(MR !1467/!1468)
- https://gitcode.com/openFuyao/sig-installation
  - 2026-09-29 静态 pod 配置热更新指导手册(MR !251)
- https://gitcode.com/openFuyao/cluster-api-provider-bke
  - 2026-09-30 `feat(worker-delete): log scale-in node list and machine-to-node mapping`(MR !501)
- https://gitcode.com/openFuyao/eagle-eye
  - 2026-09-29 README 更新(MR !30,纯文档)

本轮无实质增量(未见 2026-09-29 后实质提交):
- https://gitcode.com/openFuyao/hermes-router
- https://gitcode.com/openFuyao/npu-dra-plugin
- https://gitcode.com/openFuyao/vNPU
- https://gitcode.com/openFuyao/volcano-ext
- https://gitcode.com/openFuyao/ub-network-device-plugin
- https://gitcode.com/openFuyao/ub-ssu-csi
- https://gitcode.com/openFuyao/npu-driver-installer
- https://gitcode.com/openFuyao/npu-container-toolkit
- https://gitcode.com/openFuyao/kae-operator
- https://gitcode.com/openFuyao/bkeadm, bke-manifests, console-website, CubeSandbox

官方源:
- https://www.openfuyao.cn/zh/(news/blog/活动 暂无内容)
- https://blog.csdn.net/openFuyao(最新停在 2026-08,无 9 月下旬后新公告)
</details>
