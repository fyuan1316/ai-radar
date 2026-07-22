# 昇腾算力栈 diff 雷达 2026-07-23

## 摘要
- **mind-cluster** 两条实质改动均是"稳健性打磨":①ascend-for-volcano 修调度初始化的**级联失败** bug——一个 job 的插件初始化失败原本会 `return` 中断整个 `initJobsPlugin` 循环、连累后续所有 job 无法调度,现改为记日志 + `continue` 单 job 跳过(配套新增 157 行 `TestInitJobsPlugin` 表驱动用例);②ascend-device-plugin 把带内热复位(hot reset)启动状态轮询超时从 **480s 收紧到 180s**,加快故障卡热复位的判定节奏。
- **vNPU** 修 `isHbmChip` 芯片识别:从 `HasPrefix("910")` 改为 `Contains("910")`,并把常量 `Ascend910Prefix`→`Ascend910`,以支持 **910C** 这类"910"不在名称开头的型号被正确判为 HBM 芯片。
- 当日**重要改变=无**(未命中 API/CRD/proposal/版本跨档/新 package;均为 bug 修复与阈值调优)。其余 7 个 openFuyao 仓 EMPTY 保锚点。

## 当日重要改变(命中信号才列)
无。今日改动全部落在调度插件逻辑 / device-plugin 常量 / 芯片识别函数,未触及 `*_types.go`、`config/crd`、`docs/proposals`,也无弃用/移除既有字段、无版本跨档、无新增顶层 package。

## mind-cluster: b6e6717e -> d66a9d0f
- 比较: b6e6717ee5c39e4e7d68c3d285d69fdefff056ae..d66a9d0f | tag: v26.1.0.beta.2 | commits=10 | truncated=false
- 源链接: https://gitcode.com/Ascend/mind-cluster/compare/b6e6717ee5c39e4e7d68c3d285d69fdefff056ae...d66a9d0f6cf3e49a65770a734748cc3dd4dfbcea

### AI 总结重点(源码 diff 为据)
- **ascend-for-volcano 调度初始化去级联失败**:`ScheduleHandler.initJobsPlugin()` 遍历所有 vcJob 逐个 `InitMyJobPlugin`,原实现一旦某个 job 初始化报错就 `return` 直接退出整个循环——意味着"集群中存在一个不符合调度策略的任务"会**吞掉后续所有 job 的插件初始化**,导致其他正常任务调度异常。改为打 error 日志后 `continue`,把失败隔离到单个 job。这正是提交"修复一个集群中存在不符合调度策略的任务，导致其他任务调度异常问题"的落点。

  <details><summary>代码依据 component/ascend-for-volcano/plugin/factory.go</summary>

  ```diff
  @@ -372,7 +372,8 @@ func (sHandle *ScheduleHandler) initJobsPlugin() {
   		if err := vcJob.policyHandler.InitMyJobPlugin(vcJob.SchedulerJobAttr, sHandle.ScheduleEnv); err != nil {
  -			return
  +			klog.V(util.LogErrorLev).Infof("initJobsPlugin %s init myJobPlugin err %v.", vcJob.Name, err)
  +			continue
   		}
  ```
  </details>

- **配套测试补齐**:新增 `TestInitJobsPlugin` 表驱动用例(157 行),含 mockPolicyHandler,覆盖 empty/nil jobs map、nil policyHandler(ReqNPUNum>0 与 ==0)等分支,锁住"单 job 失败不影响其余"的新契约。

  <details><summary>代码依据 component/ascend-for-volcano/plugin/factory_test.go</summary>

  ```diff
  +func TestInitJobsPlugin(t *testing.T) {
  +	tests := []struct {
  +		name           string
  +		jobs           map[api.JobID]SchedulerJob
  +		wantInitCalled map[api.JobID]bool
  +	}{
  +		{ name: "01-empty jobs map does nothing", ... },
  +		{ name: "03-nil policyHandler with ReqNPUNum>0 skips init", ... },
  ```
  </details>

- **带内热复位超时收紧 480s→180s**:`UnifiedHotResetManager` 的 `bootStatusPollTimeout` 常量从 480 秒降到 180 秒(`idleWaitSeconds`/`bootStatusPollInterval` 未动)。即热复位后轮询启动状态的等待上限缩短 2/3,更快对"复位未成功"的卡下判定、进入下一步故障处理。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/hot_reset_manager.go</summary>

  ```diff
   const (
   	idleWaitSeconds        = 60
   	bootStatusPollInterval = 1 * time.Second
  -	bootStatusPollTimeout  = 480 * time.Second
  +	bootStatusPollTimeout  = 180 * time.Second
   )
  ```
  </details>

### 后续发展方向 [AI]
- 两处都指向**训练/推理容错链路的收敛**:调度侧不让"坏 job"污染全局初始化、device-plugin 侧缩短热复位裁决窗口——组合起来是"单卡/单任务故障更快隔离、不扩散"。证据只覆盖 initJobsPlugin 的错误分支与一个超时常量,未见热复位后续状态机是否同步调整依赖 480s 的其他等待逻辑(需看 hot_reset_manager 全量)。
- 区间内另有 "ub rdma故障检测工具名称变更""增加rdma共享挂载及状态检查资料" 等提交,落在 component 前缀之外或纯文档,本次不研判;若后续 UB/RDMA fabric 出现代码级改动会在 component/ 信号文件中显现。

## vNPU: 29117ffc -> 257e1cb6
- 比较: 29117ffcf0d144543dd4c0336c77f9abe6a612cd..257e1cb6 | tag: v0.1.0 | commits=2 | truncated=false
- 源链接: https://gitcode.com/openFuyao/vNPU/compare/29117ffcf0d144543dd4c0336c77f9abe6a612cd...257e1cb64bbc0390cc81f2e82c2654e9199c2ea0

### AI 总结重点(源码 diff 为据)
- **HBM 芯片识别放宽为子串匹配以支持 910C**:`isHbmChip(chipName)` 从 `strings.HasPrefix(chipName, "910")` 改为 `strings.Contains(chipName, "910")`,同时常量 `Ascend910Prefix` 更名为 `Ascend910`(语义从"前缀"变"标识子串")。因为 910C 等型号的芯片名里 "910" 未必位于开头,前缀匹配会漏判,导致这些卡不被识别为 HBM 芯片、影响 vNPU 切分路径。

  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/xpu/npu.go</summary>

  ```diff
  -	Ascend910Prefix = "910"
  +	Ascend910 = "910"

   func isHbmChip(chipName string) bool {
  -	return strings.HasPrefix(chipName, Ascend910Prefix)
  +	return strings.Contains(chipName, Ascend910)
   }
  ```
  </details>

### 后续发展方向 [AI]
- vNPU 正在**扩型号覆盖**(910C 类新卡纳入 HBM 识别)。证据仅覆盖 `isHbmChip` 一处判定,未见 HBM 分支下游(切分/vCANN 资源计算)是否对 910C 有额外分支;`Contains` 也可能把带 "910" 子串的非 910 型号误判,需看是否有更精确的型号表约束(本次 diff 未见)。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅锚点)</summary>

- npu-operator | 无新提交
- npu-container-toolkit | 无新提交
- npu-driver-installer | 无新提交
- npu-node-provision | 无新提交
- npu-dra-plugin | 无新提交
- volcano-ext | 无新提交
- ub-network-device-plugin | 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=d66a9d0f6cf3e49a65770a734748cc3dd4dfbcea tag=v26.1.0.beta.2 scanned=2026-07-23 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-23 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-23 -->
<!-- ANCHOR repo=npu-driver-installer sha=c898c929187bba8051e2ebed87f609bc820ead68 tag=v26.6.0 scanned=2026-07-23 -->
<!-- ANCHOR repo=vNPU sha=257e1cb64bbc0390cc81f2e82c2654e9199c2ea0 tag=v0.1.0 scanned=2026-07-23 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-23 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-23 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-23 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-23 -->
