# NVIDIA 算力栈 diff 雷达 2026-08-08

## 摘要
- 全天仅 KAI-Scheduler 一条实质提交:修一个 Go append 返回值丢弃的经典 bug——operator 生成 controller 部署时 `--qps`/`--burst` 客户端限流参数此前被静默丢弃,现在真正透传到 queue/pod_group/admission 三个 controller 的容器 args(#2027)。
- 其余 8 仓无实质改动(gpu-operator/nvidia-container-toolkit/gpu-driver-container/k8s-device-plugin/dra-driver-nvidia-gpu/mig-parted 仅 bump/CI/merge;dcgm-exporter/DCGM 无新提交)。
- 无 API/CRD、无新能力、无 breaking 信号。

## 当日重要改变
- 无(仅一条纯 bug 修复,未命中弃用/API-CRD/架构/版本跨档/新能力任何信号)。

## kai-scheduler/KAI-Scheduler: c048f657 -> d5bc503a
- 比较: c048f6571cac11da4836c0c929b09d2b56db2f38 -> d5bc503a | ahead=1 | files=8 | Release: v0.17.0
- https://github.com/kai-scheduler/KAI-Scheduler/pull/2027
- https://github.com/kai-scheduler/KAI-Scheduler/commit/d5bc503a146317e51037d89775d77172c6d12f71

### AI 总结重点(源码 diff 为据)
- `common.AddK8sClientConfigToArgs` 原来是 `func(...)`(无返回值),内部对入参 `args` 做 `append` 后不回传。由于 Go 里 `append` 在扩容时返回的是**新底层数组的切片头**,调用方 `common.AddK8sClientConfigToArgs(cfg, args)` 不接收返回值就会把追加的 `--qps`/`--burst` 全部丢掉——即用户在 `K8sClientConfig` 里配的 QPS/Burst 限流值对 operator 托管的 controller **完全不生效**。改法:函数签名改为返回 `[]string`,queue_controller / pod_group_controller / admission 三处 `buildArgsList` 全部改成 `args = common.AddK8sClientConfigToArgs(...)` 接住返回值。
  <details><summary>代码依据 pkg/operator/operands/common/common.go</summary>

  ```diff
  -func AddK8sClientConfigToArgs(k8sClientConfig *kaiv1common.K8sClientConfig, args []string) {
  +func AddK8sClientConfigToArgs(k8sClientConfig *kaiv1common.K8sClientConfig, args []string) []string {
   	if k8sClientConfig != nil {
   		if k8sClientConfig.QPS != nil {
   			args = append(args, "--qps", strconv.Itoa(*k8sClientConfig.QPS))
   		}
   		if k8sClientConfig.Burst != nil {
   			args = append(args, "--burst", strconv.Itoa(*k8sClientConfig.Burst))
   		}
   	}
  +
  +	return args
   }
  ```
  </details>
  <details><summary>代码依据 三处调用点(queue_controller / pod_group_controller / admission resources.go)</summary>

  ```diff
  -	common.AddK8sClientConfigToArgs(config.Service.K8sClientConfig, args)
  +	args = common.AddK8sClientConfigToArgs(config.Service.K8sClientConfig, args)
  ```
  </details>
- 影响面:仅限 operator(kai-operator)按 `Config` CRD 渲染各 controller Deployment 的 args 环节,是控制面渲染 bug,不触及调度内核。改动同时给 queue/pod_group/admission 三处补了断言 `--qps`/`--burst` 出现在容器 Args 的测试(如 QPS=42/Burst=84),证明此前这三条路径都漏传。

### 后续发展方向 [AI]
- 纯正确性收口,无能力/架构演进。证据只覆盖 args 渲染路径,未见对调度器主流程或 CRD schema 的任何改动;`K8sClientConfig` 字段本身早已存在(此次未改 `*_types.go`),这是让既有字段"生效"而非新增配置面。

## 本期无实质改动(折叠)
<details>
- NVIDIA/gpu-operator — ahead=2,仅 bump/CI/merge
- NVIDIA/nvidia-container-toolkit — ahead=2,仅 bump/CI/merge
- NVIDIA/gpu-driver-container — ahead=2,仅 bump/CI/merge
- NVIDIA/k8s-device-plugin — ahead=1,仅 bump/CI/merge
- kubernetes-sigs/dra-driver-nvidia-gpu — ahead=4,files=94 但均 bump/CI/merge(无实质提交)
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — ahead=2,仅 bump/CI/merge
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=cfabcc9a8c4cc071a7120d320d0d8db79984a166 branch=main release=v26.3.3 scanned=2026-08-08 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a996390117806acd2a73fd0e5b3e6a17755f3ae4 branch=main release=v1.20.0-rc.1 scanned=2026-08-08 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=dd8eab6bdea9de694423120038415b81357555dc branch=main release=— scanned=2026-08-08 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=04fc23c27961f42346bcba90e7d00fc2ed818fa0 branch=main release=v0.19.3 scanned=2026-08-08 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=95932046683719c43b6a0dd9613c2e5aad5d6703 branch=main release=v0.4.1 scanned=2026-08-08 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-08 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-08 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=a268637ff387f4b47f298e1f8b06beaa263e3ce1 branch=main release=v0.14.4 scanned=2026-08-08 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=d5bc503a146317e51037d89775d77172c6d12f71 branch=main release=v0.17.0 scanned=2026-08-08 -->
