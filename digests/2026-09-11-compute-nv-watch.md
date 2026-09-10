# NVIDIA 算力栈 diff 雷达 2026-09-11

## 摘要
- **KAI-Scheduler 深化 HAMi 集成 + 给 queue-controller 补 PDB**:e2e 首次引入 `--test-hami` 开关,新增 `hack/hami/deploy_isolator.sh` 装 `kai-resource-isolator`(projecthami 官方 chart,开 monitor)并打开 binder `hamicore` 插件——NVIDIA 自家调度器与 HAMi 软隔离栈的联调路径正式落进仓库;另把 `queue-controller` 纳入 operator 侧 PDB 实现清单,补上高可用短板。
- **mig-parted 修 `MigConfig.Equals` 语义**:zero-count profile 现在等价于"未列出",比较不再因申请里带 `2g.10gb: 0` 之类占位项而误判"配置不一致"触发无谓 reconcile。
- 其余为治理/滚动:container-toolkit 全仓开 `modernize` linter 并机械改写(`to.Ptr→new`、`for i:=0→for range`),dra-driver-nvidia-gpu 只补 kubelet 插件 NVML/MIG 单测,gpu-driver-container 仅滚 Ubuntu/UBI 基镜像日期 tag;gpu-operator / k8s-device-plugin / dcgm-exporter / DCGM 本期无新提交。

## 当日重要改变
- **KAI-Scheduler [新能力/生态]** e2e 新增 HAMi 集成路径:`hack/setup-e2e-cluster.sh` / `run-e2e-kind.sh` 加 `--test-hami`,触发 `hack/hami/deploy_isolator.sh` 装 `kai-resource-isolator`(默认 `oci://docker.io/projecthami/kai-resource-isolator`,`monitor.enabled=true`)+ helm `--set binder.plugins.hamicore.enabled=true`,验证 KAI 的 `CUDA_DEVICE_MEMORY_LIMIT` 注入与受限 `nvidia-smi` 显存可见性隔离契约。 https://github.com/kai-scheduler/KAI-Scheduler/commit/30c25346ee013e67d2e14df0429bec52f1885131
- **KAI-Scheduler [新能力]** `queue-controller` 加入 operator 侧 PDB:`PodDisruptionBudgetImplementedServices` 新增 `queue-controller`,`resources.go` 加 `podDisruptionBudgetForKAIConfig`,helm `_helpers.tpl` 渲染 `queuecontroller.podDisruptionBudget{enabled,maxUnavailable}`。 https://github.com/kai-scheduler/KAI-Scheduler/commit/30c25346ee013e67d2e14df0429bec52f1885131
- **mig-parted [缺陷/语义]** `MigConfig.Equals` 去掉 `len` 短路,改为双向比较且缺失 key 视为 count=0,zero-count profile 与 omitted 等价——避免带占位 profile 的期望配置与硬件实配被误判为"不同"。 https://github.com/NVIDIA/mig-parted/commit/377f931e2d64f1a7e716d57e4084257f4cc09757

## kai-scheduler/KAI-Scheduler: 948cd1c8 -> 30c25346
- 比较 ahead=5 / files=17 | Release: v0.17.1
### AI 总结重点(源码 diff 为据)
- **HAMi/hamicore 联调正式进仓(e2e 层)**。新增 `hack/hami/deploy_isolator.sh`:helm `upgrade --install kai-resource-isolator`,默认 chart ref `oci://docker.io/projecthami/kai-resource-isolator`(version `1.1.0-chart`),`--set monitor.enabled=true`,并等待 `${release}-webhook` deployment 就绪。集群 setup 脚本加 `--test-hami` 开关:置位时给 KAI helm 追加 `--set binder.plugins.hamicore.enabled=true`(`HAMI_HELM_SETS` 数组),并在装完 KAI 后调用上面的 isolator 部署脚本。含义:KAI binder 的 `hamicore` 插件 + HAMi 侧 `kai-resource-isolator`(mutating webhook + vgpu monitor)组成一条真实 GPU 显存软隔离验证链,契约是 `CUDA_DEVICE_MEMORY_LIMIT` 注入 + 受限 `nvidia-smi` 可见显存。
  <details><summary>代码依据 hack/hami/deploy_isolator.sh + hack/setup-e2e-cluster.sh</summary>

  ```diff
  + ISOLATOR_CHART_REF="${ISOLATOR_CHART_REF:-oci://docker.io/projecthami/kai-resource-isolator}"
  + ISOLATOR_CHART_VERSION="${ISOLATOR_CHART_VERSION:-1.1.0-chart}"
  + HELM_ARGS=( upgrade --install "${ISOLATOR_RELEASE}" "${ISOLATOR_CHART_REF}" ... --set monitor.enabled=true --wait ... )
  ```
  ```diff
  + HAMI_HELM_SETS=()
  + if [ "$TEST_HAMI" = "true" ]; then
  +   HAMI_HELM_SETS+=( --set "binder.plugins.hamicore.enabled=true" )
  + fi
  ...
  + if [ "$TEST_HAMI" = "true" ]; then
  +     ${REPO_ROOT}/hack/hami/deploy_isolator.sh
  + fi
  ```
  </details>
- **queue-controller 补 PodDisruptionBudget**。`common.PodDisruptionBudgetImplementedServices` map 新增 `queue-controller`(此前仅 admission/scheduler/pod-grouper/binder),`queue_controller/resources.go` 新增 `podDisruptionBudgetForKAIConfig` 走通用 `common.PodDisruptionBudgetForKAIConfig(...,config.Replicas,config.Service)`,helm `_helpers.tpl` 增加 `queuecontroller.podDisruptionBudget` 渲染块(`enabled` / `maxUnavailable`)。至此 KAI 五个 operand 里 queue-controller 也具备 operator 侧自动建 PDB 的能力,滚动/驱逐时保证副本可用度。
  <details><summary>代码依据 pkg/operator/operands/common/common.go + queue_controller/resources.go + _helpers.tpl</summary>

  ```diff
    var PodDisruptionBudgetImplementedServices = map[string]struct{}{
  -   "admission":   {}, "scheduler": {}, "pod-grouper": {}, "binder": {},
  +   "admission": {}, "scheduler": {}, "pod-grouper": {}, "binder": {},
  +   "queue-controller": {},
    }
  ```
  ```diff
  + func (q *QueueController) podDisruptionBudgetForKAIConfig(...) ([]client.Object, error) {
  +   pdbObj, err := common.PodDisruptionBudgetForKAIConfig(ctx, runtimeClient, kaiConfig.Spec.Namespace,
  +       q.BaseResourceName, config.Replicas, config.Service)
  +   ...
  + }
  ```
  </details>
- **CI/文档**:backport workflow 加 `workflow_dispatch`(手工传 `pr_number` 补跑 backport)+ `merge_commits: skip`;`docs/gpu-sharing/hami/README.md` 补一整段本地 e2e 步骤(minikube `--gpus=all` → device-plugin → KAI gpuSharing+hamicore → isolator → ginkgo 跑 `test/e2e/.../hamicore/`)。属工程治理,不改运行时行为。
### 后续发展方向 [AI]
- KAI 与 HAMi 的整合从"文档提及"推进到"e2e 可复现联调"(binder hamicore 插件 + kai-resource-isolator webhook/monitor),证据只覆盖 e2e/hack/docs 与 helm 开关,**未见 binder 侧 hamicore 插件本身的 Go 实现变更**——本期改的是"怎么部署联调"而非隔离算法。若后续 hamicore 插件出现在 `pkg/` 生产代码 diff,才是能力本体的推进。
- PDB 补齐路径清晰:五个 operand 现已统一走 `common.PodDisruptionBudgetForKAIConfig`,后续大概率是给 PDB 参数(maxUnavailable/minAvailable)加 CRD/values 校验;本期只到 queue-controller 接入,未见默认值策略变化。

## NVIDIA/mig-parted: 20986865 -> 377f931e
- 比较 ahead=4 / files=4 | Release: v0.15.0
### AI 总结重点(源码 diff 为据)
- **`MigConfig.Equals` 语义修正:zero-count profile == 未列出**。旧实现先 `if len(m) != len(config) { return false }` 再单向 `Contains`+值比较;带一个 `"2g.10gb": 0` 的期望配置与硬件实配(创建实例时 0-count 被省略)长度不等,直接误判"不相等"。新实现删掉 len 短路,改为双向遍历 `for k,v := range m { if v != config[k] ... }` 且 `for k,v := range config { if v != m[k] ... }`,map 取不到的 key 得零值 0,于是 count=0 与缺失项等价。配套单测覆盖 "zero count omitted"、"different zero count profiles(都为 0 视为相等)" 等 8 例。
  <details><summary>代码依据 pkg/types/mig_config.go</summary>

  ```diff
  - func (m MigConfig) Equals(config MigConfig) bool {
  -   if len(m) != len(config) { return false }
  -   for k, v := range m {
  -       if !config.Contains(k) { return false }
  -       if v != config[k] { return false }
  -   }
  + // Profiles with zero instances are equivalent to omitted profiles.
  + func (m MigConfig) Equals(config MigConfig) bool {
  +   for k, v := range m { if v != config[k] { return false } }
  +   for k, v := range config { if v != m[k] { return false } }
  ```
  </details>
### 后续发展方向 [AI]
- 纯行为修正,面向"期望配置里保留 0-count 占位 profile 也不触发无谓 MIG 重配"的场景;证据覆盖 `Equals` 与两处单测,未见 `AssertValidFormat`/apply 路径改动,说明 0-count 早已被校验接受、这次只补齐比较端一致性。distroless 基镜像同 bump 到 v4.1.3,无功能影响。

## 本期无实质改动(折叠)
- **NVIDIA/nvidia-container-toolkit**(ahead=6):全仓启用 `modernize` linter 并机械改写——测试里 `to.Ptr(...)→new(...)`(删除 `internal/test/to` 辅助包)、`for i:=0;i<n;i++ → for i := range n`、`current.Field(i)` 循环 → `for f := range current.Fields()`(Go 1.24 反射迭代器),Dockerfile distroless bump v4.1.1→v4.1.3。无运行时行为变化。
- **NVIDIA/gpu-driver-container**(ahead=4):仅滚动基镜像日期 tag(Ubuntu resolute/noble/jammy、UBI10),OS 矩阵与构建逻辑未变。
- **kubernetes-sigs/dra-driver-nvidia-gpu**(ahead=2):仅新增 `cmd/gpu-kubelet-plugin/nvlib_nvml_test.go`(284 行),用 fake NVML/nvdevice 覆盖 MIG 模式创建 GpuInstance 流程,测试专属、无生产代码改动(信号:kubelet 插件在补 MIG 相关单测覆盖)。
- **NVIDIA/gpu-operator**:无新提交(仅 bump/CI/merge)。
- **NVIDIA/k8s-device-plugin**:无新提交。
- **NVIDIA/dcgm-exporter**:无新提交。
- **NVIDIA/DCGM**:无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9f85a2ad08afc43b220cf368543fc2735244df13 branch=main release=v26.7.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=33ba68134945dded5fd2060acf3a565421d33f13 branch=main release=v1.20.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=ccc2bd607912c8d8a4fd2bde2b0aaf1cac902d71 branch=main release=— scanned=2026-09-11 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=4edf2b66ec53db87c36e035f82e5629b676893e3 branch=main release=v0.20.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=c3963bcff8a3127da4530f1ace490ba6ed13e8e3 branch=main release=v0.5.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-11 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-11 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=377f931e2d64f1a7e716d57e4084257f4cc09757 branch=main release=v0.15.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=30c25346ee013e67d2e14df0429bec52f1885131 branch=main release=v0.17.1 scanned=2026-09-11 -->
