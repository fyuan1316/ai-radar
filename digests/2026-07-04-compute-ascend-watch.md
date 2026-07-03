# 昇腾算力栈 diff 雷达 2026-07-04

## 摘要
- **mind-cluster 本期主线是 UB/UBOE 网络监控与故障判定的一次结构性重构**:端口从裸 `int` portID 升格为带 `PortType` 的 `NpuDevPortInfo` 结构,贯穿 device-plugin→ascend-common(hccn)→npu-exporter 三层;新增 UBOE bond 带宽采集路径(`hccn_tool ... -d bond<id>`),所有网络/光模块 metric 描述加 `type:` 标签;并把"UB 端口 down 数快照 + 端口使能缓存"整块逻辑从 device-plugin 下沉到公共 `hccn` 包,hccn 命令调用加互斥锁。
- **故障码前导零丢失修复**:原来一律 `strconv.FormatInt(eventId, Hex)` 会把 `0x08…` 这类带前导零的 code 渲染成 `8…`,导致日志/ConfigMap 里的故障码与 `faultCode.json` 配置对不上。新增 `faultCodeFormatMap` + `FormatFaultCodeHex()`,加载配置时按原始字符串缓存格式,格式化时优先返回配置原样值保留前导零。
- **推理亲和死循环"二改"**:昨天(07-03)修的 8RA64SP 超节点选点死循环今天补丁——内层跳过无效超节点/机架前漏了 `item = nil` 清零,退出循环时会误用上一轮已被判无效的 item,今日补齐。

## 当日重要改变
- **mind-cluster [架构方向/重构]** UB 端口监控抽象升级:`NpuDevPortInfo{PortID,PortType,LinkStatus}` 结构贯穿三层,device-plugin 侧的 UB down 计数与端口使能缓存整块下沉到公共 `hccn` 包。证据:`component/ascend-common/devmanager/common/types.go`、`component/ascend-device-plugin/pkg/device/ascendcommon.go`。 https://gitcode.com/Ascend/mind-cluster/commit/d691f809d7bc
- **mind-cluster [新能力]** npu-exporter 新增 UBOE bond 带宽指标(独立 `getUboeBandwidth` 走 `-d bond<id>`),网络/光模块 metric 描述统一加 `type:` 端口类型标签。证据:`component/ascend-common/devmanager/hccn/hccn_tool.go`、`component/npu-exporter/collector/metrics/collector_for_network.go`。 https://gitcode.com/Ascend/mind-cluster/commit/c8a2ab2c5af7
- **mind-cluster [Bugfix]** 故障码前导零保留(日志与 CM 与 faultCode.json 对齐)。证据:`component/ascend-device-plugin/pkg/common/fault_code.go` 新增 `FormatFaultCodeHex`。 https://gitcode.com/Ascend/mind-cluster/commit/c8125a2c15a6
- **mind-cluster [Bugfix/调度]** 推理亲和 8RA64SP 选点死循环二改(`continue` 前补 `item = nil`)。证据:`component/ascend-for-volcano/internal/npu/policy/chip8node8ra64sp/infer_service.go`。 https://gitcode.com/Ascend/mind-cluster/commit/12aad4abb2f0
- **vNPU [安全硬化]** volcano 组件 Dockerfile 交付产物 `--chown=1000:1000`,容器内以非 root(UID 1000)持有二进制/插件 so。证据:`ci/pipeline/Dockerfile/vc-scheduler.Dockerfile`。 https://gitcode.com/openFuyao/vNPU/commit/75efcb9f42057ad1549fdccc4edb64ba8f8657be

## mind-cluster: 6e193d89 -> 95a0438b
- 比较: 6e193d89..95a0438b | tag: v26.0.1 | commits=26 | truncated=true
- https://gitcode.com/Ascend/mind-cluster/compare/6e193d89245f496c314f2e2ef8e7dc299027a831...95a0438b7f7bccdb1437cf4180ea38c7c09552af
- 注:compare truncated=true,files 已含全部 component 信号文件,以下按 PATHPREFIX 限定后逐文件读 hunk。

### AI 总结重点(源码 diff 为据)
- **端口标识从裸 `int` 升格为 `NpuDevPortInfo` 结构,把 `PortType` 一路带到监控层**。ascend-common 新增导出结构 `NpuDevPortInfo{PortID int; PortType string; LinkStatus string}`;npu-exporter 侧把持有端口表的 `NpuDevPortInfo` 重命名为 `NpuDevPortsInfo`,其 `devPortMap` 从 `map[int][]int` 改为 `map[int][]common.NpuDevPortInfo`。因此三个 collector(ub/network/optical)遍历端口时不再 `sort.Ints(portIDs)`(struct slice 无法直接排序,排序逻辑被移除),而是 `for _, port := range portIDs { portID := port.PortID }`,并在 link_status / bandwidth / optical 各 metric 描述里追加 ` type:<PortType>`——即监控指标现在能区分 UB 口与 UBOE bond 口。
  <details><summary>代码依据 component/ascend-common/devmanager/common/types.go + collector_for_network.go</summary>

  ```diff
  +// NpuDevPortInfo ub port info without udie
  +type NpuDevPortInfo struct {
  +	PortID     int
  +	PortType   string
  +	LinkStatus string
  +}
  ```
  ```diff
  -		sort.Ints(portIDs)
  -		for _, portID := range portIDs {
  +		for _, port := range portIDs {
  +			portID := port.PortID
  -				" portId:", strconv.Itoa(portID)))
  +				" portId:", strconv.Itoa(portID), " type:", port.PortType))
  ```
  </details>

- **新增 UBOE bond 带宽采集路径,与普通 UB 口分流**。`GetNPUInterfaceTrafficNpu` 签名从 `(logicID, udieID, portID, durationTime int32)` 改为 `(logicID, udieID int32, port common.NpuDevPortInfo)`;入口先判 `port.PortType == BondingPortName`,是则转入新增的 `getUboeBandwidth`,后者用 `hccn_tool -g -bandwidth -i <logicID> -d bond<logicID>`(解析两组 dev_name 的 TX/RX),而非普通口的 `-u <udie> -p <port> -time` 形式。原来由调用方传入的 `bandwidthTime=100` 常量被删除、`durationTime` 内联硬编码为 100。新增 `uboeBondBandwidth{TX,RX *float64}` 承载解析结果。
  <details><summary>代码依据 component/ascend-common/devmanager/hccn/hccn_tool.go</summary>

  ```diff
  -func GetNPUInterfaceTrafficNpu(logicID, udieID, portID, durationTime int32) (float64, float64, error) {
  +func GetNPUInterfaceTrafficNpu(logicID, udieID int32, port common.NpuDevPortInfo) (float64, float64, error) {
  +	if port.PortType == BondingPortName {
  +		return getUboeBandwidth(logicID, int32(port.PortID))
  +	}
  +func getUboeBandwidth(logicID, portID int32) (float64, float64, error) {
  +	args := []string{"-g", "-bandwidth", "-i", strconv.Itoa(int(logicID)), "-d", fmt.Sprintf("bond%d", logicID)}
  ```
  </details>

- **UB 端口 down 计数与端口使能缓存整块从 device-plugin 下沉到公共 `hccn` 包**。device-plugin `ascendcommon.go` 删除 `ubPortEnabledCache` 全局、`isUBPortEnabled`、`getUBPortsDownSnapshot` 及私有 `ubPortsDownSnapshot` 结构;调用点改为 `hccn.GetUBPortsDownSnapshot(phyID)`,快照结构升格为 ascend-common 里导出的 `UBPortsDownSnapshot{BondingDownCnt,UBDownCnt}`,端口使能缓存 `ubPortEnabledCache` 移到 hccn_tool.go。同时错误分支从"静默兜底"改为"打 error 日志 + 兜底计数"(parameter plane 失败打 `uboe port status query failed`)。动机对应提交"修复 hccn 工具调用失败问题 && UBOE/UB down 端口数代码修复和重构":监控与故障判定共用同一份 hccn 采集,避免 device-plugin 与 exporter 各写一套。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  -	ubPortEnabledCache         = make(map[int32]map[string]bool, common.GeneralMapSize)
  ...
  -	snapshot, err := getUBPortsDownSnapshot(phyID)
  +	snapshot, err := hccn.GetUBPortsDownSnapshot(phyID)
   	if err != nil {
  -		snapshot.bondingDownCnt = npuCommon.UBOEParameterPlanePortAllDownCount
  +		hwlog.RunLog.Errorf("device %d uboe port status query failed", phyID)
  +		snapshot.BondingDownCnt = npuCommon.UBOEParameterPlanePortAllDownCount
  ```
  </details>

- **hccn_tool 命令调用加进程内互斥锁**。hccn 包新增 `runHccnCmdMu sync.Mutex`,配合上面把 down 计数/带宽采集收口到 hccn 包——多 goroutine(exporter 采集 + device-plugin 故障轮询)并发调外部 `hccn_tool` 二进制的竞争被串行化,直接回应提交标题"修复 hccn 工具调用失败问题"。(hunk 仅见变量声明,`runHccnCmdMu.Lock()` 具体包裹点在 `getInfoFromHccnTool` 内,未在本节 80 行截断内完整展开。)
  <details><summary>代码依据 component/ascend-common/devmanager/hccn/hccn_tool.go</summary>

  ```diff
  +var (
  +	runHccnCmdMu       sync.Mutex
  +	ubPortEnabledCache = make(map[int32]map[string]bool)
  +)
  ```
  </details>

- **故障码十六进制格式化改走配置原样字符串,保留前导零**。新增 `faultCodeFormatMap map[int64]string` + `faultCodeFormatMapLock`;`LoadFaultCode` 解析 `faultCode.json` 时对全部 11 类 code 列表调 `registerFaultCodeFormats`,把每个 `eventIdStr`(小写原样,如 `0800xxxx`)存入 map。新导出函数 `FormatFaultCodeHex(eventId)` 命中缓存则返回配置原字符串(含前导零),miss 才 fallback `fmt.Sprintf("%x", eventId)`。device-plugin 侧三处 `strings.ToUpper(strconv.FormatInt(eventId, common.Hex))` 全部替换为 `strings.ToUpper(common.FormatFaultCodeHex(eventId))`——修复日志与写入 CM 的故障码丢前导零、与配置对不齐的问题。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go + ascendcommon.go</summary>

  ```diff
  +func FormatFaultCodeHex(eventId int64) string {
  +	faultCodeFormatMapLock.RLock()
  +	if format, ok := faultCodeFormatMap[eventId]; ok {
  +		faultCodeFormatMapLock.RUnlock()
  +		return format
  +	}
  +	faultCodeFormatMapLock.RUnlock()
  +	return fmt.Sprintf("%x", eventId)
  +}
  ```
  ```diff
  -		hexFaultCode := strings.ToUpper(strconv.FormatInt(eventId, common.Hex))
  +		hexFaultCode := strings.ToUpper(common.FormatFaultCodeHex(eventId))
  ```
  </details>

- **推理亲和 8RA64SP 选点死循环二改:内层跳过无效项前补 `item = nil`**。07-03 已把选点从"每轮重建队列 + `i--` 回退"改为"建一次队列 + 内层弹出跳过";但 8RA64SP(带机架维度)的内层循环里,superPod 不满足 `spBlock` 或 rack 不满足时只 `continue`,没把上一轮 pop 出来、已判无效的 `item` 清空——若队列在此 break 退出,外层会误用这个失效 item。今日补丁在两个 `continue` 前各加 `item = nil`,保证跳过后 `item` 反映真实"未选中"状态。对应提交"开启推理亲和性后重调度偶现死循环二改"。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip8node8ra64sp/infer_service.go</summary>

  ```diff
   			sp, ok := superPodMap[item.superPodID]
   			if !ok || len(sp) < tp.spBlock {
  +				item = nil
   				continue
   			}
   			...
   			if !rackOk || len(nodesInRack) < tp.spBlock {
  +				item = nil
   				continue
   			}
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾监控/故障栈这轮明显在为 **UBOE(UB over Ethernet)超节点 fabric** 打底:端口类型化(UB vs bond)、UBOE 专用带宽采集、down 计数收口到公共 hccn 包并加锁,都是把"超节点内多口/bond 网络健康"做成 device-plugin 故障判定与 exporter 指标的统一数据源。证据覆盖 device-plugin + npu-exporter + ascend-common 三层的端口结构改造与 hccn 采集下沉,但 `runHccnCmdMu` 的实际加锁范围、UBOE bond 解析的完整分支未在截断 hunk 内全见,需在下一区间确认锁粒度是否覆盖全部 hccn_tool 调用。
- 推理死循环连续两日(07-03 主改、07-04 二改)说明超节点拓扑选点(8SP/8RA64SP)的边界条件仍在收敛,昇腾大规模推理实例的容错重调度尚处 v26.0.1 稳定化阶段;证据仅覆盖 for-volcano 两个拓扑策略,未见 clusterd/infer-operator 侧本区间生产 hunk。

## vNPU: 92cd0479 -> 75efcb9f
- 比较: 92cd0479..75efcb9f | tag: v0.1.0 | commits=2 | truncated=false
- https://gitcode.com/openFuyao/vNPU/compare/92cd047907d2c8919594c4707b881276e7da5ca8...75efcb9f42057ad1549fdccc4edb64ba8f8657be

### AI 总结重点(源码 diff 为据)
- **volcano 三个组件镜像交付产物统一 `--chown=1000:1000`,以非 root 用户持有二进制/插件**。vc-scheduler / vc-controller-manager / vc-webhook-manager 三个 Dockerfile 的 `COPY --from=build` 全部加 `--chown=1000:1000`(scheduler 连同 `volcano-vxpu.so` 插件),webhook 顺带删掉冗余的 `chmod 500 vc-webhook-manager`(COPY 阶段已 `--chmod=500`)。属容器安全硬化——vNPU 软切调度组件不再以 root 持有可执行文件。仅 CI/Dockerfile 变更,无 Go 生产逻辑。
  <details><summary>代码依据 ci/pipeline/Dockerfile/vc-scheduler.Dockerfile</summary>

  ```diff
  -COPY --link --from=build --chmod=500 /go/src/app/ci/output/vc-scheduler /vc-scheduler
  -COPY --link --from=build --chmod=400 /go/src/app/ci/output/volcano-vxpu.so /plugins/volcano-vxpu.so
  +COPY --link --from=build --chown=1000:1000 --chmod=500 /go/src/app/ci/output/vc-scheduler /vc-scheduler
  +COPY --link --from=build --chown=1000:1000 --chmod=400 /go/src/app/ci/output/volcano-vxpu.so /plugins/volcano-vxpu.so
  ```
  </details>

### 后续发展方向 [AI]
- vNPU 仍停在 v0.1.0 交付打磨(继 07-03 README 路线宣示后,本区间只有镜像非 root 化),未见 1% 切分粒度/弹性抢占/DRA 三模调度的生产 `.go` 落地;证据仅 CI Dockerfile,能力判断需等 `volcano-xpu-plugin`/`client_update` 出现实质 hunk。

## 本期无实质改动(折叠)
<details><summary>7 个 repo 无新提交</summary>

- npu-operator(335bc283,无新提交)
- npu-container-toolkit(d54256e0,无新提交)
- npu-driver-installer(9f400f3c,无新提交)
- npu-node-provision(717ef777,无新提交)
- npu-dra-plugin(dbffd794,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=95a0438b7f7bccdb1437cf4180ea38c7c09552af tag=v26.0.1 scanned=2026-07-04 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-07-04 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-07-04 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-07-04 -->
<!-- ANCHOR repo=vNPU sha=75efcb9f42057ad1549fdccc4edb64ba8f8657be tag=v0.1.0 scanned=2026-07-04 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-07-04 -->
<!-- ANCHOR repo=npu-dra-plugin sha=dbffd7942b003f1bd4880861c167aa7a0410c9ca tag=1.0.1 scanned=2026-07-04 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-04 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-07-04 -->
</content>
</invoke>
