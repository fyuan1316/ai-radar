# ai-radar

个人情报站,用 Claude Code 跑定期调研任务。

## 使用方式

1. 进到这个目录,启动 `claude`
2. 告诉它要跑哪个任务,例如 "跑一下 tasks/oai-weekly.md"
3. Claude 会按任务描述去抓数据、做分析、写 digest、推飞书

## 工作约定

- **产出归档**:所有分析产出写到 `digests/YYYY-MM-DD-<task>.md`,纯 markdown
- **推送**:摘要通过飞书 webhook 推到用户个人 bot,webhook 读自 `.env` 里的 `FEISHU_WEBHOOK`。两条硬约束:
  - **先 `git push` 再推飞书**:仓库 private,未 push 前简讯里的 GitHub 链接全是 404
  - **简讯必须纯文本**:默认 `msg_type=text` 不渲染 markdown,简讯里不写 `**粗体**`、`[标题](url)` 等语法
  - **链接必须 `https://` 开头的完整 URL**:飞书才会识别成可点击超链接;`github.com/...`(缺 scheme)、`#123`、相对路径都打不开
  - 详细规范见 `tasks/oai-weekly.md` 的"推送飞书"段
- **秘密管理**:任何 token、webhook 只允许出现在 `.env`(已 gitignore),绝不写进 digest 或 commit
- **抓取**:**统一用 `curl` 打 GitHub API**(`https://api.github.com/...`),不使用 `gh` CLI。原因:沙箱里 `gh` 未认证,每次都卡 `gh auth login`。
  - 匿名 curl 够用,但**速率限制只有 60 次/小时/IP**,跑一次周报会打满。建议 `.env` 里设置 `GITHUB_TOKEN`(细粒度 PAT,只授 public repo read 权限即可),curl 带 `Authorization: Bearer $GITHUB_TOKEN` 头,余量升到 5000/h
  - GitCode / Gitee(openfuyao)走 `git clone --depth 1` + 本地读(详见 openfuyao task)
  - arxiv 走 `http://export.arxiv.org/api/query` curl
  - 官方 RSS、文档站用 WebFetch
- **语言**:digest 用中文撰写,面向用户本人(云原生 AI 基础设施方向产品经理/开发)
- **风格**:不堆砌,每条结论带来源链接;重点标"对我们产品的启示"

## 用户视角

用户做云原生 AI 基础设施产品,对标 OpenShift AI(OAI)。关心:
- 新功能与架构变化
- 与上游(KServe/Kubeflow/vLLM/Ray 等)的整合方式
- 企业级能力(多租户、GPU 调度、模型生命周期、安全合规)
- 与我们自家产品的差异点
