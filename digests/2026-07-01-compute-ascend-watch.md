# 昇腾算力栈 diff 雷达 2026-07-01

## 摘要
- **mind-cluster** 本期是一波"框架升级 + 监控/可靠性加固":infer-operator 与 ascend-operator 一起把 controller-runtime 升档(cache `SelectorsByObject`→`ByObject`、`source.Kind{}`→`source.Kind(cache,…)`、`EnqueueRequestForOwner` 改函数式签名);npu-exporter **彻底删除 CRI v1alpha2 RuntimeService 兼容路径**;ascend-device-plugin 修了两个会让 hang/CPU 指标失真的 bug(proc stat comm 解析、进程集变化重置基线)。
- infer-operator 容器快照能力增强:快照超时从 40min 改 60min 且**可经 `--snapshotTimeout` flag 配置(1~600min)**,快照完成后回写 ConfigMap checkpoint(带 3 次重试);HPA 更新改用 `RetryOnConflict` 防并发冲突。
- 其余 8 仓中 npu-dra-plugin 仅单测重构(无生产行为变化),npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin 全 EMPTY。

## 当日重要改变
- mind-cluster [弃用/移除] npu-exporter 删掉对 containerd **CRI v1alpha2** 的全部兼容:移除 `getContainersByContainerdV1alpha2`、`isUnimplementedError`、常量 `criV1alpha2` 与 `v1alpha2` import,`initCriClient`/`GetContainers` 只走 `criv1`。意味着不再支持仅暴露 v1alpha2 CRI 的老 containerd(K8s 1.26 起已删 v1alpha2)。证据 `component/npu-exporter/collector/container/runtime_ops.go`。https://gitcode.com/Ascend/mind-cluster/compare/43913f29d3e387d8009f3dbeccbdd29eea431163...9e45a253f2af5eded17c000f8c0bfdaf7b436bbe
- mind-cluster [架构方向] controller-runtime 升档:ascend-operator 把 `&source.Kind{Type:…}` 全换成 `source.Kind(mgr.GetCache(),…)`、`&handler.EnqueueRequestForOwner{IsController,OwnerType}` 换成 `handler.EnqueueRequestForOwner(scheme,mapper,obj,handler.OnlyControllerOwner())`、map 回调加 `ctx` 入参;infer-operator cache 配置从 `SelectorsByObject` 换 `ByObject`。这是 controller-runtime 跨次版本(~0.14→0.15+)的破坏性 API 迁移。证据 `ascend-operator/.../ascendjob_controller.go`、`infer-operator/main.go`。

## mind-cluster: 43913f29 -> 9e45a253
- 比较: 43913f29..9e45a253 | tag: v26.0.1 | commits=22 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/43913f29d3e387d8009f3dbeccbdd29eea431163...9e45a253f2af5eded17c000f8c0bfdaf7b436bbe

### AI 总结重点(源码 diff 为据)

- **npu-exporter 删 CRI v1alpha2 兼容路径**:`GetContainers` 原先 type-assert `v1alpha2.RuntimeServiceClient`、调 `getContainersByContainerdV1alpha2`,遇 `Unimplemented` 再 fallback 到 v1;现在直接断言 `criv1.RuntimeServiceClient` 一条路。`isUnimplementedError`、`genContainerRequestV1alpha2` 系列辅助函数与 `codes`/`status` import 一并删除。

  <details><summary>代码依据 component/npu-exporter/collector/container/runtime_ops.go</summary>

  ```diff
  -	if client, ok := operator.criClient.(v1alpha2.RuntimeServiceClient); ok {
  -		containers, err := getContainersByContainerdV1alpha2(ctx, client)
  -		if isUnimplementedError(err, criV1alpha2) {
  -			v1Client := criv1.NewRuntimeServiceClient(operator.criConn)
  -			return getContainersByContainerdV1(ctx, v1Client)
  -		}
  -		return containers, err
  +	if client, ok := operator.criClient.(criv1.RuntimeServiceClient); ok {
  +		return getContainersByContainerdV1(ctx, client)
   	}
  ```
  </details>

- **ascend-device-plugin 修 proc stat CPU 时间解析**:`getProcessCPUTime` 原先 `strings.Fields` 整行切分按固定 `utimeIndex/stimeIndex` 取值,但 `/proc/[pid]/stat` 的 comm 字段(进程名)可含空格/括号会错位;现改为先 `LastIndex(")")` 跳过 comm 段,再对剩余字段用 `postCommUtimeIndex/postCommStimeIndex`(= 原索引 -2)取值。这正是 commit"修复进程CPU时间解析…导致指标异常"的实现。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/hangdetection/hang_detector.go</summary>

  ```diff
  -	fields := strings.Fields(string(data))
  -	if len(fields) <= stimeIndex {
  +	statStr := string(data)
  +	lastRightParen := strings.LastIndex(statStr, rightParenthesis)
  +	if lastRightParen < 0 {
  +		return 0, fmt.Errorf("invalid proc stat format for pid %d: missing comm field", pid)
  +	}
  +	fields := strings.Fields(statStr[lastRightParen+1:])
  +	if len(fields) <= postCommStimeIndex {
   		return 0, fmt.Errorf("invalid proc stat format for pid %d", pid)
   	}
  ```
  </details>

- **ascend-device-plugin 进程集变化时重置 hang 基线**:新增 `refreHangStateIfProcessChanged`,每轮 `detectNPU` 先对比该 logicID 上当前 PID 集合(`extractAndSortPids` 排序去抖)与缓存基线;不等则 `state.Metrics=nil` 清空基线。避免进程号变化(重启/换任务)后用旧基线误判 hang。配套在 `common.go` 新增泛型 `SliceEqual[T comparable]`。

  <details><summary>代码依据 hang_detector.go + common/common.go</summary>

  ```diff
  +	hd.refreHangStateIfProcessChanged(logicID, extractAndSortPids(procInfo))
  ...
  +	if common.SliceEqual[int32](state.PIDs, curPIDs) {
  +		return
  +	}
  +	hwlog.RunLog.Infof("process set changed, reset hang baseline, logicID=%d", logicID)
  +	state.PIDs = curPIDs
  +	state.Metrics = nil
  ```
  </details>

- **infer-operator 快照超时可配 + 回写 ConfigMap checkpoint**:`SnapshotTimeout` 由 `40*Minute` 改成 `SnapshotTimeoutNum(=60)*Minute`;`NewSnapshotChecker` 增 `timeout int` 入参,`time.ParseDuration` 钳到 [1,600] 分钟;main.go 加 `--snapshotTimeout` flag(默认 60)。快照全部完成时新增 `updateSnapshotCMCheckpoint`——按 `snapshot-metadata-<instanceSet>-<index>` 找 ConfigMap、3 次重试(退避 1s×attempt)写 checkpoint。新增常量 `SnapshotMetadataJson`、`SnapshotFinished="done"`。

  <details><summary>代码依据 infer-operator/pkg/common/constant.go + snapshot_checker.go + main.go</summary>

  ```diff
  -	SnapshotTimeout = 40 * time.Minute
  +	SnapshotTimeoutNum = 60
  +	SnapshotTimeout = SnapshotTimeoutNum * time.Minute
  ...
  -func NewSnapshotChecker(k8sClient client.Client) *SnapshotChecker {
  +func NewSnapshotChecker(k8sClient client.Client, timeout int) *SnapshotChecker {
  +	if timeoutConfig, err := time.ParseDuration(fmt.Sprintf("%dm", min(max(timeout, 1), 600))); err == nil {
  +		timeoutDuration = timeoutConfig
  +	}
  ...
  +	flag.IntVar(&snapshotTimeout, "snapshotTimeout", common.SnapshotTimeoutNum, "...3 greater than 0 and less than 600")
  ```
  </details>

- **infer-operator HPA 更新加冲突重试**:`updateHPA` 原先直接改 `existingHPA.Spec` 后 `Update`,并发下易 409 Conflict;现包进 `retry.RetryOnConflict(DefaultRetry, …)`,每次重取最新 HPA 再写 Spec。

  <details><summary>代码依据 infer-operator/pkg/controller/scaling/scaling_manager.go</summary>

  ```diff
  -	existingHPA.Spec = *desiredSpec
  -	if err := m.Update(ctx, existingHPA); err != nil {
  +	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
  +		latestHPA := &autoscalingv2.HorizontalPodAutoscaler{}
  +		if err := m.Get(ctx, types.NamespacedName{Name: hpaName, Namespace: instanceSet.Namespace}, latestHPA); err != nil {
  +			return err
  +		}
  +		latestHPA.Spec = *desiredSpec
  +		return m.Update(ctx, latestHPA)
  +	})
  ```
  </details>

- **ascend-operator + infer-operator controller-runtime API 迁移**:见"当日重要改变"。属框架升档而非功能改动,但破坏性 API 替换面广(watch/cache/handler 全覆盖),与"升级开源软件版本修复漏洞"commit 呼应。

  <details><summary>代码依据 ascend-operator/.../ascendjob_controller.go</summary>

  ```diff
  -	if err := c.Watch(&source.Kind{Type: &mindxdlv1.AscendJob{}}, &handler.EnqueueRequestForObject{},
  +	cache := mgr.GetCache()
  +	if err := c.Watch(source.Kind(cache, &mindxdlv1.AscendJob{}), &handler.EnqueueRequestForObject{},
  ...
  -	}, handler.EnqueueRequestForOwner{IsController: true, OwnerType: &mindxdlv1.AscendJob{}}
  +	}, handler.EnqueueRequestForOwner(mgr.GetScheme(), mgr.GetRESTMapper(), &mindxdlv1.AscendJob{}, handler.OnlyControllerOwner())
  ```
  </details>

### 后续发展方向 [AI]
- infer-operator 的快照 checkpoint(写 ConfigMap + `SnapshotFinished="done"` + `snapshot_metadata.json`)在搭"断点续训/推理快照恢复"的元数据落盘链路,配合可配超时,说明这条断点续训能力在往可生产化打磨。证据只覆盖 checkpoint 写入与超时配置,**未见**恢复侧(读 checkpoint 拉起)的 diff。
- npu-exporter 删 v1alpha2 + 两个 operator 同步升 controller-runtime,整体在抬运行时底座到较新 K8s/containerd;后续若继续清理 v1alpha2 别处引用值得跟。证据仅 runtime_ops.go 一处,未扫到其他组件是否还残留 v1alpha2。
- hang detection 两处修复都指向"指标真实性"——进程级 CPU 时间 + 进程集变化感知,昇腾在打磨 NPU 卡死/亚健康判定的误报率。证据只看到基线重置与解析修复,未见判定阈值逻辑变化。

## npu-dra-plugin: b28f10a1 -> 0876c67f
- 比较: b28f10a1..0876c67f | tag: 1.0.1 | commits=2 | truncated=false
- 源: https://gitcode.com/openFuyao/npu-dra-plugin/compare/b28f10a1e98ec0c2af8be45928e08e689d4a7fb4...0876c67f9bea29da06e97e09bb7def5c0039a30b

### AI 总结重点(源码 diff 为据)
- **纯单测基建,无生产行为变化**:把 `isLibraryAvailable`/`skipIfLibraryAvailable`(检测 `libdcmi.so` 是否就位)从 `dcmi_test.go` 上移到 `dcmi.go` 并导出为 `SkipIfLibraryAvailable`,供 `internal/profiles/npu` 的测试跨包复用,使有真实 dcmi 库的环境里跳过"期望报错"的用例;`getPhysicalID` 系列错误用例改成依库存在与否分支断言;mock patch 从 `ApplyFunc` 改 `ApplyPrivateMethod`。注意 `dcmi.go`(生产文件)现 import 了 `testing`,属测试代码混入生产包的味道,但无运行期行为改变。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅 merge/bump/CI 或无新提交)</summary>

- npu-operator — 无新提交
- npu-container-toolkit — 无新提交
- npu-driver-installer — 无新提交
- vNPU — 无新提交
- npu-node-provision — 无新提交
- volcano-ext — 无新提交
- ub-network-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=9e45a253f2af5eded17c000f8c0bfdaf7b436bbe tag=v26.0.1 scanned=2026-07-01 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-07-01 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-07-01 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-07-01 -->
<!-- ANCHOR repo=vNPU sha=dae5c9f541fc402bd0703b17764bb89b98e63b2c tag=v0.1.0 scanned=2026-07-01 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-07-01 -->
<!-- ANCHOR repo=npu-dra-plugin sha=0876c67f9bea29da06e97e09bb7def5c0039a30b tag=1.0.1 scanned=2026-07-01 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-01 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-07-01 -->
</content>
</invoke>
