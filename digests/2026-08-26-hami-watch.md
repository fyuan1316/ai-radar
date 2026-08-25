# HAMi diff 雷达 2026-08-26

## 摘要
- HAMi 主仓落地 **NUMA 对齐重选(NUMA refit)** 新能力(#2080/#2729/#2731):新增 `hami.io/numa-alignment` 注解(best-effort/strict)+ scheduler 新 `/refit` HTTP 路由 + device-plugin 侧 HTTPS 回调客户端,当 kubelet Topology Manager 把分配收窄到调度器没选中的 NUMA 副本时,由调度器在受限设备集上**重跑同一套 fit** 而非盲从 kubelet 选择。
- 注解解析硬化(#2765):`DecodeContainerDevices` 现拒绝空 UUID/空 type/负显存/负算力的畸形分配注解;设备锁定纳入 init 容器请求(#2755)。
- 其余 4 仓(HAMi-core / volcano-vgpu / ascend-device-plugin / HAMi-WebUI)本期无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增 NUMA refit 全链路:注解契约 `hami.io/numa-alignment` + scheduler `RefitNumaAllocation` + `/refit` 路由 + device-plugin `numa_refit_client`,GPU 软切分首次介入 kubelet Topology Manager 的 NUMA 对齐决策。证据见下。 https://github.com/Project-HAMi/HAMi/pull/2731
- Project-HAMi/HAMi [新能力] device-plugin 新增对 scheduler 的 mTLS/HTTPS 出站调用(`HAMI_SCHEDULER_ENDPOINT`/`HAMI_SCHEDULER_CA_FILE`/`HAMI_SCHEDULER_TLS_INSECURE`),这是节点组件首次主动回连调度器端点。 https://github.com/Project-HAMi/HAMi/pull/2729

## Project-HAMi/HAMi: 2d42fb43 -> 4bfa9437
- 比较: https://github.com/Project-HAMi/HAMi/compare/2d42fb43366252bea161000799e46bed103fad63...4bfa94371b3dd3adc2cad8265289a123e99d2c4f | ahead=17 | files=56 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)

- **新增 NUMA 对齐语义层:`hami.io/numa-alignment` 注解 + 三态枚举**。`pkg/util/numa_alignment.go` 定义 `NumaAlignmentMode`(`""`=None / `best-effort` / `strict`)。语义明确区分于既有 `nvidia.com/numa-bind`:后者是调度期请求多 GPU 同 NUMA 节点共置,前者是运行期处理"调度器选中的 GPU 与 kubelet Topology Manager 收窄后的可用副本不匹配"。best-effort=尽力重选、失败则退回 kubelet 选择;strict=启用 refit 时无法调和则**让 Pod admission 失败**。
  <details><summary>代码依据 pkg/util/numa_alignment.go</summary>

  ```diff
  +type NumaAlignmentMode string
  +const (
  +	NumaAlignmentNone       NumaAlignmentMode = ""
  +	NumaAlignmentBestEffort NumaAlignmentMode = "best-effort"
  +	NumaAlignmentStrict     NumaAlignmentMode = "strict"
  +)
  +// GetNumaAlignmentModeByPod returns the Pod's NUMA alignment mode ...
  +// ParseNumaAlignmentMode parses and validates a numa-alignment annotation
  +// value. Values are case-insensitive and surrounding whitespace is ignored.
  ```
  </details>

- **调度器新增受限 fit:`restrictNodeUsage` + `fitInRestrictedDevices`**(`pkg/scheduler/numa_refit.go`)。把节点设备集按调用方给的 `allowedUUIDs` 收窄(仅收窄同 `deviceType`,其他厂商设备保留,不误伤跨厂商请求),再跑**与正常调度完全相同的 policy-chain fit**(binpack/spread/mutex/numa 排序不变)。若受限集里根本没有该类型设备,返回 `AllowedSetUnmatched` 以区分"ID 不匹配(如误传 replica ID 而非物理 UUID)"与"真实容量耗尽"。
  <details><summary>代码依据 pkg/scheduler/numa_refit.go</summary>

  ```diff
  +const AllowedSetUnmatched = "AllowedDeviceSetUnmatched"
  +// restrictNodeUsage returns a copy of node whose devices of deviceType are
  +// limited to the physical device IDs in allowedUUIDs. Devices of other types
  +// are kept, so requests spanning several vendors keep fitting ...
  +func restrictNodeUsage(node *NodeUsage, deviceType string, allowedUUIDs []string) *NodeUsage {
  ```
  </details>

- **调度器落盘逻辑:`RefitNumaAllocation` 单 merge-patch 原子改注解 + resourceVersion 前置条件**(`pkg/scheduler/numa_refit_handler.go`)。调度器保持权威:同一 merge patch 同时更新 `hami.io/vgpu-devices-to-allocate` 与 `hami.io/vgpu-devices-allocated`,再改内存预留;patch 带 pod resourceVersion 前置条件,陈旧 refit 不会覆盖更新的分配(如 Allocate 已消费 to-allocate 条目),冲突即失败**不重试**;失败时注解与账目均不动。请求上限 `maxAllowedDeviceUUIDs = 512`。
  <details><summary>代码依据 pkg/scheduler/numa_refit_handler.go</summary>

  ```diff
  +const maxAllowedDeviceUUIDs = 512
  +func (s *Scheduler) RefitNumaAllocation(req device.NumaRefitRequest) device.NumaRefitResponse {
  +	if req.PodUID == "" || req.PodNamespace == "" || req.PodName == "" || req.NodeName == "" {
  +		return numaRefitFailure(nil, "incomplete refit request: ...")
  +	}
  +	// patches hami.io/vgpu-devices-to-allocate and hami.io/vgpu-devices-allocated
  +	// together in one merge patch, and only then moves the in-memory reservation.
  ```
  </details>

- **新增 scheduler↔device-plugin 有线协议:`NumaRefitRequest`/`NumaRefitResponse`**(`pkg/device/numa_refit.go`)。请求带 `ContainerIndex`(init 容器先计数,匹配 PodDevices 排序,须由当前 to-allocate 注解状态推导而非 kubelet 请求位)、`DeviceType`、`AllowedDeviceUUIDs`。响应 `ContainerDevices` 用 EncodeContainerDevices 格式;明确标注**该格式不带 CustomInfo,故 MIG 重选暂不在范围内**,与 #2080 的 hami-core-first 分阶段一致。
  <details><summary>代码依据 pkg/device/numa_refit.go</summary>

  ```diff
  +type NumaRefitRequest struct {
  +	PodUID       string `json:"podUID"`
  +	...
  +	ContainerIndex int   `json:"containerIndex"`
  +	DeviceType string     `json:"deviceType"`
  +	AllowedDeviceUUIDs []string `json:"allowedDeviceUUIDs"`
  +}
  +// ContainerDevices ... The format does not carry CustomInfo, so MIG
  +// selections are out of scope until MIG support gets its own design ...
  ```
  </details>

- **device-plugin 侧新增 HTTPS 回调客户端**(`pkg/device-plugin/.../numa_refit_client.go`)。新增三个环境变量:`HAMI_SCHEDULER_ENDPOINT`(空=禁用 refit,退化为仅日志)、`HAMI_SCHEDULER_CA_FILE`、`HAMI_SCHEDULER_TLS_INSECURE`(因 scheduler 用 admission webhook 自签证书,chart 默认置 true)。`numaRefitTimeout = 2s` 是节点唯一防线——因 kubelet 对 `GetPreferredAllocation` 无自身超时且串行 admit。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/numa_refit_client.go</summary>

  ```diff
  +	SchedulerEndpointEnvName    = "HAMI_SCHEDULER_ENDPOINT"
  +	SchedulerCAFileEnvName      = "HAMI_SCHEDULER_CA_FILE"
  +	SchedulerTLSInsecureEnvName = "HAMI_SCHEDULER_TLS_INSECURE"
  +	numaRefitPath = "/refit"
  +	numaRefitTimeout = 2 * time.Second
  ```
  </details>

- **`GetPreferredAllocation` 接入 refit 决策分支**(`pkg/device-plugin/.../server.go`)。当注解设备在 kubelet 可用集里找不到副本时,调 `plugin.tryNumaRefit`:refitErr(strict 或已提交但 kubelet 无法兑现)→ `PodAllocationFailed` 释放节点锁并让 admission 失败;拿到 refit 设备→写入响应;否则 `reportAnnotatedDeviceMismatch` 仅上报(检测态,保留 kubelet 自选,对应 #2080 未完成部分)。新增 `annotationIndices` 保留每条注解的原始 PodDevices 容器位以喂协议。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  +	refitDevices, refitErr := plugin.tryNumaRefit(ctx, pendingPod, annotationIndices[idx], req, err)
  +	switch {
  +	case refitErr != nil:
  +		if nodename != "" && pendingPod != nil {
  +			PodAllocationFailed(nodename, pendingPod, NodeLockNvidia)
  +		}
  +		return nil, refitErr
  +	case len(refitDevices) > 0:
  +		response.ContainerResponses = append(..., &...ContainerPreferredAllocationResponse{DeviceIDs: refitDevices})
  +	default:
  +		plugin.reportAnnotatedDeviceMismatch(pendingPod, idx, err)
  +	}
  ```
  </details>

- **注解解析硬化:`DecodeContainerDevices` 拒绝畸形/负值分配注解**(#2765,`pkg/device/devices.go`)。旧逻辑复用同一 `tmpdev` 变量且只在含逗号时解析;新逻辑:空段跳过、不含逗号即报错、空 UUID/空 type 报错、显存/算力为负报错,并每条 new 独立 `ContainerDevice`(消除跨迭代脏字段风险)。属分配注解入口的输入校验加固。
  <details><summary>代码依据 pkg/device/devices.go</summary>

  ```diff
  -	tmpdev := ContainerDevice{}
  -	if strings.Contains(val, ",") { ... tmpdev.UUID = tmpstr[0] ... contdev = append(contdev, tmpdev) }
  +	if val == "" { continue }
  +	if !strings.Contains(val, ",") { return nil, fmt.Errorf("malformed container device annotation segment: %q", val) }
  +	if tmpstr[0] == "" { return nil, fmt.Errorf("... missing device UUID") }
  +	if tmpstr[1] == "" { return nil, fmt.Errorf("... missing device type") }
  +	if devmem < 0 { return nil, fmt.Errorf("memory field must not be negative: %d", devmem) }
  +	if devcores < 0 { return nil, fmt.Errorf("core field must not be negative: %d", devcores) }
  +	tmpdev := ContainerDevice{UUID: tmpstr[0], Type: tmpstr[1], Usedmem: int32(devmem), Usedcores: int32(devcores)}
  ```
  </details>

- **vGPU 指标口径对齐(skill 文档,#2761)**(`skill/hami-vgpu-metrics-summary/SKILL.md`)。补齐 vGPUmonitor 运行时指标全集及 `--legacy-metrics=true` 旧名映射:新增 `hami_resource_quota_limit`、`hami_host_gpu_memory_controller_utilization_ratio`、`hami_container_device_memory_bytes`、`hami_container_device_utilization_ratio`、`hami_container_last_kernel_elapsed_seconds`、`hami_vgpu_memory_context/module/buffer_bytes`、`hami_mig_device_info` 等,并给出与 `HostGPUMemoryUsage`/`vGPU_device_memory_usage_in_bytes`/`MigInfo` 等旧名的一一对应。反映监控指标体系已扩展且保留向后兼容双轨。
  <details><summary>代码依据 skill/hami-vgpu-metrics-summary/SKILL.md</summary>

  ```diff
  +- `hami_resource_quota_limit`
  +- `hami_host_gpu_memory_controller_utilization_ratio` — GPU memory controller utilization
  +- `hami_container_device_memory_bytes` — container device memory usage
  +- `hami_mig_device_info` — MIG runtime identity per container
  +#### D. Backward-compatible legacy vGPU monitor metrics
  +- `vGPU_device_memory_usage_in_bytes` — vGPU memory usage per container
  ```
  </details>

- **其余修复(未展开 hunk,仅列)**:MIG 拓扑调度去重重复候选(#2751)、设备锁定纳入 init 容器请求(#2755,新增 `PodRequiresDevice`)、节点注解 patch 失败时不缓存为最新(#2545)、`PatchNodeAnnotations`/`RemoveNodeAnnotation` 加 nil node 检查(#2792)。

### 后续发展方向 [AI]
- **HAMi 软切分正从"调度期决策"下探到"运行期与 kubelet Topology Manager 协商"**:NUMA refit 让调度器在节点 admission 阶段被回调,重跑 fit 以对齐 NUMA 局部性。这是架构方向转变——device-plugin 首次主动 HTTPS 回连 scheduler(证据:`numa_refit_client.go` 三个 env + `/refit` 路由)。证据只覆盖 NVIDIA GPU 路径与非 MIG 场景;`NumaRefitResponse` 明确 MIG 因不带 CustomInfo 暂不支持,昇腾/寒武纪等是否复用同协议未见。
- **strict 模式把 NUMA 未对齐升级为 admission 失败**(证据:`server.go` 的 `PodAllocationFailed` + `return nil, refitErr`),意味着企业可将 NUMA 局部性作为硬约束,对延迟敏感/带宽敏感的推理负载是可用的确定性保障。但证据仅见 best-effort/strict 两态语义与失败释放节点锁逻辑,未见默认开关与 chart 侧灰度策略。
- **分配注解入口开始做防御式校验**(#2765),配合 #2545/#2792 的注解一致性修复,方向是提升多写者并发下注解账目的鲁棒性;未见是否引入 schema/webhook 级校验,目前仍是解析层逐字段兜底。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交</summary>

- Project-HAMi/HAMi-core:无新提交(锚点不变)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=4bfa94371b3dd3adc2cad8265289a123e99d2c4f branch=master release=v2.10.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=b216ba1be1b8e21488d1c7370ed3357b3049aad1 branch=main release=— scanned=2026-08-26 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4fb76ba16a1744b161e9e2fbfc0b9ec3a546dd9b branch=main release=— scanned=2026-08-26 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-26 -->
