# 昇腾算力栈 diff 雷达 2026-06-23

## 摘要
- **mind-cluster 全栈落地"推理容器快照(checkpoint/restore)"**:同一区间(36 commits)在三层同步新增 `grus` runtime 子包(ascend-docker-runtime)+ `snapshot` 控制器(infer-operator)+ `containersnapshot` 节点监控(noded),实现昇腾推理 Pod 的暂停—导出 rootfs—恢复链路,带 SHA256 完整性校验与网络命名空间重建。这是面向 PD 分离推理实例的故障快恢/迁移底座。
- ascend-docker-runtime 入口 `process.go` 重构:`getArgs` 新增 `--image-path`/`--root` 解析,参数结构上移到 `common.Args`,runc 调用逻辑迁入 `grus` 包——runtime 从"纯注入 hook"扩成"可驱动 checkpoint/restore 的容器生命周期管理器"。
- 其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本日无新提交,保锚点。

## 当日重要改变
- **mind-cluster [新能力] 推理容器快照能力首次成体系落地**(grus 包 + infer-operator/snapshot + noded/containersnapshot,均为 added、Copyright 2026)。证据见下「AI 总结重点」。compare: https://gitcode.com/Ascend/mind-cluster/compare/2a06af1cd9a7bd4d803fcd1f5b602520ec7985c4...65f4b19f231e5ce8510ccb6571c019ba45772455
- **mind-cluster [架构方向] ascend-docker-runtime 入口扩展为支持 checkpoint/restore 的运行时**:`component/ascend-docker-runtime/runtime/process/process.go` getArgs 新增 `--image-path`/`--root`、参数结构改用 `common.Args`。
- mind-cluster [新能力] noded 节点侧新增并发受限的 checkpoint 触发器(`semaphore` + `MaxCheckpointRequest`),按 `InferLabel` 在本节点 informer 监听推理 Pod。

## mind-cluster: 2a06af1c -> 65f4b19f
- 比较: 2a06af1cd9a7bd4d803fcd1f5b602520ec7985c4..65f4b19f | tag: v26.0.1 | commits=36 | truncated=false
- compare URL: https://gitcode.com/Ascend/mind-cluster/compare/2a06af1cd9a7bd4d803fcd1f5b602520ec7985c4...65f4b19f231e5ce8510ccb6571c019ba45772455

### AI 总结重点(源码 diff 为据)

- **ascend-docker-runtime 新增 `grus` 运行时子包,封装 runc 的 pause/resume/state 做 checkpoint 前置**:`checkpoint.go` 新增 `runtimeClient`(持有 `runtime.RuntimeAPI`),`initRuntimeClient` 通过 `client.State(containerID)` 拿到 bundle 并读 OCI config,再用 `pause/resume/state` 包装 runc——即"checkpoint 时先冻结容器"。
  <details><summary>代码依据 component/ascend-docker-runtime/runtime/grus/checkpoint.go (added)</summary>

  ```diff
  +var getRuntime = runtime.GetRuntime
  +type runtimeClient struct {
  +	client  runtime.RuntimeAPI
  +	bundle  string
  +	conSpec *specs.Spec
  +}
  +func initRuntimeClient(containerID, root string) (*runtimeClient, error) {
  +	result := &runtimeClient{}
  +	result.client = getRuntime(common.RuntimeNameRunc, root)
  +	con, err := result.client.State(containerID)
  +	...
  +	result.bundle = con.Bundle
  +	spec, err := readOCIConfig(result.bundle)
  +	...
  +}
  +func (c *runtimeClient) pause(containerID string) error { ... return c.client.Pause(containerID) }
  +func (c *runtimeClient) resume(containerID string) error { ... return c.client.Resume(containerID) }
  ```
  </details>

- **rootfs 快照走 containerd:把容器 rootfs diff 导出为 tar**,`ContainerdRootfs` 实现 `RootfsSnapshot` 接口,`Checkpoint` 用 containerd 的 `archive/compression` 把 rootfs diff 写到 `common.ROOTFS_DIFF` tar 文件。说明快照内容 = 进程态(runc)+ 文件系统增量(containerd 层)。
  <details><summary>代码依据 component/ascend-docker-runtime/runtime/grus/rootfs/containerd.go (added)</summary>

  ```diff
  +type ContainerdRootfs struct { socket string }
  +func NewContainerdRootfs(socket string) RootfsSnapshot { return &ContainerdRootfs{socket: socket} }
  +func (c *ContainerdRootfs) Checkpoint(ckptPath, containerID, ns string) (string, error) {
  +	tarFile := filepath.Join(ckptPath, common.ROOTFS_DIFF)
  +	hwlog.RunLog.Infof("exporting rootfs diff to tar, dst: %s", tarFile)
  +	...
  +}
  ```
  </details>

- **restore 侧重建网络命名空间并下发"已恢复"标志位**:`restore.go` import `golang.org/x/sys/unix` 并把 `unix.Setns`/`unix.Open`/`net.InterfaceAddrs` 设为可替换变量(用于进入目标 netns);`createFlagFile` 读 `GRUS_SNAPSHOT_RESTORED_FLAG` 环境变量,为 true 时在 rootfs 内创建 `common.GRUS_RESTORE_FLAG_FILE`(`/root/.grusflag`)并 chown root——给容器内进程一个"我是被快照恢复起来的"信号。
  <details><summary>代码依据 component/ascend-docker-runtime/runtime/grus/restore.go (added)</summary>

  ```diff
  +var (
  +	unixSetns = unix.Setns
  +	netInterfaceAddrs = net.InterfaceAddrs
  +)
  +func createFlagFile(spec *specs.Spec, rootfs string) error {
  +	f := getEnvFromSpec(spec, common.GRUS_SNAPSHOT_RESTORED_FLAG)
  +	if strings.ToLower(f) != "true" { return nil }
  +	flagFile := filepath.Clean(filepath.Join(rootfs, common.GRUS_RESTORE_FLAG_FILE))
  +	... os.OpenFile(flagFile, os.O_CREATE|os.O_RDWR, ...) ; os.Chown(flagFile, 0, 0)
  +}
  ```
  </details>

- **runtime 入口 process.go 从"hook 注入"扩成"快照命令解析"**:`getArgs` 返回类型从本地 `*args{bundleDirPath,cmd}` 改为 `*common.Args{Bundle,CkptPath,...}`,新增解析 `--image-path`(→ CkptPath)与 `--root`;同时删掉 `os/exec`、`syscall`、`dockerRuncFile`/`runcFile` 常量及本地 `runcName`——runc 调用职责整体迁入 `grus` 包。
  <details><summary>代码依据 component/ascend-docker-runtime/runtime/process/process.go (modified)</summary>

  ```diff
  -type args struct { bundleDirPath string; cmd string }
  -func getArgs() (*args, error) {
  -	args := &args{}
  +func getArgs() (*common.Args, error) {
  +	args := &common.Args{}
   	for i, param := range os.Args {
   		if param == "--bundle" || param == "-b" { ... args.Bundle = os.Args[i+1]
  +		} else if param == "--image-path" { ... args.CkptPath = os.Args[i+1]
  +		} else if param == "--root" { ...
  ```
  </details>

- **infer-operator 新增 snapshot 控制面:按 Pod 注解切"保存/恢复"模式,并维护恢复标志**:`PodSnapshotReconciler.Reconcile` 给 Pod 打 `SnapshotModeAnnotationKey`;当模式 ≠ `SnapshotSaveMode` 时,为 PD 实例绑 service(打 active label)并把 metadata configmap 的 `GrusSnapshotRestoredFlag` 置 true——把上面 runtime 层的 flag 串成闭环。`snapshot_utils.go` 定义 `SnapshotStatus{SHA256, DirectorySHA256 map[string]string, Status, Timestamp}` 做目录级完整性校验,`AddSnapshotInfoToPodTemplate`/`IsContainerSnapshotOn` 控制是否开启。
  <details><summary>代码依据 component/infer-operator/pkg/snapshot/pod_snapshot_controller.go (added)</summary>

  ```diff
  +func (r *PodSnapshotReconciler) Reconcile(ctx, req) (ctrl.Result, error) {
  +	... r.setPodSnapshotModeAnnotation(ctx, pod) ...
  +	mode := pod.Annotations[common.SnapshotModeAnnotationKey]
  +	if mode != common.SnapshotSaveMode {
  +		// bind service for PD instance which doesn't need to save snapshot
  +		r.setPodActiveLabel(ctx, pod)
  +		// change metadata configmap GrusSnapshotRestoredFlag key to true
  +		r.updateSnapshotConfigMap(ctx, pod)
  +	}
  +}
  ```
  </details>

- **noded 节点侧新增 PodMonitor + 并发信号量,在每个节点上自驱 checkpoint**:`pod_monitor.go` 用 informer 按 `LabelSelector=InferLabel=true` + `FieldSelector=spec.nodeName=<本节点>` 只看本机推理 Pod,Add/Update 时触发处理;`semaphore` 以 `common.MaxCheckpointRequest` 限制并发 checkpoint 请求,避免快照风暴。
  <details><summary>代码依据 component/noded/pkg/containersnapshot/pod_monitor.go (added)</summary>

  ```diff
  +var semp = newSemaphore(common.MaxCheckpointRequest)
  +func (p *PodMonitor) Monitoring() {
  +	informerFactory := informers.NewSharedInformerFactoryWithOptions(p.client.ClientSet, 0,
  +		informers.WithTweakListOptions(func(options *metav1.ListOptions) {
  +			options.LabelSelector = labels.SelectorFromSet(labels.Set{common.InferLabel: "true"}).String()
  +			options.FieldSelector = "spec.nodeName=" + p.client.NodeName
  +		}))
  +	... podInformer.AddEventHandler({AddFunc: p.AddPod, UpdateFunc: p.UpdatePod}) ...
  +}
  ```
  </details>

### 后续发展方向 [AI]
- 证据链(runtime grus + operator snapshot + noded monitor 三层同名 commit "容器快照…part1-5")指向一个完整目标:**昇腾推理实例的 checkpoint/restore 故障快恢/迁移**,且与 PD(Prefill/Decode 分离)推理强绑定——`Reconcile` 显式对"不需保存快照的 PD 实例"走绑 service 分支,说明快照主要服务于需要保存态的那一侧实例。
- 快照内容已确认为"进程态(runc pause + state)+ rootfs 增量(containerd 导 tar)+ netns 重建(unix.Setns)",并加了 `DirectorySHA256` 目录级校验——工程上已超出"重启恢复",更接近热迁移底座。证据只覆盖 checkpoint/restore 与 rootfs/netns 路径,**未见** NPU 设备态(显存/AICORE 上下文)如何随快照保存的代码,这是判断能否真正做到推理热迁移的关键缺口,需后续区间盯 grus 包是否新增 dcmi/device 快照逻辑。
- ascend-docker-runtime 入口已开始接收 `--image-path`/`--root`,但本区间未见调用方(谁以这些参数拉起 runtime)的 hunk,**hunk 未覆盖** main/cmd 装配处。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓本日无新提交</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=65f4b19f231e5ce8510ccb6571c019ba45772455 tag=v26.0.1 scanned=2026-06-23 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-23 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-23 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-23 -->
<!-- ANCHOR repo=vNPU sha=ed90d497b78be919aa5c571daf7b8914bc89c7fe tag=v0.1.0 scanned=2026-06-23 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-23 -->
<!-- ANCHOR repo=npu-dra-plugin sha=c6dc2c73fd29c1e9b43392cae51b60a6168f521e tag=1.0.1 scanned=2026-06-23 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-23 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-06-23 -->
</content>
</invoke>
