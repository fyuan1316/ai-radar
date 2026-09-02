# NVIDIA 算力栈 diff 雷达 2026-09-03

## 摘要
- **gpu-operator 一轮可观测性 + 健壮性收口**:新增 per-state reconcile 耗时直方图 `gpu_operator_state_seconds`(按 controller/state 打标)、operator 可选 `--pprof-bind-address` 性能剖析端口;nvidia-validator 把宿主 `nvidia-smi` 探测重构成 build-tag 分平台(linux 用 pathrs 安全路径解析,非 linux 出桩),privileged 校验器不再有 exec 到非常规路径二进制的口子。**无 CRD 字段增删**。
- k8s-device-plugin 仅一处 config-manager 符号链接错误包装修正(`%v`→`%w`),time-slicing/MPS 配置切换路径可用 `errors.Is` 溯源;gpu-driver-container、mig-parted 本期只加治理/行为准则文档(社区成熟度信号,非代码)。
- 其余 5 仓(container-toolkit / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / KAI-Scheduler)EMPTY;KAI-Scheduler release 标从 v0.14.8 跳到 v0.17.1(本窗口代码仅 bump/CI,系发布标追平)。

## 当日重要改变
- NVIDIA/gpu-operator [新能力/可观测性] 新增 `gpu_operator_state_seconds` 直方图,在 ClusterPolicy reconcile 循环与 state manager `SyncState` 两处按 `controller`+`state` 标签计每状态同步耗时;operator 增 `--pprof-bind-address`(空则禁用)。证据 `internal/state/metrics.go`、`controllers/clusterpolicy_controller.go`、`cmd/gpu-operator/main.go`。 https://github.com/NVIDIA/gpu-operator/commit/8f798871419a0dc4db60bc29b26a0360bea5157e
- NVIDIA/gpu-operator [健壮性] nvidia-validator 宿主 `nvidia-smi` 解析从 `main.go` 拆到 build-tag 文件:linux 用 `pathrs.OpenInRoot` 在挂载的 host root 内解析且只接受非空可执行常规文件,非 linux 出桩报错。证据 `cmd/nvidia-validator/resolve_linux.go`、`resolve_unsupported.go`。 https://github.com/NVIDIA/gpu-operator/commit/8f798871419a0dc4db60bc29b26a0360bea5157e
- kai-scheduler/KAI-Scheduler [版本跨档] 发布标 v0.14.8 → v0.17.1(锚点区间代码 diff 仅 bump/CI,归为发布标追平,非本窗口新功能)。 https://github.com/kai-scheduler/KAI-Scheduler/releases

## NVIDIA/gpu-operator: b491cd2c -> 8f798871
- 比较 / Release:`b491cd2c...8f798871` | ahead=9 | files=14 | Release v26.7.0
- https://github.com/NVIDIA/gpu-operator/compare/b491cd2c38b8e296a12f11cc844a20b0b898f96a...8f798871419a0dc4db60bc29b26a0360bea5157e

### AI 总结重点(源码 diff 为据)
- **新增每状态 reconcile 耗时指标**:新文件 `internal/state/metrics.go` 定义 `StateDurationSeconds` 直方图(namespace `gpu_operator`、name `state_seconds`、桶 0.01~300s、标签 `controller`+`state`),`init()` 注册到 controller-runtime metrics registry。两处埋点:ClusterPolicy reconcile 主循环按 `stateName` 计时,state manager `SyncState` 按 `state.Name()` 计时;`stateManager` 结构体因此新增 `crdKind` 字段并在 `NewManager` 里透传。→ 首次能按 CRD 种类 + 状态维度量化各 operand(driver/toolkit/dcgm/…)同步慢在哪。

  <details><summary>代码依据 internal/state/metrics.go + manager.go</summary>

  ```diff
  +var StateDurationSeconds = prometheus.NewHistogramVec(
  +	prometheus.HistogramOpts{
  +		Namespace: "gpu_operator",
  +		Name:      "state_seconds",
  +		Help:      "Time spent per reconcile in each state",
  +		Buckets:   []float64{0.01, 0.05, 0.1, 0.5, 1, 5, 15, 60, 300},
  +	},
  +	[]string{"controller", "state"},
  +)
  // stateManager 结构体:
  +	crdKind   string
  // SyncState 内:
  +		stateStart := time.Now()
   		ss, err := state.Sync(stateCtx, customResource, infoCatalog)
  +		StateDurationSeconds.WithLabelValues(m.crdKind, state.Name()).Observe(time.Since(stateStart).Seconds())
  ```
  </details>

- **operator 增加 pprof 端口开关**:`cmd/gpu-operator/main.go` 新增 `--pprof-bind-address` flag 并透传给 manager 的 `PprofBindAddress`,空字符串时禁用。→ 生产环境按需开 profiling,不常开以免暴露面。

  <details><summary>代码依据 cmd/gpu-operator/main.go</summary>

  ```diff
  +	var pprofAddr string
  +	flag.StringVar(&pprofAddr, "pprof-bind-address", "",
  +		"The address the pprof endpoint binds to (e.g. \":6060\"). Disabled when empty.")
   		HealthProbeBindAddress:  probeAddr,
  +		PprofBindAddress:        pprofAddr,
  ```
  </details>

- **nvidia-validator 宿主 nvidia-smi 解析跨平台化 + 安全化**:`resolveHostNvidiaSMI` 及 `hostNvidiaSMISearchPaths` 从 `main.go` 整体移出(-40 行),拆成 `resolve_linux.go`(`//go:build linux`,用 `pathrs.OpenInRoot(hostRootCtrPath, path)` 在挂载 host root 内解析候选路径,且仅接受 `IsRegular() && Size()>0 && 可执行位` 的文件)与 `resolve_unsupported.go`(`//go:build !linux` 桩,直接报错)。linux 运行行为不变,新增点是非 linux 可编译/跑单测,且注释明确"privileged validator 绝不 exec 非常规路径的假二进制"。

  <details><summary>代码依据 cmd/nvidia-validator/resolve_linux.go</summary>

  ```diff
  +func resolveHostNvidiaSMI(hostRootCtrPath string) (string, error) {
  +	for _, nvidiaSMIPath := range hostNvidiaSMISearchPaths {
  +		f, err := pathrs.OpenInRoot(hostRootCtrPath, nvidiaSMIPath)
  +		if err != nil { continue }
  +		fileInfo, err := f.Stat(); _ = f.Close()
  +		if err != nil { continue }
  +		if !fileInfo.Mode().IsRegular() || fileInfo.Size() == 0 || fileInfo.Mode().Perm()&0o111 == 0 {
  +			continue
  +		}
  +		return nvidiaSMIPath, nil
  +	}
  +	return "", fmt.Errorf("failed to find an executable 'nvidia-smi' on the host")
  +}
  ```
  </details>

- **新增 AGENTS.md(架构信号)**:面向 AI coding agent 的仓库指南,其中明确重申三条 CRD 边界——`ClusterPolicy`(api/v1,单例,走 Device Plugin 框架分配 GPU)、`GPUCluster`(api/v1alpha1,单例,**走 DRA 分配 GPU,作为 ClusterPolicy 的替代**)、`NVIDIADriver`(api/v1alpha1,per-node-pool 驱动配置)。→ 佐证 gpu-operator 侧 DRA 路径以独立 CRD 形态与经典 ClusterPolicy 并存,仍是"另一条主线"而非取代。

  <details><summary>代码依据 AGENTS.md</summary>

  ```diff
  +- `GPUCluster` (`api/v1alpha1`) — a singleton CRD describing the entire GPU software stack; uses
  +   Dynamic Resource Allocation for allocating GPUs; an alternative to the `ClusterPolicy` CRD.
  ```
  </details>

### 后续发展方向 [AI]
- 可观测性从"整体 reconcile 成功/失败"细化到"每状态耗时直方图",是把 operator 往 SLO/性能回归可量化方向推;下一步大概率是给慢状态加告警或在 e2e 里断言各 operand 同步耗时。证据只覆盖 metrics 埋点两处,未见配套 alert 规则或 dashboard。
- validator 侧的 pathrs 安全路径解析 + build-tag 分平台是"privileged 组件供应链/路径注入面收口"的延续,与近期 gpu-operator 反复加固 host 交互一致;证据只到 nvidia-smi 一处解析,未见其它 host 探测点同步改造。
- **DRA 迁移信号**:本窗口无 device-plugin→DRA 的实际搬迁代码,仅 AGENTS.md 文档层重申 GPUCluster/DRA 与 ClusterPolicy/DevicePlugin 双轨并存;time-slicing/MPS 配置面本期也无变化(k8s-device-plugin 仅错误包装修正)。方向未变,未见新增迁移动作。

## 本期无实质改动 / 仅文档(折叠)
<details><summary>展开</summary>

- **NVIDIA/k8s-device-plugin**(有微改,非新功能):`cmd/config-manager/main.go` 把 `updateSymlink` 三处错误从 `fmt.Errorf(...%v)` 改 `%w` 包装(读/删/建符号链接),使 time-slicing/MPS 配置切换失败可用 `errors.Is` 溯源;配套单测重构为子测试。 https://github.com/NVIDIA/k8s-device-plugin/commit/325c1b2d3ad97e98a8239a545df0c4e5d852ea45
- **NVIDIA/gpu-driver-container**:仅新增 `CODE_OF_CONDUCT.md`(Contributor Covenant 3.0)、`GOVERNANCE.md`(maintainer/contributor/community 角色 + core/routine 决策流程),订正 CONTRIBUTING/README 项目名。纯治理文档,无代码。 https://github.com/NVIDIA/gpu-driver-container/commit/6c0c02529f4124f52670f602f44d5c3681e7e2ba
- **NVIDIA/mig-parted**:同上,仅加 CODE_OF_CONDUCT.md / GOVERNANCE.md + README 补贡献段。无 MIG 切分逻辑变化。 https://github.com/NVIDIA/mig-parted/commit/58efa2ef91c4b6ff0f07eba943594cfb123e448b
- **NVIDIA/nvidia-container-toolkit**:EMPTY(仅 bump/CI/merge)。
- **kubernetes-sigs/dra-driver-nvidia-gpu**:EMPTY(无新提交)。
- **NVIDIA/dcgm-exporter**:EMPTY(无新提交)。
- **NVIDIA/DCGM**:EMPTY(无新提交)。
- **kai-scheduler/KAI-Scheduler**:EMPTY(仅 bump/CI/merge);release 标 v0.14.8 → v0.17.1,系发布标追平,本窗口无代码新功能。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=8f798871419a0dc4db60bc29b26a0360bea5157e branch=main release=v26.7.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=e03cd9be3a84635bce03df730f0c93605d966cbe branch=main release=v1.20.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=6c0c02529f4124f52670f602f44d5c3681e7e2ba branch=main release=— scanned=2026-09-03 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=325c1b2d3ad97e98a8239a545df0c4e5d852ea45 branch=main release=v0.20.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=6bbfbe0201cb43ba0e75a5aa653d5104285f6ffa branch=main release=v0.5.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-09-03 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-03 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=58efa2ef91c4b6ff0f07eba943594cfb123e448b branch=main release=v0.15.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=6d498486e4ba7967ad69853a5ed5fc54b6efac85 branch=main release=v0.17.1 scanned=2026-09-03 -->
