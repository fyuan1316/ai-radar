# NVIDIA 算力栈 diff 雷达 2026-09-04

## 摘要
- **container-toolkit 新增一整套 MIG 管理能力(config/monitor)的 JIT-CDI 注入**:新 CDI 模式 `mig-caps` + 新文件 `lib-mig-caps.go`,让设置 `NVIDIA_MIG_CONFIG_DEVICES=all` / `NVIDIA_MIG_MONITOR_DEVICES=all` 的特权容器自动获得 MIG 配置/监控 capability 字符设备。这是把"容器内做 MIG 切分/监控"从旧 nvidia-container-runtime 路径迁到 CDI 原生路径的实质一步,并顺带修了 hookscratch 目录名拼接 bug。
- **k8s-device-plugin 把 greedyAlloc 分配器的每轮全量排序换成最小堆**:密集节点(8 卡 × 高 replica)分配从 O(n²·log n) 降到堆维护,分配语义(distributed 策略跨物理 GPU 铺开 + pickedFrom 平局轮转)保持不变,配套加 BenchmarkGreedyAlloc。
- 其余:gpu-operator 回退 CUDA samples 到 v12.9(保 Maxwell 兼容)、gpu-driver-container 装包 `--nodocs` 瘦镜像、dra-driver 删一条 FabricManager 文档前置项、mig-parted 仅 go 1.27.1 bump、KAI 仅修 flaky 测试;dcgm-exporter、DCGM 两仓 EMPTY。**无任何 CRD 字段增删**。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [新能力] 新增 CDI 模式 `mig-caps` 与 `pkg/nvcdi/lib-mig-caps.go`,JIT-CDI 路径下按环境变量把 MIG `config`/`monitor` 管理 capability 设备注入特权容器;仅接受值 `all`、非特权或已限定具体 MIG 设备时拒绝。证据 `pkg/nvcdi/lib-mig-caps.go`、`internal/modifier/cdi.go`、`pkg/nvcdi/mode.go`。 https://github.com/NVIDIA/nvidia-container-toolkit/commit/4ea74829b94b2a03ca6295cb5663296ea1591ddf
- NVIDIA/k8s-device-plugin [性能] `greedyAlloc` 用 `container/heap` 最小堆(`gpuPriorityQueue`)替代每轮 `sort`,按 `allocated()` 排序、`pickedFrom` 平局,分配结果语义不变,专治密集共享节点分配开销。证据 `internal/rm/allocate.go`。 https://github.com/NVIDIA/k8s-device-plugin/commit/3c6be400411aad793892e976824910d0880dd3a8

## NVIDIA/nvidia-container-toolkit: e03cd9be -> 4ea74829
- 比较 / Release:`e03cd9be...4ea74829` | ahead=6 | files=16 | Release v1.20.0
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/e03cd9be3a84635bce03df730f0c93605d966cbe...4ea74829b94b2a03ca6295cb5663296ea1591ddf

### AI 总结重点(源码 diff 为据)
- **新增 `mig-caps` CDI 模式,把 MIG 管理 capability 设备做成一等 CDI 设备**:新文件 `pkg/nvcdi/lib-mig-caps.go` 定义 `migCapsLib` 与 `migCapDeviceSpecGenerator`,`DeviceSpecGenerators` 只认 `config`/`monitor` 两个 id(其余报 `invalid MIG capability`);`GetDeviceSpecs` 经 `nvcaps.NewMigCapsFromRoot(l.driver.Root)` 解析 MIG minors 文件、拿到 cap 设备路径后用 `NewCharDeviceDiscoverer` 生成字符设备节点;系统非 MIG 能力机器则告警并跳过(返回 nil)。配套 `mode.go` 增 `ModeMigCaps=Mode("mig-caps")` 并注册进 `getModes()`,`lib.go` 的 `New()` 增 `case ModeMigCaps: factory = (*migCapsLib)(l)`,`options.go` 让该模式的 CDI class 取模式名自身。→ 从此 MIG 的 config/monitor 能力设备可以走 CDI spec 生成器统一产出,而不再依赖旧 runtime 的特判逻辑。

  <details><summary>代码依据 pkg/nvcdi/lib-mig-caps.go + mode.go + lib.go</summary>

  ```diff
  +type migCapsLib nvcdilib
  +func (l *migCapsLib) DeviceSpecGenerators(ids ...string) (DeviceSpecGenerator, error) {
  +	for _, id := range ids {
  +		cap := nvcaps.MigCap(id)
  +		switch cap {
  +		case "config", "monitor":
  +			deviceSpecGenerators = append(deviceSpecGenerators, &migCapDeviceSpecGenerator{lib: l, cap: cap})
  +		default:
  +			return nil, fmt.Errorf("invalid MIG capability %q: must be one of [config, monitor]", id)
  +		}
  +	}
  +}
  // mode.go
  +	ModeMigCaps = Mode("mig-caps")
  // lib.go New():
  +	case ModeMigCaps:
  +		factory = (*migCapsLib)(l)
  ```
  </details>

- **JIT-CDI 修饰器接入 MIG caps,并加严格准入校验**:`internal/modifier/cdi.go` 的 `newJitCDIModifier` 在处理 image 时新增 `migCapsDevices(*f.image)`,先 `Validate()` 再把设备请求追加进自动注入列表。`Validate()` 规则:`NVIDIA_MIG_CONFIG_DEVICES`/`NVIDIA_MIG_MONITOR_DEVICES` **仅允许值 `all`**(其余报错),**必须特权容器**,且**不允许容器已被限定到具体 MIG 设备**(`requestsSpecificMigDevices` 检测可见设备列表里是否点名了具体 MIG 实例)。`DeviceRequests()` 据两个 env 分别产出 `mode=mig-caps,id=config` / `id=monitor`。→ 把"谁能拿 MIG 管理设备"的边界从文档约定固化成代码准入。

  <details><summary>代码依据 internal/modifier/cdi.go</summary>

  ```diff
  +		migCaps := migCapsDevices(*f.image)
  +		if err := migCaps.Validate(); err != nil {
  +			return nil, fmt.Errorf("invalid MIG capability request: %w", err)
  +		}
  +		automaticDevices = append(automaticDevices, withUniqueDevices(migCaps).DeviceRequests()...)
  ...
  +func (d migCapsDevices) Validate() error {
  +	if migConfig != "" && !strings.EqualFold(migConfig, "all") {
  +		return fmt.Errorf("invalid NVIDIA_MIG_CONFIG_DEVICES %q: only \"all\" is supported", migConfig)
  +	}
  +	if !i.IsPrivileged() {
  +		return fmt.Errorf("cannot set NVIDIA_MIG_CONFIG_DEVICES or NVIDIA_MIG_MONITOR_DEVICES in a non-privileged container")
  +	}
  +	if requestsSpecificMigDevices(i) {
  +		return fmt.Errorf("cannot request MIG config/monitor devices for a container scoped to specific MIG devices")
  +	}
  ```
  </details>

- **`nvcaps` 支持 root 相对解析**:`NewMigCaps()` 保持原签名但改为委托 `NewMigCapsFromRoot("")`,新函数用 `filepath.Join(root, nvcapsMigMinorsPath)` 打开 MIG minors 文件,`root=""` 读宿主。→ 让 CDI 生成器能在挂载了驱动 root 的场景下正确定位 MIG capability 设备。

  <details><summary>代码依据 internal/nvcaps/nvcaps.go</summary>

  ```diff
  +func NewMigCapsFromRoot(root string) (MigCaps, error) {
  -	minorsFile, err := os.Open(nvcapsMigMinorsPath)
  +	minorsFile, err := os.Open(filepath.Join(root, nvcapsMigMinorsPath))
  ```
  </details>

- **修 hookscratch 目录名拼接 bug(malformed dir names)**:`ldconfig_linux.go` 与 `disable-device-node-modification/params_linux.go` 两处把 `"/run/nvidia-ctk-hook" + uuid.NewString()` 改成 `filepath.Join("/run/nvidia-ctk-hook", uuid.NewString())`。原 `params_linux.go` 那处缺斜杠(`"/run/nvidia-ctk-hook"` 直接接 uuid),会生成 `/run/nvidia-ctk-hookXXXX` 这类畸形目录。→ 属 hook 侧临时目录健壮性修正,不改行为语义。

  <details><summary>代码依据 cmd/nvidia-cdi-hook/.../params_linux.go</summary>

  ```diff
  -	hookScratchDirPath := "/run/nvidia-ctk-hook" + uuid.NewString()
  +	hookScratchDirPath := filepath.Join("/run/nvidia-ctk-hook", uuid.NewString())
  ```
  </details>

### 后续发展方向 [AI]
- MIG 管理能力入 CDI 是 container-toolkit 持续"把所有 GPU 可见性/能力设备统一到 CDI spec 生成器"的又一格:继 imex/nvswitch/management 之后,MIG config/monitor 也成为一个独立 mode。可预期上游 gpu-operator / device-plugin 的 MIG manager 容器后续会切到 `mig-caps` CDI 模式拿设备,而非旧 runtime env 特判。证据只覆盖 toolkit 侧生成器与准入校验,未见调用方(operator/mig-parted)已切换的代码。
- 准入校验把"仅 all + 必须特权 + 不可与具体 MIG 设备并存"写死,说明短期不打算支持给非特权容器按需下发单个 MIG 管理设备;这与 MIG 管理本身需要 root 能力一致。证据止于 `Validate()`,未见放宽计划。

## NVIDIA/k8s-device-plugin: 325c1b2d -> 3c6be400
- 比较 / Release:`325c1b2d...3c6be400` | ahead=3 | files=2 | Release v0.20.0
- https://github.com/NVIDIA/k8s-device-plugin/compare/325c1b2d3ad97e98a8239a545df0c4e5d852ea45...3c6be400411aad793892e976824910d0880dd3a8

### AI 总结重点(源码 diff 为据)
- **greedyAlloc 分配器从"每轮全量重排"改为最小堆增量取最优**:引入 `container/heap`,删掉 `sort`。新增 `gpuAllocState`(每物理 GPU 的簿记:共享 `*replicaCount`、本轮已取 `pickedFrom`、剩余候选 `replicas`)与 `gpuPriorityQueue`(堆,`Less` 先比 `count.allocated()`、相等时按 `pickedFrom` 升序做平局轮转)。分配循环把候选按底层物理 GPU id 分桶成 `byGPU`,每次从堆顶取当前策略最优的物理 GPU 取一个 slot。→ 语义与旧实现等价(distributed 策略仍跨物理 GPU 铺开、平局时轮转到本轮碰得最少的兄弟卡),但把每次选择的 O(n log n) 排序降为堆的 O(log n) 调整,密集共享节点(8 卡 × 多 replica)分配开销显著下降。

  <details><summary>代码依据 internal/rm/allocate.go</summary>

  ```diff
  +	"container/heap"
   	"fmt"
  -	"sort"
  ...
  +type gpuAllocState struct {
  +	count      *replicaCount // shared reference to this GPU's replicaCount
  +	pickedFrom int           // slots picked from this GPU during this allocation
  +	replicas   []string      // remaining annotated-ID candidates for this GPU
  +}
  +func (q *gpuPriorityQueue) Less(i, j int) bool {
  +	a, b := q.items[i], q.items[j]
  +	if a.count.allocated() != b.count.allocated() {
  +		return q.preferred(a.count, b.count)
  +	}
  +	return a.pickedFrom < b.pickedFrom
  +}
  ```
  </details>

- **加基准测试锁定回归**:新文件 `internal/rm/allocate_bench_test.go` 的 `BenchmarkGreedyAlloc` 覆盖 3 种节点形态(4×4/n=16 小节点、8×8/n=64 典型密集、8×16/n=128 激进共享),用 `AllocationPolicyDistributed` 比较器 + `ReportAllocs()`。→ 为后续分配器改动提供性能基线。

  <details><summary>代码依据 internal/rm/allocate_bench_test.go</summary>

  ```diff
  +		{gpus: 8, replicas: 8, request: 8},   // n=64  — typical dense (8-GPU) node
  +		{gpus: 8, replicas: 16, request: 16}, // n=128 — 8-GPU node, aggressive sharing
  ```
  </details>

### 后续发展方向 [AI]
- 这是纯性能重构、不动分配语义(注释与测试都强调 distributed 平局轮转不变),信号是社区开始关注 device-plugin 在超密集共享(time-slicing/MPS 高 replica)下的分配热路径开销——间接说明这些共享模式在生产里跑到了足够大的规模才值得优化。证据只到分配器与 benchmark,未见调度语义或对外配置面变化。

## 本期无实质改动 / 仅构建/文档/测试(折叠)
<details><summary>展开</summary>

- **NVIDIA/gpu-operator**(仅构建):回退上一轮把 CUDA samples 从 v12.9 bump 到 v13.2 的改动,固定回 `CUDA_SAMPLES_VERSION=12.9`,注释说明 R580 是 gpu-operator 支持的最低驱动分支、向后兼容到 Maxwell,而 v12.9 是最后一个支持 Maxwell 的 CUDA samples;顺带去掉 tar 解包里的 `*/cmake/*` 通配。**无 CRD 字段变化**。 https://github.com/NVIDIA/gpu-operator/commit/6cf33d2875b53dbb0d6786dadb363094b87f900e
- **NVIDIA/gpu-driver-container**(仅构建):rhel8/9/10 及 vgpu-manager 的 Dockerfile 统一在装包/更新前设 `tsflags=nodocs`(rhel8 还兜底装 `dnf-command(config-manager)`),不装文档以缩小驱动镜像体积。无驱动构建逻辑变化。 https://github.com/NVIDIA/gpu-driver-container/commit/9ac64592151369a93da35b831322f193c03b13f5
- **kubernetes-sigs/dra-driver-nvidia-gpu**(仅文档):FabricManagerPartitioning 指南删除 `FABRIC_MODE_RESTART=1` 这条前置项,只留 `FABRIC_MODE=1` + `FM_CMD_UNIX_SOCKET_PATH`。反映该 featuregate 启用门槛降低,非代码变更。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/58f4c3bd936cd168b9e0ab2f088dd1183e63ba16
- **NVIDIA/mig-parted**(仅 bump):devel/container 两 Dockerfile 把 golang 1.27.0 → 1.27.1。无 MIG 切分逻辑变化。 https://github.com/NVIDIA/mig-parted/commit/7b3cf9c2f4b74e5c5c3887d4d2fc6d52eccd00c1
- **kai-scheduler/KAI-Scheduler**(仅测试):`test/e2e/scale/kwok_test.go` 修 flaky——reclaim 场景改用 `patchQueueGPU` 走 RawPatch(MergePatch)更新 Queue 的 GPU quota,替代原先 Get+改字段+Update 的读改写(易并发冲突)。非生产代码。 https://github.com/kai-scheduler/KAI-Scheduler/commit/f5287fb22942a52d38b1f5cdd17f2c78823afffb
- **NVIDIA/dcgm-exporter**:EMPTY(无新提交)。
- **NVIDIA/DCGM**:EMPTY(无新提交)。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=6cf33d2875b53dbb0d6786dadb363094b87f900e branch=main release=v26.7.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=4ea74829b94b2a03ca6295cb5663296ea1591ddf branch=main release=v1.20.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9ac64592151369a93da35b831322f193c03b13f5 branch=main release=— scanned=2026-09-04 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=3c6be400411aad793892e976824910d0880dd3a8 branch=main release=v0.20.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=58f4c3bd936cd168b9e0ab2f088dd1183e63ba16 branch=main release=v0.5.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-09-04 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-04 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=7b3cf9c2f4b74e5c5c3887d4d2fc6d52eccd00c1 branch=main release=v0.15.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=f5287fb22942a52d38b1f5cdd17f2c78823afffb branch=main release=v0.17.1 scanned=2026-09-04 -->
