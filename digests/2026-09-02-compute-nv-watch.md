# NVIDIA 算力栈 diff 雷达 2026-09-02

## 摘要
- 两处真功能修复,均属健壮性收口:**mig-parted** 在 MIG 重配流程里,等待 pod 删除失败或验证器重启失败时补设 `migStateFailed`(此前中途 abort 会把节点留在"进行中"状态);**dra-driver-nvidia-gpu** 修 Helm 里 `healthcheckPort=0` 被当成"关闭健康检查"的坑(0 在模板里为假值),改用 `ge (int port) 0` 判定,让端口 0 也能启用。
- gpu-operator 唯一一批新提交是全仓 Go 现代化重构(`interface{}`→`any`、`ptr.To`→`new`、`SplitSeq`/`maps.Copy`)+ 新增 RELEASE.md 发版流程文档,**无 CRD 字段增删、无行为变化**——`clusterpolicy_types.go` 命中仅是 `ImagePath(any)` 签名换字,非语义信号。
- KAI-Scheduler 新增 `kai-pending` 诊断 Agent 技能(纯文档),不改调度器代码,但把其"为什么 pod pending"的判定面完整摊开(PodGroup 按 node-pool 的 schedulingConditions、reclaim/fair-share/gang/fractional 语义),对我们做调度可观测性有直接参考价值。

## 当日重要改变
- 无(未命中弃用/移除、CRD 字段增删、架构方向、版本跨档、新增顶层 package 等硬信号)。gpu-operator 的 `api/nvidia/v1/clusterpolicy_types.go` 路径命中经核对为 `interface{}→any` 纯语法改写,不构成 API/CRD 变更,特此排除误报。

## kubernetes-sigs/dra-driver-nvidia-gpu: ccb1632e -> 6bbfbe02
- 比较: ccb1632e -> 6bbfbe02 | ahead=6 | files=10 | Release: v0.5.0
### AI 总结重点(源码 diff 为据)
- **修 `healthcheckPort=0` 被误判为"禁用健康检查"**。Helm 模板原来用 `{{- if .Values...healthcheckPort }}` 门控注入 `HEALTHCHECK_PORT` 环境变量,而 Helm 里数值 0 为假值,导致想显式用端口 0 的用户健康检查被静默跳过。改为 `{{- if ge (int .Values...healthcheckPort) 0 }}`——只要端口 ≥0 就注入。computeDomains(ComputeDomain 子系统)与 gpus(GPU 分配子系统)两个容器同步改。
  <details><summary>代码依据 deployments/helm/dra-driver-nvidia-gpu/templates/kubeletplugin.yaml</summary>

  ```diff
  -        {{- if .Values.kubeletPlugin.containers.computeDomains.healthcheckPort }}
  +        {{- if ge (int .Values.kubeletPlugin.containers.computeDomains.healthcheckPort) 0 }}
           - name: HEALTHCHECK_PORT
             value: {{ .Values.kubeletPlugin.containers.computeDomains.healthcheckPort | quote }}
           {{- end }}
  ...
  -        {{- if .Values.kubeletPlugin.containers.gpus.healthcheckPort }}
  +        {{- if ge (int .Values.kubeletPlugin.containers.gpus.healthcheckPort) 0 }}
  ```
  </details>
- 附带修一处 Helm `_helpers.tpl` 的 `selectorLabels` 兜底分支:原来 `fail "..."` 未包在 `{{ }}` 里、模板报错文本被当字面量输出,改成真正触发 `{{- fail ... -}}`;以及 validation.yaml 里 `nvidia-cdi-hook` 说明的拼写订正(diffent→different)。均为模板正确性修复,不改运行时行为。
  <details><summary>代码依据 deployments/helm/dra-driver-nvidia-gpu/templates/_helpers.tpl</summary>

  ```diff
  -fail "selectorLabels: both arguments are required: context, componentName"
  +{{- fail "selectorLabels: both arguments are required: context, componentName" -}}
  ```
  </details>
### 后续发展方向 [AI]
- 本期只碰 Helm 打包层,未见 DRA driver 内核逻辑(ResourceSlice/ComputeDomain 分配)改动,属发布后打磨。`nvidia-cdi-hook` 已是既定事实(validation.yaml 里对旧 `nvidiaCtkPath` flag 的弃用说明仍在),CDI hook 二进制自带化的方向未反转。证据仅覆盖 helm templates,未见 Go 侧。

## NVIDIA/mig-parted: 288cbe55 -> ed9999b7(概览+定点读)
- 比较: 288cbe55 -> ed9999b7 | ahead=9 | files=300(TPN/依赖噪声占绝大多数) | Release: v0.15.0
### AI 总结重点(源码 diff 为据)
- **MIG 重配 abort 时补置失败状态**。`pkg/mig/reconfigure/reconfigure.go` 的 `Run()` 在两个中途返回点补了 `_ = r.setState(migStateFailed)`:等待第三方 GPU 客户端 pod 删除失败(`waitForPodsToBeDeleted`)、以及重启验证器 pod 失败(`restartValidatorPod`)。此前这两条失败路径直接 `return err`、不落状态,节点会停在上一次的"进行中/pending"标注,外部(gpu-operator 的 mig-manager)据此判断易误读为"仍在重配"。
  <details><summary>代码依据 pkg/mig/reconfigure/reconfigure.go</summary>

  ```diff
   	if err := r.waitForPodsToBeDeleted(); err != nil {
  +		_ = r.setState(migStateFailed)
   		return fmt.Errorf("failed to wait for pods to be deleted: %w", err)
   	}
  ...
   	if err := r.restartValidatorPod(); err != nil {
  +		_ = r.setState(migStateFailed)
   		return fmt.Errorf("failed to restart validator pod: %w", err)
   	}
  ```
  </details>
- 本区间其余 8 条提交为依赖/TPN 维护(k8sio group、logrus 1.10.1→1.10.2、Third Party Notices 更新),files=300 系 THIRD_PARTY_NOTICES 与 vendor 撑大,非功能面。(概览模式,已定点拉取 pkg/mig 唯一功能 hunk;未逐一读依赖 diff)
### 后续发展方向 [AI]
- 延续 v0.15.0 "在 MIG 应用期间弹开第三方 GPU 客户端 pod"能力的收尾——把该流程的失败态可观测化,便于 gpu-operator 侧做状态机判定。证据只覆盖状态落库这一处,未见 MIG profile 计算或 GI/CI 切分逻辑改动。

## kai-scheduler/KAI-Scheduler: 99f938ed -> f8d0da40(信息型,非代码)
- 比较: 99f938ed -> f8d0da40 | ahead=1 | files=8 | Release: v0.14.8
### AI 总结重点(源码 diff 为据)
- **新增 `kai-pending` Agent 诊断技能**(`.agents/skills/kai-pending/`,纯 markdown,不改调度器),但内容等于把 KAI 的调度判定面官方文档化,几个对我们有参考价值的语义确认:
  - 判定单位:Pod(单)或 PodGroup(gang);裁决落在 `PodGroup.status.schedulingConditions`,**每个 node-pool 一条 condition**,读 `reasons[]`(顶层 `reason`/`message` 已弃用)。
  - 典型 reason 分类与含义:`QueueDoesNotExist`、`OverLimit`(allocated+requested>limit)、`NonPreemptibleOverQuota`(allocatedNP+requestedNP>deserved)、`PodSchedulingErrors`(逐节点 fit)。
  - 逐节点 fit 明细依赖安装开关:`--detailed-fit-errors=true` 才把 `requested/used/capacity` 写进 condition message,否则只在 `-v=6` 调度器日志。
  - fair-share/reclaim 只在调度器日志(`-v=3`)可见:`Attempting to allocate/reclaim job`、`Successfully preempted`、`Didn't find a reclaim strategy`;`fairShare = min(quota,requested)+加权 surplus`,受 `limit` 上限,自顶向下每周期重算;priorityClass ≥100 = 非抢占。
  <details><summary>代码依据 .agents/skills/kai-pending/SKILL.md</summary>

  ```markdown
  Its verdict is on the PodGroup's `.status.schedulingConditions`, one condition **per node-pool**
  ...
  - `OverLimit` (`allocated + requested > limit`) -> ...
  - `NonPreemptibleOverQuota` (`allocatedNP + requestedNP > deserved`) -> ...
  - per-node lines ... (available if installed with `--detailed-fit-errors=true`)
  ```
  </details>
### 后续发展方向 [AI]
- KAI 在把"调度可解释性"沉淀成可复用的诊断资产(此前已有 `snapshots` 技能),显示其运维定位是"决策必须可回放/可解释"。对我们产品的启示:PodGroup 级、按 node-pool 的分条裁决 + 可选的 detailed-fit-errors 开关,是可直接对标的可观测性接口设计。证据仅为文档,未见调度算法本身改动,不代表 fair-share/reclaim 实现有变。

## gpu-operator / gpu-driver-container(低信号,列备查)
- **NVIDIA/gpu-operator**(e6bac630 -> b491cd2c,ahead=3):全仓 Go 现代化重构 + 新增 `RELEASE.md`。改动集中在 `controllers/object_controls.go` 等:`interface{}`→`any`、`ptr.To(x)`→`new(x)`、`strings.Split`+for→`strings.SplitSeq`+range、手写 map 拷贝→`maps.Copy`、删冗余 `pod := pod`/`ds := ds` 循环变量捕获。**无 ClusterPolicy 字段增删、无 daemonset 编排行为变化**;`clusterpolicy_types.go` 仅 `ImagePath` 签名换 `any`。https://github.com/NVIDIA/gpu-operator/pull/2836
- **NVIDIA/gpu-driver-container**(63168bd0 -> 6c173e11,ahead=4):仅刷新基础镜像时间戳标签——Ubuntu resolute-20260724.1→20260811.1、noble-20260730.1→20260810、jammy-20260731.1→20260810,RHEL UBI8/9/10 同步跟版。OS 矩阵组成未变,无预编译逻辑改动。
- **NVIDIA/k8s-device-plugin**(5a3b3d85 -> 4d2b3c8e,ahead=2):仅新增 GOVERNANCE.md / CODE_OF_CONDUCT.md 及 CONTRIBUTING/README 引用,无代码。

## 本期无实质改动(折叠)
<details><summary>4 个 repo 本期无实质增量(EMPTY / 仅文档,均保锚点)</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 仍 3121efcf,Release v1.20.0)
- NVIDIA/dcgm-exporter — 无新提交(HEAD 仍 181290c3,Release 4.6.0-4.8.3)
- NVIDIA/DCGM — 无新提交(HEAD 仍 64df9f89,分支 master)
- NVIDIA/k8s-device-plugin — 仅治理/行为准则文档,无代码(见上,HEAD 4d2b3c8e)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=b491cd2c38b8e296a12f11cc844a20b0b898f96a branch=main release=v26.7.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3121efcf04bfe6898daa13d06c3101b1adc22234 branch=main release=v1.20.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=6c173e117cbb94145652f6c6217869f27b00294f branch=main release=— scanned=2026-09-02 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=4d2b3c8ef9cffedb7d1ea30e84b58a41e87cdee8 branch=main release=v0.20.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=6bbfbe0201cb43ba0e75a5aa653d5104285f6ffa branch=main release=v0.5.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-09-02 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-02 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=ed9999b74c336aacb5dfa5e47c4ee64c640bf12d branch=main release=v0.15.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=f8d0da40476b77ee2dd5b500039b0ca27a1227ad branch=main release=v0.14.8 scanned=2026-09-02 -->
