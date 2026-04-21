# 任务:OpenShift AI 周度情报

## 目标
每周跟踪 OpenShift AI(OAI)及其上游 Open Data Hub 的动态,输出一份对标分析。

## 数据源(按优先级)

**GitHub(用 `curl` 打 api.github.com,不使用 `gh` CLI)**
- `opendatahub-io/opendatahub-operator` — 主 operator
- `opendatahub-io/odh-dashboard` — 控制台
- `opendatahub-io/kserve` — 推理服务(OAI fork)
- `opendatahub-io/notebooks` — 工作台镜像
- `opendatahub-io/data-science-pipelines-operator` — 流水线
- `opendatahub-io/model-registry` — 模型注册中心
- `opendatahub-io/trustyai-service-operator` — 可信 AI

每个仓库看过去 7 天(示例,`$REPO` 为 `opendatahub-io/xxx`):
```bash
AUTH=(); [ -n "$GITHUB_TOKEN" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
SINCE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)

# Releases
curl -s "${AUTH[@]}" "https://api.github.com/repos/$REPO/releases?per_page=10"

# Main 分支 commits
curl -s "${AUTH[@]}" "https://api.github.com/repos/$REPO/commits?since=$SINCE&per_page=100"

# 热点 issue/PR(updated in 7 days)
curl -s "${AUTH[@]}" "https://api.github.com/search/issues?q=repo:$REPO+updated:>=${SINCE%T*}"
```

未设 `$GITHUB_TOKEN` 时走匿名,60 次/h 限额;扫 7 个 repo 很容易打满,**强烈建议在 `.env` 里配 token**。

**Red Hat 官方**
- OpenShift AI release notes 页(WebFetch)
- Red Hat Developer 博客里 "OpenShift AI" 标签的新文章

## 输出

写到 `digests/YYYY-MM-DD-oai-weekly.md`,结构:

```markdown
# OpenShift AI 周报 YYYY-MM-DD

## 摘要(3 条以内)
- ...

## 新功能 / 能力
- [<功能>](<PR/issue 链接>) — 一句话说明
  - 启示:对我们产品意味着什么

## 架构 / 依赖变化
- ...

## 上游生态整合动向
- KServe / Kubeflow / vLLM / Ray 等相关变更

## 值得跟进
- [ ] 具体 action:读哪个 PR、试哪个新特性、评估哪个能力

## 原始材料
- 本次扫描的 commit/PR/release 清单(折叠)
```

## 推送飞书

> 本节是 ai-radar 所有 task 的飞书推送**权威规范**,其他 task 文档通过"见 oai-weekly 推送规范"引用。

### 前置(硬约束)
digest **必须已 `git add && git commit && git push origin main`** 到 `${GITHUB_REPO}` 的 main 分支**之后**,再推飞书。该仓库是 private,未 push 前飞书里的链接全是 404。这是先前反馈过的问题,不要再重现。

### 简讯格式(硬约束)
飞书自定义机器人 `msg_type=text` **不渲染 markdown**,`**粗体**` / `[标题](url)` / `# 标题` 都会变成字面量字符。因此:

- **不使用**任何 markdown 语法:不要 `**`、`_`、`#`、反引号、`[title](url)`
- **链接必须是 `https://` 开头的完整 URL**,飞书才会识别成可点击超链接
  - ✅ `https://github.com/kserve/kserve/releases/tag/v0.18.0-rc0`
  - ❌ `github.com/kserve/kserve/releases/tag/v0.18.0-rc0`(无 scheme 不识别)
  - ❌ `#38479` / `PR 38479` / `digests/2026-04-21-xxx.md`(相对引用不识别)
  - ❌ `[#38479](https://github.com/...)`(markdown 语法会变字面量)
- 段落分行用 `\n`,条目前缀用 `-` 或阿拉伯数字即可
- 控制在 500 字以内

### 简讯骨架
```
OAI 周报 YYYY-MM-DD

3 条要点(每条一行,事实 + 裸 URL):
- 要点 1 ……  https://github.com/...
- 要点 2 ……  https://github.com/...
- 要点 3 ……  https://github.com/...

完整报告: https://github.com/fyuan1316/ai-radar/blob/main/digests/YYYY-MM-DD-oai-weekly.md
```

### 推送脚本(text 模式,默认)
```bash
source .env
DIGEST_FILE="digests/$(date +%Y-%m-%d)-oai-weekly.md"

# 1. 先 push 到 main
git add "$DIGEST_FILE"
git commit -m "digest: $(basename "$DIGEST_FILE" .md)"
git push origin main

# 2. 推飞书(纯文本,简讯里不要用任何 markdown 语法)
DIGEST_URL="https://github.com/${GITHUB_REPO}/blob/main/${DIGEST_FILE}"
SUMMARY="OAI 周报 $(date +%Y-%m-%d)

- 要点 1 …… <裸 URL>
- 要点 2 …… <裸 URL>
- 要点 3 …… <裸 URL>

完整报告: ${DIGEST_URL}"

curl -X POST "$FEISHU_WEBHOOK" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg t "$SUMMARY" '{msg_type:"text", content:{text:$t}}')"
```

### 可选增强:富文本卡片(interactive + markdown)
如果希望飞书里显示粗体/可点击的命名链接,改用 `msg_type=interactive` + markdown element,**卡片内容**可以用 markdown 语法(仅 card 支持,text 不支持):

```bash
PAYLOAD=$(jq -nc --arg md "$MARKDOWN_SUMMARY" --arg u "$DIGEST_URL" '{
  msg_type: "interactive",
  card: {
    config: {wide_screen_mode: true},
    elements: [
      {tag: "markdown", content: $md},
      {tag: "hr"},
      {tag: "markdown", content: ("📄 [完整报告](" + $u + ")")}
    ]
  }
}')
curl -X POST "$FEISHU_WEBHOOK" -H "Content-Type: application/json" -d "$PAYLOAD"
```

默认仍用 text 模式(最稳);切到 card 之前先本机验证一次,确认飞书账号收到的渲染符合预期再用。

## 质量要求
- 每条结论必须有链接依据,没有就不要写
- 如果一周没什么实质变化,如实说"本周无重大更新",不要凑数
- "启示"一节要具体,不说"值得关注"这类废话
