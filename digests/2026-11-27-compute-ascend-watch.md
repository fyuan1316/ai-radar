# 昇腾算力栈 diff 雷达 2026-11-27

## 摘要
- **ascend-device-plugin 的"重复设备检测"新增 CRI-O 运行时支持**,昇腾 device-plugin 第一次脱离 containerd/docker 的 OCI 客户端路径:新增 `kubeclient.CrioRuntime = "cri-o"` 常量与 `crio_client.go`(284 行新文件),走标准 CRI v1 `ListContainers`/`ContainerStatus(verbose=true)`,从 `Info["info"].runtimeSpec` 的 `Process.Env` 里反解 `ASCEND_VISIBLE_DEVICES`。因为 CRI 没有 containerd 的事件流,改成 1s 轮询 diff 容器集合来模拟 create/destroy 事件;并给 `ContainerEvent` 加了 `ContainerInfo` 字段把已解析快照直接带给 manager,省掉一次重复查询。**对我们产品的启示**:OpenShift 系底座只有 CRI-O,这是昇腾栈纳管 OCP/ACM 类环境的前置条件之一,此前这条路是断的。
- **A5 超节点"单卡复位把整机其余卡误隔离"的真因是掉卡设备被算进了 UB 整平面故障判定**。修复新增 `isCardDrop()`(同时看 `device.CardDrop` 瞬时标志和 `FaultCodes` 里的 `CardDropFaultCode`)与 `isHyperPlaneOverallFault()`,把掉卡/复位中的设备**排除出**"是否全卡 UB 端口 down"的全量判定,并且 UBSubHeal 故障码只写给确实带 `UBPortDownCode` 的设备——否则没有 UB down 的卡会永久挂着 sub-heal 码、再也升不回 separate。
- **npu-exporter 的 `npu_chip_info_health_status` 指标语义扩档**:DCMI 健康码从"0/非0"二值判定改成 Healthy(0)/Warning(1)/Alarm(2)/Critical(3) 四档,并把档位作为新 label `status` 挂到指标上。**这是对既有指标的 label schema 变更**,现有 Grafana 面板/录制规则按 label 集精确匹配的会受影响;Telegraf 输出路径更是把 health 从设备主指标里**摘出来另发一条**带 `status` tag 的 metric。

## 当日重要改变
- mind-cluster/ascend-device-plugin [新能力] 重复设备检测支持 CRI-O:新增常量 `CrioRuntime = "cri-o"`、`GetContainerRuntime()` 识别 `cri-o://` 前缀、`NewClient()` 按 `RuntimeType` 分流到 `NewCrioClient()`;新文件 `pkg/duplicatedetector/containerruntime/crio_client.go`(284 行)+ `crio_client_test.go`(411 行),并新增 `k8s.io/cri-api` 依赖(新增 `LICENSES/vendor/k8s.io/cri-api/LICENSE`)。 https://gitcode.com/Ascend/mind-cluster/commit/3491c063e506498f57ebb17df2116795c90f2bdd
- mind-cluster/ascend-device-plugin [行为变更] A5 单卡复位误隔离修复:`a950HyperPlaneNewOverallFaultModify` 的全量判定从"遍历所有设备、有一个缺 `UBPortDownCode` 就不算整平面故障"改为先 `isCardDrop()` 跳过掉卡设备,且全是掉卡时返回 false(不再误判)。 https://gitcode.com/Ascend/mind-cluster/commit/648bc8b2708a3827789d2f51e5ea0f13ba002dad
- mind-cluster/npu-exporter [API变更] `npu_chip_info_health_status` 新增 `status` label(`Healthy`/`Warning`/`Alarm`/`Critical`/`Unknown`),`descHealthStatus` 从 `BuildDesc` 改 `BuildDescWithLabel(cardLabelForHealthStatus)`;`TelegrafMetric` 新增 `ExtraLabels map[string]string` 并在 `buildTags` 里合并。 https://gitcode.com/Ascend/mind-cluster/commit/4478aca94015334b362172cdbee5962abbdfed84
- mind-cluster/k8s-rdma-shared-dev-plugin [行为变更] Atlas 950 SP500 DPU 掉卡检测判据整体换掉:从"按网卡 `card_type`(A5Server/A5Pod400G/A5Pod200G)硬编码期望物理口数"改为"遍历 `hinic$i` 读 `hinicadm5 cfg_template` 的配置模板名",且比较从 `==` 放宽为 `>=`。**本期扫描盲区**:该 component 不在 PATHPREFIX 清单里(第 4 次漏项),靠不带 prefix 的全量 compare 才发现。 https://gitcode.com/Ascend/mind-cluster/commit/895ad9c42521cf091adee36be30c07ddd7c9245d
- mind-cluster/infer-operator [新能力] InferService / InferServiceSet 补 Event 上报:新增 Created / Deleted / Ready 翻转三类事件,Reason 常量化(`InferServiceCreatedReason` 等 8 个),Reconciler 结构体加 `startTime time.Time` + `deletedEvents sync.Map` 做"仅本进程启动后创建"与"每对象只报一次删除"的去重。 https://gitcode.com/Ascend/mind-cluster/commit/29a8efbc15967a9df37e5882cfd4b48adfd19b83
- mind-cluster [架构方向] CI 的 API 兼容性扫描从独立 workflow 并入主门禁:删除 `.gitcode/workflows/api_scan.yml`(原本是 `pull_request_target` + 评论 `^api_scan$` 手动触发),同样的 `openlibing/api-scan-action@v1.0.2` 作为 `api-scan` job 进了 `PR-pipeline_mindcluster.yml` 的 stage_1,**变成每个 PR 必跑**。 https://gitcode.com/Ascend/mind-cluster/commit/8e08b0213d68095fee16b6141b137482f92f657f

## mind-cluster: 50a33a26 -> 629a0324
- 比较: 50a33a268d77a14bb8bb42bd32d24452b2b1e54a..629a0324 | tag: v26.3.0-beta.2(未跨档) | commits=26 | truncated=false
- 源链接: https://gitcode.com/Ascend/mind-cluster/compare/50a33a268d77a14bb8bb42bd32d24452b2b1e54a...629a03245ffb8f2b8bda040305fbb6c74051556c
- 改动分布(全量 76 文件,不限 PATHPREFIX):docs 21 / ascend-clusterops-agent 18(**全是版权头,无逻辑**) / ascend-device-plugin 17 / npu-exporter 8 / infer-operator 5 / ascend-faultdiag 3 / .gitcode 3 / k8s-rdma-shared-dev-plugin 1

### AI 总结重点(源码 diff 为据)

- **CRI-O 客户端走的是"轮询 + 集合 diff"而不是事件订阅**,这是与 containerd 路径的核心架构差异。`WatchContainerEvents` 起 1s ticker,每次 `ListContainers(State=RUNNING)` 拿 ID 集合,与上次集合做差:消失的发 `ContainerEventDestroy`,新增的**先 `ParseSingleContainer` 解析成功才**发 `ContainerEventCreate` 并记入 `next`(解析失败就不记,下一轮重试)。list 失败时 `previous` 原样保留,不会把活容器误判为已删除。代价写在 README 里:"两次成功查询之间的短命容器可能无法感知"。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/duplicatedetector/containerruntime/crio_client.go</summary>

  ```diff
  +func (c *crioClient) reconcileContainers(ctx context.Context, previous, current map[string]struct{},
  +	handler types.EventHandler) map[string]struct{} {
  +	// Keep raw lifecycle state separate from parsing success. Temporary status errors
  +	// must not remove a live container, and failed new containers are retried next poll.
  +	next := make(map[string]struct{})
  +	for id := range previous {
  +		if _, exists := current[id]; exists {
  +			next[id] = struct{}{}
  +			continue
  +		}
  +		handler(types.ContainerEvent{Type: types.ContainerEventDestroy, ContainerID: id,
  +			Namespace: crioNamespace, Timestamp: time.Now()})
  +	}
  +	for id := range current {
  +		if _, exists := previous[id]; exists {
  +			continue
  +		}
  +		info, err := c.ParseSingleContainer(ctx, id)
  +		if err != nil {
  +			hwlog.RunLog.Warnf("retry new CRI-O container %s on next poll: %v", id, err)
  +			continue
  +		}
  +		handler(types.ContainerEvent{Type: types.ContainerEventCreate, ContainerID: id,
  +			Namespace: crioNamespace, Timestamp: time.Now(), ContainerInfo: info})
  +		next[id] = struct{}{}
  +	}
  +	return next
  +}
  ```
  </details>

- **设备信息的提取路径:优先环境变量,回退 OCI spec 扫设备节点**。`ParseSingleContainer` 把 `ContainerStatus` 的 `Info["info"]` 反序列化出 `runtimeSpec`,**从后往前**遍历 `Process.Env` 找第一个 `ASCEND_VISIBLE_DEVICES=`(取最后一次赋值,语义正确),交给 `parser.ParseAscendDeviceInfo`;没有该环境变量才 `filterNPUDevices(runtimeSpec)` 从 spec 里的设备列表过滤。Pod 身份靠 CRI label `io.kubernetes.pod.name`/`io.kubernetes.pod.namespace` 还原,`Namespace` 字段固定填 `cri-o`(与 containerd 的 `k8s.io` 命名空间语义对齐)。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/duplicatedetector/containerruntime/crio_client.go</summary>

  ```diff
  +	var detail struct {
  +		RuntimeSpec *oci.Spec `json:"runtimeSpec"`
  +	}
  +	if err := json.Unmarshal([]byte(resp.Info["info"]), &detail); err != nil {
  +		return nil, fmt.Errorf("decode CRI-O container %s info: %w", id, err)
  +	}
  +	labels := resp.Status.Labels
  +	info := &types.ContainerNPUInfo{
  +		ID: resp.Status.Id, Name: labels[kubeContainerNameLabel], Namespace: crioNamespace,
  +		PodName: labels[kubePodNameLabel], PodNS: labels[kubePodNamespaceLabel],
  +	}
  +	if detail.RuntimeSpec.Process != nil {
  +		envs := detail.RuntimeSpec.Process.Env
  +		for i := len(envs) - 1; i >= 0; i-- {
  +			env := strings.TrimSpace(envs[i])
  +			if strings.HasPrefix(env, api.AscendDeviceInfo+"=") {
  +				info.Devices = parser.ParseAscendDeviceInfo(env, id)
  +				break
  +			}
  +		}
  +	}
  +	if len(info.Devices) == 0 {
  +		info.Devices = filterNPUDevices(detail.RuntimeSpec)
  +	}
  ```
  </details>

- **socket 路径做了相当保守的安全加固**,只认 `/var/run -> /run` 这一种系统别名,且要求 `/var/run` symlink 与 `/var` 目录都归 root、`/var` 的 group/other 写位为 0:`normalizeCrioSocketPath` 要求绝对且 `filepath.Clean(path) == path`(堵 `..`/重复斜杠),非 `/var/run/` 前缀直接放行给后续 `checkSockFile`;是 `/var/run/` 前缀时,readlink 结果必须精确等于 `/run` 或 `../run`,否则报 "only supports the standard /var/run to /run alias"。**部署含义**:自建 symlink 或非标准 socket 布局会被直接拒绝启动该检测器,README 已明确要求把宿主机 socket 挂到 `/run/crio`(容器内 `/var/run` 是真实目录时挂 `/var/run/crio`)。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/duplicatedetector/containerruntime/crio_client.go</summary>

  ```diff
  +func normalizeCrioSocketPath(path string) (string, error) {
  +	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
  +		return "", fmt.Errorf("CRI-O endpoint must be a clean absolute Unix socket path")
  +	}
  +	if !strings.HasPrefix(path, "/var/run/") {
  +		return path, nil
  +	}
  +	target, err := os.Readlink("/var/run")
  +	if err != nil || (target != "/run" && target != "../run") {
  +		return "", fmt.Errorf("CRI-O endpoint only supports the standard /var/run to /run alias")
  +	}
  +	owner, ok := info.Sys().(*syscall.Stat_t)
  +	parent, parentErr := os.Lstat("/var")
  +	if !ok || owner.Uid != 0 || parentErr != nil || !parent.IsDir() || parent.Mode().Perm()&0022 != 0 {
  +		return "", fmt.Errorf("unsafe /var/run alias or parent")
  +	}
  ```
  </details>

- **manager 侧同步把"事件携带快照"变成一条正式入缓存路径**:`watchContainerEvents` 收到 create 事件时,若 `event.ContainerInfo != nil` 就直接 `storeContainerInfo` 并 `break`,**不再**走 `HandleNewContainer`(后者带最多 `maxRetries` 次重查)。`HandleNewContainer` 的尾段被抽成 `storeContainerInfo`,两条路径共用去重/告警逻辑。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/duplicatedetector/manager.go</summary>

  ```diff
   		case types.ContainerEventCreate:
   			hwlog.RunLog.Infof("new container detected: %s", event.ContainerID)
  +			if event.ContainerInfo != nil {
  +				m.storeContainerInfo(event.ContainerInfo, event.Namespace)
  +				break
  +			}
   			if err := m.HandleNewContainer(ctx, event.ContainerID, event.Namespace); err != nil {
  -	if info == nil || len(info.Devices) == 0 {
  -		return nil
  -	}
  +	m.storeContainerInfo(info, namespace)
  +	return nil
  +}
  +
  +func (m *Manager) storeContainerInfo(info *types.ContainerNPUInfo, namespace string) {
  ```
  </details>

- **A5 UB 整平面故障判定:掉卡设备必须"弃权"而不是"投反对票"**。旧逻辑用一个 `allHaveHyperPlaneFaultCode` 标志遍历全部设备,只要有一张卡没有 `UBPortDownCode` 就认为不是整平面故障——但复位中的卡**查不到 UB 端口状态**,必然缺这个码,于是单卡复位会让其余卡从 sub-heal 降级成 separate(被隔离)。新 `isHyperPlaneOverallFault` 对掉卡设备 `continue` 跳过,并用 `reportable` 标志保证"一张可上报的卡都没有"时返回 false。掉卡判定本身也做成双条件 `device.CardDrop || Contains(FaultCodes, CardDropFaultCode)`,注释说明理由是**掉卡故障码会留存到故障恢复,而 `CardDrop` 标志每周期重建**,两者都要看。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go</summary>

  ```diff
  -func a950HyperPlaneNewOverallFaultModify(devices []*NpuDevice) {
  -	allHaveHyperPlaneFaultCode := true
  +func isCardDrop(device *NpuDevice) bool {
  +	return device.CardDrop || Int64Tool.Contains(device.FaultCodes, CardDropFaultCode)
  +}
  +
  +func isHyperPlaneOverallFault(devices []*NpuDevice) bool {
  +	reportable := false
   	for _, device := range devices {
  -		if !Int64Tool.Contains(device.FaultCodes, UBPortDownCode) {
  -			allHaveHyperPlaneFaultCode = false
  +		if isCardDrop(device) {
  +			hwlog.RunLog.Infof("device %d is dropped or resetting, excluded from the overall judgment",
  +				device.LogicID)
  +			continue
   		}
  +		if !Int64Tool.Contains(device.FaultCodes, UBPortDownCode) {
  +			return false
  +		}
  +		reportable = true
   	}
  -	if allHaveHyperPlaneFaultCode {
  +	return reportable
  +}
  ```
  </details>

- **同一提交还修了一个"sub-heal 码写错对象导致永久卡死"的问题**:整平面故障成立时,原来会给循环里所有设备都补 `UBSubHealFaultCode`;新代码先判 `if !Contains(device.FaultCodes, UBPortDownCode) { continue }`。注释给的理由很硬:sub-heal 码的**唯一恢复路径是 UB port down 故障的 recover 事件**,没有 down 码的设备拿到 sub-heal 后永远不会被清除,也就再也无法升级成 separate 故障。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go</summary>

  ```diff
   				updateDeviceFaultTimeMap(device, tmpFaultInfo, false)
   			}
  +			// the sub heal fault code is written only to the devices that are in the UB port down
  +			// state: its only recovery path is the recover event of the UB port down fault code, so
  +			// a device without it would keep the sub heal fault code forever and could never be
  +			// promoted to the separate fault later
  +			if !Int64Tool.Contains(device.FaultCodes, UBPortDownCode) {
  +				continue
  +			}
   			if !Int64Tool.Contains(device.FaultCodes, UBSubHealFaultCode) {
  ```
  </details>

- **npu-exporter 健康状态从二值变四档,`getHealth` 返回值由 1 个变 2 个**:`(healthClass, statusLabel)`。`healthClass` 仍是老的 Healthy/UnHealthy/Unknown 三态(喂给 `getHealthCode` 算指标数值,**数值语义不变、向后兼容**),新的 `statusLabel` 才区分 Warning(DCMI 码 1)/Alarm(2)/Critical(3)。注意 DCMI 码 1~3 全部映射成 `colcommon.UnHealthy`——**即 Warning 级别也会被当成不健康**,这点和 npu-dra-plugin 那边可配阈值 `unhealthyHealthCodeThreshold`(默认 2,即 Warning 仍算健康)的判定**不一致**,同一集群里 exporter 指标和 DRA 设备健康状态可能对不上。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_npu.go</summary>

  ```diff
  -func getHealth(logicID int32, dmgr devmanager.DeviceInterface) string {
  +func getHealth(logicID int32, dmgr devmanager.DeviceInterface) (healthClass string, statusLabel string) {
   	health, err := dmgr.GetDeviceHealth(logicID)
   	if err != nil {
  -		return colcommon.Unknown
  +		return colcommon.Unknown, colcommon.Unknown
   	}
  -	if health != 0 {
  -		return colcommon.UnHealthy
  +	switch health {
  +	case healthCodeHealthy:
  +		return colcommon.Healthy, colcommon.Healthy
  +	case healthCodeWarning:
  +		return colcommon.UnHealthy, colcommon.Warning
  +	case healthCodeAlarm:
  +		return colcommon.UnHealthy, colcommon.Alarm
  +	case healthCodeCritical:
  +		return colcommon.UnHealthy, colcommon.Critical
  +	default:
  +		return colcommon.Unknown, colcommon.Unknown
   	}
  -	return colcommon.Healthy
   }
  ```
  </details>

- **Prometheus 侧是"给既有指标加 label",Telegraf 侧是"拆出独立 metric"**,两条输出路径的兼容性代价不同。Prometheus:`descHealthStatus` 改用 `BuildDescWithLabel(cardLabelForHealthStatus)`(= `CardLabel` + `"status"`),上报时 `append(cardLabel, cache.HealthStatusLabel)`;testdata 的期望输出可见 `npu_chip_info_health_status{...,status="Healthy",vdie_id=""}`,**既有面板的精确 label 匹配会失效**。Telegraf:原先写进设备主 metric 的 `descHealthStatus` 字段被删掉,改成单独 `NewDeviceMetric` + `ExtraLabels{"status": ...}` 再 `ch <- healthMetric`,**消费端会看到多出一条 series**。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_npu.go + platforms/inputs/npu/npu.go</summary>

  ```diff
  -	descHealthStatus  = colcommon.BuildDesc("npu_chip_info_health_status", "the npu health status")
  +	descHealthStatus = colcommon.BuildDescWithLabel("npu_chip_info_health_status", "the npu health status",
  +		cardLabelForHealthStatus)
  @@ UpdateTelegraf
  -		doUpdateTelegrafWithValidateNum(metric.Fields, descHealthStatus, float64(getHealthCode(cache.HealthStatus)), "")
  +		healthMetric := colcommon.NewDeviceMetric(cache.chip.LogicID)
  +		healthMetric.ExtraLabels = map[string]string{
  +			"status": cache.HealthStatusLabel,
  +		}
  +		doUpdateTelegrafWithValidateNum(healthMetric.Fields, descHealthStatus,
  +			float64(getHealthCode(cache.HealthStatus)), "")
  +		ch <- healthMetric
  @@ npu.go buildTags
  +	for key, value := range data.ExtraLabels {
  +		tags[key] = value
  +	}
  ```
  </details>

- **DPU 掉卡检测:判据从"网卡 sysfs card_type"换成"hinic 配置模板名",且比较从等值放宽为 `>=`**。旧逻辑经由 `get_eth_name_by_hca_name` 找网卡名,再读 `/sys/class/net/$eth/device/card_type` 或 `/sys/class/net/$eth/card_type`,按 `A5Server`/`A5Pod400G*`/`A5Pod200G*` 映射 `phy_num` 4/4/2,最后 `card_num == phy_num` 才算正常。新逻辑完全不碰 sysfs:遍历 `hinic$i` 跑 `hinicadm5 cfg_template` 取 `Current` 索引对应的模板名(如 `ETH_2X400GR4_UBC_4DAVID_2HOST`),按模板映射 `expected_phy_num`(2 或 4),未知模板置 0 **直接跳过检测**;判定改成 `card_num >= expected_phy_num` 才算正常。另加 `card_num == 0` 时 skip。**风险点**:未识别的新模板会静默不检测(返回 `false:...expected_phy_num=0`),且 `>=` 让"卡数多于预期"也算正常。
  <details><summary>代码依据 component/k8s-rdma-shared-dev-plugin/pkg/fault/scripts/fault_detection.sh</summary>

  ```diff
  -	eth_name=$(get_eth_name_by_hca_name $hca)
  -	device_card_type_path="/sys/class/net/$eth_name/device/card_type"
  -	case "$card_type" in
  -		A5Server)   phy_num=4 ;;
  -		A5Pod400G*) phy_num=4 ;;
  -		A5Pod200G*) phy_num=2 ;;
  -	esac
  +	for((i=0;i<$card_num;i++))
  +	do
  +		cfg_template_index=$(hinicadm5 cfg_template -i hinic$i 2>/dev/null | grep -oP "Current[^0-9]*\K[0-9]+")
  +		cfg_template=$(hinicadm5 cfg_template -i hinic$i 2>/dev/null | grep -oP "Template\[ ${cfg_template_index}\]: \K\S+")
  +	done
  +	case $cfg_template in
  +		ETH_2X400GR4_UBC_4DAVID_2HOST|ETH_4X200GR2_UBC_4DAVID_2HOST) expected_phy_num=2 ;;
  +		ETH_2X400GR4_UBC_2DAVID_1HOST|ETH_4X200GR2_UBC_2DAVID_1HOST) expected_phy_num=4 ;;
  +		ETH_2X400GR4_UBC_2HOST_UB_EXP|ETH_4X200GR4_UBC_2HOST_UB_EXP) expected_phy_num=4 ;;
  +		*) expected_phy_num=0 ;;
  +	esac
  -	if [[ "$card_num" -eq "$phy_num" ]]; then
  +	if [[ "$card_num" -ge "$expected_phy_num" ]]; then
   		echo "false:no card drop detected, card num=$card_num"
  ```
  </details>

- **infer-operator 的 Event 去重逻辑比"报个事件"要讲究**:`createdWhileRunning` 用 `Status.ObservedGeneration == 0 && CreationTimestamp.After(r.startTime)` 双条件,注释明确说"ObservedGeneration 为 0 只能证明 status 还没写过,也会匹配 controller 启动前就存在的对象",所以必须叠加创建时间比对;`emitDeletedEvent` 用 `sync.Map` 的 `LoadOrStore` 保证每个 NamespacedName 只报一次(理由:对象已消失时构造的最小引用**没有 UID,K8s 的事件聚合失效**),而 `getInferService` 成功拿到对象时会 `deletedEvents.Delete(key)`,让"删掉又重建"的对象还能再报一次删除。
  <details><summary>代码依据 component/infer-operator/pkg/controller/v1/inferservice_controller.go</summary>

  ```diff
  +func (r *InferServiceReconciler) createdWhileRunning(is *apiv1.InferService) bool {
  +	if is.Status.ObservedGeneration != 0 || is.CreationTimestamp.IsZero() {
  +		return false
  +	}
  +	return is.CreationTimestamp.Time.After(r.startTime)
  +}
  +
  +func (r *InferServiceReconciler) emitDeletedEvent(obj runtime.Object, key types.NamespacedName, msg string) {
  +	if _, loaded := r.deletedEvents.LoadOrStore(key, struct{}{}); loaded {
  +		return
  +	}
  +	r.emitEvent(obj, corev1.EventTypeNormal, common.InferServiceDeletedReason, msg)
  +}
  ```
  </details>

- **Ready 条件翻转只比 `Status` 字段,不比 Reason/Message**:`readyConditionTransitioned` 显式注释"Ready 还是 False 时进度消息的更新不应产生重复事件";首次出现的 Ready=False 算一次翻转(发 Warning),首次 Ready=True 则由 Created 事件覆盖、不重复发。事件发送在 `updateStatusWithRetry` **成功之后**,避免 status 写失败却已经广播。
  <details><summary>代码依据 component/infer-operator/pkg/controller/v1/inferservice_controller.go</summary>

  ```diff
  -	return r.updateStatusWithRetry(ctx, is, newStatus)
  +	created := r.createdWhileRunning(is)
  +	newCondition := meta.FindStatusCondition(newStatus.Conditions, string(common.InferServiceReady))
  +	transitioned := newCondition != nil && readyConditionTransitioned(is.Status.Conditions, *newCondition)
  +	if err := r.updateStatusWithRetry(ctx, is, newStatus); err != nil {
  +		return err
  +	}
  +	if created {
  +		r.emitEvent(is, corev1.EventTypeNormal, common.InferServiceCreatedReason, ...)
  +	}
  +	if transitioned {
  +		eventType := corev1.EventTypeNormal
  +		if newCondition.Status == metav1.ConditionFalse {
  +			eventType = corev1.EventTypeWarning
  +		}
  +		r.emitEvent(is, eventType, newCondition.Reason, newCondition.Message)
  +	}
  ```
  </details>

- **CI:API 兼容性扫描由"可选/手动"升为"PR 必过门禁"**,同时 UT 镜像从一堆日期各异的通用镜像(`mindxdl_DT_20240124`、`mindxdl_go1207_ub22_ut_20260421_cluster`、`SDK_20260113_1`)统一切到两个按日期标记的精简专用镜像 `mindcluster-ut-cpp-x86_64-202611250842` / `mindcluster-ut-python-x86_64-202611250842`;faultdiag 的 python UT 也并到同一个 python 镜像上,不再单独用 SDK 镜像。
  <details><summary>代码依据 .gitcode/workflows/PR-pipeline_mindcluster.yml(api_scan.yml 被 removed)</summary>

  ```diff
  +      api-scan:
  +        name: api-scan task
  +        runs-on: [ self-hosted, default, x86, cpu=8 ]
  +        steps:
  +          - name: api-scan
  +            uses: openlibing/api-scan-action@v1.0.2
  -  img_ut_cpp_x86: "swr.../mindx_x86_runtime_dt:mindxdl_DT_20240124"
  -  img_ut_python_x86: "swr.../mindx_x86:mindxdl_go1207_ub22_ut_20260421_cluster"
  -  img_ut_faultdiag_python_x86: "swr.../mindx_x86:SDK_20260113_1"
  +  img_ut_cpp_x86: "swr.../mindx_image:mindcluster-ut-cpp-x86_64-202611250842"
  +  img_ut_python_x86: "swr.../mindx_image:mindcluster-ut-python-x86_64-202611250842"
  +  img_ut_faultdiag_python_x86: "swr.../mindx_image:mindcluster-ut-python-x86_64-202611250842"
  ```
  </details>

- **faultdiag 小修:掉卡检查器不再往结果里塞 `chains` 字段**,同时删掉 `from ascend_fd.utils.i18n import LANG` 和 `_format_link_key(...)` 调用。等于把"按语言拼因果链 key"的输出从 `LostDeviceChecker` 摘掉,大概率是上层改成统一按 code 查 kg-config 渲染,避免在 checker 里固化语言。另有 kg-config.json 一处中文括号补全(风扇故障建议文案)。
  <details><summary>代码依据 component/ascend-faultdiag/src/ascend_fd/pkg/parse/knowledge_graph/prechecker/lost_device_checker.py</summary>

  ```diff
  -from ascend_fd.utils.i18n import LANG
  -        link = self._format_link_key(entities_attribute.get(f"cause_{LANG}", ""), code)
                       "events_attribute": events_attribute,
  -                    "chains": {self.source_device: link},
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾栈正在补齐"非 containerd 底座"的纳管能力,但只走到了可观测/一致性检测这一层**。证据只覆盖 `duplicatedetector`(重复设备挂载检测)这一个消费方接了 CRI-O:`kubeclient.GetContainerRuntime()` 新识别 `cri-o://`、`NewClient` 分流。**未见**设备挂载主路径(Ascend Docker Runtime / `ASCEND_VISIBLE_DEVICES` 注入)有 CRI-O 适配改动,也未见 DaemonSet yaml 把 crio.sock 挂载进去(README 只给了手动挂载说明)。所以"昇腾能跑在 OpenShift 上"这个结论本期 diff 还不支持。
- **A5/Atlas 950 超节点的 UB 故障状态机仍在高频修补,核心难点是"复位中的设备不可观测"**。本期两处修复(整平面判定排除掉卡设备、sub-heal 码只写给有 down 码的设备)都是同一类 bug:设备临时不可查询时,被当成了"确定没有故障"。再加上 k8s-rdma-shared-dev-plugin 的 DPU 掉卡检测也在换判据,说明 UB/DPU 这套 fabric 的健康语义还没稳定。**对我们产品的启示**:如果要做多厂商统一的 fault 语义层,昇腾这边"掉卡"与"端口 down"必须当成两个独立维度建模,不能折叠成一个 unhealthy 位。证据只覆盖 device-plugin 与 rdma 插件的 diff,未看 noded/clusterd 侧消费这些故障码的逻辑。
- **健康状态分级(Warning/Alarm/Critical)正在从 DRA 插件扩散到 exporter,但两边阈值语义不统一**。exporter 把 DCMI 码 1(Warning)就判 UnHealthy;npu-dra-plugin(见 2026-11-26 期)的 `unhealthyHealthCodeThreshold` 默认 2,Warning 仍算健康。同一集群会出现"Prometheus 报不健康、DRA ResourceSlice 报健康"。预计后续会有一次对齐(要么 exporter 也引入阈值配置,要么 DRA 默认值下调),目前**无 diff 证据**指向哪一边,仅从两边常量定义推断。
- **CI 把 API 兼容性扫描提为必过门禁,是"组件 API 要开始当契约管"的信号**。证据只是 workflow 文件的 job 迁移(`openlibing/api-scan-action` 从可选 workflow 进 stage_1),没有看到配套的 API 基线文件或白名单提交;对我们判断"昇腾组件的 ConfigMap/CRD 字段还会不会随意改"有参考价值,但强度有限。

## 本期无实质改动(折叠)
<details><summary>10 个 openFuyao 仓本期零新提交</summary>

- npu-operator(ddcf0eb7,无新提交)
- npu-container-toolkit(c720a3b8,无新提交)
- npu-driver-installer(bd1b2a9e,无新提交)
- vNPU(21a52631,无新提交)
- npu-node-provision(717ef777,无新提交)
- npu-dra-plugin(4f20ad9b,无新提交)
- npu-feature-discovery(4ba6e58e,无新提交)
- volcano-ext(0f265f98,无新提交)
- ub-network-device-plugin(9cc5dbdd,无新提交)
- ub-network-bandwidth-operator(d4ee1a47,无新提交)
</details>

## 扫描维护备注
- **PATHPREFIX 第 4 次漏项**:`component/k8s-rdma-shared-dev-plugin`(本期 Atlas 950 DPU 掉卡检测改动落在这里)不在清单。核对 `component/` 全量目录后,另有 `dpu-exporter`、`mindio`、`taskd`、`ub-host-device-cni` 四个目录同样从未被扫描过。已把这 5 个前缀补进 `tasks/compute-ascend-watch.md` 的执行命令。
- `component/ascend-clusterops-agent` 本期 18 个文件改动**全部是版权头合规修订**(`[Usage][FD] Copyright compliance revision part4`),无逻辑变化;这类批量改动会按改动量挤占 helper 的 patch 节选槽位,本期靠全量 compare + 按文件名定向取 patch 绕开。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=629a03245ffb8f2b8bda040305fbb6c74051556c tag=v26.3.0-beta.2 scanned=2026-11-27 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=vNPU sha=21a52631996530ae84da9ca97eb469d9cab436f3 tag=v26.9.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=npu-dra-plugin sha=4f20ad9bd8a6d248315d32f42fbd706c6e241713 tag=v26.9.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=npu-feature-discovery sha=4ba6e58e3e132f61936ae2c619f91d9e75c5ec90 tag=v26.9.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=9cc5dbdd87c01f90aa7f9ea8038b7a1ed5b2bd2d tag=v26.9.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=ub-network-bandwidth-operator sha=d4ee1a478ec50c0c543b73f01a00944467e8018d tag=— scanned=2026-11-27 -->
