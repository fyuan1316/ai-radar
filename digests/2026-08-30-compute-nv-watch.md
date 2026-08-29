# NVIDIA 算力栈 diff 雷达 2026-08-30

## 摘要
- gpu-operator 停止给**已弃用的 `cdi.default` 字段**下发 `default=false` 默认值(CRD + Go 类型双侧删 kubebuilder 默认注解),CDI 的开关语义彻底收敛到 `cdi.enabled`——弃用字段清退进入"不再写默认值"阶段。
- dra-driver-nvidia-gpu 把 driver-root 发现逻辑从 gpu-kubelet-plugin 本地 `root` 字符串类型(删 133 行)抽成独立可复用包 `internal/lookup/root`(`root.Driver` 结构 + `LibraryPath/BinaryPath/DriverLibraryPath/DevRoot`),为 FabricManager/VFIO/CDI 共用同一套库/二进制定位;配套 gpu-kubelet-plugin 清理(unprepare/cleanup)生命周期测试大补。
- container-toolkit 修开机竞态:新增 systemd drop-in 让容器引擎(docker/containerd/crio)排在 `nvidia-cdi-refresh.service` 之后启动,避免首个容器抢在设备节点/CDI spec 生成前起来;CDI hook 对只读根文件系统(EROFS)从报错改为告警放行。

## 当日重要改变
- NVIDIA/gpu-operator [API/CRD变更][弃用/移除] `CDIConfigSpec.Default`(`cdi.default`,已标 Deprecated)移除 `+kubebuilder:default=false`,CRD YAML 同步删 `default: false`——不再向该字段写默认值。证据 `api/nvidia/v1/clusterpolicy_types.go` / `config/crd/bases/nvidia.com_clusterpolicies.yaml` https://github.com/NVIDIA/gpu-operator/commit/fa49ea63b83991253d08125a9879e4a67767c360
- kai-scheduler/KAI-Scheduler [架构方向] 新增驱逐指标重设计 design doc:给 `kai_pod_group_evicted_pods_total` 加 `owner_group/owner_kind/owner_name/owner_uid/subgroup` 标签、新增事件级计数器 `kai_pod_group_eviction_events_total`,并对每个 PodGroup 观测到即预置 0,修 counter 首样本 `rate()/increase()` 恒为 0 的痼疾。证据 `docs/developer/designs/eviction-metrics/README.md` https://github.com/kai-scheduler/KAI-Scheduler/commit/98f95935d6d0521f81510cecf9eceb820586e482
- kubernetes-sigs/dra-driver-nvidia-gpu [新能力/架构方向] 新增 `internal/lookup/root` 包,统一 driver-root 下的库/二进制/dev 根路径发现,替代 gpu-kubelet-plugin 内嵌的 `root` 类型。证据 `cmd/gpu-kubelet-plugin/root.go`(删)、`device_state.go`/`nvlib.go`(改用 `root.Driver`) https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/ad6e0ec73dc5eb2abcdb177a6192a6710f64794a...98550b6c33dd64fe1e16313775adce85c185ac06

## NVIDIA/gpu-operator: 476868ab -> fa49ea63
- 比较: https://github.com/NVIDIA/gpu-operator/compare/476868abe0ab2f71c934443e370040c08ad2f880...fa49ea63b83991253d08125a9879e4a67767c360 | ahead=19 | Release: v26.7.0(未变)
- 注:helper 因 API 文件数被截断到 300 触发概览模式,以下结论基于对 `api/nvidia`/`config/crd` 命中文件的**单独取 patch**(非全量 hunk),其余为 bump/distroless/CodeRabbit 配置。
### AI 总结重点(源码 diff 为据)
- `CDIConfigSpec.Default` 字段(`cdi.default`,注释已标 Deprecated、语义早已让位给 `cdi.enabled`)去掉了 `+kubebuilder:default=false` 注解。前:Operator 会对未设该字段的 ClusterPolicy 回填 `false`;后:不再写默认值,字段留空。这是"弃用字段不再参与默认化"的清退动作,避免已废弃开关继续在 CRD 层产生隐式写入。
  <details><summary>代码依据 api/nvidia/v1/clusterpolicy_types.go</summary>

  ```diff
  	// Deprecated: This field is no longer used. Setting cdi.enabled=true will configure CDI as the default mechanism for making GPUs accessible to containers.
  	// +kubebuilder:validation:Optional
  -	// +kubebuilder:default=false
  	// +operator-sdk:gen-csv:customresourcedefinitions.specDescriptors=true
  ```
  </details>
  <details><summary>代码依据 config/crd/bases/nvidia.com_clusterpolicies.yaml(deployments/gpu-operator/crds 同步)</summary>

  ```diff
                  properties:
                    default:
  -                    default: false
                      description: 'Deprecated: This field is no longer used. Setting
                        cdi.enabled=true will configure CDI as the default mechanism ...
  ```
  </details>
- 三个 CRD(clusterpolicies/gpuclusters/nvidiadrivers)里 SELinux 卷重打标签(`seLinuxChangePolicy`/`seLinuxMount`)的字段描述被简化——删掉"仅当 SELinuxMount feature gate 启用时才允许 MountOption / 未指定时按 gate 状态回退"的分支说明,收敛为"未指定即用 MountOption"。这是 CRD 从更新版 vendored k8s 类型重新生成的结果(上游 SELinuxMount 特性已定型,条件文案随之消失),非 gpu-operator 主动语义变更。
  <details><summary>代码依据 config/crd/bases/nvidia.com_clusterpolicies.yaml</summary>

  ```diff
  -                          "MountOption" value is allowed only when SELinuxMount feature gate is enabled.
  -                          If not specified and SELinuxMount feature gate is enabled, "MountOption" is used.
  -                          If not specified and SELinuxMount feature gate is disabled, "MountOption" is used for ReadWriteOncePod volumes
  -                          and "Recursive" for all other volumes.
  +                          If not specified, "MountOption" is used.
  ```
  </details>
### 后续发展方向 [AI]
- CDI 配置面持续做减法:`cdi.default` 从"弃用但仍默认化"退到"弃用且不再写默认",下一步大概率是彻底删字段。证据只覆盖注解/CRD 默认值的移除,未见控制器侧对该字段的读取逻辑是否同步删除(本窗口未命中 controllers/)。

## NVIDIA/nvidia-container-toolkit: b5a4721d -> 3121efcf
- 比较: https://github.com/NVIDIA/nvidia-container-toolkit/compare/b5a4721daa18ec48fb3bcc2c9e04cbd6baff373a...3121efcf04bfe6898daa13d06c3101b1adc22234 | ahead=6 | Release: v1.20.0(未变)
### AI 总结重点(源码 diff 为据)
- 新增 systemd drop-in `10-container-engines.conf`,给 `nvidia-cdi-refresh.service` 加 `Before=docker.service containerd.service crio.service`,让容器引擎排在 CDI 刷新之后启动——修开机时首个容器抢在设备节点创建 / CDI spec 生成前就绪导致的竞态。同时把该 oneshot 服务的 `TimeoutStartSec` 从 systemd 默认的 infinity 收到 90s,避免 nvidia-smi 卡死无限期拖住引擎启动。以 drop-in 而非改主 unit 下发,便于用户用同名空文件覆盖取消。rpm/deb 打包同步纳入(Source12 + install 到 `nvidia-cdi-refresh.service.d/`)。
  <details><summary>代码依据 deployments/systemd/10-container-engines.conf(新增)</summary>

  ```diff
  +[Unit]
  +Before=docker.service containerd.service crio.service
  +
  +[Service]
  +TimeoutStartSec=90s
  ```
  </details>
- `update-application-profile` CDI hook 对只读根文件系统容错:把创建目录 + 写 profile 文件包进闭包,若返回 `syscall.EROFS` 则降级为 `Warningf` 告警放行,而非整个 hook 失败。让只读 rootfs 容器(启用了 application profile 注入时)不再因写不进 profile 而起不来。
  <details><summary>代码依据 cmd/nvidia-cdi-hook/update-application-profile/update-application-profile.go</summary>

  ```diff
  +	if err = func() error {
  +		if err := containerRoot.MkdirAll(applicationProfileDir, 0555); err != nil { ... }
  +		if err := containerRoot.WriteFile(applicationProfileFile, buildApplicationProfileConfig(mask), 0444); err != nil { ... }
  +		return nil
  +	}(); err != nil {
  +		if !errors.Is(err, syscall.EROFS) {
  +			return err
  +		}
  +		logger.Warningf("Ignoring read-only filesystem error: %v", err)
  +	}
  ```
  </details>
- 其余为治理文件(GOVERNANCE.md/CODE_OF_CONDUCT.md/CONTRIBUTING.md),非功能。
### 后续发展方向 [AI]
- 两处均是把 CDI 化路径(设备可见性的根)往"更鲁棒的启动/只读环境"方向硬化,呼应 gpu-operator 侧 CDI 成为默认机制。证据覆盖 systemd 启动顺序与 hook 容错,未见 CDI spec 内容格式变化。

## NVIDIA/k8s-device-plugin: d75aac2a -> 5a3b3d85
- 比较: https://github.com/NVIDIA/k8s-device-plugin/compare/d75aac2a65e366afd31285dc2c6011ef0b9fa39f...5a3b3d85a44ec0e493684c713218eaea07675601 | ahead=2 | Release: v0.20.0(未变)
### AI 总结重点(源码 diff 为据)
- `config-manager` 的 `updateSymlink` 重写,修**悬空软链接**(dst 指向已被删除的目标)导致的失败。旧实现用 `fileExists`+`filepath.EvalSymlinks(dst)` 判等,EvalSymlinks 遇悬空链接会报错直接 return;新实现改用 `os.Readlink` 直接读链接目标比对,且对 `EINVAL`(dst 非软链)与 `IsNotExist` 容错,`os.Remove` 也忽略 `IsNotExist`,并删除了 `fileExists` 辅助函数。config-manager 负责热切换 time-slicing/MPS 等配置的软链,悬空链场景(配置文件被删)以前会卡住整个更新。
  <details><summary>代码依据 cmd/config-manager/main.go</summary>

  ```diff
  -	exists, err := fileExists(f.ConfigFileDst)
  -	if exists {
  -		srcRealpath, err := filepath.EvalSymlinks(src)
  -		dstRealpath, err := filepath.EvalSymlinks(f.ConfigFileDst)
  -		if srcRealpath == dstRealpath { return false, nil }
  -		err = os.Remove(f.ConfigFileDst)
  -	}
  +	current, err := os.Readlink(f.ConfigFileDst)
  +	if err == nil {
  +		if current == src { return false, nil }
  +	} else if !os.IsNotExist(err) && !errors.Is(err, syscall.EINVAL) {
  +		return false, fmt.Errorf("error reading symlink '%s': %v", f.ConfigFileDst, err)
  +	}
  +	err = os.Remove(f.ConfigFileDst)
  +	if err != nil && !os.IsNotExist(err) { ... }
  ```
  </details>
### 后续发展方向 [AI]
- 纯健壮性修复,不涉及配置面语义或 DRA 迁移。证据只覆盖 updateSymlink 一函数。

## kubernetes-sigs/dra-driver-nvidia-gpu: ad6e0ec7 -> 98550b6c
- 比较: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/ad6e0ec73dc5eb2abcdb177a6192a6710f64794a...98550b6c33dd64fe1e16313775adce85c185ac06 | ahead=18 | Release: v0.5.0(未变,即本窗口为 v0.5.0 后续开发,非发版)
- 注:helper 因文件数被截断触发概览(18 文件属 `.agents/skills` 的 Agent/CodeRabbit 工具化,非产品代码);以下结论基于对 `internal/lookup`/`cmd/gpu-kubelet-plugin` 命中文件的单独取 patch。
### AI 总结重点(源码 diff 为据)
- **driver-root 发现抽包**:删除 `cmd/gpu-kubelet-plugin/root.go`(-133 行,内嵌的 `root` 字符串类型 + `getFMLibraryPath/getDriverLibraryPath/getNvidiaSMIPath/getDevRoot` 方法),改用新包 `internal/lookup/root` 的 `root.Driver`(`root.New(root.WithDriverRoot(...))`,方法 `LibraryPath("libnvfm.so")` / `DriverLibraryPath()` / `BinaryPath("nvidia-smi")`,字段 `DevRoot`/`Root`)。FabricManager、VFIO passthrough、CDI、deviceLib 全部改吃统一 `*root.Driver`,不再各自传 `containerDriverRoot`/`hostRoot` 字符串。这是把库/二进制/设备根定位从 kubelet-plugin 局部逻辑提成可复用基础设施(commit 标题 "part1",预示后续还有迁移)。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  -	containerDriverRoot := root(config.flags.containerDriverRoot)
  -	devRoot := containerDriverRoot.getDevRoot()
  +	driver := root.New(root.WithDriverRoot(config.flags.containerDriverRoot))
  +	devRoot := driver.DevRoot
  -	nvdevlib, err := newDeviceLib(containerDriverRoot, hostRoot)
  +	nvdevlib, err := newDeviceLib(driver, config.flags.hostRoot)
  ...
  -func newFabricManager(nvdevlib *deviceLib, containerDriverRoot root) (*fabricmanager.Manager, error) {
  -	libPath, err := containerDriverRoot.getFMLibraryPath()
  +func newFabricManager(nvdevlib *deviceLib, driver *root.Driver) (*fabricmanager.Manager, error) {
  +	libPath, err := driver.LibraryPath("libnvfm.so")
  ```
  </details>
- gpu-kubelet-plugin 清理生命周期测试大补(`test: unprepare if stale` / `cleanup only processes prepare started` / `enqueue cleanup`,配 vendor 引入 client-go/fake + ktesting),硬化 ResourceClaim 准备/反准备的幂等与陈旧态处理;伴随 `internal/resourceclaimutils` 的 ResourceClaim 格式化改动。
### 后续发展方向 [AI]
- driver-root 抽包("part1")指向 DRA driver 把设备/驱动发现做成可跨 gpu / compute-domain 两个 kubelet-plugin 复用的公共层,是 v0.5.0(HostManagedIMEX / FabricManagerPartitioning / ConsumableShares 等 feature gate)之后的内部整固。证据覆盖 lookup 抽包与测试,未逐一展开 resourceclaimutils 的格式化语义变化;`.agents/skills` 大批入库说明该仓在用 Agent 辅助研发,与产品能力无关。

## kai-scheduler/KAI-Scheduler: a20cb84e -> 98f95935
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/a20cb84efddef6cfb62ae5190e8a9bba66fdb6e1...98f95935d6d0521f81510cecf9eceb820586e482 | ahead=1 | Release: v0.14.8(未变)
### AI 总结重点(源码 diff 为据)
- 仅一个 design 文档 `docs/developer/designs/eviction-metrics/README.md`(+349),重设计 PodGroup 驱逐指标(尚未落代码):
  - 给现有 `kai_pod_group_evicted_pods_total` 增 `owner_group/owner_kind/owner_name/owner_uid/subgroup` 五个标签(来源 PodGroup 上的 `kai.scheduler/top-owner-metadata` 注解),使运维能用一句 `sum by (owner_name)` 直接回答"某 JobSet/Workspace 近期被打断多少次",不再靠 PG 名正则 `label_replace`。
  - 新增事件级计数器 `kai_pod_group_eviction_events_total`(每次触发驱逐的调度决策 +1,与"驱逐了几个 Pod"解耦,应对变长 gang)。
  - 两个计数器都在调度器首次观测到 PodGroup 时预置 0,修 Prometheus counter 从首样本起 `rate()/increase()` 恒返 0(生产 24h 实测 series 91→94 但 `rate>0` 计数恒 0)的问题。
  - 明确 Non-Goals:不加 CRD、不改驱逐机制、v1 不做 per-SubGroup 事件计数。驱动场景为多机架分布式训练 JobSet 的按机架(replica/subgroup)打断可观测。
  <details><summary>代码依据 docs/developer/designs/eviction-metrics/README.md</summary>

  ```diff
  +kai_pod_group_evicted_pods_total{ podgroup, namespace, nodepool, action,
  +  owner_group, owner_kind, owner_name, owner_uid, subgroup }
  +kai_pod_group_eviction_events_total{ ... }   # NEW, +1 per eviction decision
  +# Pre-initialized at 0 when the scheduler first observes the PodGroup.
  ```
  </details>
### 后续发展方向 [AI]
- KAI 在补抢占/回收(preempt/reclaim/consolidation/stalegangeviction)的**工作负载视角可观测性**,把内部 PodGroup 抽象映射回用户提交的 JobSet/MPIJob 对象——对标企业级调度器的"作业被打断"审计。证据仅为设计文档,实现 PR 未在本窗口出现;可关注后续 metrics 落地是否引入 `top-owner-metadata` 注解的 grouper 依赖(#1189)。

## 本期无实质改动(折叠)
<details><summary>4 个 repo 本期 EMPTY(仅无新提交/bump/CI,保锚点)</summary>

- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=fa49ea63b83991253d08125a9879e4a67767c360 branch=main release=v26.7.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3121efcf04bfe6898daa13d06c3101b1adc22234 branch=main release=v1.20.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-30 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=5a3b3d85a44ec0e493684c713218eaea07675601 branch=main release=v0.20.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=98550b6c33dd64fe1e16313775adce85c185ac06 branch=main release=v0.5.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-30 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-08-30 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=8bac7a587a30504efbce56f0416b0cd9330c618e branch=main release=v0.15.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=98f95935d6d0521f81510cecf9eceb820586e482 branch=main release=v0.14.8 scanned=2026-08-30 -->
