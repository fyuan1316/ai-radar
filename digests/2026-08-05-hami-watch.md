# HAMi diff 雷达 2026-08-05

## 摘要
- **HAMi 主仓本期无新能力,集中在软切分语义 + 并发/健康度稳健性修补**:`gpumem-percentage=0` 从"当非法 clamp 到 100"改判为"当 unset 哨兵"——避免向 hami-core 注入 `CUDA_DEVICE_MEMORY_LIMIT=0m`(被内核读作"无限制");vGPUmonitor 指标求和 clamp 到活跃进程槽防共享内存越界 panic;scheduler `GetNode` 返回深拷贝防并发 map 读写。
- **ascend-device-plugin 本期全是发布工程**:新增独立 Helm chart 打包(`values.schema.json` 强校验 + GHCR chart-releaser + helm-docs),把昇腾 vNPU 配置面(`hamiVnpuCore.enabled` / 每节点 `hami-vnpu-core` / `vDeviceCount`)固化成可校验契约;但 `cmd/` 无一行代码改动 = 虚拟化能力本身本期未动。
- HAMi-core / volcano-vgpu-device-plugin / HAMi-WebUI 三仓本期 EMPTY(无新提交)。

## 当日重要改变
- **Project-HAMi/HAMi [新能力/语义]** NVIDIA 软切分显存百分比 `gpumem-percentage=0` 语义从"非法值 clamp 100"改为"unset 哨兵(101)",堵住 `CUDA_DEVICE_MEMORY_LIMIT=0m` 被 hami-core 误判为无限显存的隐患。证据 `pkg/device/nvidia/device.go`。 https://github.com/Project-HAMi/HAMi/pull/2156
- **Project-HAMi/ascend-device-plugin [新能力]** 新增独立 Helm chart 发布链路(`charts/ascend-device-plugin/values.schema.json` + `.github/workflows/build-helm-release.yaml`),用 JSON Schema 把昇腾 vNPU 软切配置面固化为强校验契约。证据 `charts/ascend-device-plugin/`。 https://github.com/Project-HAMi/ascend-device-plugin/compare/5d5bad2d544a9725e064d68a4de28b6271628adb...771e19f8

## Project-HAMi/HAMi: 0345bd87 -> 2cabe290
- 比较: `0345bd87 -> 2cabe290` | ahead=10 | files=24 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/0345bd878f8966e8c22b151608a84c92634c0c20...2cabe290

### AI 总结重点(源码 diff 为据)
- **`GenerateResourceRequests` 把 `gpumem-percentage` 的取值判据从"< 0 或 > 100 才 clamp"改成"只有 > 100 才 clamp,且 0/负值走 unset 哨兵 101"**。旧逻辑里 `mempnums=0` 是合法值、会被原样写成 `mempnum=0`,进而向容器注入 `CUDA_DEVICE_MEMORY_LIMIT=0m`——而 hami-core 把 `0m` 读作"不限制显存",等于软切分失效。新逻辑对 `mempnums<=0` 记 error 并置 `mempnum=101`(与 `nvidia.com/gpumem: 0` 相同的"未设置"语义),让后续默认逻辑接管。这是直接落在 hook 边界上的软切分语义修正,不是纯校验。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  -					if mempnums < 0 || mempnums > 100 {
  +					if mempnums > 100 {
   						klog.ErrorS(nil, "memory percentage request out of range, clamping to 100", ...)
   						mempnum = 100
   					}
  -					mempnum = int32(mempnums)
  +					if mempnums > 0 {
  +						mempnum = int32(mempnums)
  +					} else {
  +						// 0 would inject CUDA_DEVICE_MEMORY_LIMIT=0m, which hami-core reads as "no limit"...
  +						klog.ErrorS(nil, "memory percentage request is not positive, ignoring it", ...)
  +						mempnum = 101
  +					}
   			}
   			if mempnum == 101 && memnum == 0 {
  ```
  </details>

- **vGPUmonitor v0/v1 spec 新增 `activeProcs()`,把所有 `DeviceMemory*` / `DeviceSmUtil` 求和的迭代范围从"裸切片"收窄为 clamp 后的活跃进程槽**。`procnum` 来自共享内存区、可能被写坏(负数或超过 `procs` 底层数组长度),旧 v0 直接 `range s.sr.procs`(遍历全数组含空槽)、旧 v1 用 `s.sr.procs[:int(s.sr.procnum)]`(未夹取,`procnum` 越界即 panic)。新 helper `min(max(procnum,0), len(procs))` 保证切片永不越界,指标只统计真实占用槽。
  <details><summary>代码依据 pkg/monitor/nvidia/v1/spec.go(v0 同型)</summary>

  ```diff
  +func (s Spec) activeProcs() []shrregProcSlotT {
  +	n := min(max(int(s.sr.procnum), 0), len(s.sr.procs))
  +	return s.sr.procs[:n]
  +}
   func (s Spec) DeviceMemoryContextSize(idx int) uint64 {
  -	for _, p := range s.sr.procs[:int(s.sr.procnum)] {   // v0 旧为 range s.sr.procs
  +	for _, p := range s.activeProcs() {
   		v += p.used[idx].contextSize
  ```
  </details>

- **scheduler `nodeManager.GetNode` 从"返回内部共享指针 `n`"改为"构造 `NodeInfo` 深拷贝再返回"**(`Node.DeepCopy()` + 逐设备 `DeepCopyDeviceInfos`)。旧代码在 `RLock` 下把内部 map 里的指针直接交出,调用方读/改与其他 goroutine 写并发触发 concurrent map read/write。改后调用方拿到的是隔离副本。这是调度器并发正确性修补,不改调度语义。
  <details><summary>代码依据 pkg/scheduler/nodes.go</summary>

  ```diff
  -	if n, ok := m.nodes[nodeID]; ok {
  -		return n, nil
  +	n, ok := m.nodes[nodeID]
  +	if !ok {
  +		return &device.NodeInfo{}, fmt.Errorf("node %v not found", nodeID)
   	}
  -	return &device.NodeInfo{}, fmt.Errorf("node %v not found", nodeID)
  +	nodeInfoCopy := &device.NodeInfo{ID: n.ID, Devices: make(map[string][]device.DeviceInfo, len(n.Devices))}
  +	if n.Node != nil { nodeInfoCopy.Node = n.Node.DeepCopy() }
  +	for k, v := range n.Devices { nodeInfoCopy.Devices[k] = device.DeepCopyDeviceInfos(v) }
  +	return nodeInfoCopy, nil
  ```
  </details>

- **昇腾 `Devices.Fit()` 在打分循环开头新增健康门:不健康的卡直接记 `common.CardNotHealth` 拒因并 `continue`**,不再进入 `checkType`/容量匹配。此前不健康设备也会走完全部匹配逻辑、可能被选中。与本仓 `kunlun`/`awsneuron` 的 `GenReason` 用 `len(devices)` 修多设备记账(#2292)是同一波"拒因计数准确化"的延续。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
   		klog.V(4).InfoS("scoring pod", "pod", ..., "device", dev.ID, ...)
  +		if !dev.Health {
  +			reason[common.CardNotHealth]++
  +			klog.V(5).InfoS(common.CardNotHealth, "pod", klog.KObj(pod), "device", dev.ID, "health", dev.Health)
  +			continue
  +		}
   		_, found, numa := npu.checkType(pod.GetAnnotations(), *dev, k)
  ```
  </details>

- **scheduler HTTP `checkBody` 从 `func(...)`(void)改为返回 `bool`,Predicate handler 据返回值提前 return**。旧代码里空 body 时 `checkBody` 写完 400 就 `return`——但这个 return 只跳出 `checkBody` 自身、handler 继续往下读空 body。改后 handler `if !checkBody(...) { return }` 才真正短路。属请求处理健壮性修补(commit 标题"Sorting Issue #2296"名不副实,靠 hunk 才还原真实改动)。
  <details><summary>代码依据 pkg/scheduler/routes/route.go</summary>

  ```diff
  -func checkBody(w http.ResponseWriter, r *http.Request) {
  +func checkBody(w http.ResponseWriter, r *http.Request) bool {
   	if r.Body == nil {
   		http.Error(w, "Please send a request body", 400)
  -		return
  +		return false
   	}
  +	return true
   }
   ...
  -		checkBody(w, r)
  +		if !checkBody(w, r) { return }
  ```
  </details>

- **Helm `values.yaml` 新增 `device-config.content` 字段:允许把整份 device-config.yaml 内容直接内联进 values,覆写 `files/device-config.yaml` 注入 `hami-scheduler-device` ConfigMap**(示例含 MIG `knownMigGeometries` 几何)。此前只能靠 chart 内文件,现支持 GitOps 风格纯 values 交付。属部署可用性,不改切分逻辑。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
  +# If content is set under device-config.content, it will be used as the device-config.yaml
  +# payload in the hami-scheduler-device ConfigMap instead of files/device-config.yaml...
  +device-config:
  +  content: ""
  ```
  </details>

- 另:`cmd/vGPUmonitor/metrics.go` 删除 client_golang 教程遗留脚手架(`ReallyExpensiveAssessmentOfTheSystemState` mock 及大段注释死码,#2263),纯清理;`ClusterManager` doc 注释重写为真实字段说明。无行为变化。

### 后续发展方向 [AI]
- **软切分的"边界值语义"仍在逐个堵漏,方向是与 hami-core hook 的约定对齐**:`gpumem-percentage=0` 这条证明团队在核对"平台层填了什么值 → hook 层读成什么行为",`0m=无限制` 这种隐式约定正被显式哨兵化。证据只覆盖 NVIDIA `gpumem-percentage` 这一路,未见 `gpucores` 百分比或昇腾侧是否有同类 `0=无限制` 隐患被同批处理。
- **调度器正在补并发正确性欠账(深拷贝 GetNode)**,暗示 HAMi scheduler 的读多写并发路径此前存在共享可变状态。证据仅 `GetNode` 一处,未见 `ListNodes`/打分路径是否也返回共享指针——若只补了 GetNode,并发隐患可能未清完。

## Project-HAMi/ascend-device-plugin: 5d5bad2d -> 771e19f8
- 比较: `5d5bad2d -> 771e19f8` | ahead=10 | files=11 | Release: —
- https://github.com/Project-HAMi/ascend-device-plugin/compare/5d5bad2d544a9725e064d68a4de28b6271628adb...771e19f8

### AI 总结重点(源码 diff 为据)
- **本期 0 行 `cmd/` 代码改动,全部是把昇腾 device-plugin 做成可独立分发的 Helm chart**:新增 `values.schema.json`(JSON Schema draft 2020-12,`required` 列表把 `image/daemonSet/rbac/runtimeClass/config/hamiVnpuCore/nodeConfig` 等全部设为必填,`additionalProperties:false` 禁止未知键)、GHCR chart-releaser 发布流水线、helm-lint PR 门禁、`README.md.gotmpl` + helm-docs 自动生成值表。方向是把这个"两生态交汇点"组件从"HAMi 主 chart 的附属"抬成有独立版本线的可安装单元。
  <details><summary>代码依据 charts/ascend-device-plugin/values.schema.json(新增)</summary>

  ```diff
  +    "required": [
  +        "image", "daemonSet", "rbac", "runtimeClass", "serviceAccount",
  +        "nodeSelector", "resources", "config", "nodeConfigMap",
  +        "hamiVnpuCore", "deviceConfig", "nodeConfig"
  +    ],
  +    "hamiVnpuCore": { "type": "object", "required": ["enabled"],
  +        "properties": { "enabled": { "type": "boolean" } },
  +        "additionalProperties": false },
  ```
  </details>

- **vNPU 软切配置面被 values 契约固化**:`values.yaml` 给每个键加 `@schema` 标注,`daemonSet.args` 从"仅 `--config_file`"扩为额外挂 `--node_config_file /node-config.yaml`——即每节点 `hami-vnpu-core: true` + `vDeviceCount` 的按节点软切开关正式进入 chart 契约(README 说明"Override `nodeConfig` to enable or customize hami-vnpu-core per node")。这与 2026-08-04 digest 里"昇腾软切分朝零配置可用打磨"是同一条线,本期把配置面从代码下沉到可校验的 chart values。
  <details><summary>代码依据 charts/ascend-device-plugin/values.yaml</summary>

  ```diff
   daemonSet: # @schema required:true;additionalProperties:false
     args: # @schema required:true
       - --config_file
       - /device-config.yaml
  +    - --node_config_file
  +    - /node-config.yaml
       - --v=4
  ```
  </details>

- 附带:README 删去 `## Monitoring`(`hami-vnpu-core` 软切模式下 `:9395/metrics` 端口的接入说明)整段,并移除各 `helm install` 示例里手动 `--set image.tag=v1.4.0`(改为默认取 chart `appVersion`)。前者是文档瘦身、把监控接线移出 chart 范围,不代表 metrics 能力被删。
  <details><summary>代码依据 charts/ascend-device-plugin/README.md</summary>

  ```diff
  -## Monitoring
  -
  -In `hami-vnpu-core` (soft slicing) mode, the device plugin exposes Prometheus-format
  -metrics on `:9395/metrics` (container port `monitorport`)...
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾 vNPU 组件在走"独立可分发 + 契约可校验"的产品化路径**,发布工程(GHCR / chart-releaser / schema 强校验 / helm-docs)先于能力迭代落地——本期虚拟化逻辑本身零改动,是纯打包成熟度信号。证据只覆盖 chart/CI 文件,`cmd/main.go` 与设备分配代码未动,不能据此推断 vNPU 软切能力有功能变化;需下几期看 `cmd/` 是否跟进 schema 里已声明的 `hamiVnpuCore`/`nodeConfig` 语义。

## 本期无实质改动(折叠)
<details><summary>3 仓无实质改动(保锚点)</summary>

- Project-HAMi/HAMi-core:无新提交(CUDA hook 内核本期静默,仍 5496322f)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HAMi × Volcano 集成路径静默)
- Project-HAMi/HAMi-WebUI:无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=2cabe290b6dd49843555fcbd0e1344970e19d978 branch=master release=v2.9.0 scanned=2026-08-05 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-05 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-08-05 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=771e19f836103727bc84d0bda29ba6a03538e5f2 branch=main release=— scanned=2026-08-05 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-05 -->
