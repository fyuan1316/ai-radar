# 任务:AI 系统论文周报

## 目标
从 arxiv 筛选与 AI 基础设施/系统相关的新论文,只关注跟"做产品"有关的方向,不追纯算法/纯模型。

## 数据源

**arxiv API**,搜索过去 7 天提交的论文:

```bash
# 类目:cs.DC(分布式计算)+ cs.LG(机器学习) + cs.PF(性能)
# 关键词组合(OR):
#   "LLM serving" OR "model serving" OR "inference optimization"
#   "GPU scheduling" OR "GPU cluster" OR "GPU sharing"
#   "distributed training" OR "pipeline parallelism" OR "tensor parallelism"
#   "KV cache" OR "speculative decoding" OR "continuous batching"
#   "MLOps" OR "model registry" OR "feature store"
#   "RAG" AND "system"

curl "http://export.arxiv.org/api/query?search_query=(...)" 
```

用 WebSearch 补充:搜索 "site:arxiv.org LLM serving system 2026" 等查漏补缺。

## 筛选标准

**收录**:
- 提出新的系统架构 / 调度算法 / 优化技术,且有实验验证
- 对已有开源项目(vLLM/SGLang/Ray/KServe)的性能分析或改进方案
- 大规模集群管理/调度的实证研究
- AI 安全/评测方法论(跟 TrustyAI/Garak 路线相关)

**不收录**:
- 纯模型结构创新(新 Attention 机制、新 MoE 设计)
- 纯 NLP/CV 应用论文
- 仅有理论分析无系统实现

## 输出

写到 `digests/YYYY-MM-DD-arxiv-ai-systems.md`:

```markdown
# AI 系统论文周报 YYYY-MM-DD

## 本周精选(3-5 篇)
- **[论文标题](arxiv链接)** — 一句话概括
  - 核心思路:...
  - 对我们的启示:...
  - 关键数据点:如 "比 vLLM baseline 快 2.3x"

## 值得泛读(5-10 篇)
- [论文标题](arxiv链接) — 一行摘要

## 趋势观察
- 本周论文集中在哪些方向?跟上周比有什么变化?
```

## 推送飞书

只推"本周精选"部分的标题+一句话,不超过 300 字。附 GitHub 链接到完整 digest。

## 质量要求
- 精选论文必须自己读了 abstract + intro + experiments 才写,不能只看标题猜
- "对我们的启示"要具体到产品决策级别,不说"值得关注"
- 如果本周没有跟 AI 系统相关的好论文,如实说"本周无优质系统论文",推飞书可以跳过
