# 任务:OpenFuyao(开源扶摇)周度情报

## 目标
跟踪华为牵头的 OpenFuyao 社区动态,重点关注云原生 AI 推理、训练编排、昇腾资源调度等方向,看清它跟 OAI / KServe / Kueue 路线的异同,识别对我们产品有借鉴或竞争意义的能力。

OpenFuyao 定位:K8s 之上、CANN/MindSpore 之下,给昇腾等异构硬件在 K8s 上提供企业级集群软件栈。2025 Q3 开源,季度发版(YY.MM),v25.12 是首个 LTS。

## 数据源

### 代码托管(主仓在 GitCode,不是 GitHub)
- 主组织:`https://gitcode.com/openFuyao`
- Gitee 镜像/治理:`https://gitee.com/openfuyao`
- 昇腾 upstream:`https://gitcode.com/ascend/mind-cluster`

### 云原生 AI 方向核心 repo(优先级从高到低)

**AI 推理(SIG-ai-inference)—— 对标 KServe/vLLM stack**
- `openFuyao/InferNex` — LLM 推理总集,一键部署 vLLM / vLLM-Ascend
- `openFuyao/hermes-router` — KVCache-aware 智能路由(跟 llm-d、Dynamo 路由层对标)
- Elastic Scaler / Eagle Eye / 分布式 KVCache 子项目(InferNex 目录下或独立 repo,按发现为准)

**昇腾资源 Operator(SIG-large-scale-cluster)**
- `openFuyao/npu-operator` — Operator Framework 管驱动/固件/device plugin,含 vNPU、断点续训、弹性训练
- `ascend/mind-cluster` — ClusterD / Ascend Operator / Ascend Device Plugin / NPU-Exporter / Ascend Docker Runtime
- `openFuyao/kae-operator` — 鲲鹏加速引擎 operator

**调度 & 资源分配**
- `openFuyao/volcano-ext` — Volcano 的 NPU 拓扑亲和扩展
- `openFuyao/npu-dra-plugin` — K8s DRA 架构接入昇腾(重点,跟我们 DRA 选型强相关)
- 在离线混部 / NUMA 亲和 / 分布式作业调度相关 repo

**网络 & 部署**
- `openFuyao/ub-network-device-plugin` — UB/URMA 超低时延容器网络
- SIG-installation 下的 BKECluster CR / chart addon / `npu-driver-installer` / `npu-node-provision`

> 每周扫描时先跑一次 `WebFetch https://gitcode.com/openFuyao` 拿最新 repo 清单,补齐上面没列到的新增项目,避免漏扫。

### 抓取方式(注意:无 `gh` CLI 支持)
GitCode 和 Gitee 都不在 `gh` CLI 范围。按下述顺序取数:

1. **GitCode**:**优先 `git clone --depth 1`**,实测 WebFetch 对 `gitcode.com/.../raw/...` 和 `raw.gitcode.com/...` 都只返回 JS 壳 HTML(约 3.6KB),不是真实 markdown;页面 URL(`/blob/`、`/commits/`)也是 JS 渲染
   - 读文件:`git clone --depth 1 https://gitcode.com/<org>/<repo>.git /tmp/<repo>` 后本地 `cat`
   - 看近 7 天提交:`git clone --depth 100 ... && git log --since="7 days ago" --oneline`
   - 看 tag/release:`git tag --list --sort=-creatordate | head`(不要依赖网页 releases 页)
   - 列组织下所有 repo:网页 `https://gitcode.com/openFuyao` WebFetch 可用(首页 SSR),但详情页不行
2. **Gitee**:有 OpenAPI,`curl https://gitee.com/api/v5/repos/openfuyao/<repo>/commits?since=...`
3. **官方信息源**(优先级其实比代码还高,因为 OpenFuyao 发布节奏以官方公告驱动):
   - 官网 news/release/blogs:`https://www.openfuyao.cn/zh/`
   - 文档站(按版本分):`https://docs.openfuyao.cn/zh/`
   - CSDN 官方博客(最活跃,发公告+月度运作报告):`https://blog.csdn.net/openFuyao`
   - 知乎专栏 / SegmentFault 专栏(搜 "openFuyao")

每个 repo 看过去 7 天:releases、重要 PR/MR(过滤 merge/bump/CI)、热点 issue。
官方源看过去 7 天:新 blog、release note、社区运作报告。

## 输出

写到 `digests/YYYY-MM-DD-openfuyao-weekly.md`,结构:

```markdown
# OpenFuyao 周报 YYYY-MM-DD

## 摘要(3 条以内)
- ...

## 新功能 / 能力
- [<功能>](<gitcode/官网链接>) — 一句话说明
  - 启示:对我们产品意味着什么(要具体到能力/架构层面,不说"值得关注")

## AI 推理栈(InferNex / hermes-router / ...)
- 路由策略、KVCache 池化、弹性伸缩、与 vLLM-Ascend 集成相关变更

## 昇腾资源管理(NPU Operator / MindCluster / DRA)
- 驱动/固件/device plugin / DRA 接入进展

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)
- 1.6w+ 节点、NUMA 亲和、分布式作业调度

## 官方动态
- 版本发布、社区会议、路线图公告、合作方

## 跟我们产品的对比
- 哪些能力我们已经有 / 哪些是 OpenFuyao 独有 / 哪些我们该补

## 值得跟进
- [ ] 具体 action:读哪个 PR、试哪个 release、评估哪个能力

## 原始材料
- 本次扫描清单(折叠)
```

## 推送飞书

**格式和推送流程:见 [oai-weekly 推送规范](./oai-weekly.md#推送飞书)**(前置先 `git push`、简讯纯文本、链接裸 URL、默认 text 模式;DIGEST_FILE 改成 `digests/$(date +%Y-%m-%d)-openfuyao-weekly.md`)。

**空周跳过规则(本 task 特有)**:如果本周 digest 正文只能写成"无重大更新"类内容(无新 release、无有价值 PR、官方无新公告),**不推飞书**,只把 digest 归档到 `digests/`,避免无信息量的消息骚扰。判断标准:如果"新功能 / 能力"和"官方动态"两节都是空的,就跳过。

## 质量要求

- **对标视角第一**:每条变更都要回答"跟 OAI / KServe / Kueue / vLLM 上游相比,它走的是同一条路还是分叉";不做这个对比就别写
- **避开民族主义叙事**:官方博客常带"自主可控"等宣传词,写 digest 时剥离营销话术,只留技术事实
- **昇腾专用 vs. 通用**:明确区分"只对昇腾 NPU 有意义"的特性(如 UB 网络、vNPU)和"通用 K8s AI 栈能用"的特性(如 hermes-router 的 KVCache 路由思路),后者才是我们可以借鉴的
- **版本节奏**:季度发版,非发版周可能非常冷清,如实写"本周无重大更新",不凑字
- **链接必须落到 GitCode/Gitee/官网**,不要只给百度/CSDN 搜索结果
- 每个 repo 如果过去 7 天无实质变化,直接跳过,不要写空条目
