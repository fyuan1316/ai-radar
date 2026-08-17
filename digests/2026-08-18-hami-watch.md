# HAMi diff 雷达 2026-08-18

## 摘要
- HAMi 主仓新增 **Per-Pod 设备打分权重**能力:`hami.io/device-scoring-weights` 注解让单个 Pod 覆盖 slot/core/memory 三维默认等权(1:1:1),调度打分公式从固定加和改为加权和;默认不填保持旧行为(#2469)。
- HAMi 出现 **Sidecar 容器 GPU 记账**设计文档:指出当前把 native sidecar(initContainers+restartPolicy:Always)误当 init 容器,导致显存低估/超卖、shrink 门永不打开,拟引入"第三类容器"记账公式(#2584,仅设计未落码)。
- volcano-vgpu-device-plugin 给设备注册增加 `Minor` 字段并按 minor number 排序,稳定注解顺序(次要);HAMi-core / ascend-device-plugin / WebUI 三仓无新提交。

## 当日重要改变(命中信号才列;无则写"无")
- Project-HAMi/HAMi [新能力] 新增独立文件 `pkg/util/device_scoring_weights.go`,引入 Pod 级设备打分权重注解,打通 `ComputeScore`→`fitInDevices`→`scoreNode` 全链路传参。https://github.com/Project-HAMi/HAMi/pull/2469
- Project-HAMi/HAMi [架构方向] `docs/develop/sidecarsContainer-design.md` 提出 sidecar 作为第三类容器的 GPU 记账模型,修正 init 容器分类漏洞。https://github.com/Project-HAMi/HAMi/pull/2584

## Project-HAMi/HAMi: 51c593c0 -> 45b3d467
- 比较: https://github.com/Project-HAMi/HAMi/compare/51c593c01a6a37cf41a6438feaa65ac1b62b16aa...45b3d467 | ahead=5 | files=15 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)

- **调度打分从"三维等权固定和"改为"Pod 可配的加权和"**。`ComputeScore` 由 `Weight*(usedScore+coreScore+memScore)` 改为 `Weight*(slot*usedScore+core*coreScore+memory*memScore)`,权重来自新类型 `DeviceScoringWeights{Slot,Core,Memory}`。默认 `{1,1,1}` 完全复刻旧公式,不填注解行为不变(#2469)。
  <details><summary>代码依据 pkg/scheduler/policy/gpu_policy.go</summary>

  ```diff
  -func (ds *DeviceListsScore) ComputeScore(requests device.ContainerDeviceRequests) {
  +func (ds *DeviceListsScore) ComputeScore(requests device.ContainerDeviceRequests, weights util.DeviceScoringWeights) {
   	usedScore := float32(request+ds.Device.Used) / float32(ds.Device.Count)
   	coreScore := float32(core+ds.Device.Usedcores) / float32(ds.Device.Totalcore)
   	memScore := float32(mem+ds.Device.Usedmem) / float32(ds.Device.Totalmem)
  -	ds.Score = float32(util.Weight) * (usedScore + coreScore + memScore)
  +	ds.Score = float32(util.Weight) * (float32(weights.Slot)*usedScore + float32(weights.Core)*coreScore + float32(weights.Memory)*memScore)
  ```
  </details>

- **权重从注解解析,严格校验**。新文件定义 `GetDeviceScoringWeightsByPod`/`ParseDeviceScoringWeights`:注解格式必须是 `slot=1,core=1,memory=3`(恰好 3 项、不许重复 key、值须整数),否则返回 error;无注解回落默认等权。文档补充"至少一个权重为正,非法注解会阻止 Pod 调度直到修正"。
  <details><summary>代码依据 pkg/util/device_scoring_weights.go</summary>

  ```diff
  +func GetDeviceScoringWeightsByPod(pod *corev1.Pod) (DeviceScoringWeights, error) {
  +	value, ok := pod.Annotations[DeviceScoringWeightsAnnotationKey]
  +	if !ok { return DefaultDeviceScoringWeights(), nil }
  +	return ParseDeviceScoringWeights(value)
  +}
  +func ParseDeviceScoringWeights(value string) (DeviceScoringWeights, error) {
  +	parts := strings.Split(value, ",")
  +	if len(parts) != 3 { return weights, fmt.Errorf("... expected slot, core, and memory weights") }
  ```
  </details>

- **weights 贯穿整条调度链**。`scoreNode`/`allocateInitContainers`/`allocateAppContainers`/`fitInDevices` 全部新增 `weights util.DeviceScoringWeights` 参数并逐层透传给 `ComputeScore`,说明权重作用于 init 与 app 两阶段的所有设备候选打分,而非仅最终 tie-break。
  <details><summary>代码依据 pkg/scheduler/score.go</summary>

  ```diff
  -func fitInDevices(node *NodeUsage, requests ..., devinput *device.PodDevices) (bool, string) {
  +func fitInDevices(node *NodeUsage, requests ..., devinput *device.PodDevices, weights util.DeviceScoringWeights) (bool, string) {
  -		node.Devices.DeviceLists[index].ComputeScore(requests)
  +		node.Devices.DeviceLists[index].ComputeScore(requests, weights)
  -func (s *Scheduler) scoreNode(..., userNodePolicy string) nodeScoreResult {
  +func (s *Scheduler) scoreNode(..., userNodePolicy string, weights util.DeviceScoringWeights) nodeScoreResult {
  ```
  </details>

- **新增 AST 级 RBAC 一致性校验工具**(#2567):`hack/tools/rbaccheck/main.go` 读取 `charts/hami/templates` 里 ClusterRole/Role 的 (resource, verb) 授权,再用 go/ast 扫生产代码里的 `CoreV1().Nodes().Update(...)` 链式调用,报出任何 RBAC 未授权的 verb;并按 binary 的 ServiceAccount 分目录校验(scheduler / device-plugin / 共享 pkg/util 取并集)。属安全/CI 硬化,非运行时能力。
  <details><summary>代码依据 hack/tools/rbaccheck/main.go</summary>

  ```diff
  +// rbaccheck verifies that production Go code only calls Kubernetes API
  +// methods (Get, Patch, Update, Delete, Create, List, Watch) that are
  +// granted by the RBAC roles in the helm chart.
  +var resourceToMethod = map[string]string{
  +	"nodes": "Nodes", "pods": "Pods", "configmaps": "ConfigMaps", ...
  +}
  ```
  </details>

- **调度器路由写响应抽出 `writeResponse` 助手,处理 Write 错误**(#2571):原先散落的 `w.Header().Set/WriteHeader/Write` 三连、且忽略 `Write` 返回值,统一到 `writeResponse(w, code, body)` 并对写失败 `klog.ErrorS`。健壮性修复,不改协议语义。
  <details><summary>代码依据 pkg/scheduler/routes/route.go</summary>

  ```diff
  +func writeResponse(w http.ResponseWriter, code int, body []byte) {
  +	w.Header().Set("Content-Type", "application/json")
  +	w.WriteHeader(code)
  +	if _, err := w.Write(body); err != nil { klog.ErrorS(err, "Failed to write response") }
  +}
  -			w.Header().Set("Content-Type", "application/json")
  -			w.WriteHeader(http.StatusOK)
  -			w.Write(resultBody)
  +			writeResponse(w, http.StatusOK, resultBody)
  ```
  </details>

- **Sidecar 容器 GPU 记账设计**(#2584,仅 docs,未落实现代码):文档指出当前 `CollapseInitContainerUsage` 按 index(`cidx < numInit`)分类,把 native sidecar 归入 init-peak 桶取 max,导致 4000+4000 MiB 被记成 4000 → 单卡超卖;且 shrink 门等所有 init 容器 Terminated 才开,sidecar 永不终止 → 显存永不释放。拟以 `isSidecar := c∈initContainers && *c.RestartPolicy==Always` 分出第三类,记账公式改为 `effective = sidecar_sum + max(init_peak, app_sum)`。
  <details><summary>代码依据 docs/develop/sidecarsContainer-design.md</summary>

  ```diff
  +effective[uuid] = sidecar_sum[uuid] + max( init_peak[uuid], app_sum[uuid] )
  +isSidecar(c) := c ∈ spec.initContainers && c.RestartPolicy != nil &&
  +                *c.RestartPolicy == corev1.ContainerRestartPolicyAlways
  ```
  </details>

### 后续发展方向 [AI]
- 打分权重可配是 HAMi 从"固定 binpack/spread"向"用户可调度亲和"的一步:证据显示权重只改设备利用率打分排序(文档明确 capacity/mutex/NUMA/topology 优先级不变),即当前只影响同分设备的取舍与 spread/binpack 的择优,不改变"能不能放下"的 fit 判定。证据只覆盖 GPU 打分链路(score.go/gpu_policy.go),未见对 vNPU/MIG 路径是否复用同一权重。
- Sidecar 记账目前只是设计文档,尚未见 `pkg/device/initContainer.go` 的实现改动;方向明确指向修正 init 容器分类模型(引入 RestartPolicy 判定),落地前 sidecar 场景仍有超卖风险。证据只覆盖 design.md,未见配套 PR 落码。
- rbaccheck 工具化说明 HAMi 在收紧最小权限边界(按 SA 分目录校验 verb),是企业级安全合规的正向信号;证据只覆盖工具本身,未见是否已接入 CI 门禁(verify-all.sh 有 2 行改动但 patch 未展开)。

## Project-HAMi/volcano-vgpu-device-plugin: abe6919b -> 4fb76ba1
- 比较: https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/abe6919b389e98d33af1d8dd1c7d4fee6874102c...4fb76ba1 | ahead=2 | files=2 | Release: —

### AI 总结重点(源码 diff 为据)
- **设备注册按 minor number 排序,稳定注解顺序**。`ConvertDeviceInfo` 新增 `ndev.GetMinorNumber()` 取 minor(失败置 -1 并告警),写入 `DeviceInfo.Minor` 新字段,并对结果切片 `sort.Slice` 按 Minor 升序排。目的是让上报节点注解里的设备顺序确定,避免枚举顺序抖动导致调度/展示不一致。
  <details><summary>代码依据 pkg/plugin/register.go + pkg/util/types.go</summary>

  ```diff
  +	minor, ret := ndev.GetMinorNumber()
  +	if ret != nvml.SUCCESS { klog.Warningf("failed to get minor number ...", dev.ID); minor = -1 }
  		res = append(res, &util.DeviceInfo{
  			Id: dev.ID, Count: ..., Devmem: registeredmem, ...
  +			Minor:  int32(minor),
  		})
  +	sort.Slice(res, func(i, j int) bool { return res[i].Minor < res[j].Minor })
  ```
  ```diff
   type DeviceInfo struct {
  +	Minor                int32             `json:"minor,omitempty"`
  ```
  </details>

### 后续发展方向 [AI]
- 纯稳定性/确定性修复,不涉及切分语义;证据只覆盖 register.go 排序,未见 minor 是否被下游调度器用于绑定物理卡。

## 本期无实质改动(折叠)
<details><summary>3 仓无新提交</summary>

- Project-HAMi/HAMi-core(5496322f,无新提交)
- Project-HAMi/ascend-device-plugin(771e19f8,无新提交)
- Project-HAMi/HAMi-WebUI(fa9b560d,Release hami-webui-1.2.0,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=45b3d46769b44cfc1445728dfcb8e524939afba1 branch=master release=v2.9.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-18 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4fb76ba16a1744b161e9e2fbfc0b9ec3a546dd9b branch=main release=— scanned=2026-08-18 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=771e19f836103727bc84d0bda29ba6a03538e5f2 branch=main release=— scanned=2026-08-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-18 -->
