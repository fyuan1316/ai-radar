# AI 系统论文周报 2026-04-26

窗口:2026-04-19 → 2026-04-26(过去 7 天)

抓取说明:本次运行环境中 `curl http://export.arxiv.org/api/query...` 同样受 DNS/网络限制影响,未能完成 arXiv API 原始抓取。WebSearch 未返回足够高置信的“本周提交 + 系统论文 + 可读 abstract/experiment”的论文集合,因此本周按任务规则不推飞书,只归档一份空周 digest。下列“值得泛读”包含本周搜索中出现的相关但不满足“本周精选”标准的材料,不视为正式精选论文。

## 本周精选

本周无优质系统论文入选。

原因:
- 未能访问 arXiv API,无法可靠限定 2026-04-19 → 2026-04-26 提交窗口。
- WebSearch 返回的结果多为二手文章、百科或早于本周的论文,不满足“读 abstract + intro + experiments 后精选”的质量要求。

## 值得泛读

- [Prefill-as-a-Service: KVCache of Next-Generation Models Could Go Cross-Datacenter](https://arxiv.org/abs/2604.15039) — 搜索结果显示为 2026-04 的 PD disaggregation/KVCache 论文,主题与跨数据中心 prefill/decode 分离相关。需要下次打开 arXiv 正文确认实验设置和数据点。
- [LMCache](https://github.com/LMCache/LMCache) — 项目 README 指向 KV cache 层复用,声称在长上下文/多轮 QA/RAG 场景降低延迟和 GPU 周期,并给出 arXiv 引用。不是本周新论文,但与 vLLM v0.20.0 的 KV connector/LMCache 事件同向。
- [Towards Efficient Large Language Model Serving: A Survey on System-Aware KV Cache Optimization](https://openreview.net/forum?id=2GxL9EcMIX) — OpenReview 论文,系统化梳理 KV cache 的执行/调度、放置/迁移、表示/保留三个维度。不是本周 arXiv 新稿,但适合做产品能力框架。
- [ORBITFLOW: SLO-Aware Long-Context LLM Serving with Fine-Grained KV Cache Reconfiguration](https://chatpaper.com/paper/227105) — 长上下文 serving 的细粒度 KV cache reconfiguration 方向,需要回源 arXiv/OpenReview 验证。

## 趋势观察

- KV cache 仍是 AI 系统方向最集中的主题:本周工程侧 vLLM v0.20.0 已经把 2-bit KV cache、KV offload/connector、LMCache events、NIXL 等能力写进 release notes,研究侧也持续围绕 PD disaggregation、跨层/跨设备 KV 放置、SLO-aware retention 展开。
- 系统论文与工程实现的距离正在缩短。对产品来说,论文价值不在“又一个新 cache 算法”,而在是否能映射成可配置的 runtime knob:KV 压缩等级、GPU/CPU/SSD/S3 放置策略、跨节点传输协议、cache 命中率指标、SLO 违约回退。
- RAG 系统论文需要更严格筛选。很多结果讨论“长上下文是否替代 RAG”或“RAG latency”,但没有系统实现/实验细节时,不应进入精选。

## 下次补跑建议

- 用 arXiv API 补跑:
  - `cat:cs.DC OR cat:cs.PF OR cat:cs.LG`
  - 关键词:`"LLM serving" OR "model serving" OR "KV cache" OR "GPU scheduling" OR "distributed training" OR "continuous batching" OR "RAG system"`
  - 时间:2026-04-19 → 2026-04-26
- 对候选论文逐篇打开 abstract、intro、experiments,只保留有系统实现和数据点的 3-5 篇。

## 原始材料

- [Prefill-as-a-Service: KVCache of Next-Generation Models Could Go Cross-Datacenter](https://arxiv.org/abs/2604.15039)
- [LMCache repository](https://github.com/LMCache/LMCache)
- [Towards Efficient Large Language Model Serving: A Survey on System-Aware KV Cache Optimization](https://openreview.net/forum?id=2GxL9EcMIX)
- [ORBITFLOW paper summary](https://chatpaper.com/paper/227105)
- 未完成:arXiv API curl 原始扫描失败,未能生成本周精选。
