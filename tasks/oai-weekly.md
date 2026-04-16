# 任务:OpenShift AI 周度情报

## 目标
每周跟踪 OpenShift AI(OAI)及其上游 Open Data Hub 的动态,输出一份对标分析。

## 数据源(按优先级)

**GitHub(用 `gh` CLI)**
- `opendatahub-io/opendatahub-operator` — 主 operator
- `opendatahub-io/odh-dashboard` — 控制台
- `opendatahub-io/kserve` — 推理服务(OAI fork)
- `opendatahub-io/notebooks` — 工作台镜像
- `opendatahub-io/data-science-pipelines-operator` — 流水线
- `opendatahub-io/model-registry` — 模型注册中心
- `opendatahub-io/trustyai-service-operator` — 可信 AI

每个仓库看过去 7 天:
- `gh release list --repo <repo> --limit 10`(过滤日期)
- `gh api repos/<repo>/commits?since=<7d ago>` 看 main 分支提交
- `gh issue list --repo <repo> --state all --search "updated:>=<7d ago>"` 看热点 issue/PR

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

digest 写完后,生成一段不超过 500 字的简讯,推送到 `$FEISHU_WEBHOOK`:

```bash
source .env
curl -X POST "$FEISHU_WEBHOOK" \
  -H "Content-Type: application/json" \
  -d '{"msg_type":"text","content":{"text":"<简讯内容,末尾附 digest 相对路径>"}}'
```

## 质量要求
- 每条结论必须有链接依据,没有就不要写
- 如果一周没什么实质变化,如实说"本周无重大更新",不要凑数
- "启示"一节要具体,不说"值得关注"这类废话
