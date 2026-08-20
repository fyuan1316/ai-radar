# 任务:K8s 大版本深读(事件驱动)

## 目标

给每个 Kubernetes minor 版本(1.37、1.38 …)建立一份**版本档案**:重要功能全景、按 SIG 的代码演进、API 变更与废弃/移除、对我们产品的升级 checklist、跨版本方向线。

> **与周报的分工**:`k8s-core` / `k8s-ai-infra` 是 7 天窗口的**新闻视角**,版本主题被切碎在多期里;本任务是**版本视角**,在 rc.0 / GA 两个时刻做系统性盘点。周报已有的分析**引用不重做**(链接到对应 digest),本任务的增量是:全量晋级清单、milestone 级 feature PR 梳理、纵向对比、升级影响收口。AI 专用件(DRA/WAS/gang)的深析仍归 `k8s-ai-infra`,本任务在版本档案里做**汇总收录**并链接。

## 触发机制(事件驱动,非固定周期)

每次运行先自检,决定做事还是跳过:

1. 取 `kubernetes/kubernetes` 最新 tag(`https://api.github.com/repos/kubernetes/kubernetes/releases?per_page=15`),识别最新 minor 的 `v1.XX.0-rc.0`(或更高 rc)和 `v1.XX.0` 正式 tag。
2. 查锚点:`grep -rh 'RELEASE-ANCHOR' digests/*-k8s-release-deep-dive.md`,锚点格式(HTML 注释,渲染不可见):
   `<!-- RELEASE-ANCHOR version=1.37 stage=rc|ga -->`
3. 决策:
   - 出现新版本的 rc 且无该版本任何锚点 → 产出**前瞻版**(stage=rc)
   - 出现正式 tag 且该版本最高锚点是 rc(或无)→ 产出**定稿版**(stage=ga)
   - 否则 → **跳过**:写 `digests/YYYY-MM-DD-k8s-release-deep-dive.md` 仅含一行 `__SKIP__ (latest=v1.XX.y, anchor=1.XX/ga)`,commit + push 留痕,**不推飞书**(对齐 diff-watch 的 `__EMPTYS__` 哲学)
4. 每期正文头部必须带本期 RELEASE-ANCHOR 注释,这是唯一状态,不建 state 文件。

节奏预期:K8s 一年 3 个 minor(约 4、8、12 月),本任务一年实际产出约 6 期(3×rc 前瞻 + 3×GA 定稿),其余每周自检都是 `__SKIP__`。

## 数据源与抓取

统一 curl GitHub API(见 CLAUDE.md 抓取约定):

1. **CHANGELOG**(主料):`https://raw.githubusercontent.com/kubernetes/kubernetes/master/CHANGELOG/CHANGELOG-1.XX.md`,重点段:What's New / Urgent Upgrade Notes / Changes by Kind(API Change、Feature、Deprecation)
2. **Release blog**(GA 定稿时):`https://kubernetes.io/blog/` 当期 release announcement,WebFetch
3. **KEP 全量晋级清单**:`https://api.github.com/search/issues?q=repo:kubernetes/enhancements+is:issue+milestone:v1.XX&per_page=100`(分页取全),按 SIG 分组;stage 从 issue label(`stage/alpha|beta|stable`)与标题取
4. **代码演进(重点 SIG 的 milestone 级 feature PR)**:对 sig/scheduling、sig/node、sig/api-machinery、sig/storage、sig/network 逐个:
   `https://api.github.com/search/issues?q=repo:kubernetes/kubernetes+is:pr+is:merged+milestone:v1.XX+label:sig/XXX+label:kind/feature&per_page=100`
   过滤 test/ci/bump 噪声;每 SIG 挑 5-10 条有方向性信号的,读 PR body 而非只抄标题
5. **搜索 API 限流注意**:30 次/min,查询之间 `sleep 3`;全部查询预算控制在 ~15 次

## 输出

写到 `digests/YYYY-MM-DD-k8s-release-deep-dive.md`:

```markdown
# K8s v1.XX 版本深读(前瞻版|定稿版)YYYY-MM-DD
<!-- RELEASE-ANCHOR version=1.XX stage=rc|ga -->

## 版本主题(一段话:这个版本在讲什么故事)

## 重要功能(按 SIG)
### 调度(含 AI 线汇总,链接 k8s-ai-infra 周报既有分析)
### Node & kubelet
### API Machinery
### 存储 / 网络
(每条:能力 + alpha/beta/GA 状态 + 一句为什么重要 + 链接)

## API 变更 / 废弃 / 移除
- Urgent Upgrade Notes 逐条
- deprecated / removed 清单

## 对我们产品的升级 checklist
- [ ] ACP 底座升该版本前必须处理的事项(gate 默认值变化、API 移除、行为变化)

## 纵向方向线(跨版本)
- 该版本在 WAS/gang、DRA、in-place resize 等主线上相对前两个版本走到哪了

## 代码演进速览(重点 SIG milestone feature PR)
- 每 SIG 5-10 条,标注信号

## 值得跟进
- [ ] ...
```

## 推送飞书

仅 rc 前瞻版和 GA 定稿版推送(`__SKIP__` 期不推)。**格式和推送流程:见 [oai-weekly 推送规范](./oai-weekly.md#推送飞书)**(先 `git push` 再推;简讯纯文本;链接完整 `https://` URL;DIGEST_FILE 改成 `digests/$(date +%Y-%m-%d)-k8s-release-deep-dive.md`)。

## 质量要求

- **版本档案是长效文档**:半年后还会被翻出来当"1.37 我们评估过什么"的依据,写作面向未来读者,结论要落到版本号和 gate 名,不写"本周""最近"这类相对时间
- **升级 checklist 是核心交付**:每条要能直接进升级 runbook,不接受"值得关注"这种没有动作的条目
- **引用不重做**:周报(k8s-core / k8s-ai-infra)已深析过的条目,一句话结论 + 链接 digest,省下的篇幅花在周报没做的全量盘点和纵向对比上
- **rc 前瞻版允许留疑**:CHANGELOG draft 未定稿的条目标"待 GA 确认";GA 定稿版必须回头核对前瞻版的每个"待确认"
- 每条带链接
