# HAMi diff 雷达 2026-07-16

## 摘要
- **HAMi 主仓**移除了 Ascend vNPU(hami-core 模式)容器的 PostStart 生命周期钩子——限流器进程 `/hami-vnpu-core/limiter` 不再由 k8s lifecycle 注入启动,vNPU 软切分的算力/显存限流启动路径被改造。
- HAMi 首次在 `SECURITY.md` 里明确写出**软隔离信任边界**:HAMi-core 的容器内限流是"可信集群内协作式多租共享",不是对抗越权 workload 的硬安全边界(unset `LD_PRELOAD`/静态链接/`ptrace` 均可绕过自身配额)——越自身配额不算漏洞,跨租户越权才在范围内。
- HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI 四仓本期无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力/架构方向] 删除 Ascend hami-core vNPU 的 PostStart 钩子注入,限流器启动方式换代 —— pkg/device/ascend/device.go https://github.com/Project-HAMi/HAMi/pull/2062
- Project-HAMi/HAMi [架构方向] 官方文档化 HAMi-core 软隔离的安全边界与漏洞判定口径 —— SECURITY.md https://github.com/Project-HAMi/HAMi/pull/2063

## Project-HAMi/HAMi: a1b418c7 -> 3166c1a2
- 比较: a1b418c7a439948e3e22192a397e1716ceecff34 -> 3166c1a2 | ahead=4 | files=7 | Release: v2.9.0
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/a1b418c7a439948e3e22192a397e1716ceecff34...3166c1a23d9821d03769b059a212debf4792b666

### AI 总结重点(源码 diff 为据)
- **`MutateAdmission` 里针对 Ascend vNPU(`isHAMiCore`)容器注入 PostStart 钩子的整段逻辑被删除**(-21 行):此前当检测到 Ascend core 资源时,HAMi 会给容器 `ctr.Lifecycle.PostStart` 塞一个 `bash -c "export RUST_LOG=info; /hami-vnpu-core/limiter > /tmp/limiter_manager.log 2>&1 &"` 的 Exec 钩子,靠 k8s 生命周期在容器启动后拉起 Rust 写的限流器守护进程。现在这套注入没了——意味着 vNPU 限流器的启动改由别处负责(大概率移进镜像 entrypoint / 由 device-plugin 侧挂载的组件启动),不再依赖 PostStart。配套测试 `Test_MutateAdmission_VNPUCoreMode` 的用例名从 "inject postStart and keep raw memory" 改成 "keep raw memory without postStart",`wantPostStart` 由 `true` 翻成 `false`,断言反转为"若有 Lifecycle 则 PostStart 必须为 nil",坐实了"不再注入"的语义。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
  -	if isHAMiCore {
  -		klog.V(3).Infof("Ascend core resource detected, injecting postStart lifecycle for container %s", ctr.Name)
  -		if ctr.Lifecycle == nil {
  -			ctr.Lifecycle = &corev1.Lifecycle{}
  -		}
  -		// Inject PostStart hook to start the limiter process
  -		if ctr.Lifecycle.PostStart == nil {
  -			ctr.Lifecycle.PostStart = &corev1.LifecycleHandler{
  -				Exec: &corev1.ExecAction{
  -					Command: []string{
  -						"bash", "-c",
  -						"export RUST_LOG=info\n/hami-vnpu-core/limiter > /tmp/limiter_manager.log 2>&1 &",
  -					},
  -				},
  -			}
  -		}
  -	}
  ```
  </details>
  <details><summary>代码依据 pkg/device/ascend/device_test.go</summary>

  ```diff
  -			name: "vNPU-mode hami-core: inject postStart and keep raw memory",
  +			name: "vNPU-mode hami-core: keep raw memory without postStart",
  ...
  -			wantPostStart: true,
  +			wantPostStart: false,
  ...
  -			if test.wantPostStart {
  -				assert.Assert(t, test.args.ctr.Lifecycle != nil, "Lifecycle should not be nil")
  -				assert.Assert(t, test.args.ctr.Lifecycle.PostStart != nil, "PostStart should not be nil")
  -				...
  +			if !test.wantPostStart {
  +				if test.args.ctr.Lifecycle != nil {
  +					assert.Assert(t, test.args.ctr.Lifecycle.PostStart == nil, "PostStart should not be set")
  +				}
  ```
  </details>

- **`PodInfo` 结构体删除 `CtrIDs []string` 字段**(#2071 refactor):连同 `DeepCopy()` 里的 `append([]string(nil), p.CtrIDs...)` 拷贝逻辑一并移除,pod_test/devices_test 中所有 `CtrIDs` 断言与 mutate 测试全部清掉。属于调度侧内部数据模型瘦身——该字段此前用于记录 pod 下的容器 ID 列表,现判定为无用状态被清理,不影响外部 CRD/API。
  <details><summary>代码依据 pkg/device/pods.go</summary>

  ```diff
   type PodInfo struct {
   	*corev1.Pod
   	NodeID  string
   	Devices PodDevices
  -	CtrIDs  []string
   }
  ...
   func (p *PodInfo) DeepCopy() *PodInfo {
   		Pod:     p.Pod.DeepCopy(),
   		NodeID:  p.NodeID,
   		Devices: p.Devices.DeepCopy(),
  -		CtrIDs:  append([]string(nil), p.CtrIDs...),
   	}
  ```
  </details>

- **`SECURITY.md` 新增 "Is It In Scope?" 段**:官方定义 HAMi-core/libvgpu 的容器内 GPU 显存+算力限制是"面向可信集群上协作式多租共享",明确**不是**对抗"有足够权限绕过自身钩子(unset `LD_PRELOAD`、静态二进制、`ptrace`)"的硬安全边界;并给出漏洞判定口径:workload 突破自身配额而不影响他租户 = 非漏洞;能触达他租户数据/设备/命名空间 = 在范围内需上报。
  <details><summary>代码依据 SECURITY.md</summary>

  ```diff
  +## Is It In Scope?
  +
  +HAMi's in-container enforcement (HAMi-core/libvgpu and vendor libraries) limits GPU memory and compute for cooperative multi-tenant sharing on a trusted cluster. It is not a hard security boundary against a workload with enough privilege to bypass its own hook, for example by unsetting `LD_PRELOAD`, using a static binary, or `ptrace`.
  +- A report that a workload can exceed its own quota, without affecting another tenant, is not a new vulnerability by itself.
  +- A report that lets a workload reach another tenant's data, device, or namespace it was not granted is in scope, please report it through the process above.
  ```
  </details>

### 后续发展方向 [AI]
- **vNPU 限流器启动方式在去耦 k8s lifecycle**:删掉 PostStart 注入后,`/hami-vnpu-core/limiter` 必须换个入口拉起。证据只覆盖"admission 侧不再注入钩子"这一半,未见新的启动方在哪个仓/哪个 commit 落地(HAMi-core 本期无提交,ascend-device-plugin 本期无提交)——后续要盯 HAMi-core 或 ascend-device-plugin 镜像 entrypoint/init 的对应改动来闭环。PostStart 钩子本身可靠性差(容器已 Running 才异步执行、失败不阻塞),移除它对 vNPU 限流生效时机是正向收敛。
- **软隔离边界被正式"文档化"是产品信号**:HAMi 把"协作式共享、非硬隔离"写进安全策略,等于官方承认单靠 hook 挡不住恶意越权。对标我们做企业级多租 GPU 时,这条要直接进合规话术——HAMi 软切分只能用于可信租户间超卖,强隔离场景需叠加 MIG/整卡/DRA 或 vNPU 硬分区,不能拿 HAMi-core 当租户隔离的唯一防线。证据仅为 SECURITY.md 文本,未展开对应代码强化。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点,无新提交)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release: hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=3166c1a23d9821d03769b059a212debf4792b666 branch=master release=v2.9.0 scanned=2026-07-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=06e698079335cffd0009f3c119bd95b012600ae5 branch=main release=— scanned=2026-07-16 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-16 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=f8ae57c30dd6e8311815bb3327a2991e34293b1d branch=main release=— scanned=2026-07-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-16 -->
