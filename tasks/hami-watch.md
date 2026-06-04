# 任务:HAMi 异构算力虚拟化 diff 雷达

## 目标
按 commit 区间跟踪 HAMi(开源 GPU/NPU 软虚拟化中间件,CNCF Sandbox)全家桶的**代码级变化**,从 diff 里判断功能发展趋势与重要改变。不是新闻罗列,是"自上次扫描以来代码改了什么、往哪走"。

这是 ai-radar 里第一类 **diff-watch** 任务(区别于周度新闻 digest):高频(每天)、小步、按 base..HEAD 比对、LLM 只做研判,取数由 `hack/diff-scan-gh.sh` 确定性完成。

## 与其他 task 的边界(硬约束)
- 本 task 只管 **HAMi 软切分(vGPU/vNPU)能力本身**。
- NVIDIA driver 容器化 / device-plugin / DRA 归 `compute-nv-watch`;Ascend driver/operator 归 `compute-ascend-watch`;K8s 调度抽象/KEP 仍归 `k8s-ai-infra`(新闻视角)。重叠时本 task 只看 HAMi 仓自身。

## 数据源(全部 GitHub,用 hack/diff-scan-gh.sh)
| repo | 分支 | 优先级 | 说明 |
|---|---|---|---|
| `Project-HAMi/HAMi` | master | P0 | vGPU/vNPU 调度+device plugin 主仓 |
| `Project-HAMi/HAMi-core` | main | P0 | CUDA hook 显存/算力切分内核,软隔离能力边界 |
| `Project-HAMi/volcano-vgpu-device-plugin` | main | P1 | HAMi × Volcano 集成路径 |
| `Project-HAMi/ascend-device-plugin` | main | P1 | HAMi 对昇腾 vNPU 的虚拟化支持(两生态交汇点) |
| `Project-HAMi/HAMi-WebUI` | main | P2 | 控制台,商业化/可用性信号 |

> 注:`HAMi` 默认分支是 `master`,其余是 `main`,helper 不传分支会自动取默认分支,无需手填。

## 执行步骤
1. 对每个 repo 跑:`./hack/diff-scan-gh.sh <repo> hami-watch`
   - 脚本会自动从上一篇 `digests/*-hami-watch.md` 读锚点 SHA、compare base...HEAD、滤掉 vendor/generated 噪声、打印实质提交+信号文件+API/CRD 命中,并打印今天的 `<!-- ANCHOR ... -->` 行。
   - 输出含 `__EMPTY__` 的 repo = 本期无实质改动(仅 bump/CI/merge 或无新提交),**跳过不写正文**,但其 ANCHOR 行必须收进末尾"扫描锚点"节(否则下次断链)。
2. 按 helper 输出的标记处理每个 repo:
   - **`__BASELINE__`**(首跑,仅建锚点,无 diff):不写正文,只把锚点收进末尾。若**所有** repo 都是 BASELINE(任务首次跑),digest 写一句"基线已建立,从次日起跟踪增量"即可,**不推飞书**。
   - **`__EMPTY__`**(无实质改动):跳过正文,保锚点。
   - **`__OVERVIEW__`**(大区间安全网:漏跑多日致积压 >60 commit 或被 API 截断):写**概览**——从"实质提交"聚 3-5 个方向主题 + "改动热点目录",标注"大区间概览,未逐文件读代码"。不要假装读了 hunk。
   - 其余(深度模式,有「关键 patch 节选」):**基于真实代码 hunk 写符号级总结 + 贴代码依据**,见质量要求第 1 条。这是**正常每日增量**的形态。
   - 锚点机制:首跑只盖锚点(base=HEAD);从第 2 次起以上一篇 digest 的锚点为 base 做小增量,趋势随天数自然累积。
3. 汇总当日"重要改变"与"摘要",按 CLAUDE.md 硬约束 git push 后推飞书。

## 输出 → digests/YYYY-MM-DD-hami-watch.md
```markdown
# HAMi diff 雷达 YYYY-MM-DD

## 摘要(3 条内,优先放重要改变/方向转向;当日全 EMPTY 写"本日无实质改动")

## 当日重要改变(命中信号才列;无则写"无")
- <repo> [信号类型] 一句话 + 证据文件/提交 + 裸 URL

## <repo>: <base8> -> <head8>
- 比较 / 最新 Release(直接用 helper 那行)
### AI 总结重点(源码 diff 为据)
- <符号级结论:改了哪个函数/字段/常量,前→后行为差异>。**每条结论后必须贴出代码依据**:
  <details><summary>代码依据 path/to/file.go</summary>

  ```diff
  -   旧逻辑(从 helper 的 patch 节选原样摘关键 hunk)
  +   新逻辑
  ```
  </details>
- 没有 patch 依据的结论不许写;commit 标题不能当依据。
### 后续发展方向 [AI]
- <从上面 diff 证据推断的方向;必须能指回某段 hunk;标"证据只覆盖 X,未见 Y">

## 本期无实质改动(折叠)
- <EMPTY 的 repo 列一行>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=... sha=... ... -->   ← 把每个 repo 的 ANCHOR 行(含 EMPTY 的)全部收齐
```

## 重要改变信号(命中即必报,逐条映射证据)
- `[弃用/移除]` 提交标题含 deprecate/remove/drop,或删了已有 CRD 字段/flag
- `[API/CRD变更]` 改动命中 `*_types.go` / `config/crd` / `/crds/` / `apis/`
- `[架构方向]` 改动命中 `docs/proposals` / `/design/`,或新增/删除顶层 package
- `[版本跨档]` 最新 Release 相对上期跨 major/minor
- `[新能力]` 新增独立 package/子目录(如 HAMi-core 新增 hook 类型)

## 推送飞书
见 [oai-weekly 推送规范](./oai-weekly.md#推送飞书)(先 git push、纯文本、裸 URL、500 字内;DIGEST_FILE=`digests/$(date +%Y-%m-%d)-hami-watch.md`)。
**空日跳过(本 task 特有)**:若所有 repo 都 EMPTY,只 commit+push 归档 digest(保锚点链),**不推飞书**。简讯只放"当日重要改变"那几条 + 完整报告链接。

## 质量要求
- **"AI 总结重点"必须读「关键 patch 节选」的代码 hunk 写到符号级**:改了哪个函数/结构体/字段/常量/配置项、前后行为差异是什么(例:"把命名空间限制从'所有 CDI 设备'收窄为仅 management.nvidia.com/gpu 设备")。**严禁只复述 commit 标题或文件名**——commit 标题含糊(如 "update"、中文流水账)时尤其要靠 patch 还原真实改动。patch 被截断的,基于已见 hunk 写并标注"(hunk 截断,未覆盖全部)"。
- 每条带源链接(commit/PR/release 的完整 https:// URL)。
- 区分"HAMi 软切分(hook/时分)" vs "DRA 原生路径",别混。
- "后续发展方向"必须落到能力/架构层面,且标注证据边界(只看了 diff,没逐 PR 展开),不说"值得关注"这类废话。
- 锚点节必须完整,EMPTY 的 repo 也要留锚点,否则趋势链断。
