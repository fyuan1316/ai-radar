# OpenShift AI 周报 2026-05-04

窗口:2026-04-27 → 2026-05-04(7 天)

## 摘要(3 条以内)
- Dashboard 把 NVIDIA NeMo Guardrails 接入 gen-ai playground(状态端点 + playground integration),叠加既有的 LlamaStack/TrustyAI 形成"内嵌 LLM 安全栈"路线
- NIM serving 单独开包(`nim-serving` 包 + `nimWizard` 临时 dev feature flag),OAI 在为 NVIDIA NIM 开 wizard 化部署入口铺路,与 KServe ServingRuntime 并存
- MaaS(Model-as-a-Service)多租户限流落地:修了 `TokenRateLimitPolicy` 与 `RateLimitPolicy` 冲突,manifest 切到 perses.dev RBAC,意味着 OAI 把 MaaS 仪表盘从 Grafana 迁向 Perses

## 新功能 / 能力

- [NemoGuardrails 状态端点 + playground integration](https://github.com/opendatahub-io/odh-dashboard/pull/7435) — gen-ai 包加 NemoGuardrails 状态接口与 playground 联动
  - 启示:OAI 选择把 LLM 安全护栏做成 dashboard 内嵌"开箱"组件而非外置代理。我们做安全/合规模块时,`Guardrails-as-a-runtime` 与 `TrustyAI Detector` 这两条线已经在 OAI 同台对齐,我们的 LLM 安全侧需要决定是和 NeMo Guardrails 合还是替换
- [HuggingFace 离线环境变量注入到 LlamaStackDistribution](https://github.com/opendatahub-io/odh-dashboard/pull/7439) — `HF_HUB_OFFLINE`、`TRANSFORMERS_OFFLINE` 等 env 注入
  - 启示:gen-ai distribution 默认走完全离线,适配气隙环境的部署细节;我们的离线场景配置 checklist 可以对照这一组 env 校验
- [nim-serving 包 + nimWizard 临时 dev feature flag](https://github.com/opendatahub-io/odh-dashboard/pull/7421) — Dashboard 拆出 NIM 专属包,加 wizard 入口
  - 启示:OAI 把 NIM 当作"半官方一等公民"做产品化(独立 wizard,不复用 ServingRuntime 通用面板),说明 NIM 成本/性能优势在企业场景里被验证;我们要么对应做 wizard,要么明确放弃 NIM 走 vLLM-only 路线
- [MaaS Tiers TokenRateLimitPolicy / RateLimitPolicy 冲突修复](https://github.com/opendatahub-io/odh-dashboard/pull/7414) — Kuadrant 二种限流策略并存时的合并语义
  - 启示:OAI 的 MaaS 多租户限流落到 Kuadrant 上,`Token` 维度和"按请求数"维度并存;我们如果做对外暴露 LLM 服务,这是参考实现
- [DEV_IMPERSONATE_TOKEN 支持 OAuth/IDP 用户](https://github.com/opendatahub-io/odh-dashboard/pull/7442) — 后端开发态多用户调试支持
- [AutoRAG 过滤系统命名空间 + AutoML/AutoRAG 删除已完成 pipeline run](https://github.com/opendatahub-io/odh-dashboard/pull/7380) — AutoRAG 是新出现的产品线,AutoML 也在持续成型
  - 启示:OAI 已把 RAG 自动化(AutoRAG)与 ML 自动化(AutoML)同框设计,RAG 不再只是"应用层";我们做模型服务平台时要把 RAG 流水线视为一类作业类型,不仅仅是 inferencing endpoint
- [统一模型 schema 兼容 3.5 与 legacy 3.4](https://github.com/opendatahub-io/odh-dashboard/pull/7408) — `automl` 模块 schema 演进
- [MCP deployments 重组 + namespace 路由参数 + 双向项目同步](https://github.com/opendatahub-io/odh-dashboard/pull/7405) — Model Context Protocol 工具迁到 odh/ 路径
  - 启示:MCP 在 OAI 里走的是"per-project deployment"形态,把 MCP server 当作 project-scope 的工具池;我们做 agent/工具集成时这是模板
- [opendatahub-operator MCP tools 增强](https://github.com/opendatahub-io/opendatahub-operator/pull/3483) — event 计数、summary 模式、managed resources、容器发现
  - 启示:Operator 端把 MCP tools 当作"可被 agent 调用的运维 API",这是 Operator 暴露给 LLM agent 的能力面
- [移除 Managed Addon manifests](https://github.com/opendatahub-io/opendatahub-operator/pull/3470) — 不再支持 Managed Addon 形态
  - 启示:OAI 彻底切到 OLM-only 安装路径,Cloud Services Managed Addon 路线下线
- [移除 legacy managed monitoring stack](https://github.com/opendatahub-io/opendatahub-operator/commit/2ea33f0ac79f31f5c11f35a810c50b5dd18afa65) — 旧 managed monitoring 完全删除
  - 启示:OAI 监控栈已完成迁移,新栈走 perses.dev + OpenTelemetry,我们对应组件对标点变了
- [MaaS manifest 引入 perses.dev RBAC fix](https://github.com/opendatahub-io/opendatahub-operator/commit/eff2cc3c4c2611307a133a18ad8bbf25634accc3) — perses.dev 作为新仪表盘
  - 启示:Grafana → Perses 的迁移已经动到 manifest 层,Perses 是 CNCF sandbox 项目;我们若仍依赖 Grafana,可观测性栈未来 1-2 个季度需要评估迁移代价

## 架构 / 依赖变化

- [trainer 镜像参数从 torch291 回退到 torch210](https://github.com/opendatahub-io/opendatahub-operator/pull/3491) — torch 2.9 -> 2.10
  - 启示:训练镜像短期内还是跟着 PyTorch 主线,torch 2.10 是当前 OAI 训练栈基线
- [KServe sync upstream/master to odh/master 4-26](https://github.com/opendatahub-io/kserve/pull/1445) — odh-fork 对齐上游
- [skip INFERENCE_SERVICE_NAME 注入避免升级重启](https://github.com/opendatahub-io/kserve/pull/1435) — RHOAIENG-59268
  - 启示:KServe 升级时 pod restart 一直是 OAI 的痛点,这个修复对滚动升级语义有意义,我们如果 fork KServe 要 cherry-pick

## 上游生态整合动向

- KServe(odh-fork)与上游每周同步的节奏稳定(此周 1 次大 sync)
- model-registry 与上游 kubeflow/model-registry 多次同步(`[pull] main from kubeflow:main` 共 3 次:#1732 #1729 #1723);odh-fork 持续追踪上游
- LlamaStack 仍是 gen-ai 默认 LLM 运行时容器;NemoGuardrails 是与之并列的安全 sidecar
- Perses(CNCF sandbox)取代 Grafana 进入 OAI 的可观测性栈

## 值得跟进
- [ ] 读 #7435 NemoGuardrails playground 集成的具体 CR/路径,确认是否走 NeMo Guardrails OSS 还是闭源 NIM 包
- [ ] 跟 NIM Wizard(#7421)演进:wizard 流程定型后比对我们模型部署 wizard 的差距
- [ ] 评估 Perses 替代 Grafana 在我们产品里的代价(查我们当前 dashboard 是否有 Perses-incompatible 用法)
- [ ] AutoRAG / AutoML 作为新作业类型在 pipeline 中的实现方式(看 odh-dashboard 后端的 schema)
- [ ] Cherry-pick KServe #1435 升级 pod 不重启的修复

## 原始材料

<details>
<summary>Releases(本周窗口内无新 release,最新 release 早于窗口)</summary>

- opendatahub-operator: v3.4.0 (2026-04-08), 之前 v3.4.0-ea.2 (2026-03-10)
- odh-dashboard: v3.4.0 (2026-04-16),v3.4.2-odh (2026-04-06)
- kserve(odh): odh-v3.4 (2026-04-06)
- model-registry: v0.3.8 (2026-04-03)
- notebooks: v1.43.0 (2026-04-05)
- trustyai-service-operator: odh-3.4-final (2026-04-07)
- data-science-pipelines-operator: v2.18.0 (2025-11-11)
</details>

<details>
<summary>Merged PR 计数</summary>

- odh-dashboard: 44
- notebooks: 35
- opendatahub-operator: 23
- model-registry: 8
- trustyai-service-operator: 3
- kserve(odh-fork): 2
- data-science-pipelines-operator: 0
</details>
