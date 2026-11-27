# NVIDIA 算力栈 diff 雷达 2026-11-28

## 摘要
- **9 仓里 8 个 NVIDIA 官方仓本期零提交**,HEAD 自 11-24/11-25 起冻结(感恩节假期窗口),唯一有实质改动的是已迁出 NVIDIA org 的 `kai-scheduler/KAI-Scheduler`,2 个提交。
- **KAI 的场景生成器组合(scenario portfolio)从"管理员配的固定顺序"变成"按作业形状动态定序"。** 新增 `generatorsForJob()`:当注册表恰好是默认的 `[NodeLocalGreedy, MultiNodeGang]` 两项且作业 Pod 数 >1 时,per-job 把 `MultiNodeGang` 提到前面;其余情形(自定义组合、管理员已显式反序、单 Pod 作业)一律原样返回。抢占/回收搜索的探测预算不再先浪费在"多 Pod gang 挤进单节点"这种极少成立的尝试上。
- **chart 侧 OpenShift 硬化补齐最后一个 hook job。** `post-delete` 清理 job 的容器 `securityContext` 此前只认 `global.securityContext`,现在 OpenShift 模式下改为内置硬编码的 `runAsUser:10000 / runAsNonRoot / allowPrivilegeEscalation:false / drop ALL`,且**优先级高于** `global.securityContext`(整段被替换,不是合并)。

## 当日重要改变
- `kai-scheduler/KAI-Scheduler` **[新能力·调度行为变更]** 新增 `generatorsForJob(registrations, pendingJob)`(`pkg/scheduler/actions/common/solvers/job_solver.go`),`SolveWithResult` 里 `availableGenerators` 由直接取 `ssn.ScenarioGeneratorRegistrations` 改为经该函数按作业重排。判定口径是 `len(pendingJob.GetAllPodsMap()) > 1`——用**作业总 Pod 数**而非待调度 Pod 数,所以"2 Pod 作业已有 1 个 Running、只剩 1 个 pending"仍按多节点优先处理(测试用例 `multi-pod job with one pending pod` 明确断言)。 https://github.com/kai-scheduler/KAI-Scheduler/pull/2750
- `kai-scheduler/KAI-Scheduler` **[行为变更·升级陷阱]** OpenShift 模式下 `post-delete` hook 的 `global.securityContext` 自定义项会被静默丢弃:模板由 `{{- if .Values.global.securityContext }}` 改为 `{{- if (include "kai-scheduler.openshift" .) }} ... {{- else if .Values.global.securityContext }}`,是互斥分支。chart 测试新增断言 `openshift: true` + `global.securityContext.readOnlyRootFilesystem: true` 时该字段 `notExists`。 https://github.com/kai-scheduler/KAI-Scheduler/pull/2718
- `[版本跨档]` 未命中。KAI releases 列表最大 semver 仍是 `v0.19.0`(与上期同),helper 报的 `v0.18.9` 是 0.18 分支 backport,不构成跨档;其余 8 仓 Release 与上期逐仓全同(gpu-operator v26.7.3 / container-toolkit v1.20.2 / k8s-device-plugin v0.20.2 / dra-driver-nvidia-gpu v0.5.1 / dcgm-exporter 4.9.0 / mig-parted v0.15.2)。
- `[API/CRD变更]` 未命中。本期改动文件无一命中 `_types.go` / `config/crd` / `apis/` / `/crds/`;**`api/nvidia/v1/clusterpolicy_types.go` 未改动,ClusterPolicy 无字段增删**。
- `[弃用/移除]` 未命中:无 deprecate/remove/drop 类提交,无 CRD 字段或 flag 删除。
- `[架构方向]` 未命中:无 `docs/proposals` / `/design/` 改动,无新增/删除顶层 package。
- `[NVIDIA 特有关注点]` 本期全部零信号:driver 容器 OS/预编译矩阵无改动(`gpu-driver-container` 零提交)、time-slicing/MPS→DRA 迁移无新动作(`k8s-device-plugin`、`dra-driver-nvidia-gpu` 均零提交)、dcgm 指标语义无变化(`dcgm-exporter`、`DCGM` 均零提交)。

## kai-scheduler/KAI-Scheduler: 523b3329 -> 9b8f4b3d
- 比较: 523b33294d2fbec6467a12f79a32c72a323d78f2 -> 9b8f4b3d | ahead=2 | files=7 | Release: v0.18.9(0.18 分支 backport;releases 最大 semver 为 v0.19.0)
- compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/523b33294d2fbec6467a12f79a32c72a323d78f2...9b8f4b3d5f6e68c719659c7f8ce1d96f3bfa04f2
- 提交(已用 compare API 核对全量标题,无被 `Bump ` 前缀过滤掉的实质提交):
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/c26a068a fix(chart): harden post-delete hook container securityContext on OpenShift(PR https://github.com/kai-scheduler/KAI-Scheduler/pull/2718)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/9b8f4b3d perf(scheduler): prioritize multi-node scenarios for multi-pod jobs(PR https://github.com/kai-scheduler/KAI-Scheduler/pull/2750)

### AI 总结重点(源码 diff 为据)
- **生成器组合的顺序决策权从"配置时"下移到"每次求解时",依据是作业形状。** `JobSolver.SolveWithResult` 里 `availableGenerators := ssn.ScenarioGeneratorRegistrations` 改为 `availableGenerators := generatorsForJob(ssn.ScenarioGeneratorRegistrations, pendingJob)`。新函数的守卫条件极窄,四个条件全部满足才重排:注册表长度恰为 2、`registrations[0].Name == constants.GeneratorNodeLocalGreedy`、`registrations[1].Name == constants.GeneratorMultiNodeGang`、`len(pendingJob.GetAllPodsMap()) > 1`;命中时返回**新切片** `[registrations[1], registrations[0]]`,不就地修改。行为差异:6-25 落地的 portfolio 机制(`scenarioPortfolio` 逐生成器分配时间预算、按 `currentIndex` 推进)此前对所有作业一律先跑 `NodeLocalGreedy`,gang 作业要耗完第一个生成器的预算才轮到 `MultiNodeGang`;现在多 Pod 作业第一轮探测(`ProbeK=1`)就直接进 `MultiNodeGang`。
  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/job_solver.go</summary>

  ```diff
  -	availableGenerators := ssn.ScenarioGeneratorRegistrations
  +	availableGenerators := generatorsForJob(ssn.ScenarioGeneratorRegistrations, pendingJob)
   	if len(availableGenerators) == 0 {
   		return false, nil, nil, terminalSearchResult(SearchResultNoGenerator, jobBudget.ReducedBudget())
   	}
  +func generatorsForJob(
  +	registrations []framework.ScenarioGeneratorRegistration, pendingJob *podgroup_info.PodGroupInfo,
  +) []framework.ScenarioGeneratorRegistration {
  +	if len(registrations) != 2 ||
  +		registrations[0].Name != constants.GeneratorNodeLocalGreedy ||
  +		registrations[1].Name != constants.GeneratorMultiNodeGang ||
  +		len(pendingJob.GetAllPodsMap()) <= 1 {
  +		return registrations
  +	}
  +
  +	return []framework.ScenarioGeneratorRegistration{registrations[1], registrations[0]}
  +}
  ```
  </details>
- **重排是"偏好"不是"排除",节点本地贪心仍作为回退被跑到;且管理员显式配置的顺序被当作意图保留。** 测试 `TestSolveWithResultUsesJobGeneratorOrderAcrossProbesAndFallback` 的 `multi-pod fallback` 用例断言工厂调用序列是 `[MultiNodeGang:1, NodeLocalGreedy:1, NodeLocalGreedy:2]`——多节点生成器出不了可行场景时仍回落到 `NodeLocalGreedy` 并继续推进 `ProbeK`。同一测试还断言 `require.Equal(t, order, generatorNames(ssn.ScenarioGeneratorRegistrations))`,即 session 上的注册顺序本身不被改写,重排只影响本次求解。`explicit reversed order` 与 `custom portfolio` / `missing built-in` 用例覆盖了守卫条件的三条短路路径(已反序、含自定义生成器、缺内置生成器)——均原样返回。
  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/job_solver_result_test.go、job_solver_test.go</summary>

  ```diff
  +		{
  +			name: "multi-pod fallback", pods: 2,
  +			solvingGenerator: constants.GeneratorNodeLocalGreedy,
  +			wantFactoryCalls: []string{"MultiNodeGang:1", "NodeLocalGreedy:1", "NodeLocalGreedy:2"},
  +		},
  +			require.Equal(t, test.wantFactoryCalls, factoryCalls)
  +			require.Equal(t, order, generatorNames(ssn.ScenarioGeneratorRegistrations))
  +		{
  +			name:          "admin-reversed portfolio for multi-pod job",
  +			pods:          2,
  +			registrations: []string{constants.GeneratorMultiNodeGang, constants.GeneratorNodeLocalGreedy},
  +			want:          []string{constants.GeneratorMultiNodeGang, constants.GeneratorNodeLocalGreedy},
  +		},
  +		{
  +			name:          "custom portfolio",
  +			pods:          2,
  +			registrations: []string{"custom-first", constants.GeneratorNodeLocalGreedy, "custom-middle", constants.GeneratorMultiNodeGang},
  +			want:          []string{"custom-first", constants.GeneratorNodeLocalGreedy, "custom-middle", constants.GeneratorMultiNodeGang},
  +		},
  ```
  </details>
- **`post-delete` 清理 hook 在 OpenShift 下的 `securityContext` 由"用户可配"改为"内置硬编码且独占"。** 模板原先只有一个分支 `{{- if .Values.global.securityContext }}`(渲染用户给的整段);现在前置一个 `{{- if (include "kai-scheduler.openshift" .) }}` 分支,硬编码 `runAsUser: 10000`、`runAsNonRoot: true`、`allowPrivilegeEscalation: false`、`capabilities.drop: [ALL]`,并把原分支降为 `else if`。两个分支互斥,所以 OpenShift 模式下 `global.securityContext` 里的任何字段(如 `readOnlyRootFilesystem`)对这个 job 不再生效。changelog 条目自述为"把 OpenShift 容器 securityContext 应用到 post-delete 清理 hook",说明这是补齐——`crd-upgrader` / `topology-migration` / `kai-config-deployer` 三个 hook job 早已有同样处理,chart 测试本期把它们一并纳入同一个 `openshift_test.yaml` 用例做回归锁定。
  <details><summary>代码依据 deployments/kai-scheduler/templates/hooks/post/post-delete-job.yaml、tests/openshift_test.yaml</summary>

  ```diff
  -          {{- if .Values.global.securityContext }}
  +          {{- if (include "kai-scheduler.openshift" .) }}
  +          securityContext:
  +            runAsUser: 10000
  +            runAsNonRoot: true
  +            allowPrivilegeEscalation: false
  +            capabilities:
  +              drop:
  +              - ALL
  +          {{- else if .Values.global.securityContext }}
             securityContext:
               {{- toYaml .Values.global.securityContext | nindent 12 }}
             {{- end }}
  +  - it: should prefer the OpenShift container securityContext over global.securityContext in the post-delete hook
  +    set:
  +      openshift: true
  +      postCleanup.enabled: true
  +      global.securityContext.readOnlyRootFilesystem: true
  +    asserts:
  +      - notExists:
  +          path: spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem
  +        template: hooks/post/post-delete-job.yaml
  ```
  </details>

### 后续发展方向 [AI]
- **portfolio 的"选型策略"正在成为一个独立的可演化面。** 从 6-25 的"注册 + 逐生成器时间预算"到今天的"按作业形状定序",决策输入第一次不再只是管理员配置,而是待调度对象的属性(Pod 数)。`generatorsForJob` 现在是硬编码的 if 链、只认两个内置生成器名,这种形状通常是后续抽成策略接口(按 gang 大小/拓扑需求/队列打分选生成器)的前身。证据只覆盖本次 diff 引入的单个函数与其测试,**未见**任何策略接口、配置项或 CRD 字段用来表达这个偏好,也未见把 `GetAllPodsMap()` 之外的作业属性引入判定。
- **判定用作业总 Pod 数而非 pending 数,是对"gang 作业整体放置"的刻意倾斜,代价是部分恢复场景的多余探测。** `multi-pod job with one pending pod` 用例把"2 Pod 作业只剩 1 个待调度"也归入多节点优先;这类"补一个 Pod"的恢复场景其实很可能单节点就能放下,却要先走一轮 `MultiNodeGang`。证据边界:diff 里没有任何注释或 changelog 解释这个取舍,也没有基准数据佐证净收益,PR 标题只说 `perf(scheduler)`;本次未展开读 PR #2750 讨论。
- **chart 的 OpenShift 分支正在从"逐 job 打补丁"走向"统一回归锁定",但没有抽成公共 helper。** 四个 hook job 的硬化已齐,测试也集中到一个 `openshift_test.yaml` 用例里断言;但四处的 `securityContext` 字面量仍各自重复一份,`kai-scheduler.openshift` helper 只负责判定模式、不负责产出 context。证据只覆盖 `post-delete-job.yaml` 与测试文件的 diff,**未见** `_helpers.tpl` 本期有改动,也未见把该 securityContext 提成命名模板的动作。

## 本期无实质改动(折叠)
<details><summary>8 仓本期零提交(HEAD 与上期锚点全同)</summary>

- `NVIDIA/gpu-operator` — HEAD 877c9860 停在 2026-11-25T19:53Z
- `NVIDIA/nvidia-container-toolkit` — HEAD 8abf9478 停在 2026-11-24T21:26Z
- `NVIDIA/gpu-driver-container` — HEAD 24e26a1a 停在 2026-11-24T22:33Z
- `NVIDIA/k8s-device-plugin` — HEAD c22b0c89 停在 2026-11-25T22:46Z
- `kubernetes-sigs/dra-driver-nvidia-gpu` — HEAD 5da6f625 停在 2026-11-24T21:04Z
- `NVIDIA/dcgm-exporter` — HEAD 4e663a52 停在 2026-11-06T18:45Z
- `NVIDIA/DCGM` — HEAD 9fae2867 停在 2026-10-21T16:46Z(master 分支长期低频)
- `NVIDIA/mig-parted` — HEAD 6cf77a2b 停在 2026-11-24T16:12Z

> 8 仓 HEAD 与提交时间已用 `commits?per_page=1` 单独复核,排除 helper 瞬时取数失败导致的假 EMPTY。`mig-parted` 首次扫描返回空 Release 字段,单独重跑后确认为 `v0.15.2`(与上期同),属瞬时抖动。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=877c98604aa7e9d88bf5b805307172acdf73548e branch=main release=v26.7.3 scanned=2026-11-28 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=8abf947869fd1f97019c267e9f02397c3ce4dc97 branch=main release=v1.20.2 scanned=2026-11-28 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=24e26a1ab32df265a298e95a4ec9116789d0b140 branch=main release=— scanned=2026-11-28 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=c22b0c894ebfdb779b6285ee980377032f28de3c branch=main release=v0.20.2 scanned=2026-11-28 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=5da6f62540fe3f807ba7023cc5b0690451072b3d branch=main release=v0.5.1 scanned=2026-11-28 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-28 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=6cf77a2b52a528d2bac5468b7a33abb7bf45ac68 branch=main release=v0.15.2 scanned=2026-11-28 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=9b8f4b3d5f6e68c719659c7f8ce1d96f3bfa04f2 branch=main release=v0.18.9 scanned=2026-11-28 -->
