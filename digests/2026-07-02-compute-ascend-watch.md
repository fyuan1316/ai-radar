# 昇腾算力栈 diff 雷达 2026-07-02

## 摘要
- **mind-cluster** 落地 **Hyper Plane(UB 口)独立故障面**:device-plugin 把原「parameter plane」抽象泛化成 `networkPlaneStatus`,新增 UB 超平面故障码集合 `HyperPlaneFaultCodes`(UBPortDown/UBSeparate/UBSubHeal)与 `HandleLostHyperPlaneFaultEvents` 补漏回路,并给下一代 `Ascend910A5` 芯片的 `GetDeviceIP` 走空返回——都是 A5/A3 超节点 UB fabric 上线的配套。
- **mind-cluster** docker-runtime 新增 `LD_LIBRARY_PATH` 注入(把 driver `lib64/common`+`lib64/driver` 前插进容器环境),让容器里 `npu-smi` 能找到依赖 so;for-volcano 构建改双基座(Alpine musl + openEuler glibc)。
- **vNPU** 把内嵌 Volcano 从 **1.9.0 跨到 1.15.0**,并适配上游 `PredicateFn` 签名收敛(`([]*api.Status, error)` → `error`);其余 7 仓无新提交。

## 当日重要改变
- mind-cluster [新能力] UB 超平面(hyper plane)成为与 RoCE/UBoE 并列的独立故障处理面,新增故障码集+补漏事件回路,并接进 `mendSubscribeFaultEvents` 主循环 —— 证据 `pkg/common/fault_code.go`、`pkg/device/ascendcommon.go`、`pkg/server/manager.go` https://gitcode.com/Ascend/mind-cluster/commit/f93bbaab77dedfe2e831ed97995b4e052c1b3daa
- mind-cluster [新能力] docker-runtime 运行期注入 Ascend driver so 到 `LD_LIBRARY_PATH`,修 `npu-smi` 找不到依赖库 —— 证据 `runtime/process/process.go` https://gitcode.com/Ascend/mind-cluster/commits/master
- vNPU [版本跨档] 内嵌 Volcano 1.9.0 → 1.15.0(跨 6 个 minor),plugin 层适配上游调度接口签名变化 —— 证据 `volcano-xpu-plugin/plugin/node.go`、`ci/build.sh` https://gitcode.com/openFuyao/vNPU/commit/299afce43a428027ccbe7baf863414071d657d1a

## mind-cluster: 9e45a253 -> f93bbaab
- 比较: 9e45a253..f93bbaab | tag: v26.0.1 | commits=26 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/9e45a253f2af5eded17c000f8c0bfdaf7b436bbe...f93bbaab77dedfe2e831ed97995b4e052c1b3daa

### AI 总结重点(源码 diff 为据)
- **新增 UB 超平面(hyper plane)故障面,与 parameter plane(RoCE/UBoE)解耦**。原 `parameterPlaneStatus` 结构体改名为通用的 `networkPlaneStatus`(注释明说"parameter plane 或 hyper plane"),并新起三组缓存 `hyperPlaneLimiterMap` / `hyperPlaneStatusCache` / `ubPortEnabledCache`;`DevManager` 接口新增 `HandleLostHyperPlaneFaultEvents`。芯片故障事件生成时,`generateChipFaultEventsBasedOnFaultCacheChange` 与 `getOriginalFaultCodes` 都改为把 `NetworkFaultCodes` **和** `HyperPlaneFaultCodes` 都排除出普通芯片故障(避免网络/UB 故障被当成 chip 故障重复上报)。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  -type parameterPlaneStatus struct {
  +// networkPlaneStatus indicates the link status and down ports count of a network plane
  +// (parameter plane or hyper plane)
  +type networkPlaneStatus struct {
  	status       string
  	downPortsNum int
   }
  -	parameterPlaneStatusCache  = make(map[int32]parameterPlaneStatus, common.GeneralMapSize)
  +	parameterPlaneStatusCache  = make(map[int32]networkPlaneStatus, common.GeneralMapSize)
  +	hyperPlaneLimiterMap       = make(map[int32]*rate.Limiter, common.GeneralMapSize)
  +	hyperPlaneStatusCache      = make(map[int32]networkPlaneStatus, common.GeneralMapSize)
  +	ubPortEnabledCache         = make(map[int32]map[string]bool, common.GeneralMapSize)
  	HandleLostNetworkFaultEvents(*common.NpuDevice, []int32)
  +	HandleLostHyperPlaneFaultEvents(*common.NpuDevice, []int32)
  -		if common.NetworkFaultCodes.Has(faultCode) {
  +		if common.NetworkFaultCodes.Has(faultCode) || common.HyperPlaneFaultCodes.Has(faultCode) {
  			continue
  ```
  </details>
- **明确 UB 超平面的三个故障码,并把补漏回路接进故障订阅主循环**。`fault_code.go` 新增 `HyperPlaneFaultCodes = {UBPortDownCode, UBSeparateFaultCode, UBSubHealFaultCode}`,同时把 `NetworkFaultCodes` 注释收窄为"roce and uboe";`manager.go` 的 `mendSubscribeFaultEvents` 在既有 `HandleLostNetworkFaultEvents` 之后补调 `HandleLostHyperPlaneFaultEvents`,即 UB 口故障与 RoCE 口故障走各自独立的"订阅可能丢事件"兜底路径。
  <details><summary>代码依据 fault_code.go + server/manager.go</summary>

  ```diff
  -	// NetworkFaultCodes is a set that contains all the network fault codes
  +	// NetworkFaultCodes is a set that contains roce and uboe network fault codes
  	NetworkFaultCodes = sets.NewInt64(LinkDownFaultCode, UBOEPortDownCode, UBOESubHealFaultCode, UBOEPreSeparateFaultCode)
  +	// HyperPlaneFaultCodes is a set that contains all the hyper plane fault codes
  +	HyperPlaneFaultCodes = sets.NewInt64(UBPortDownCode, UBSeparateFaultCode, UBSubHealFaultCode)
  // --- manager.go mendSubscribeFaultEvents ---
  			hdm.manager.HandleLostNetworkFaultEvents(npuDevice, initLogicIDs)
  +			hdm.manager.HandleLostHyperPlaneFaultEvents(npuDevice, initLogicIDs)
  ```
  </details>
- **下一代 `Ascend910A5` 芯片的 `GetDeviceIP` 直接返回空**。在虚拟设备判断之前提前 short-circuit——A5 代际不再走原有 device IP 查询路径(结合 commit "Atlas350&850&950 代际不再提供 dcmiv2_get_device_ip 接口"看,是 A5/新代际取消了该 dcmi 接口)。
  <details><summary>代码依据 pkg/device/ascendcommon.go</summary>

  ```diff
   func (tool *AscendTools) GetDeviceIP(deviceType string, phyID int) (string, error) {
  +	if tool.dmgr.GetDevType() == api.Ascend910A5 {
  +		return "", nil
  +	}
  	if common.IsVirtualDev(deviceType) {
  ```
  </details>
- **docker-runtime 运行期把 Ascend driver so 目录前插进容器 `LD_LIBRARY_PATH`**。新增 `ascendDriverLibPaths = {/usr/local/Ascend/driver/lib64/common, .../lib64/driver}`,`addAscendLibraryPath` 只挑真实存在(`os.Stat`)的目录,去重后前插到容器已有 `LD_LIBRARY_PATH`(无则新建 env)。对应 commit"AscendDockerRuntime 增加驱动 so 动态库路径配置,支持 npu-smi 命令执行时查找依赖 so"。
  <details><summary>代码依据 component/ascend-docker-runtime/runtime/process/process.go</summary>

  ```diff
  +	ldLibraryPathKey     = "LD_LIBRARY_PATH"
  +	ascendDriverLibPaths = []string{
  +		"/usr/local/Ascend/driver/lib64/common",
  +		"/usr/local/Ascend/driver/lib64/driver",
  +	}
  +func addAscendLibraryPath(spec *specs.Spec) {
  +	existingPaths := collectExistingLibPaths()   // 只保留 os.Stat 成功的目录
  +	...
  +	spec.Process.Env[i] = ldLibraryPathKey + "=" + strings.Join(newPaths, ":") + ":" + parts[1]
  ```
  </details>
- **for-volcano 构建改双基座(Alpine musl + openEuler glibc)**。build.sh 从写死 `output/` 单目录重构为参数化 `clean_dir(dir)` / `copy_resources(dir)`,新增"Dual Build Mode"同时产 `output`(Alpine)与 `output-oe`(openEuler);新增 `output/openeuler/Dockerfile-scheduler|controller`(`FROM openeuler/openeuler:24.03-lts`,hwMindX 9000 非 root 用户),Alpine 侧 Dockerfile 也补齐 `agreement.txt` 拷贝与 `cat agreement.txt` 的 ENTRYPOINT。企业级信创基座信号,非功能改动。
  <details><summary>代码依据 output/openeuler/Dockerfile-scheduler + build/build.sh</summary>

  ```diff
  +FROM openeuler/openeuler:24.03-lts
  +RUN groupadd -g 9000 hwMindX && useradd ... -u 9000 -g hwMindX ... hwMindX && \
  +    chmod 500 /vc-scheduler /plugins && chmod 400 /plugins/*.so
  +USER hwMindX
  // build.sh:
  -function clean() { rm -f "${BASE_PATH}"/output/... }
  +function clean_dir() { local OUTPUT_DIR=$1; rm -f "${OUTPUT_DIR}"/... }
  +echo "===== Start Dual Build Mode ====="
  ```
  </details>
- **clusterd pingmesh 设备类型日志按 acceleratorType 是否为空分支**(A3/A5 超节点):非空才打印 acceleratorType,纯日志可读性,不改判活逻辑(A3 恒 true;NPU 仍判 A5PodType/Ascend800ia5SuperPod)。npu-exporter `collector_for_network.go` 本区间仅注释微调(udie 0/1 说明),port 状态范围判断的实质代码未落在本次 hunk。

### 后续发展方向 [AI]
- UB(Unified Bus)超平面正被建成与传统 RoCE/UBoE 网络平面对等的一等故障域,证据集中在 device-plugin 的故障码分类 + 独立缓存 + 独立补漏回路——指向 A5/A3 超节点(SuperPod)UB fabric 的可观测/自愈能力成型。**证据只覆盖故障码集合与事件补漏的接线,未见 `generateHyperPlaneFaultEventsBasedOnFaultCacheChange` 的完整实现体(hunk 截断)**,也未见 UB 口 enable 状态(`ubPortEnabledCache`)的消费方。
- `Ascend910A5` 常量与 dcmi 接口取消的配套改动,预示新代际(Atlas 350/850/950)在 device IP、UB 口上与 910B 走不同 code path;后续可留意 device-plugin 里 A5 专属分支扩散。证据仅一处 `GetDeviceIP` short-circuit。
- openEuler glibc 双基座只见于 for-volcano 调度器/控制器镜像,未见 device-plugin/npu-exporter 同步双基座;信创底座迁移是否全栈铺开尚无证据。

## vNPU: dae5c9f5 -> 299afce4
- 比较: dae5c9f5..299afce4 | tag: v0.1.0 | commits=2 | truncated=false
- https://gitcode.com/openFuyao/vNPU/compare/dae5c9f541fc402bd0703b17764bb89b98e63b2c...299afce43a428027ccbe7baf863414071d657d1a

### AI 总结重点(源码 diff 为据)
- **内嵌 Volcano 从 1.9.0 升到 1.15.0**,构建脚本/离线导入镜像 tag、README 支持声明全线同步 `1.9.0 → 1.15.0`,`third_party/volcano` submodule 与 `.gitmodules` 一并更新。跨 6 个 minor 的大版本抬升。
  <details><summary>代码依据 ci/build.sh + docs</summary>

  ```diff
  -    build_image "vc-controller-manager.Dockerfile"   "vc_controller_manager"  "1.9.0"
  +    build_image "vc-controller-manager.Dockerfile"   "vc_controller_manager"  "1.15.0"
  -Currently supports volcano 1.9.0 version, latest version is planned.
  +Currently supports volcano 1.15.0 version, latest version is planned.
  ```
  </details>
- **适配上游 Volcano `PredicateFn` 签名收敛**:`ScheduleHandler.NodePredicate` 返回值从 `([]*api.Status, error)` 退化为单个 `error`,内部不再构造 `api.Status` 列表;`addPredicateFn` 注册回调同步改签名。说明 1.15.0 的 `AddPredicateFn` 回调签名已从"返回状态切片+error"变为"仅 error"。
  <details><summary>代码依据 volcano-xpu-plugin/plugin/node.go + volcano_vxpu.go</summary>

  ```diff
  -func (sh *ScheduleHandler) NodePredicate(task *api.TaskInfo, node *api.NodeInfo) ([]*api.Status, error) {
  +func (sh *ScheduleHandler) NodePredicate(task *api.TaskInfo, node *api.NodeInfo) error {
  -	ssn.AddPredicateFn(xp.Name(), func(taskInfo *api.TaskInfo, nodeInfo *api.NodeInfo) ([]*api.Status, error) {
  +	ssn.AddPredicateFn(xp.Name(), func(taskInfo *api.TaskInfo, nodeInfo *api.NodeInfo) error {
  ```
  </details>
- **XPU 资源忽略判断修累积 bug**:volcano patch 里 `ignore = GetXPUIgnoreStatus(...)` 改为 `ignore = ignore || GetXPUIgnoreStatus(...)`,避免直接覆盖上游已算出的 ignore 状态(原写法会把上游的 true 冲掉)。另 `vxpu.go` 一批 `fmt.Errorf(errMsg)` → `fmt.Errorf("%s", errMsg)`,消除非常量格式串的 vet 告警。
  <details><summary>代码依据 ci/patches/volcano.patch + plugin/vxpu.go</summary>

  ```diff
  -				ignore = GetXPUIgnoreStatus(rName.String())
  +				ignore = ignore || GetXPUIgnoreStatus(rName.String())
  -		return fmt.Errorf(errMsg)
  +		return fmt.Errorf("%s", errMsg)
  ```
  </details>
- 文档补充:Volcano 容器以 UID 1000 运行,`/var/log/volcano-*` 日志目录需 `chown -R 1000:1000` 授权(部署踩坑修正)。

### 后续发展方向 [AI]
- vNPU 紧跟上游 Volcano 主线(1.15.0),vxpu 软切分(elastic/fixed-share 策略 + XPUCore/XPUMem 校验)依赖 Volcano 调度框架的 predicate 扩展点;签名从状态切片退回 error 意味着上游简化了 predicate 返回契约,vNPU 侧丢失了每节点不可调度原因的结构化 `Status`(改回退到 `Reason[err]+=node` 字符串拼接)。**证据仅覆盖 predicate 注册与 NodePredicate 主体,未见 score/allocate 路径是否同步适配**。
- `GetXPUIgnoreStatus` 的 `||` 累积修复说明此前存在"上游标记忽略被 vNPU 覆盖"的资源核算错误,可能影响 vGPU/vNPU 配额统计准确性;仅 patch 层证据,未见实际资源核算测试。

## 本期无实质改动(折叠)
<details><summary>7 仓无新提交</summary>

- npu-operator(sha 335bc283,tag 1.2.0)
- npu-container-toolkit(sha d54256e0,tag 1.2.0)
- npu-driver-installer(sha 9f400f3c,tag 1.2.0)
- npu-node-provision(sha 717ef777,tag 1.2.0)
- npu-dra-plugin(sha 0876c67f,tag 1.0.1)
- volcano-ext(sha c9be5c4c,tag v1.9.0)
- ub-network-device-plugin(sha 263d6387,tag 1.0.1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=f93bbaab77dedfe2e831ed97995b4e052c1b3daa tag=v26.0.1 scanned=2026-07-02 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-07-02 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-07-02 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-07-02 -->
<!-- ANCHOR repo=vNPU sha=299afce43a428027ccbe7baf863414071d657d1a tag=v0.1.0 scanned=2026-07-02 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-07-02 -->
<!-- ANCHOR repo=npu-dra-plugin sha=0876c67f9bea29da06e97e09bb7def5c0039a30b tag=1.0.1 scanned=2026-07-02 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-02 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-07-02 -->
