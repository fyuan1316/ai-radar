# NVIDIA 算力栈 diff 雷达 2026-07-17

## 摘要
- **DRA driver 接管 `nvidia.com/gpu.clique` 节点标签,GFD 弃用后的又一块拼图落到 DRA 侧**:kubelet plugin 新增 opt-in flag `gpuCliqueLabelEnabled`(默认关),开启后由 DRA driver 自己给节点打这个历史上由 gpu-feature-discovery 打的 clique 标签,并每 10 分钟刷新一次以跟上 fabric 分区导致的 CliqueID 动态变化。这是 GFD→DRA 迁移的持续信号(上期 dcgm-exporter 补 DRA 监控,本期 label 归属也在迁)。
- **gpu-driver-container 把 SELinux 判定从"容器内看 /sys/fs/selinux"改成"探测宿主机 /proc/1"**:容器化 driver 之前用容器自身的 selinuxfs 存在与否判断,在 SELinux 关闭的宿主上会误判并跑无谓的 chcon;现改为读宿主 PID1 的 mounts + enforce 文件(需 hostPID: true),更准确。同批还修了 ARM64 预编译镜像双发布、更新 RHEL UBI/Ubuntu base。
- **KAI-Scheduler NUMA 插件做了一次向量化性能重构 + 加 PDB**:NUMA 拓扑从 `map[ResourceName]Quantity` 换成索引化的 ResourceVector/VectorMap,预算 Allocatable 前缀和、per-session 缓存请求向量,消除每次对齐的分配与排序;另给 scheduler 加了 PodDisruptionBudget。gpu-operator 仅加两条 Helm 校验。其余 5 仓无实质改动。

## 当日重要改变
- kubernetes-sigs/dra-driver-nvidia-gpu [弃用/迁移][新能力] gpu-feature-discovery 弃用后,`nvidia.com/gpu.clique` label 改由 DRA kubelet plugin 设置(opt-in `gpuCliqueLabelEnabled`,默认 false),CliqueID 每 10min 刷新应对 fabric 分区动态变化;RBAC 加 nodes `patch` 权限。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/9001f17e...64a8903b
- NVIDIA/gpu-driver-container [架构方向] 容器化 driver 的 SELinux 判定从容器内 `/sys/fs/selinux` 改为宿主机 `/proc/1/mounts` + `/proc/1/root/.../enforce`(需 hostPID: true),修正 SELinux-off 宿主上的误判。 https://github.com/NVIDIA/gpu-driver-container/compare/1ea5e0fc...b7d88d64
- kai-scheduler/KAI-Scheduler [架构方向] NUMA 对齐核心从 ResourceList/Quantity 重构为 ResourceVector 索引化 + 前缀和预算 + per-session 缓存(性能优化,行为等价);新增 scheduler PDB。 https://github.com/kai-scheduler/KAI-Scheduler/compare/55d8aba0...900fe5fe

## kubernetes-sigs/dra-driver-nvidia-gpu: 9001f17e -> 64a8903b
- 比较 / Release: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/9001f17e...64a8903b | ahead=3 | files=6 | Release v0.4.1

### AI 总结重点(源码 diff 为据)
- **compute-domain kubelet plugin 新增设置 `nvidia.com/gpu.clique` 节点标签的能力,由新 flag `gpu-clique-label-enabled` / env `GPU_CLIQUE_LABEL_ENABLED` 控制,默认 false**。注释明确这是接管 gpu-feature-discovery 历史职责——GFD 随 k8s-device-plugin 一起弃用,DRA driver 开启时自己拥有这个 label。
  <details><summary>代码依据 cmd/compute-domain-kubelet-plugin/computedomain.go + main.go</summary>

  ```diff
  + // gpuCliqueLabelKey sets the node label historically set by gpu-feature-discovery (...).
  + // gpu-feature-discovery that is bundled with the k8s-device-plugin is being deprecated,
  + // so the kubelet plugin now owns setting it on systems where the DRA driver is enabled.
  + gpuCliqueLabelKey = "nvidia.com/gpu.clique"
  + gpuCliqueLabelRefreshInterval = 10 * time.Minute
  ```
  ```diff
  + &cli.BoolFlag{
  +     Name:        "gpu-clique-label-enabled",
  +     Usage:       "Set the nvidia.com/gpu.clique node label, historically set by gpu-feature-discovery.",
  +     Value:       false,
  +     Destination: &flags.gpuCliqueLabelEnabled,
  +     EnvVars:     []string{"GPU_CLIQUE_LABEL_ENABLED"},
  + },
  ```
  </details>
- **CliqueID 由"启动时读一次的静态字段"改为"可动态刷新的受锁字段"**:`ComputeDomainManager` 把 `cliqueID string` 换成 `cliqueIDMu sync.RWMutex + cliqueID` 并保存 `getCliqueIDFunc`,新增线程安全的 `CliqueID()` 读取器;构造函数签名从 `NewComputeDomainManager(config, cliqueID string) *ComputeDomainManager` 改为 `(config, getCliqueIDFunc func()(string,error)) (*ComputeDomainManager, error)`。原来 device_state.go 里有 TODO 说"cliqueID 运行时可能变化、需重新获取",本次正是兑现——IMEX channel 注入判断也从直接读字段 `cliqueID` 改成调 `CliqueID()`。
  <details><summary>代码依据 cmd/compute-domain-kubelet-plugin/computedomain.go + device_state.go</summary>

  ```diff
  - cliqueID        string
  + cliqueIDMu sync.RWMutex
  + cliqueID   string
  + getCliqueIDFunc func() (string, error)
  ```
  ```diff
  - // TODO: explore calling this not only during plugin startup because this
  - // information may change during runtime.
  - cliqueID, err := nvdevlib.getCliqueID()
  - computeDomainManager := NewComputeDomainManager(config, cliqueID)
  + computeDomainManager, err := NewComputeDomainManager(config, nvdevlib.getCliqueID)
  ```
  ```diff
  - if s.computeDomainManager.cliqueID != "" {
  + if s.computeDomainManager.CliqueID() != "" {
  ```
  提交说明("Refresh CliqueID as it can change dynamically due to fabric partitioning")印证了动机是 fabric 动态分区。
  </details>
- **RBAC 给 kubelet plugin 加 nodes `patch` 权限**,以支持打 label;Helm values 新增 `gpuCliqueLabelEnabled: false`,并把 env 透传进 DaemonSet 模板。
  <details><summary>代码依据 deployments/helm/.../rbac-kubeletplugin.yaml + values.yaml + kubeletplugin.yaml</summary>

  ```diff
  - resources: ["nodes"]
  -   verbs: ["get", "list", "watch", "update"]
  + resources: ["nodes"]
  +   verbs: ["get", "list", "watch", "update", "patch"]
  ```
  ```diff
  + # Set the nvidia.com/gpu.clique node label, historically set by gpu-feature-discovery. Disabled by default.
  + gpuCliqueLabelEnabled: false
  + - name: GPU_CLIQUE_LABEL_ENABLED
  +   value: {{ .Values.kubeletPlugin.containers.computeDomains.gpuCliqueLabelEnabled | quote }}
  ```
  </details>

### 后续发展方向 [AI]
- 这是 GFD 弃用后节点标签职责重新分配的又一步:clique(NVLink/fabric 拓扑域)标签下沉到 DRA driver,意味着未来"哪些 GPU 在同一 fabric 域"的信息将由 DRA 路径而非 device-plugin/GFD 路径产出。对我们产品的启示——若拓扑感知调度依赖 `nvidia.com/gpu.clique`,在启用 DRA driver 时要显式打开 `gpuCliqueLabelEnabled`,否则该 label 在 GFD 退场后会缺失。证据只覆盖 label 的写入侧与刷新机制,未见消费侧(调度器如何用 clique)的改动。
- CliqueID 改为可刷新说明 NVIDIA 认可 fabric 分区在运行时会变(如 NVSwitch 重新分区),IMEX channel 注入随之动态开关。证据仅到 10min 定时刷新这一层,刷新失败时的降级行为、刷新与已注入 channel 的一致性处理未在本次 hunk 覆盖(computedomain.go patch 被截断)。

## NVIDIA/gpu-driver-container: 1ea5e0fc -> b7d88d64
- 比较 / Release: https://github.com/NVIDIA/gpu-driver-container/compare/1ea5e0fc...b7d88d64 | ahead=10 | files=17 | Release —

### AI 总结重点(源码 diff 为据)
- **SELinux 检测语义从"容器视角"改为"宿主机视角"**:新增统一的 `_host_selinux_enabled()` 函数,通过 `grep -qsw "selinuxfs" /proc/1/mounts` + `[ -f /proc/1/root/sys/fs/selinux/enforce ]` 判断宿主 PID1 命名空间的 SELinux 状态(注释标注需 `hostPID: true`)。此前 `rhel*/precompiled/nvidia-driver` 用 `[ -e /sys/fs/selinux ]`(容器内路径)判断,vgpu-manager 与 ocp_dtk_entrypoint 甚至无条件执行 chcon。改后所有脚本统一走宿主判定,SELinux-off 宿主上跳过 chcon。
  <details><summary>代码依据 rhel9/precompiled/nvidia-driver（其余脚本同构）</summary>

  ```diff
  + # Requires the pod to run with hostPID: true.
  + _host_selinux_enabled() {
  +     [ -r /proc/1/mounts ] &&
  +         grep -qsw "selinuxfs" /proc/1/mounts &&
  +         [ -f /proc/1/root/sys/fs/selinux/enforce ]
  + }
  ...
  - echo "Check SELinux status"
  - if [ -e /sys/fs/selinux ]; then
  -     echo "SELinux is enabled"
  + echo "Check host SELinux status"
  + if _host_selinux_enabled; then
  +     echo "Host SELinux is enabled"
          chcon -R -t container_file_t ${RUN_DIR}/driver/dev
  ```
  </details>
- **ocp_dtk_entrypoint(OpenShift Driver-Toolkit 路径)同样加 SELinux 守卫**:原先无条件对 `*.txt`/`*.go` 执行 `chcon -t modules_object_t`,现包在 `_host_selinux_enabled` 判断内。对我们对标 OAI/OpenShift 的场景直接相关——OCP DTK 编译 driver 时的 SELinux 处理更稳健。
  <details><summary>代码依据 rhel9/ocp_dtk_entrypoint</summary>

  ```diff
  - find . -type f \( -name "*.txt" -or -name "*.go" \) -exec chcon -t modules_object_t "{}" \;
  + echo "Check host SELinux status"
  + if _host_selinux_enabled; then
  +     find . -type f \( -name "*.txt" -or -name "*.go" \) -exec chcon -t modules_object_t "{}" \;
  + else
  +     echo "Host SELinux is disabled, skipping..."
  + fi
  ```
  </details>
- 其余为工程/供应链:修 ARM64 kernel release 预编译镜像双发布(`.github/workflows/precompiled.yaml`)、更新 RHEL UBI 与 Ubuntu(resolute-20260707)base 镜像、新增 `SECURITY.md`(PSIRT 报告流程,非代码逻辑)。

### 后续发展方向 [AI]
- SELinux 判定统一到宿主视角,是容器化 driver 在混合 SELinux 状态集群里"少做错事"的修正——之前容器内探测会在无 selinuxfs 挂载的容器里误判为关闭、或在关闭的宿主上误做 chcon。对我们产品:若用 gpu-driver-container 部署,需确保 driver DaemonSet 带 `hostPID: true`,否则 `/proc/1` 读的是容器自身 PID1,新逻辑会失效退回"当作 SELinux 关闭"。证据覆盖了所有 rhel8/9/10 + vgpu-manager + ocp 变体,未见对应 DaemonSet 清单是否已默认加 hostPID(需在 gpu-operator/部署侧确认)。

## kai-scheduler/KAI-Scheduler: 55d8aba0 -> 900fe5fe
- 比较 / Release: https://github.com/kai-scheduler/KAI-Scheduler/compare/55d8aba0...900fe5fe | ahead=3 | files=27 | Release v0.16.4

### AI 总结重点(源码 diff 为据)
- **NUMA 拓扑数据结构从"按资源名的 Quantity map"重构为"索引化的 ResourceVector"**:`NumaZone.Available/Allocatable` 从 `map[v1.ResourceName]resource.Quantity` 改为 `resource_info.ResourceVector`,`NumaTopology` 新增 `VectorMap`、`AwareIndices`(kubelet 会对齐的、NRT 上报的资源索引)、`AwareNames`、`AllocatablePrefix`(每个 aware 索引的降序前缀和,预算好让 restricted 策略的 preferred-width 查询变成前缀扫描、免每次排序)。`BuildNumaTopology` 签名加了 `ResourceVectorMap` 入参。
  <details><summary>代码依据 pkg/scheduler/api/node_info/numa_topology.go</summary>

  ```diff
    type NumaZone struct {
        ID          string
  -     Available   map[v1.ResourceName]resource.Quantity
  -     Allocatable map[v1.ResourceName]resource.Quantity
  +     Available   resource_info.ResourceVector
  +     Allocatable resource_info.ResourceVector
    }
  + // AllocatablePrefix holds, per aware index, the descending-sorted prefix sums of the zones'
  + // Allocatable ... so the restricted policy's preferred-width lookup is a prefix scan, no per-call sort.
  + AllocatablePrefix map[int][]float64
  ```
  </details>
- **evaluator 从"接口 + 每次克隆 available map"改为"numaPlugin 方法 + 向量 delta 累积 + 栈上位掩码"**:删掉 `numaEvaluator` 接口和 `singleNUMAEvaluator/restrictedEvaluator` 的 map 克隆实现,改为 `pp.solveTask` 驱动的 `allocatable()`(仅判可行)/`evaluate()`(返回 `zoneAllocation = map[int]ResourceVector` 的 per-zone 分配),并加 `const stackZones = 16` 用栈缓冲装 mask/scratch、超出才落堆。
  <details><summary>代码依据 pkg/scheduler/plugins/numa/evaluator.go</summary>

  ```diff
  - type numaEvaluator interface {
  -     evaluate(topo *node_info.NumaTopology, ignoreList sets.Set[v1.ResourceName], requests []v1.ResourceList) (placement pod_info.NUMAPlacement, admit bool)
  - }
  + // stackZones bounds the mask/scratch stack buffers; nodes with more NUMA zones fall back to heap.
  + const stackZones = 16
  + type zoneAllocation = map[int]resource_info.ResourceVector
  + func (pp *numaPlugin) allocatable(task *pod_info.PodInfo, node *node_info.NodeInfo) bool {
  +     return pp.solveTask(task, node, nil)
  + }
  ```
  </details>
- **每 session 缓存 per-task NUMA 请求向量,消除重复分解**:新增 `podNumaRequests`(podScope/concurrent/serial 三组 ResourceVector)与 `numaRequestCache map[PodID]*podNumaRequests`,`OnSessionOpen` 里 `initCaches` 重建;`numaPlugin` 还挂了 `ssn *framework.Session`、`ignoreIndices`、`effectiveAwareByNode`、`hasModeledNodes`(无 modeled-policy 节点时 PrePredicate 整段跳过)。原 `containerUnits`/`requestUnits` 的 `toAmounts(ResourceList)` 路径换成 `NewResourceVectorFromResourceList(..., vectorMap)`。
  <details><summary>代码依据 pkg/scheduler/plugins/numa/requests.go + numa.go</summary>

  ```diff
  + type podNumaRequests struct {
  +     podScope   []resource_info.ResourceVector
  +     concurrent []resource_info.ResourceVector
  +     serial     []resource_info.ResourceVector
  + }
  + // numaRequestCache caches each task's NUMA request vectors, keyed by pod ID. Rebuilt each session.
  + numaRequestCache map[common_info.PodID]*podNumaRequests
  + // hasModeledNodes is false when no node carries a modeled-policy topology, letting the PrePredicateFn skip all per-task precompute.
  + hasModeledNodes bool
  ```
  </details>
- **新增 scheduler 的 PodDisruptionBudget**:operator 加 `podDisruptionBudgetForShard`,Helm `_helpers.tpl` 透传 `podDisruptionBudget.enabled/maxUnavailable`,并加了 `scheduler_pdb_test.yaml`。保障多分片调度器在节点 drain 时的可用性。
  <details><summary>代码依据 pkg/operator/operands/scheduler/resources_for_shard.go + templates/_helpers.tpl</summary>

  ```diff
  + func (s *SchedulerForShard) podDisruptionBudgetForShard(...) (client.Object, error) {
  +     return common.PodDisruptionBudgetForKAIConfig(ctx, readerClient, kaiConfig.Spec.Namespace, DeploymentName(kaiConfig, shard), config.Replicas, config.Service)
  + }
  + podDisruptionBudget:
  +   enabled: {{ .Values.scheduler.podDisruptionBudget.enabled }}
  +   maxUnavailable: {{ .Values.scheduler.podDisruptionBudget.maxUnavailable }}
  ```
  </details>

### 后续发展方向 [AI]
- NUMA 插件这次是纯性能/内存重构(向量化 + 前缀和预算 + 缓存 + 栈缓冲),自证"行为等价"(测试改的是断言取值方式,非期望值),说明 KAI 的 NUMA 对齐已进入"正确性稳定、转攻规模化"阶段——面向大 NUMA 节点/高频调度的 CPU 与分配开销优化。对我们产品:若做拓扑感知调度对标,KAI 用"镜像 kubelet Topology Manager hint 合并 + restricted 策略前缀和"这套建模值得参考。证据覆盖数据结构与请求缓存,`solveTask` 的完整位掩码搜索逻辑(evaluator.go 主体)被 hunk 截断,未逐行验证等价性。
- PDB 落地是 KAI 往"生产级高可用调度器"补齐运维面(继此前 changie 发布流程规范化)。证据仅到 operator/Helm 接线,未见默认 `maxUnavailable` 取值策略。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓(5 仓)+ gpu-operator 仅 Helm 校验</summary>

- NVIDIA/gpu-operator — 本期 ahead=2 只 1 个实质提交,为 Helm 加两条校验:`devicePlugin.config.create` 为 true 时 `devicePlugin.config.data`、`config.name` 均不得为空(`deployments/gpu-operator/templates/validations.yaml`),纯部署期防呆,无 ClusterPolicy CRD/控制器逻辑改动。HEAD 前移到 f54bd421,Release v26.3.3。 https://github.com/NVIDIA/gpu-operator/compare/557886b8...f54bd421
- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 3db41dec 未动,Release v1.20.0-rc.1）
- NVIDIA/k8s-device-plugin — 无新提交(HEAD 24816472 未动,Release v0.19.3）
- NVIDIA/dcgm-exporter — 无新提交(HEAD 181290c3 未动,Release 4.6.0-4.8.3）
- NVIDIA/mig-parted — 无新提交(HEAD 90668a23 未动,Release v0.14.3）
- NVIDIA/DCGM(master）— 无新提交(HEAD 72fa3fea 未动)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=f54bd42108d9dba1664f15fbfe3f1e13eff295f1 branch=main release=v26.3.3 scanned=2026-07-17 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3db41dec03bf1179b4f7259f6a7037f7f158d39b branch=main release=v1.20.0-rc.1 scanned=2026-07-17 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=b7d88d64c402759134ad0ed7475ec9bc4fb4fe60 branch=main release=— scanned=2026-07-17 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=248164727d5d8bac7024a8e12a13e69246cf0969 branch=main release=v0.19.3 scanned=2026-07-17 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=64a8903b5729bb0468201a2a99039a055bc248ab branch=main release=v0.4.1 scanned=2026-07-17 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-17 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=90668a237485113fdb77cadd825957ffbf3a3c1c branch=main release=v0.14.3 scanned=2026-07-17 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=900fe5fef9f6d99797a8e868a1119841dcba6e27 branch=main release=v0.16.4 scanned=2026-07-17 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-17 -->
