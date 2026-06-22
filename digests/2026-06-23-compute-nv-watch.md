# NVIDIA 算力栈 diff 雷达 2026-06-23

## 摘要
- KAI-Scheduler 落地一篇调度核心设计提案 `reclaim-generator-portfolio-design`:把"无界 reclaim 场景枚举"换成**有时间预算、插件注册的受害者场景生成器组合**,直指 reclaim/preempt/consolidation 同步路径上的调度耗时炸点(架构方向信号)。Release v0.15.2 → v0.15.3。
- gpu-driver-container 把生产驱动矩阵 580.159.04 → **580.167.08**,Rocky8/9 的 CUDA base 由 13.2.1 → **13.3.0**(Rocky10 仍停在 13.2.0,出现版本分叉);其余为 CI 维护(checkout v6→v7、Go 1.26.4、UBI digest)。
- 其余 7 仓全 EMPTY,无新提交。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [架构方向] 新增设计文档,用"有界生成器组合"替换无界 reclaim 场景搜索,所有被接受方案仍由现有 simulator + post-simulation validator 裁决,首发 NodeLocalGreedy / MultiNodeGang 两个生成器并加超时预算与指标。证据:docs/developer/designs/reclaim-generator-portfolio-design.md(+387)https://github.com/kai-scheduler/KAI-Scheduler/pull/1696

## kai-scheduler/KAI-Scheduler: 4cbd3eab -> cbd6e181
- 比较 https://github.com/kai-scheduler/KAI-Scheduler/compare/4cbd3eab2ec39c2ecce87b2e2c77e01759e9700e...cbd6e181953aa2cf480746c00f0cb009fb20fda6 | ahead=1 files=1 | Release v0.15.3
### AI 总结重点(源码 diff 为据)
- **把 reclaim 的"证伪无解"从无界同步搜索改为有界生成器组合**。文档明确动机:当前 reclaim 路径会花费"无界同步调度时间"去证明不存在合法 victim 集合,scale-test 里一个本就不可调度的 pending job 会拖垮整轮搜索。新机制让该失败模式"有界且可观测",同时保留"任何被接受的 reclaim 方案都经过完整模拟 + validator 批准"的安全性。
- **生成器组合 + 插件注册/排序**。复用 reclaim/preempt/consolidation 共享的 `JobSolver` 路径,每个适用生成器增量产出 `ByNodeScenario` 候选;driver 把候选喂给现有 solver 模拟、validator 校验,命中解 / 生成器耗尽 / 超时三者之一即停。首发组合固定两档:顺序 1 `NodeLocalGreedy`(还原 #1537 之前的廉价 node-local 场景形态,覆盖常见 case 与 scale-test 失败)、顺序 2 `MultiNodeGang`(包住当前的宽幅累积场景构建器,保留 #1537 的"整 gang victim 不拆"行为)。
- **显式承认负向结果是近似**。预算耗尽或已注册生成器覆盖不到该形态时,即便存在合法方案也可能报"无解";作者把这一权衡明列为可接受,因为正向解仍全模拟、且行为有界可观测。新增预算配置旋钮列为 alpha/experimental,并加生产指标暴露预算使用、生成器工作量、场景结果、被降预算的 job。
  <details><summary>代码依据 docs/developer/designs/reclaim-generator-portfolio-design.md</summary>

  ```diff
  +## Summary
  +This proposal replaces unbounded reclaim scenario enumeration with a bounded,
  +plugin-registered generator portfolio. Generators propose concrete victim
  +scenarios best-first, while the existing simulator and post-simulation
  +validator remain the authority for accepted solutions. The first policy runs a
  +cheap node-local generator before the existing multi-node gang generator, all
  +under configurable time budgets.
  +
  +| 1 | `NodeLocalGreedy` | Restore the cheap pre-#1537 node-local scenario shape ... |
  +| 2 | `MultiNodeGang`   | Wrap today's wide accumulated scenario builder while preserving the #1537 whole-gang behavior. |
  ```
  </details>
### 后续发展方向 [AI]
- 这是把 NVIDIA(原 Run:ai)调度器的 **reclaim/抢占可扩展性**从"正确但可能卡死"推向"工程上有界可调"的一步:victim 选择被当成 knapsack 类难题,不再追求完备证伪,而是用时间预算 + 可插拔生成器把尾部代价裁掉。对标我们产品的 GPU 批调度/抢占,这条"生成器组合 + validator 仍是唯一裁决者"的分层值得借鉴——把启发式探索与正确性裁决解耦。证据只覆盖该设计文档的 Summary/Motivation/Proposal 段(hunk 截断),未见配套实现 PR、`JobSolver` 实际接口改动与默认预算取值。

## NVIDIA/gpu-driver-container: d5f83987 -> 5c02984f
- 比较 https://github.com/NVIDIA/gpu-driver-container/compare/d5f839873900dc0f985eae0ff4d975c9aacff0b4...5c02984fbb61061f8a6a7ca69e869c5224ca41ec | ahead=12 files=10 | Release —
### AI 总结重点(源码 diff 为据)
- **生产驱动矩阵升档**:`DRIVER_VERSIONS` 由 `580.159.04 595.71.05` → `580.167.08 595.71.05`,在 `.common-ci.yml`(含 ubuntu24.04 / rhel10 各并行矩阵)、`image.yaml`、`versions.mk` 同步推进;即提交标题 "containerize 580TRD10 driver" 的实质——把 580 数据中心分支的容器化版本前移一个 patch,595 不动。
- **Rocky8/9 的 CUDA base 对齐 13.3.0,但 Rocky10 未跟**:`Makefile` 里 `build-rocky8%/build-rocky9%` 的 `BASE_IMAGE` 由 `cuda:13.2.1-base-rockylinux{8,9}` → `cuda:13.3.0-...`,而 `build-rocky10%` 仍是 `cuda:13.2.0-base-rockylinux10`——三条 Rocky 线 CUDA base 出现 13.3.0 / 13.2.0 分叉,值得盯下次是否补齐。
  <details><summary>代码依据 .common-ci.yml / Makefile</summary>

  ```diff
  -  DRIVER_VERSIONS: 580.159.04 595.71.05
  +  DRIVER_VERSIONS: 580.167.08 595.71.05

  -build-rocky8%: DOCKER_BUILD_ARGS = --build-arg BASE_IMAGE=nvcr.io/nvidia/cuda:13.2.1-base-rockylinux8
  +build-rocky8%: DOCKER_BUILD_ARGS = --build-arg BASE_IMAGE=nvcr.io/nvidia/cuda:13.3.0-base-rockylinux8
  -build-rocky9%: DOCKER_BUILD_ARGS = --build-arg BASE_IMAGE=nvcr.io/nvidia/cuda:13.2.1-base-rockylinux9
  +build-rocky9%: DOCKER_BUILD_ARGS = --build-arg BASE_IMAGE=nvcr.io/nvidia/cuda:13.3.0-base-rockylinux9
  ```
  </details>
- 其余为 CI/构建维护,无能力面影响:`actions/checkout@v6→v7`(多 workflow)、`GOLANG_VERSION 1.26.3→1.26.4`、`renovatebot/github-action v46.1.15→v46.1.16`、RHEL8/9 UBI base digest 滚动。
### 后续发展方向 [AI]
- 纯版本/基镜维护,无预编译矩阵结构性变化、无新 OS 进入矩阵。唯一可跟的趋势点是 Rocky8/9 已迈到 CUDA 13.3.0 而 Rocky10 滞后,可能下期补齐对齐。证据只覆盖本次 10 文件 diff,未见 driver 595 分支或 precompiled kernel 矩阵的实质改动。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY(仅保锚点)</summary>

- NVIDIA/gpu-operator — 无新提交
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9b198ba801ee9f1754dea0d74d85384659bea1c9 branch=main release=v26.3.2 scanned=2026-06-23 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=6d1a53dbd83f7b95eff3645afedf2335466014f2 branch=main release=v1.19.1 scanned=2026-06-23 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=5c02984fbb61061f8a6a7ca69e869c5224ca41ec branch=main release=— scanned=2026-06-23 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.2 scanned=2026-06-23 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=ed0d0e5593dad7f0f7594ce08fd3239e52fb15ba branch=main release=v0.4.1-rc.1 scanned=2026-06-23 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-23 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-23 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=d8348422bc7338fba3e112fa3f733e7eecaf51da branch=main release=v0.14.2 scanned=2026-06-23 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=cbd6e181953aa2cf480746c00f0cb009fb20fda6 branch=main release=v0.15.3 scanned=2026-06-23 -->
