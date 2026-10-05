# NVIDIA 算力栈 diff 雷达 2026-10-06

## 摘要
- gpu-operator 修补多 NVIDIADriver 场景的节点标签 reconcile 盲区:节点标签变化时不再只看自己当前 owner,而是遍历所有存活 NVIDIADriver 的 `Spec.NodeSelector`,任一 selector 键命中变化即触发 reconcile——解决"节点因标签变化应进入另一 driver 池却不被重新评估"的问题。
- mig-parted 把 systemd D-Bus 连接从构造时改为懒加载(`getSystemdManager`),`NewManager` 加 10s 连接超时并对无 systemd 的主机给出明确报错;MIG 重配流程在不需要 systemd 时不再因连不上 D-Bus 而初始化失败。
- 另有两处构建/解析 bugfix(gpu-driver-container RHEL 预编译镜像 shell 续行、k8s-device-plugin nvml 库路径解析跳过同名目录);dra-driver-nvidia-gpu 与 KAI-Scheduler 本期仅 CI/测试基础设施改动;container-toolkit / dcgm-exporter / DCGM 三仓无新提交。

## 当日重要改变
无命中弃用/API-CRD/架构硬信号。本日改动均为行为修复与 CI,其中产品相关度最高的两条(非 CRD 变更,列此备查):
- gpu-operator [行为变更] 节点标签 reconcile 触发条件扩展到"遍历所有存活 NVIDIADriver 的 NodeSelector",修复多 driver 池成员变更漏判。 https://github.com/NVIDIA/gpu-operator/commit/1b64815e64068b618856c9f7c7f3f8bb3d13f9bf
- mig-parted [行为变更] systemd 连接改懒加载 + 10s 超时,MIG 重配不再在构造期强依赖 D-Bus。 https://github.com/NVIDIA/mig-parted/commit/87f9e3c6be56020a346e9d25379734291cfc9cca

## NVIDIA/gpu-operator: 3e1873a2 -> 1b64815e
- 比较: https://github.com/NVIDIA/gpu-operator/compare/3e1873a25ef46219f9b2db6f19a0b90818729586...1b64815e64068b618856c9f7c7f3f8bb3d13f9bf | ahead=6 | files=9 | Release: v26.7.1

### AI 总结重点(源码 diff 为据)
- **reconcile 触发从"看单个 owner"扩展为"扫全部存活 driver 的 NodeSelector"**:`nodeLabelUpdateReasons` 新增字段 `nvidiaDriverNodeSelectorLabelChanged`,并进入 `needsUpdate()` 的或条件。`getNodeLabelUpdateReasons` 由自由函数升级为 `*NodeLabelingReconciler` 的方法,签名加上 `ctx` 和 `nodeName`。逻辑:若已有已知原因触发或新旧标签完全相等则直接返回;否则 `r.List` 列出所有 `NVIDIADriverList`,跳过带 DeletionTimestamp 的,逐个比对该 driver `Spec.NodeSelector` 的每个 key 在新旧标签里的值/存在性,只要有差异就置位 `nvidiaDriverNodeSelectorLabelChanged`。注释点明动机:一个节点即便当前 owner 是 default driver 或无 owner,也可能因标签变化进入另一个 driver 的池,所以必须检查每个存活 selector。
  <details><summary>代码依据 controllers/nodelabeling_controller.go</summary>

  ```diff
  -	nvidiaDriverOwnerLabelChange bool
  +	nvidiaDriverOwnerLabelChange         bool
  +	nvidiaDriverNodeSelectorLabelChanged bool
   }

   func (r nodeLabelUpdateReasons) needsUpdate() bool {
   		r.osTreeLabelChanged ||
  -		r.nvidiaDriverOwnerLabelChange
  +		r.nvidiaDriverOwnerLabelChange ||
  +		r.nvidiaDriverNodeSelectorLabelChanged
   }

  -func getNodeLabelUpdateReasons(oldLabels, newLabels map[string]string) nodeLabelUpdateReasons {
  +func (r *NodeLabelingReconciler) getNodeLabelUpdateReasons(ctx context.Context, nodeName string, oldLabels, newLabels map[string]string) (nodeLabelUpdateReasons, error) {
  +	if reasons.needsUpdate() || maps.Equal(oldLabels, newLabels) {
  +		return reasons, nil
  +	}
  +	drivers := &nvidiav1alpha1.NVIDIADriverList{}
  +	if err := r.List(ctx, drivers); err != nil { ... return reasons, err }
  +	for _, driver := range drivers.Items {
  +		if driver.HasDeletionTimestamp() { continue }
  +		for key := range driver.Spec.NodeSelector {
  +			oldValue, oldPresent := oldLabels[key]
  +			newValue, newPresent := newLabels[key]
  +			if oldValue != newValue || oldPresent != newPresent {
  +				reasons.nvidiaDriverNodeSelectorLabelChanged = true
  +				return reasons, nil
  +			}
  ```
  </details>
- **测试覆盖新增多 driver 场景**:新增 `TestNodeUpdateRequiresReconcileForDriverSelectors`,用例覆盖 "default owner becomes eligible" / "unowned node becomes eligible" / "another owner becomes eligible" / "selector label added|removed" / "deleting driver's selector ignored" 等,验证已知标签变化会跳过 driver 查询(`skipList`)、删除中的 driver 其 selector 被忽略。印证上面行为是针对多 NVIDIADriver 动态归属设计的。
  <details><summary>代码依据 controllers/nodelabeling_controller_test.go</summary>

  ```diff
  +		"another owner becomes eligible": { owner: "other-driver",
  +			oldLabels: {waitLabel: "true"}, newLabels: {waitLabel: "false"}, wantUpdate: true },
  +		"known label change skips driver lookup": { ... listError: true, skipList: true, wantUpdate: true },
  +		"deleting driver's selector ignored": { ... }
  ```
  </details>
- 另:`docker/Dockerfile` 基础镜像 distroless/cc 从 v4.1.4 bump 到 v4.1.5(纯镜像版本)。

### 后续发展方向 [AI]
- 这条坐实了 gpu-operator 的 **多 NVIDIADriver 实例共存** 是正式支持路径(不同节点池跑不同 driver 版本/分支),reconcile 层正在补齐"节点可动态在 driver 池间迁移"的事件响应。对标我们产品:若做分池异构 driver 管理,节点标签→driver 归属的重算必须覆盖"非当前 owner 的 selector 也可能命中",否则漏 reconcile。证据只覆盖 reconcile 触发判定(`getNodeLabelUpdateReasons`),未展开后续实际 relabel/driver pod 调度动作的 hunk。

## NVIDIA/gpu-driver-container: 46f292d3 -> 599fbecb
- 比较: https://github.com/NVIDIA/gpu-driver-container/compare/46f292d300b2affd6202d45a1422e41bfedd8fd0...599fbecbc0fff74106d08918e5e3e0418a06f1c0 | ahead=2 | files=2 | Release: —

### AI 总结重点(源码 diff 为据)
- **修复 RHEL 预编译 driver 镜像 userspace 安装被静默跳过的 shell bug**:rhel9/rhel10 `precompiled/Dockerfile` 里相邻的 `if [ "$DRIVER_BRANCH" -ge ... ]` 块之间缺 `&&` 续行符,导致前一条 `dnf install` 的退出码决定整串命令是否继续,后续 imex/nvsdm/infiniband 组件可能不被安装;本次补上 `&&`。同时修两个笔误:`libnvdsm` → `libnvsdm`(包名拼错会致安装失败)、`dnf install install -y` → `dnf install -y`(重复 install 子命令)。
  <details><summary>代码依据 rhel9/precompiled/Dockerfile(rhel10 同改)</summary>

  ```diff
  -            if [ "$DRIVER_BRANCH" -ge "580" ]; then \
  -            dnf install -y nvidia-imex-${DRIVER_VERSION} libnvdsm-${DRIVER_VERSION}; \
  +            && if [ "$DRIVER_BRANCH" -ge "580" ]; then \
  +            dnf install -y nvidia-imex-${DRIVER_VERSION} libnvsdm-${DRIVER_VERSION}; \
   ...
  -            if [ "$DRIVER_BRANCH" -ge "550" ]; then \
  -            dnf install install -y infiniband-diags nvlsm ; \
  -            fi \
  +            && if [ "$DRIVER_BRANCH" -ge "550" ]; then \
  +            dnf install -y infiniband-diags nvlsm ; \
  +            fi ; \
  ```
  </details>

### 后续发展方向 [AI]
- 纯构建正确性修复,影响 580/570/550 分支预编译镜像里 IMEX / nvSDM / InfiniBand(nvlsm)等 NVLink/多机互联相关 userspace 组件是否齐全——对用 RHEL 预编译路径跑 NVLink/IMEX 拓扑的部署是实打实的可用性修复。证据仅两 Dockerfile 的 RUN 层,未涉及 driver 内核态或 OS 矩阵扩展。

## NVIDIA/k8s-device-plugin: d7265fdc -> d5dce58a
- 比较: https://github.com/NVIDIA/k8s-device-plugin/compare/d7265fdcf89f571e70b5eb6724ba78a3398bc03e...d5dce58aff4ddf572dc52666f949b37d6be2846c | ahead=2 | files=2 | Release: v0.20.1

### AI 总结重点(源码 diff 为据)
- **nvml 库路径解析跳过同名目录**:`root.tryResolveLibrary` 在 `EvalSymlinks` 成功后增加 `os.Stat` + `info.Mode().IsRegular()` 校验,非普通文件(尤其是前序搜索路径里恰好有个与库同名的目录)直接 `continue`,避免目录"遮蔽"真正的 `libnvidia-ml.so.1`。新增 `root_test.go` 用例覆盖 "directory in earlier search path does not shadow library" 与 "only directories found" 返回空。
  <details><summary>代码依据 cmd/nvidia-device-plugin/root.go</summary>

  ```diff
  +		// EvalSymlinks succeeds for directories too, so a directory named after
  +		// the library in an earlier search path would shadow the real one.
  +		info, err := os.Stat(resolved)
  +		if err != nil || !info.Mode().IsRegular() {
  +			continue
  +		}
   		return resolved
  ```
  </details>

### 后续发展方向 [AI]
- 边界修复,提升 device-plugin 在非常规文件系统布局(容器挂载里存在同名目录)下定位 NVML 的鲁棒性;不涉及 time-slicing/MPS/DRA 配置面。证据仅 `tryResolveLibrary` 一处与其单测。

## NVIDIA/mig-parted: 9a831d5d -> 87f9e3c6
- 比较: https://github.com/NVIDIA/mig-parted/compare/9a831d5d84770d6d976c6499572425eddc88ee7a...87f9e3c6be56020a346e9d25379734291cfc9cca | ahead=2 | files=4 | Release: v0.15.1

### AI 总结重点(源码 diff 为据)
- **systemd D-Bus 连接改懒加载 + 连接超时**:`Reconfigure.New` 不再在构造时调用 `systemd.NewManager`,改为新增 `getSystemdManager()`,首次需要时才连并缓存到 `r.systemdManager`;`ReloadDaemon`/`shutdownHostGPUClients`/`hostStartSystemdServices` 等调用点都先 `getSystemdManager()`。`systemd.NewManager` 重写为 `newManagerWithTimeout`:开 goroutine 做 `dbus.NewSystemConnectionContext`,与 10s `time.Timer` select,超时则 cancel 连接 context 并返回明确报错 "the system bus socket exists but is not responding (is this a systemd-less host?)"。
  <details><summary>代码依据 internal/systemd/systemd.go + pkg/mig/reconfigure/reconfigure.go</summary>

  ```diff
  +const systemdConnectTimeout = 10 * time.Second
  -func NewManager(ctx context.Context) (*Manager, error) {
  -	conn, err := dbus.NewSystemConnectionContext(ctx) ...
  +func NewManager(ctx context.Context) (*Manager, error) {
  +	return newManagerWithTimeout(ctx, systemdConnectTimeout, nil)
  +}
  +	select {
  +	case res := <-ch: ... return &Manager{conn: res.conn, cancel: cancel}, nil
  +	case <-timer.C:
  +		cancel()
  +		return nil, fmt.Errorf("timed out after %s connecting to systemd D-Bus: ... (is this a systemd-less host?)", timeout)
  +	}
  ```
  ```diff
  # reconfigure.go: New 不再连接,改懒加载并缓存
  +func (r *Reconfigure) getSystemdManager() (*systemd.Manager, error) {
  +	if r.systemdManager != nil { return r.systemdManager, nil }
  +	... systemdManager, err := systemd.NewManager(r.ctx) ...
  +	r.systemdManager = systemdManager
  +	return systemdManager, nil
  +}
  ```
  </details>
- **失败连接不缓存**:单测 `TestSystemdMgrErrorIsNotCached` 断言连接失败后 `r.systemdManager` 仍为 nil(下次重试);`TestNewDoesNotConnectSystemd` 断言 `New` 不建立连接;`TestCleanupWithNilManager` 断言 nil manager 下 `cleanup()` 不 panic。
  <details><summary>代码依据 pkg/mig/reconfigure/reconfigure_test.go</summary>

  ```diff
  +func TestNewDoesNotConnectSystemd(t *testing.T) { ... if r.systemdManager != nil { t.Error("New must not establish a systemd D-Bus connection ...") } }
  +func TestSystemdMgrErrorIsNotCached(t *testing.T) { ... if r.systemdManager != nil { t.Error("a failed connection must not be cached ...") } }
  ```
  </details>

### 后续发展方向 [AI]
- 让 mig-parted 在 systemd-less / D-Bus 不响应的主机上能先构造再按需失败(而非启动即挂),并避免 D-Bus 挂起拖死整个重配流程;配合"失败不缓存"支持瞬时故障后重试。对标:MIG 静态切分的 host 侧依赖正在被做得更可容错。证据覆盖连接超时与懒加载调用点,未展开 `cleanup()` 对 `cancel` 的具体释放时序(hunk 截断)。

## 本期无实质改动(折叠)
<details><summary>2 仓仅 CI/测试基础设施 + 3 仓无新提交</summary>

仅 CI/测试(非产品代码,不展开):
- kubernetes-sigs/dra-driver-nvidia-gpu(Release v0.5.0):ahead=8 但实质仅 CI——CodeQL action 升 commit、mock-nvml-e2e 的 k8s-test-infra ref bump 到 18befbf0,无驱动/DRA 逻辑改动。
- kai-scheduler/KAI-Scheduler(Release v0.18.2):把 PR E2E 测试用 Go planner(`hack/e2ebuckets`)拆成可配置数量的均衡并行桶、PR runner 换 cncf-ubuntu-8-32-x86、加 Go build cache——纯 CI 吞吐优化,无调度器逻辑改动。

无新提交:
- NVIDIA/nvidia-container-toolkit(Release v1.20.1)
- NVIDIA/dcgm-exporter(Release 4.8.4)
- NVIDIA/DCGM
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=1b64815e64068b618856c9f7c7f3f8bb3d13f9bf branch=main release=v26.7.1 scanned=2026-10-06 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-06 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=599fbecbc0fff74106d08918e5e3e0418a06f1c0 branch=main release=— scanned=2026-10-06 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d5dce58aff4ddf572dc52666f949b37d6be2846c branch=main release=v0.20.1 scanned=2026-10-06 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=53bae861d6188eef85c6e2b4275aec504181c5a6 branch=main release=v0.5.0 scanned=2026-10-06 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-06 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-06 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=87f9e3c6be56020a346e9d25379734291cfc9cca branch=main release=v0.15.1 scanned=2026-10-06 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=9fceedff7808fd3c603ba64a49e33310b8446d3a branch=main release=v0.18.2 scanned=2026-10-06 -->
