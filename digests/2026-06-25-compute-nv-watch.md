# NVIDIA 算力栈 diff 雷达 2026-06-25

## 摘要
- **KAI-Scheduler 发布 v0.16.0(跨 minor)**:把过去两天"有界场景搜索 + 生成器组合"从 CRD/骨架推到**可运行实现** —— 昨天还是 `return nil` 的两个生成器 `NodeLocalGreedy`/`MultiNodeGang` 今天补成真实代码,solver 接入逐层时间预算并返回结构化"为何停止搜索"结果,配套 7 个 `scenario_search_*` Prometheus 指标。抢占/整理(reclaim/preempt/consolidation)的可控时延能力闭环。
- **dra-driver-nvidia-gpu** 给 MPS 控制守护进程加 `--service-account-name`,让 MPS pod 继承 kubelet-plugin 的 SA(原先用 default SA),并把一批 flag 文案从"MPS 专用"泛化为"渲染 pod 模板通用"——DRA 驱动渲染更多 pod 模板的信号。
- 其余 7 仓(gpu-operator/container-toolkit/driver-container/device-plugin/dcgm-exporter/DCGM/mig-parted)本期无实质改动。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [版本跨档] 最新 Release v0.15.3 → **v0.16.0**(跨 minor),主线即下述场景搜索特性收口。https://github.com/kai-scheduler/KAI-Scheduler/releases/tag/v0.16.0
- kai-scheduler/KAI-Scheduler [新能力] 昨天注册但实现为空(`return nil`)的两个场景生成器今天落地:新增 `pkg/scheduler/plugins/nodelocalgreedy/generator.go`、`pkg/scheduler/plugins/multinodegang/generator.go` 两个 `framework.ScenarioGenerator` 真实实现。https://github.com/kai-scheduler/KAI-Scheduler/pull/1744
- kai-scheduler/KAI-Scheduler [架构方向] solver 接入逐层时间预算 + 结构化搜索结果:`NewJobsSolver` 增 `actionBudget` 形参、新增 `SolveWithResult` 返回 `*SearchResult`;consolidation/reclaim/preempt 据预算耗尽提前停。设计文档 `docs/developer/designs/reclaim-generator-portfolio-design.md` 同步更新。https://github.com/kai-scheduler/KAI-Scheduler/pull/1743
- kai-scheduler/KAI-Scheduler [新能力] 新增 7 个 `scenario_search_*` 可观测指标(jobs_total/duration_seconds/scenarios_total + 三级 budget_configured_seconds + action_budget_exhausted_total)。https://github.com/kai-scheduler/KAI-Scheduler/pull/1746
- kubernetes-sigs/dra-driver-nvidia-gpu [新能力/配置面] MPS 控制守护进程新增 `--service-account-name`/`SERVICE_ACCOUNT_NAME`,pod 模板渲染出 `serviceAccountName`,使 MPS pod 继承 kubelet-plugin 的 SA。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/65a7e283b7826333e20578bebb98bbbf9246a2df

## kai-scheduler/KAI-Scheduler: 9e0fcfec -> 181e80d2
- 比较: 9e0fcfececb190e0f24320ac69f58d2ffb7cd119 -> 181e80d2 | ahead=5 | files=30 | Release: v0.16.0
- 实质提交:wire scenario search budgets into solver(#1743)/ add built-in scenario generators(#1744)/ drive solver from generator portfolio(#1745)/ add scenario search metrics(#1746)/ Prepare changelog for v0.16(#1762)

### AI 总结重点(源码 diff 为据)
- **`JobSolver` 接入 action 级搜索预算,并新增结构化结果出口 `SolveWithResult`**。`NewJobsSolver` 多了 `actionBudget *ActionSearchBudget` 形参,传 nil 时回落到 `newUnlimitedActionSearchBudget`(无限 deadline);新增 `SolveWithResult` 在 `defer` 里按结果调 `metrics.IncScenarioSearchJobs(action, result, reducedBudget)`,把"搜索为何停止"显式上报。原 `Solve` 退化为 `SolveWithResult` 的薄封装。这是把昨天 `search_budget.go`/`search_result.go` 的模型真正接到求解主循环。

  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/job_solver.go</summary>

  ```diff
   type JobSolver struct {
   	solutionValidator    SolutionValidator
   	generateVictimsQueue GenerateVictimsQueue
   	actionType           framework.ActionType
  +	actionBudget         *ActionSearchBudget
   }
  +func newUnlimitedActionSearchBudget(action framework.ActionType) *ActionSearchBudget {
  +	now := time.Now
  +	return &ActionSearchBudget{ action: action, deadline: newDeadlineBudget(unlimitedRemaining, now) }
  +}
  +func (s *JobSolver) SolveWithResult(
  +	ssn *framework.Session, pendingJob *podgroup_info.PodGroupInfo,
  +) (solved bool, statement *framework.Statement, victimTaskNames []string, searchResult *SearchResult) {
  +	defer func() {
  +		if searchResult != nil {
  +			metrics.IncScenarioSearchJobs(s.actionType, searchResult.scenarioSearchMetricResult(), searchResult.ReducedBudget())
  +		}
  +	}()
  ```
  </details>

- **两个生成器从昨天的空壳变成真实实现**。昨天 `scenario_generator.go` 里 `NewNodeLocalGreedyGenerator`/`NewMultiNodeGangGenerator` 还是 `return nil`;今天新建独立包实现:`nodeLocalGreedyGenerator` 用 `PodAccumulatedScenarioBuilder` 逐个累积受害者、把累积场景展开成 node-local 子场景(`nodeLocalScenarios`)按节点贪心吐 `ScenarioInfo`;`multiNodeGangGenerator` 首次返回 `GetValidScenario`、之后 `GetNextScenario`,对应"多节点 gang"整体放置。两者各自 `Name()` 返回 `constants.GeneratorNodeLocalGreedy`/`GeneratorMultiNodeGang`。

  <details><summary>代码依据 pkg/scheduler/plugins/nodelocalgreedy/generator.go(新增)、multinodegang/generator.go(新增)</summary>

  ```diff
  +func NewNodeLocalGreedyGenerator(ctx framework.ScenarioGeneratorContext) framework.ScenarioGenerator {
  +	solveCtx, generateVictimsQueue, ok := solvers.ValidateScenarioGeneratorContext(ctx)
  +	if !ok { return nil }
  +	return &nodeLocalGreedyGenerator{ solveCtx: solveCtx, generateVictimsQueue: generateVictimsQueue }
  +}
  +func (g *nodeLocalGreedyGenerator) Next() api.ScenarioInfo {
  +	if !g.ensureBuilder() { return nil }
  +	for {
  +		if sn := g.popScenario(); sn != nil { return sn }
  +		accumulated := g.nextValidAccumulatedScenario()
  +		if accumulated == nil { return nil }
  +		g.scenarios = nodeLocalScenarios(g.solveCtx.Session, accumulated)
  +	}
  +}
  +// multinodegang:
  +func (g *multiNodeGangGenerator) Next() api.ScenarioInfo {
  +	if g.first { g.first = false; return g.builder.GetValidScenario() }
  +	return g.builder.GetNextScenario()
  +}
  ```
  </details>

- **`scenario_generator.go` 引入 `scenarioPortfolio` 编排多生成器 + 逐层预算**。原本两个工厂返回 nil 的位置,改为构造 `scenarioPortfolio{generators, jobBudget, currentBudget, stopReason}`,从 `ctx.Session.ScenarioGeneratorRegistrations` 拉取已注册生成器组成"组合",并提供 `newSingleGeneratorScenarioPortfolio` 单生成器路径。即昨天提案的 "generator portfolio" 调度面。

  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/scenario_generator.go</summary>

  ```diff
  -func NewNodeLocalGreedyGenerator(_ framework.ScenarioGeneratorContext) framework.ScenarioGenerator { return nil }
  -func NewMultiNodeGangGenerator(_ framework.ScenarioGeneratorContext) framework.ScenarioGenerator { return nil }
  +type scenarioPortfolio struct {
  +	ctx *SolveContext; generators []framework.ScenarioGenerator; jobBudget *jobSearchBudget
  +	currentIndex int; currentBudget *generatorSearchBudget; currentName string
  +	currentStartedAt time.Time; stopReason SearchResultReason
  +}
  +func newScenarioPortfolio(ctx *SolveContext, jobBudget *jobSearchBudget) *scenarioPortfolio {
  +	return newScenarioPortfolioForAvailableGenerators(ctx, jobBudget, ctx.Session.ScenarioGeneratorRegistrations, nil)
  +}
  ```
  </details>

- **consolidation action 据预算耗尽提前返回**。`Execute` 开头构造 `NewActionSearchBudget(ssn, framework.Consolidation)`,失败即退;主循环改用 `SolveWithResult`,新增 `shouldStopActionForSearchResult(searchResult)` 判断——预算耗尽时整个 action `return`,不再继续遍历后续 job。函数签名一路从 `(bool, *Statement)` 改成带 `*solvers.SearchResult` 的三返回值。这把"时间预算"真正落到 action 级时延控制。

  <details><summary>代码依据 pkg/scheduler/actions/consolidation/consolidation.go</summary>

  ```diff
  +	actionBudget, err := solvers.NewActionSearchBudget(ssn, framework.Consolidation)
  +	if err != nil { log.InfraLogger.Errorf("Invalid scenario search budget for consolidation: %v", err); return }
  -		if succeeded, stmt := attemptToConsolidateForPreemptor(ssn, job); succeeded {
  +		if succeeded, stmt, searchResult := attemptToConsolidateForPreemptor(ssn, job, actionBudget); succeeded {
   			...
  +		} else if shouldStopActionForSearchResult(searchResult) {
  +			return
   		}
  ```
  </details>

- **7 个 `scenario_search_*` 指标落地,搜索过程可观测**。`metrics.go` 新增 `scenario_search_jobs_total{action,result,reduced_budget}`、`scenario_search_duration_seconds`、`scenario_search_scenarios_total`,以及三级预算配置量 `..._action/job/generator_budget_configured_seconds` 与 `scenario_search_action_budget_exhausted_total`。配套 `METRICS.md` 更新。对应昨天"负向结果是近似、需可观测"承诺的指标侧兑现。

  <details><summary>代码依据 pkg/scheduler/metrics/metrics.go</summary>

  ```diff
  +	scenarioSearchJobsTotal                        *prometheus.CounterVec
  +	scenarioSearchActionBudgetConfiguredSeconds    *prometheus.GaugeVec
  +	scenarioSearchJobBudgetConfiguredSeconds       prometheus.Gauge
  +	scenarioSearchGeneratorBudgetConfiguredSeconds *prometheus.GaugeVec
  +	scenarioSearchActionBudgetExhaustedTotal       *prometheus.CounterVec
  +	scenarioSearchDurationSeconds                  *prometheus.HistogramVec
  +	scenarioSearchScenariosTotal                   *prometheus.CounterVec
  ```
  </details>

- **`PodAccumulatedScenarioBuilder` 暴露"只取累积外层场景、不展开子场景"的迭代入口**。新增 `GetValidAccumulatedScenario`/`GetNextAccumulatedScenario` + 内部 `iterateAccumulated`,供生成器按需先拿外层累积场景再自行展开(nodelocalgreedy 即基于此)。`SearchResult` 结构同步重构:去掉 `enteredSearch`,加 `solution *solutionResult`/`metricResult`,新增 `terminalSearchResult`/`solvedSearchResult`/`NewNotAttemptedSearchResult` 工厂与 `scenarioSearchMetricResult()`。

  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/pod_scenario_builder.go、search_result.go</summary>

  ```diff
  +func (asb *PodAccumulatedScenarioBuilder) GetValidAccumulatedScenario() *solverscenario.ByNodeScenario {
  +	return asb.iterateAccumulated(false)
  +}
   type SearchResult struct {
   	reason        SearchResultReason
  +	solution      *solutionResult
   	reducedBudget bool
  -	enteredSearch bool
  +	metricResult  string
   }
  ```
  </details>

### 后续发展方向 [AI]
- "有界场景搜索 + 生成器组合"三天内走完 CRD(06-23)→预算/结果骨架(06-24)→生成器实现+solver接入+指标(06-25)→v0.16.0 发布的完整链路:KAI 正把"抢占/整理决策的时延"做成可配置、可观测、可分层预算的一等能力。证据覆盖 solver 接入、两生成器实现、consolidation 提前停、7 指标;**未见** reclaim/preempt 两 action 是否同样接好 `SolveWithResult`(patch 仅完整展示 consolidation,job_solver hunk 截断),也未见 v0.16.0 release body 是否标 breaking。
- **对我们产品的启示**:GPU 集群抢占类调度的"搜索时延爆炸"是真实运维痛点,KAI 用"每 action/每 job/每 generator 三级时间预算 + 为何停止的结构化结果 + Prometheus 指标"给出一套可借鉴范式。我们若做自研/二开调度器,这套"有界搜索 + 可观测停因"值得对标——尤其 `scenario_search_action_budget_exhausted_total` 这类指标直接服务 SLO 告警。

## kubernetes-sigs/dra-driver-nvidia-gpu: ed0d0e55 -> 65a7e283
- 比较: ed0d0e5593dad7f0f7594ce08fd3239e52fb15ba -> 65a7e283 | ahead=4 | files=5 | Release: v0.4.1-rc.1
- 实质提交:fix typo in CDI spec error message / Fix: Use kubelet-plugin service account for MPS control daemon

### AI 总结重点(源码 diff 为据)
- **MPS 控制守护进程改用 kubelet-plugin 的 ServiceAccount,而非 default SA**。`gpu-kubelet-plugin` 新增 flag `--service-account-name`(env `SERVICE_ACCOUNT_NAME`);`MpsControlDaemonTemplateData` 加 `ServiceAccountName` 字段并在 `Start` 时从 `config.flags.serviceAccountName` 填充;`mps-control-daemon.tmpl.yaml` 据此渲染 `serviceAccountName:`。helm `kubeletplugin.yaml` 用 downward API(`fieldRef: spec.serviceAccountName`)把 plugin pod 自身 SA 注入该 env——即 MPS pod 默认继承 plugin 的 SA。修掉了 MPS 守护进程跑在 default SA 下导致 RBAC/镜像拉取权限不对的问题。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/main.go、sharing.go、templates/mps-control-daemon.tmpl.yaml、helm/.../kubeletplugin.yaml</summary>

  ```diff
  +		&cli.StringFlag{
  +			Name:        "service-account-name",
  +			Usage:       "Service account to use for rendering pod templates (e.g. for MPS control daemon Deployments). Empty string uses the Kubernetes default.",
  +			Destination: &flags.serviceAccountName,
  +			EnvVars:     []string{"SERVICE_ACCOUNT_NAME"},
  +		},
  +        - name: SERVICE_ACCOUNT_NAME
  +          valueFrom:
  +            fieldRef:
  +              fieldPath: spec.serviceAccountName
   # mps-control-daemon.tmpl.yaml:
  +      {{- if .ServiceAccountName }}
  +      serviceAccountName: {{ .ServiceAccountName }}
  +      {{- end }}
  ```
  </details>

- **flag 文案从"MPS 专用"泛化为"渲染 pod 模板通用"**。`--image-pull-secrets`/`--image-pull-policy` 的 Usage 从 "for MPS control daemon Deployments" 改为 "for rendering pod templates (e.g. for MPS control daemon Deployments)"。措辞泛化暗示 DRA 驱动后续会用同一套机制渲染更多 pod 模板(不止 MPS)。另含 `cdi.go` 两处错误信息拼写修正("failed to creat" → "create")。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/main.go、cmd/compute-domain-kubelet-plugin/cdi.go</summary>

  ```diff
  -			Usage:       "Comma-separated imagePullSecret names for MPS control daemon Deployments (e.g. regcred,other). Empty string means none.",
  +			Usage:       "Comma-separated imagePullSecret names for rendering pod templates (e.g. for MPS control daemon Deployments). Empty string means none.",
  -		return fmt.Errorf("failed to creat CDI spec: %w", err)
  +		return fmt.Errorf("failed to create CDI spec: %w", err)
  ```
  </details>

### 后续发展方向 [AI]
- DRA 驱动把"image pull secret/policy/SA"统一成"渲染 pod 模板的通用参数",而非 MPS 专属——证据是 Usage 文案泛化 + `SERVICE_ACCOUNT_NAME` 走 downward API。**对我们产品的启示**:DRA 路径下 GPU 共享(MPS)子组件的 RBAC/镜像凭证治理正在补齐,自研多租户场景需注意这些渲染出的 pod 是否落到正确 SA/命名空间。证据仅覆盖 MPS 一类模板,未见是否扩展到 time-slicing 等其他共享模式。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY</summary>

- NVIDIA/gpu-operator(ahead=2,仅 bump/CI/merge)
- NVIDIA/nvidia-container-toolkit(ahead=2,仅 bump/CI/merge)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9e35d5d4d2b30ca123aae53176ad9b8dfa6342f7 branch=main release=v26.3.2 scanned=2026-06-25 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=6fe425a59d0f722fd4ee29777f0714407bfeb909 branch=main release=v1.19.1 scanned=2026-06-25 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d13e99f038cf9943c73e53e2b17af34883ae3ae3 branch=main release=— scanned=2026-06-25 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.3 scanned=2026-06-25 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=65a7e283b7826333e20578bebb98bbbf9246a2df branch=main release=v0.4.1-rc.1 scanned=2026-06-25 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-25 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-25 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5dc3caa478807fec0fc6a2160ef9e8f056300e4e branch=main release=v0.14.2 scanned=2026-06-25 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=181e80d2d4f2856c140a7d4dcde11f003c7c6573 branch=main release=v0.16.0 scanned=2026-06-25 -->
