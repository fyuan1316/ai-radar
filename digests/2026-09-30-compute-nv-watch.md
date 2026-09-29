# NVIDIA 算力栈 diff 雷达 2026-09-30

## 摘要
- **MPS 信号目标匹配 bug 跨两仓修复**:gpu-operator 与 k8s-device-plugin 同步把 `PROCESS_TO_SIGNAL` 默认值从绝对路径 `/usr/bin/mps-control-daemon` 改成裸名 `mps-control-daemon`,并在 config-manager 里改用 basename 比较,修的是 MPS 控制守护进程在 pod PID namespace 内因路径不一致而找不到 PID、SIGHUP 重载配置失败的问题。MPS(多进程共享 GPU)是 time-slicing 之外的 NVIDIA 原生共享路径,这条链路稳定性直接影响我们做 GPU 共享的可靠性。
- **gpu-operator 修复 DaemonSet 就绪误判**:`isDaemonSetReady` 现在要求 `ObservedGeneration >= Generation` 才判就绪,堵住"上一代 generation 的 pod 数刚好匹配就被当成新一代已滚动完成"的假就绪窗口——operator 上报 operand ready 更可信。
- 其余为 UBI 基镜像 digest bump(gpu-driver-container)、测试开 race detector(mig-parted)、KAI-Scheduler 节点扩容器纳入 nvFraction 注解计算。无 API/CRD 字段增删,无版本跨档。

## 当日重要改变(命中信号才列;无则写"无")
- 无(本期无提交命中 弃用/移除·API/CRD变更·架构方向·版本跨档·新能力 五类硬信号;下列改动均为行为修复/测试基建,归入各 repo 正文)

## NVIDIA/gpu-operator: 60526e35 -> 20fb2db3
- 比较: https://github.com/NVIDIA/gpu-operator/compare/60526e35efeeedef584d8f40db0bac8864f98f26...20fb2db3ee43b85cb59cbb51c44e8a129bee1829 | ahead=7 | Release: v26.7.1
### AI 总结重点(源码 diff 为据)
- `isDaemonSetReady` 的非零-desired 分支新增 `ObservedGeneration >= Generation` 前置条件。之前只比对 DesiredNumberScheduled/NumberAvailable/UpdatedNumberScheduled 三者,DaemonSet controller 还没 observe 到新 generation 时,旧一代残留的匹配 pod 数会被误判为"已就绪";现在必须 controller 已 observe 当代才可能返回 ready。配套把原来标注"已知缺陷、暂当 ready"的 characterization 测试翻转为"stale generation 必须 not ready"。
  <details><summary>代码依据 internal/state/state_skel.go</summary>

  ```diff
  -	if ds.Status.DesiredNumberScheduled != 0 && ds.Status.DesiredNumberScheduled == ds.Status.NumberAvailable &&
  +	if ds.Status.ObservedGeneration >= ds.Generation &&
  +		ds.Status.DesiredNumberScheduled != 0 && ds.Status.DesiredNumberScheduled == ds.Status.NumberAvailable &&
   		ds.Status.UpdatedNumberScheduled == ds.Status.NumberAvailable {
   		return true, nil
   	}
  ```
  </details>
- MPS 控制守护进程 manifest 里 `PROCESS_TO_SIGNAL` 从绝对路径改裸名,与 k8s-device-plugin 的 basename 匹配修复对齐(见该 repo)。
  <details><summary>代码依据 assets/state-mps-control-daemon/0400_daemonset.yaml</summary>

  ```diff
  -              value: "/usr/bin/mps-control-daemon"
  +              value: "mps-control-daemon"
  ```
  </details>
- `GetFilesWithSuffix` 在匹配到一个后缀后 `break`,避免同一文件命中多个重叠后缀(如 `.gz` 和 `.tar.gz`)被重复收录;`GetObjectHashIgnoreEmptyKeys` 补文档明确 obj 必须是 struct/struct 指针,否则 panic。均为健壮性修补,无行为面变化。
  <details><summary>代码依据 internal/utils/utils.go</summary>

  ```diff
   			if strings.HasSuffix(base, s) {
   				files = append(files, path)
  +				break
   			}
  ```
  </details>
### 后续发展方向 [AI]
- 两条修复都指向 operator 状态机的"就绪判定精确化"与"MPS 运维正确性",无 ClusterPolicy CRD 字段变动(本期 `api/nvidia/v1` 未命中)。证据只覆盖 state/utils 与 MPS manifest,未见 driver/toolkit/DRA 编排层改动。

## NVIDIA/k8s-device-plugin: 86142cf1 -> 55eb57c8
- 比较: https://github.com/NVIDIA/k8s-device-plugin/compare/86142cf1a93fb68a99c5927b9599e13392e27e15...55eb57c83ebed81932f0c68320078d67cdc459fc | ahead=4 | Release: v0.20.1
### AI 总结重点(源码 diff 为据)
- config-manager 新增 `cmdlineMatchesProcessTarget(argv0, target)`:先全等比,再退化到 `filepath.Base` 比 basename。`findPidToSignal` 里遍历 procfs 时改用它替换原来的 `cmdline[0] == f.ProcessToSignal` 严格全等。根因是容器 command 常是裸名 `mps-control-daemon` 而 `PROCESS_TO_SIGNAL` 曾被设成绝对路径,pod PID namespace 内 argv0 对不上导致信号发不出去。同时 Helm 模板把默认 `PROCESS_TO_SIGNAL` 也改成裸名。
  <details><summary>代码依据 cmd/config-manager/main.go</summary>

  ```diff
  +func cmdlineMatchesProcessTarget(argv0, target string) bool {
  +	if argv0 == target {
  +		return true
  +	}
  +	return filepath.Base(argv0) == filepath.Base(target)
  +}
  @@ findPidToSignal @@
  -		if cmdline[0] == f.ProcessToSignal {
  +		if cmdlineMatchesProcessTarget(cmdline[0], f.ProcessToSignal) {
   			return p.PID, nil
   		}
  ```
  </details>
- Helm 模板 `daemonset-mps-control-daemon.yml` 的 `PROCESS_TO_SIGNAL` 由 `/usr/bin/mps-control-daemon` 改 `mps-control-daemon`,与上面的匹配逻辑及 gpu-operator manifest 三处一致收口。
  <details><summary>代码依据 deployments/helm/nvidia-device-plugin/templates/daemonset-mps-control-daemon.yml</summary>

  ```diff
  -            value: "/usr/bin/mps-control-daemon"
  +            value: "mps-control-daemon"
  ```
  </details>
### 后续发展方向 [AI]
- basename 匹配是容错性放宽而非精确化(理论上两个同名不同路径的进程会误命中,测试用例已把 `mps-control` 前缀不匹配 `mps-control-daemon` 覆盖到)。证据只覆盖 config-manager 与 MPS Helm 模板,time-slicing/MPS→DRA 的迁移信号本期未见。

## kai-scheduler/KAI-Scheduler: 52155f61 -> 45cadab0
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/52155f6189bda3d46f4011fa1ce328fd74e25a95...45cadab0443fe1a3ea9032968ca7208c36d97897 | ahead=1 | Release: v0.18.1
### AI 总结重点(源码 diff 为据)
- node-scale-adjuster(为不可调度的分片 GPU pod 触发节点扩容的组件)的 GPU 需求计算重构:`getGPUFraction` 从"先读 `gpu-fraction` 注解、否则读 `gpu-memory` 注解"的二分支,改成统一走 `resources.ParsePodGPUFractionRequest(pod)`,返回结构含 `Portion`/`Memory`;`req == nil` 明确表示"非分片 pod 返回 0"。这样能识别新的 nvFraction(按容器的 `CalcGpuFractionAnnotationForContainer`)注解形式,原先只认 pod 级 `gpu-fraction`/`gpu-memory` 会漏算,导致扩容设备数偏少。
  <details><summary>代码依据 pkg/nodescaleadjuster/scale_adjuster/calculator.go</summary>

  ```diff
  -	if pod.Annotations[constants.GpuFraction] != "" {
  -		gpuFraction, err := resources.GetGPUFraction(pod)
  -		...
  -	}
  -	gpuMemory, err := resources.GetGPUMemory(pod)
  +	req, err := resources.ParsePodGPUFractionRequest(pod)
   	if err != nil {
  -		return 0, err
  +		return 0, fmt.Errorf("failed to parse GPU fraction request for pod %v/%v: %w", ...)
  +	}
  +	if req == nil {
  +		return 0, nil // not a fractional pod
  +	}
  +	if req.Portion != 0 {
  +		return req.Portion, nil
   	}
  -	if gpuMemory > 0 {
  +	if req.Memory != nil {
   		return c.gpuMemoryToFractionRatio, nil
   	}
  ```
  </details>
- 随重构删除了 `resources.GetGPUFraction` 与 `GetGPUMemory` 两个基于单一注解、直接 ParseFloat/ParseInt 的旧 helper(其职责被 `ParsePodGPUFractionRequest` 吸收)。方法与变量从 `unschedulablePods` 统一改名为 `unschedulableFractionalPods`,语义收窄为"只针对分片 pod"。
  <details><summary>代码依据 pkg/common/resources/gpu_sharing.go</summary>

  ```diff
  -func GetGPUFraction(pod *v1.Pod) (float64, error) { ... }
  -func GetGPUMemory(pod *v1.Pod) (int64, error) { ... }
  ```
  </details>
### 后续发展方向 [AI]
- 方向是把 GPU 分片请求的解析收敛到单一入口(`ParsePodGPUFractionRequest`),支持按容器粒度的 nvFraction 注解,自动扩容更精确。删的是内部 Go helper 非对外 flag/CRD,不算破坏性。证据只覆盖 node-scale-adjuster 计算路径,调度主环(gang/reclaim 等)本期未见改动。

## NVIDIA/gpu-driver-container: 39e0cfd3 -> 73b03d85
- 比较: https://github.com/NVIDIA/gpu-driver-container/compare/39e0cfd337a0cac8d272412b8fa16343c973afe9...73b03d850b0d2468a75341e5054315aee49f966d | ahead=2 | Release: —
### AI 总结重点(源码 diff 为据)
- rhel8/9/10 三个 Dockerfile 的 `BASE_IMAGE` UBI digest 例行 bump(如 ubi9 `9.8-1789646010`→`9.8-1790556197`),同一 UBI 小版本内的镜像 refresh,不涉 OS 矩阵新增/预编译策略变化。
  <details><summary>代码依据 rhel9/Dockerfile</summary>

  ```diff
  -ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:9.8-1789646010
  +ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:9.8-1790556197
  ```
  </details>
### 后续发展方向 [AI]
- 纯基镜像刷新,无信号价值。证据仅覆盖三个 Dockerfile 首行。

## NVIDIA/mig-parted: 626a3f6a -> a668e5c9
- 比较: https://github.com/NVIDIA/mig-parted/compare/626a3f6a2c8597705f42b4be27a822f561fef706...a668e5c92da14856769edcb0fec27946abf8920c | ahead=2 | Release: v0.15.1
### AI 总结重点(源码 diff 为据)
- Makefile 的 `test` target 加 `-race`,单测启用竞态检测器,纯测试基建,无 MIG 切分逻辑改动。
  <details><summary>代码依据 Makefile</summary>

  ```diff
  -	go test -v -coverprofile=$(COVERAGE_FILE) ...
  +	go test -v -race -coverprofile=$(COVERAGE_FILE) ...
  ```
  </details>
### 后续发展方向 [AI]
- 无功能信号。MIG 静态切分配置面本期无变化。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos(仅 bump/CI/merge 或无新提交,保锚点)</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交(Release v1.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(Release v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(Release 4.8.4)
- NVIDIA/DCGM — 无新提交(master)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=20fb2db3ee43b85cb59cbb51c44e8a129bee1829 branch=main release=v26.7.1 scanned=2026-09-30 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=84e2c2c182bfa0b2edab4fdca27e5197faba0ca7 branch=main release=v1.20.1 scanned=2026-09-30 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=73b03d850b0d2468a75341e5054315aee49f966d branch=main release=— scanned=2026-09-30 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=55eb57c83ebed81932f0c68320078d67cdc459fc branch=main release=v0.20.1 scanned=2026-09-30 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=495bf4c59b9423080aa1fe2163955f44a495012c branch=main release=v0.5.0 scanned=2026-09-30 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-09-30 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-30 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=a668e5c92da14856769edcb0fec27946abf8920c branch=main release=v0.15.1 scanned=2026-09-30 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=45cadab0443fe1a3ea9032968ca7208c36d97897 branch=main release=v0.18.1 scanned=2026-09-30 -->
