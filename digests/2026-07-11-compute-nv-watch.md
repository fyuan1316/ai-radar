# NVIDIA 算力栈 diff 雷达 2026-07-11

## 摘要
- **k8s-device-plugin 提前支持 Rubin 架构**:`getArchFamily` 给 CUDA compute capability 13 返回 `"rubin"`,在 Blackwell(10/12)之后加入下一代 GPU 家族的 arch 字符串识别——设备发现/标签面已为 Rubin 铺路。同仓另修 MIG 设备 placement 解析:当现代驱动返回不透明 MIG UUID 且 NVML 取 handle 失败时,回退到解析 legacy UUID,并把原 NVML 错误一并 wrap 而非静默吞掉。
- **KAI-Scheduler 把 Dynamo DynamoGraphDeployment 的 gang 分组从 v1alpha1 收敛到通配版本 `*`**:一次覆盖 v1alpha1(Dynamo ≤1.1.x)、v1beta1(1.2.0+ 实际 own DGD 的版本)及未来版本,DGD API 升档时 gang grouping 不断。另修 `MaxNodeResourcesPredicate`:`SetMax` 改指针接收者并支持扩容,修掉"扩展资源只存在于部分节点时被漏算"的 bug。
- **gpu-operator 简化 driver 容器 OS tag 规则 + 常规版本 bump**:RHEL/Rocky 的 osTag 一律只取主版本号,删掉"RHEL <10 才带 minor"的分支;同时 driver 595.58.03→595.71.05、toolkit 全线接到 v1.20.0-rc.1。其余 5 仓 EMPTY(mig-parted 仅容器镜像 symlink 修复)。

## 当日重要改变
- NVIDIA/k8s-device-plugin [新能力] `getArchFamily` 新增 compute capability 13 → `"rubin"`,在 Blackwell 之后识别下一代 Rubin GPU 家族。https://github.com/NVIDIA/k8s-device-plugin/commit/c52135bbf85fe4bc7af4b0dfb3e2c3689c5a0ad8
- kai-scheduler/KAI-Scheduler [新能力/整合] Dynamo `DynamoGraphDeployment` 的 gang 分组注册版本从 `v1alpha1` 改为通配 `*`,覆盖 v1beta1(1.2.0+ own DGD 的版本)及未来版本(#1870)。https://github.com/kai-scheduler/KAI-Scheduler/commit/b63badc941faf424756d2e4e0d2348fccbca4793
- NVIDIA/gpu-operator [行为变更] RHEL driver 容器 OS tag 由"RHEL 10+ 才省 minor"改为 RHEL/Rocky 一律只用主版本号(如 rhel9 而非 rhel9.x),删除 `parseOSMajorVersion` 与 `>=10` 判据。https://github.com/NVIDIA/gpu-operator/commit/7d0402b9980e44d54518e829b717ed8661e72bf8

## NVIDIA/k8s-device-plugin: 10fd1c08 -> c52135bb
- 比较: 10fd1c08afa74932e0f949e540eca9d9953d9cec -> c52135bb | ahead=20 | files=220 | Release: v0.19.3
- Compare: https://github.com/NVIDIA/k8s-device-plugin/compare/10fd1c08afa74932e0f949e540eca9d9953d9cec...c52135bbf85fe4bc7af4b0dfb3e2c3689c5a0ad8

### AI 总结重点(源码 diff 为据)
- **新增 Rubin 架构字符串**:`getArchFamily(computeMajor, computeMinor)` 在 Blackwell 的 `case 10, 12` 后新增 `case 13: return "rubin"`。即 device-plugin 的 label/资源发现路径开始识别 CUDA compute capability 13 这代(NVIDIA 下一代 Rubin),此前会落到 `"undefined"`。纯识别层,尚未见针对 Rubin 的切分/调度特化逻辑。
  <details><summary>代码依据 internal/lm/resource.go</summary>

  ```diff
   	// The Blackwell GPU family is bifurcated into two cuda compute capabilities 10.0 and 12.0
   	case 10, 12:
   		return "blackwell"
  +	case 13:
  +		return "rubin"
   	}
   	return "undefined"
  ```
  </details>
- **MIG 设备 placement 解析:失败路径不再静默吞 NVML 错误(#1899)**:`getMigDeviceParts` 原逻辑是 `DeviceGetHandleByUUID` 成功才走 handle 解析、末尾 `return parseMigDeviceUUID(uuid)` 作兜底(NVML 失败时静默转字符串解析)。改后先判 `ret != SUCCESS`:此时回退解析 legacy `MIG-GPU-<parent>/<gi>/<ci>` 格式,且当 legacy 解析也失败时,把原 NVML 错误字符串 `nvml.ErrorString(ret)` 与解析错误一起 wrap 返回——现代驱动给的是不透明 MIG UUID(不含 placement 信息),这样出问题时能看到真正原因而非被掩盖。
  <details><summary>代码依据 internal/rm/health.go</summary>

  ```diff
  -	if ret == nvml.SUCCESS {
  -		parentHandle, ret := mig.GetDeviceHandleFromMigDeviceHandle()
  -		...
  -	}
  -	return parseMigDeviceUUID(uuid)
  +	if ret != nvml.SUCCESS {
  +		// Modern drivers assign opaque MIG UUIDs that carry no placement information,
  +		// so if parsing fails the NVML error above must not be masked
  +		parentUUID, gi, ci, err := parseMigDeviceUUID(uuid)
  +		if err != nil {
  +			return "", 0, 0, fmt.Errorf("failed to get MIG device handle for %s: %s; %w", uuid, nvml.ErrorString(ret), err)
  +		}
  +		return parentUUID, gi, ci, nil
  +	}
  +	parentHandle, ret := mig.GetDeviceHandleFromMigDeviceHandle()
  ```
  </details>

### 后续发展方向 [AI]
- Rubin arch 字符串先行落地,是 NVIDIA 硬件路线在 device-plugin 侧的例行占位;证据只覆盖 arch 字符串识别一处,未见 Rubin 专属的 MIG profile/time-slicing/MPS 配置,后续要盯该家族是否带来新的切分粒度。MIG placement 改动是可观测性/诊断硬化(现代不透明 UUID 场景下暴露 NVML 根因),非能力变化。files=220 主要是 CI actions(checkout@v6→v7、setup-helm、golang 1.26.4→1.26.5)批量 bump,非产品逻辑。

## kai-scheduler/KAI-Scheduler: 4e644c4d -> b63badc9
- 比较: 4e644c4dfcc87f9b44d1d1af22fa83e00e73ab08 -> b63badc9 | ahead=4 | files=17 | Release: v0.14.7
- Compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/4e644c4dfcc87f9b44d1d1af22fa83e00e73ab08...b63badc941faf424756d2e4e0d2348fccbca4793

### AI 总结重点(源码 diff 为据)
- **Dynamo `DynamoGraphDeployment` gang 分组改用通配版本(#1870,commit 标题只说 v1beta1,实际是 `*`)**:`NewDefaultPluginsHub` 里 DGD 的 GVK 注册项 `Version` 从 `v1alpha1` 改为 `*`,借 `GetPodGrouperPlugin` 的通配-版本 fallback 一次性覆盖 v1alpha1(Dynamo ≤1.1.x)、v1beta1(1.2.0+ 实际 serve/own DGD 的版本)与任何未来版本,均走 `skipTopOwnerGrouper`(Grove grouper,把元数据从 DGD 传播到 PodGang/PodClique)。目的:DGD API 升档时 gang grouping 不断。
  <details><summary>代码依据 pkg/podgrouper/podgrouper/hub/hub.go</summary>

  ```diff
  -	// Dynamo uses Grove Grouper and needs to propagate metadata from DynamoGraphDeployment to PodGang and PodClique.
  +	// Match every served version via the wildcard-version fallback in GetPodGrouperPlugin: v1alpha1 (Dynamo
  +	// <=1.1.x), v1beta1 (1.2.0+, which serves/owns the DGD), and any future version
   	table[metav1.GroupVersionKind{
   		Group:   "nvidia.com",
  -		Version: "v1alpha1",
  +		Version: "*",
   		Kind:    "DynamoGraphDeployment",
   	}] = skipTopOwnerGrouper
  ```
  </details>
- **`MaxNodeResourcesPredicate` 修"扩展资源仅存在于部分节点时被漏算"(#1852)**:`ResourceVector.SetMax` 从值接收者改为指针接收者,并在 `len(*v) < len(other)` 时把接收者向量扩容到 `other` 长度再逐元素取 max。原值接收者版本无法增长向量,导致某扩展资源(如 `example.com/foo`)只在少数节点上出现、且该节点较晚被扫到时,其索引未纳入 max,predicate 会错误接纳/拒绝。新增 test 覆盖"资源在 5 节点中仅 1 个存在、20 次乱序迭代"等场景。
  <details><summary>代码依据 pkg/scheduler/api/resource_info/resource_vector.go</summary>

  ```diff
  -func (v ResourceVector) SetMax(other ResourceVector) {
  -	for i := range min(len(v), len(other)) {
  -		if other[i] > v[i] {
  -			v[i] = other[i]
  +func (v *ResourceVector) SetMax(other ResourceVector) {
  +	if len(*v) < len(other) {
  +		extended := make(ResourceVector, len(other))
  +		copy(extended, *v)
  +		*v = extended
  +	}
  +	for i := range other {
  +		if other[i] > (*v)[i] {
  +			(*v)[i] = other[i]
  ```
  </details>
- **新增 5 套 Grafana 官方 dashboard + 导入脚本(观测面)**:`docs/metrics/grafana/` 加入 kai-scheduler-internals、queues-allocation(含 `kai_queue_allocated_gpus`、E2E 调度延迟 `kai_e2e_scheduling_latency_milliseconds`)、controller-runtime-workqueues、apiserver-scale、service-resources 五个 JSON,配 `hack/add-grafana-dashboards.sh` 一键 port-forward 导入(#1869)。纯文档/运维物料,非调度逻辑。

### 后续发展方向 [AI]
- Dynamo 整合从"锁 v1alpha1"转向"版本无关",说明 NVIDIA 把自家 Dynamo 推理框架的 DGD 当作 KAI 的一等 gang 调度对象长期维护(对标我们:推理编排 CRD 若要走 gang 调度,需在 podgrouper 侧显式注册 GVK+grouper)。证据覆盖注册项与注释,未展开 Grove grouper 如何传播 PodGang/PodClique 元数据。SetMax 修复是调度正确性 bug(扩展资源/异构节点场景),对多类型加速卡混布集群相关。Grafana dashboard 官方化是 KAI 走向可运维产品的信号。

## NVIDIA/gpu-operator: ee622d5c -> 7d0402b9
- 比较: ee622d5c1f6a035e8968677a49e8102fd94e88f4 -> 7d0402b9 | ahead=20 | files=93 | Release: v26.3.3
- Compare: https://github.com/NVIDIA/gpu-operator/compare/ee622d5c1f6a035e8968677a49e8102fd94e88f4...7d0402b9980e44d54518e829b717ed8661e72bf8

### AI 总结重点(源码 diff 为据)
- **RHEL/Rocky driver 容器 OS tag 统一只取主版本号**:`getOSTag`(nodepool.go)与 `getGPUNodeOSInfo`(state_manager.go)两处的 switch 从 `case "rocky"`/`case "rhel"`(RHEL 走 `parseOSMajorVersion` 判 `>=10` 才省 minor,否则保留完整 `osVersion`)合并为 `case "rocky", "rhel": osTagSuffix = strings.Split(osVersion, ".")[0]`,并删除 `parseOSMajorVersion` 辅助函数。即所有 RHEL 版本的 driver 镜像 tag 现在都只带主版本(rhel9),不再是 rhel9.4——driver 容器 OS 矩阵按大版本收敛,依赖 minor 粒度镜像的用户受影响。
  <details><summary>代码依据 internal/state/nodepool.go(state_manager.go 同构)</summary>

  ```diff
  -	osMajorVersion := strings.Split(osVersion, ".")[0]
   	var osTagSuffix string
  -	// If the OS is RockyLinux or RHEL 10 & above, we will omit the minor version
   	switch osRelease {
  -	case "rocky":
  -		osTagSuffix = osMajorVersion
  -	case "rhel":
  -		osMajorNumber, err := parseOSMajorVersion(osVersion)
  -		...
  -		if osMajorNumber >= 10 { osTagSuffix = osMajorVersion } else { osTagSuffix = osVersion }
  +	case "rocky", "rhel":
  +		osTagSuffix = strings.Split(osVersion, ".")[0]
   	default:
   		osTagSuffix = osVersion
   	}
  ```
  </details>
- **常规版本 bump 落进 CSV/values**:default driver 595.58.03→595.71.05(`values.yaml`、`config/samples`、CSV 里 driver-image sha 同步换);container-toolkit 全线 v1.19.1→v1.20.0-rc.1(CSV relatedImages、`CONTAINER_TOOLKIT_IMAGE` env、`values.yaml` toolkit.version);renovate 配置新增规则允许探测 toolkit 的 `-rc.N` 预发布 tag;e2e 加 `GPU_MODE` 默认 `gpu`、holodeck v0.3.4→v0.3.6。未命中 `clusterpolicy_types.go`,ClusterPolicy API 面本期无增删。
  <details><summary>代码依据 deployments/gpu-operator/values.yaml</summary>

  ```diff
  -  version: "595.58.03"
  +  version: "595.71.05"
   ...
   toolkit:
  -  version: v1.19.1
  +  version: v1.20.0-rc.1
  ```
  </details>

### 后续发展方向 [AI]
- OS tag 收敛到主版本,方向上是简化 driver 镜像发布矩阵(不再为 RHEL 每个 minor 出一套 tag),与昨日 R535 EOL 下架同属"驱动/OS 矩阵瘦身"的持续动作;证据覆盖 tag 构造两处与函数删除,未见对应 driver 镜像仓的 tag 命名是否同步改动(需回看 gpu-driver-container)。toolkit v1.20.0-rc.1 现已正式作为 gpu-operator 默认编排镜像(昨日仅 toolkit 仓切 RC,今日 operator 侧接线)。ClusterPolicy CRD 本期无字段变更。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓</summary>

- NVIDIA/nvidia-container-toolkit — ahead=2,仅 bump/CI/merge(锚点前移)
- NVIDIA/gpu-driver-container — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM(master)— 无新提交
- NVIDIA/mig-parted — ahead=4,仅容器镜像 symlink 修复(`/var/run`→`/run`,让 nvidia-smi 找到 persistenced socket 做 GPU reset)+ golang bump,无产品逻辑改动
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7d0402b9980e44d54518e829b717ed8661e72bf8 branch=main release=v26.3.3 scanned=2026-07-11 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=312b675b7c06fe7f9cfb9a80ab647040516e8b70 branch=main release=v1.20.0-rc.1 scanned=2026-07-11 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=65b0904e77aa95ac77f62a735d8a7aff2e276148 branch=main release=— scanned=2026-07-11 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=c52135bbf85fe4bc7af4b0dfb3e2c3689c5a0ad8 branch=main release=v0.19.3 scanned=2026-07-11 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=2607fc64e99547f604f201b66cefc06eab45090e branch=main release=v0.4.1 scanned=2026-07-11 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-11 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=bdb9a4bbce2f1ac22533c074f081c5a539fc14f0 branch=main release=v0.14.3 scanned=2026-07-11 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=b63badc941faf424756d2e4e0d2348fccbca4793 branch=main release=v0.14.7 scanned=2026-07-11 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-11 -->
