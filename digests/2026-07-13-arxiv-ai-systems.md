# AI 系统论文周报 2026-07-13

窗口:2026-07-06 -> 2026-07-13(7 天)

## 本周精选(3-5 篇)

本周未可靠筛选。

原因:arXiv API 在本轮抓取中先返回 429，再次带 User-Agent 重试时返回 503，未能稳定取得 Atom feed。按任务质量要求，精选论文必须读 abstract / intro / experiments 后再写，因此本周不根据标题或搜索片段凑结论。

抓取端点:
- https://export.arxiv.org/api/query?search_query=all:%22LLM%20serving%22%20OR%20all:%22KV%20cache%22%20OR%20all:%22GPU%20scheduling%22%20OR%20all:%22distributed%20training%22%20OR%20all:%22model%20serving%22%20OR%20all:%22inference%20optimization%22&sortBy=submittedDate&sortOrder=descending&start=0&max_results=12

## 值得泛读(5-10 篇)

本周未列出。原因同上，未能可靠读取论文摘要和实验信息。

## 趋势观察

- 本周不推断趋势，避免把 API 失败误写成“无优质系统论文”。
- 可补跑建议:等 arXiv API 恢复后，按 `tasks/arxiv-ai-systems.md` 的关键词重新拉取，并优先筛选 LLM serving、KV cache、GPU scheduling、distributed training、model serving、RAG system 方向。

## 原始材料

<details>
<summary>本次扫描情况</summary>

- arXiv API 第一次请求返回 429。
- arXiv API 带 User-Agent 重试返回 503。
- 因未取得可靠 feed，本 task 本轮只归档失败状态，按 task 规则不推飞书。
</details>
