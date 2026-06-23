# NVIDIA 算力栈 diff 雷达 2026-06-24

## 摘要
- KAI-Scheduler **把昨天的设计文档落成代码**:新增 CRD 字段 `ScenarioSearchBudgets`(action/job/generator 三级时间预算)+ 新建 `solvers` 子包(search_budget/search_result/scenario_generator)+ 两个场景生成器插件 `sg-nodelocalgreedy`(优先级 360)与 `sg-multinodegang`(350),注册到 reclaim/preempt/consolidation 三类 action——"有界生成器组合"从提案进入实现期(API/CRD变更 + 新能力)。
- gpu-operator 清理死代码:删掉 ClusterPolicy Helm 模板里已失效的 `operator.initContainer` 渲染块、并从测试脚本移除 `CONTAINER_RUNTIME`/`defaultRuntime` 注入;同步把 device-plugin / GFD 镜像 v0.19.2 → **v0.19.3**(弃用/移除 + 版本)。
- 其余 7 仓全 EMPTY,无实质改动(toolkit/dra/dcgm-exporter/DCGM/k8s-device-plugin 无新提交;gpu-driver-container、mig-parted 仅 bump/CI)。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [API/CRD变更] SchedulingShard 新增 `scenarioSearchBudgets` 字段(maxActionSearchDuration / maxJobSearchDuration / minJobSearchDuration / maxGeneratorSearchDuration),CRD YAML 与 `_types.go` 同步,标注 alpha/experimental。证据:pkg/apis/kai/v1/schedulingshard_types.go(+87/-21)、deployments/kai-scheduler/crds/kai.scheduler_schedulingshards.yaml(+30/-1)https://github.com/kai-scheduler/KAI-Scheduler/pull/1742
- kai-scheduler/KAI-Scheduler [新能力] 新增 `pkg/scheduler/actions/common/solvers` 预算/结果模型 + 两个 scenario-generator 插件 sg-nodelocalgreedy / sg-multinodegang,经插件注册挂到 Reclaim/Preempt/Consolidation。证据:pkg/scheduler/plugins/nodelocalgreedy/nodelocalgreedy.go、pkg/scheduler/plugins/multinodegang/multinodegang.go、pkg/scheduler/actions/common/solvers/search_budget.go(+394)https://github.com/kai-scheduler/KAI-Scheduler/pull/1741
- NVIDIA/gpu-operator [弃用/移除] 删除 ClusterPolicy Helm 模板中已无用的 `operator.initContainer` 渲染块及测试脚本对 `CONTAINER_RUNTIME` 的支持。证据:deployments/gpu-operator/templates/clusterpolicy.yaml(-18)、tests/scripts/env-to-values.sh(-7)https://github.com/NVIDIA/gpu-operator/commit/c258f8370e11208b67ae3d396c0ce45ad4958eed

## kai-scheduler/KAI-Scheduler: cbd6e181 -> 9e0fcfec
- 比较 https://github.com/kai-scheduler/KAI-Scheduler/compare/cbd6e181953aa2cf480746c00f0cb009fb20fda6...9e0fcfececb190e0f24320ac69f58d2ffb7cd119 | ahead=4 files=27 | Release v0.15.3
### AI 总结重点(源码 diff 为据)
- **昨天的 `reclaim-generator-portfolio` 设计文档开始落地为可配置 CRD**。`SchedulingShardSpec` 新增可选字段 `ScenarioSearchBudgets *ScenarioSearchBudgets`,结构含四个时间预算旋钮:`MaxActionSearchDuration map[string]metav1.Duration`(按 action 名,`default` 兜底)、`MaxJobSearchDuration`(每个 pending job 上限)、`MinJobSearchDuration`(在 action/generator 预算砍掉前,保证每个 job 至少搜这么久)、`MaxGeneratorSearchDuration map[string]metav1.Duration`(按 generator 名)。`SetDefaultsWhereNeeded()` 新增 `DefaultScenarioSearchBudgets()` 注入默认值,CRD YAML 同步生成 `scenarioSearchBudgets` schema,字段描述明写 "alpha/experimental"。
  <details><summary>代码依据 pkg/apis/kai/v1/schedulingshard_types.go</summary>

  ```diff
  +type ScenarioSearchBudgets struct {
  +	// MaxActionSearchDuration limits total scenario search time per scheduler action.
  +	// Keys are action names, with "default" used as the fallback budget.
  +	MaxActionSearchDuration map[string]metav1.Duration `json:"maxActionSearchDuration,omitempty"`
  +	// MaxJobSearchDuration limits total scenario search time per pending job.
  +	MaxJobSearchDuration *metav1.Duration `json:"maxJobSearchDuration,omitempty"`
  +	// MinJobSearchDuration guarantees each pending job this much scenario search time
  +	// before action and generator budgets can stop the job's search.
  +	MinJobSearchDuration *metav1.Duration `json:"minJobSearchDuration,omitempty"`
  +	// MaxGeneratorSearchDuration limits scenario search time per generator attempt.
  +	MaxGeneratorSearchDuration map[string]metav1.Duration `json:"maxGeneratorSearchDuration,omitempty"`
  +}
  ```
  </details>
- **新增 `solvers` 预算执行三件套**:`search_budget.go`(+394)实现 `ActionSearchBudget` / `jobSearchBudget` / `generatorSearchBudget` 三层 deadline,顶层按 action 解析、逐 job 与逐 generator 下分;`search_result.go` 定义 `SearchResultReason` 五态枚举(`solved` / `deadline_exhausted` / `generators_exhausted` / `no_generator` / `not_attempted`)+ `reducedBudget`/`enteredSearch` 标志,把"为何停止搜索"显式建模(对应昨天提案"负向结果是近似、需可观测"的承诺)。
  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/search_result.go / search_budget.go</summary>

  ```diff
  +const (
  +	SearchResultSolved              SearchResultReason = "solved"
  +	SearchResultDeadlineExhausted   SearchResultReason = "deadline_exhausted"
  +	SearchResultGeneratorsExhausted SearchResultReason = "generators_exhausted"
  +	SearchResultNoGenerator         SearchResultReason = "no_generator"
  +	SearchResultNotAttempted        SearchResultReason = "not_attempted"
  +)
  +type ActionSearchBudget struct {
  +	action          framework.ActionType
  +	actionLimit     time.Duration
  +	jobLimit        time.Duration
  +	minJobSearch    time.Duration
  +	generatorLimits map[string]time.Duration
  +	deadline        deadlineBudget
  +}
  ```
  </details>
- **两个生成器以插件形式注册,绑定到三类 action**。新建 `sg-nodelocalgreedy`(优先级 360)、`sg-multinodegang`(350)两个 framework.Plugin,在 `OnSessionOpen` 里经 `ssn.AddScenarioGenerator(name, factory, framework.Reclaim, framework.Preempt, framework.Consolidation)` 注册,且做重名幂等防护。优先级编号也写进 plugin 默认顺序注释(360/350 紧挨在 gpupack/gpuspread=300 之上),即昨天提案"顺序 1 NodeLocalGreedy、顺序 2 MultiNodeGang"的实现。operator 侧 `resources_for_shard.go` 新增 `validateScenarioSearchBudgets()`:`maxActionSearchDuration` 只允许 `default/reclaim/preempt/consolidation` 四个 key、duration 不得为负、`minJob < maxJob`。
  <details><summary>代码依据 pkg/scheduler/plugins/nodelocalgreedy/nodelocalgreedy.go / operator validate</summary>

  ```diff
  +const Name = "sg-nodelocalgreedy"
  +func (p *nodeLocalGreedyPlugin) OnSessionOpen(ssn *framework.Session) {
  +	addScenarioGenerator(ssn, constants.GeneratorNodeLocalGreedy, solvers.NewNodeLocalGreedyGenerator)
  +}
  +	ssn.AddScenarioGenerator(name, factory, framework.Reclaim, framework.Preempt, framework.Consolidation)
  +var validScenarioSearchActionKeys = []string{
  +	constants.ActionDefault, constants.ActionReclaim, constants.ActionPreempt, constants.ActionConsolidation,
  +}
  ```
  </details>
- **queue 指标改用 `prometheus.Labels` map**(#1752,顺带修一类潜在 bug):`metrics.go` 把原来按位置 append 的 `[]string` 标签值改成按 metricLabelKey 命名的 `prometheus.Labels{}`,`getAdditionalMetricLabelValues` 返回类型由 `[]string` 改为 `prometheus.Labels`、用 `additionalMetricLabelKeys[i]` 显式键控——消除了"附加标签靠 key 与 value 切片顺序一致"的隐式约束。
  <details><summary>代码依据 pkg/queuecontroller/metrics/metrics.go</summary>

  ```diff
  -	queueQuotaMetricValues := append([]string{queueName, queueName, queueDisplayName}, additionalMetricLabelValues...)
  -	queueInfo.WithLabelValues(queueQuotaMetricValues...).Set(1)
  +	queueLabels := prometheus.Labels{ queueNameLabel: queueName, queueMetadataNameLabel: queueName, queueDisplayNameLabel: queueDisplayName }
  +	for metricLabelKey, value := range getAdditionalMetricLabelValues(queue.Labels) { queueLabels[metricLabelKey] = value }
  +	queueInfo.With(queueLabels).Set(1)
  ```
  </details>
### 后续发展方向 [AI]
- 这是 reclaim/抢占可扩展性改造从"提案"进入"实现"的关键一跳:昨天的设计文档(reclaim-generator-portfolio-design.md)今天落成 ① 可配置 CRD 字段、② solvers 预算/结果模型、③ 两个可插拔生成器插件。预算字段标 alpha/experimental,默认值由代码注入,说明先以"安全旁路"姿态合入、默认行为不变。对标我们产品的 GPU 批调度:"时间预算 + 可插拔场景生成器 + 显式停止原因枚举"这套分层值得直接借鉴,尤其 `SearchResultReason` 把"为何没找到 victim"做成可观测一等公民。证据覆盖 CRD/types/插件注册/预算骨架与 metrics 重构的 hunk;未见 `JobSolver` driver 如何消费这些 budget(消费侧改动在 session/framework 文件,本次 patch 节选被截断)、也未见默认预算的具体取值(在 constants.go,本次未摘到 hunk)。

## NVIDIA/gpu-operator: 9b198ba8 -> c258f837
- 比较 https://github.com/NVIDIA/gpu-operator/compare/9b198ba801ee9f1754dea0d74d85384659bea1c9...c258f8370e11208b67ae3d396c0ce45ad4958eed | ahead=16 files=136(含大量 vendor) | Release v26.3.2
### AI 总结重点(源码 diff 为据)
- **删除已失效的 `operator.initContainer` Helm 模板块**。ClusterPolicy 模板原本会按 `.Values.operator.initContainer.{repository,image,version,imagePullPolicy,imagePullSecrets}` 渲染一个 `initContainer:` 段,本次整段移除(-18 行);提交标题点明这是 "dead" 配置——即该 value 已无对应 operator 逻辑消费,属清理而非功能删减。
  <details><summary>代码依据 deployments/gpu-operator/templates/clusterpolicy.yaml</summary>

  ```diff
  -    {{- if .Values.operator.initContainer }}
  -    initContainer:
  -      {{- if .Values.operator.initContainer.repository }}
  -      repository: {{ .Values.operator.initContainer.repository }}
  -      ...
  -      imagePullSecrets: {{ toYaml .Values.operator.initContainer.imagePullSecrets | nindent 8 }}
  -    {{- end }}
  ```
  </details>
- **测试脚本同步移除 `CONTAINER_RUNTIME` → `operator.defaultRuntime` 注入**。`env-to-values.sh` 删去把 `CONTAINER_RUNTIME`(docker/containerd/crio)写成 `operator.defaultRuntime` 的分支及注释,与上面 dead 配置清理同批,反映 operator 已不再需要显式指定默认运行时。
  <details><summary>代码依据 tests/scripts/env-to-values.sh</summary>

  ```diff
  -#   - CONTAINER_RUNTIME: default runtime (docker, containerd, crio)
  -if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
  -    OPERATOR_CONFIG="${OPERATOR_CONFIG}  defaultRuntime: \"${CONTAINER_RUNTIME}\"\n"
  -    echo "Added operator.defaultRuntime: ${CONTAINER_RUNTIME}"
  -fi
  ```
  </details>
- **device-plugin / GFD 镜像 v0.19.2 → v0.19.3**:`values.yaml` 的 devicePlugin/gfd version、bundle CSV 的 device-plugin-image/gpu-feature-discovery-image/GFD_IMAGE/DEVICE_PLUGIN_IMAGE(含 sha256)同步推进。container-toolkit(v1.19.1)、dcgm(4.5.2)、dcgm-exporter(4.5.3-4.8.2)、mig-manager(v0.14.2)均不动。其余为 CI 维护:全仓 workflow `actions/checkout@v6→v7`、`renovatebot/github-action v46.1.15→v46.1.16`。
### 后续发展方向 [AI]
- 本期 gpu-operator 无 ClusterPolicy CRD 实质字段增删(改动集中在 Helm 模板渲染与测试脚本),是一次配置面瘦身 + 子组件 patch 版本对齐,无能力面变化。值得留意 `defaultRuntime`/`initContainer` 这类历史配置被判定 dead,说明 operator 正持续收敛安装期可调项。证据覆盖模板与脚本 hunk;files=136 主要为 vendor(prometheus-operator)噪声,API 路径命中全部落在 vendor 内,无第一方 CRD 改动。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY(仅保锚点)</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 仅 bump/CI/merge(ahead=2)
- NVIDIA/k8s-device-plugin — 无新提交(release 标签随 v0.19.3 推进,HEAD 未变)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 仅 bump/CI/merge(ahead=8)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=c258f8370e11208b67ae3d396c0ce45ad4958eed branch=main release=v26.3.2 scanned=2026-06-24 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=6d1a53dbd83f7b95eff3645afedf2335466014f2 branch=main release=v1.19.1 scanned=2026-06-24 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d13e99f038cf9943c73e53e2b17af34883ae3ae3 branch=main release=— scanned=2026-06-24 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.3 scanned=2026-06-24 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=ed0d0e5593dad7f0f7594ce08fd3239e52fb15ba branch=main release=v0.4.1-rc.1 scanned=2026-06-24 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-24 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-24 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5dc3caa478807fec0fc6a2160ef9e8f056300e4e branch=main release=v0.14.2 scanned=2026-06-24 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=9e0fcfececb190e0f24320ac69f58d2ffb7cd119 branch=main release=v0.15.3 scanned=2026-06-24 -->
