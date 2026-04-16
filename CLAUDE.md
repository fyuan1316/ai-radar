# ai-radar

个人情报站,用 Claude Code 跑定期调研任务。

## 使用方式

1. 进到这个目录,启动 `claude`
2. 告诉它要跑哪个任务,例如 "跑一下 tasks/oai-weekly.md"
3. Claude 会按任务描述去抓数据、做分析、写 digest、推飞书

## 工作约定

- **产出归档**:所有分析产出写到 `digests/YYYY-MM-DD-<task>.md`,纯 markdown
- **推送**:摘要通过飞书 webhook 推到用户个人 bot,webhook 读自 `.env` 里的 `FEISHU_WEBHOOK`
- **秘密管理**:任何 token、webhook 只允许出现在 `.env`(已 gitignore),绝不写进 digest 或 commit
- **抓取**:优先用 GitHub API(`gh` CLI,已登录)、官方 RSS、文档站 git 仓库,不硬爬网页
- **语言**:digest 用中文撰写,面向用户本人(云原生 AI 基础设施方向产品经理/开发)
- **风格**:不堆砌,每条结论带来源链接;重点标"对我们产品的启示"

## 用户视角

用户做云原生 AI 基础设施产品,对标 OpenShift AI(OAI)。关心:
- 新功能与架构变化
- 与上游(KServe/Kubeflow/vLLM/Ray 等)的整合方式
- 企业级能力(多租户、GPU 调度、模型生命周期、安全合规)
- 与我们自家产品的差异点
