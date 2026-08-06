# 昇腾算力栈 diff 雷达 2026-08-07

## 摘要
- mind-cluster 唯一有实质代码改动:ascend-operator 做**三方依赖消减**,砍掉对 `kubeflow/training-operator` 的直接依赖——把原先复用的 `util.GetSchedulerName`/`util.FakeWorkQueue` 全部内联成本仓私有实现,行为不变,是解耦上游、收敛依赖树的工程动作(#4296)。
- 其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期均无新提交。

## 当日重要改变
- mind-cluster [依赖收敛] ascend-operator 移除对 `github.com/kubeflow/training-operator/pkg/common/util` 的导入,`GetSchedulerName` 与测试用 `FakeWorkQueue` 内联为本仓实现,功能等价、意在切断对 training-operator 的编译期耦合。证据:`component/ascend-operator/pkg/controllers/v1/utils.go`、`pod.go`、`ascendjob_controller_test.go`;提交 https://gitcode.com/Ascend/mind-cluster/commit/b73e9130b513

## mind-cluster: ea8943af -> 7e5db130
- 比较: `ea8943af..7e5db130` | tag: v26.1.0 | commits=8 | truncated=false
- 区间 8 提交里多为文档/合流噪声(mindio 兼容性声明、sha256sum 链接、action 代码化);限定 `component/` 后唯一信号提交是「【MindCluster】三方依赖消减」(https://gitcode.com/Ascend/mind-cluster/commit/b73e9130b513)。

### AI 总结重点(源码 diff 为据)
- **`ascendjob_controller` 不再依赖 training-operator 的调度器名工具函数**:`pod.go` 中 `setGangScheduleInfo` 原先调用外部 `util.GetSchedulerName(replicas)`,改为调本仓新加的私有 `getSchedulerName`。新函数逻辑与上游等价——遍历各 `ReplicaSpec`,返回第一个非空 `Template.Spec.SchedulerName`,全空返回 `""`。属纯解耦重构,gang 调度器名解析行为不变。

  <details><summary>代码依据 component/ascend-operator/pkg/controllers/v1/utils.go + pod.go</summary>

  ```diff
  // utils.go — 新增本仓私有实现
  +func getSchedulerName(replicas map[commonv1.ReplicaType]*commonv1.ReplicaSpec) string {
  +	for _, spec := range replicas {
  +		if len(spec.Template.Spec.SchedulerName) > 0 {
  +			return spec.Template.Spec.SchedulerName
  +		}
  +	}
  +	return ""
  +}

  // pod.go — 调用点切换 + 删除 training-operator 导入
  -	"github.com/kubeflow/training-operator/pkg/common/util"
  ...
  -	podSchedulerName := util.GetSchedulerName(replicas)
  +	podSchedulerName := getSchedulerName(replicas)
  ```
  </details>

- **测试侧同步内联 `FakeWorkQueue`**:`ascendjob_controller_test.go` 删掉 `util.FakeWorkQueue{}`,改用本文件新定义的 `fakeWorkQueue`(完整实现 client-go `RateLimitingInterface` 的 12 个方法,全部空操作)。证实这次消减是把 training-operator 在**产品代码 + 测试**两侧的引用一并清干净,而非只动主逻辑。

  <details><summary>代码依据 component/ascend-operator/pkg/controllers/v1/ascendjob_controller_test.go</summary>

  ```diff
  -	"github.com/kubeflow/training-operator/pkg/common/util"
  ...
  -		WorkQueue:           &util.FakeWorkQueue{},
  +		WorkQueue:           &fakeWorkQueue{},
  ...
  +// fakeWorkQueue implements RateLimitingInterface but actually does nothing.
  +type fakeWorkQueue struct{}
  +func (f *fakeWorkQueue) Add(item interface{}) {}
  +func (f *fakeWorkQueue) AddRateLimited(item interface{}) {}
  +func (f *fakeWorkQueue) AddAfter(item interface{}, duration time.Duration) {}
  +// …(Len/Get/Done/ShutDown/ShutDownWithDrain/ShuttingDown/Forget/NumRequeues 均空实现)
  ```
  </details>

### 后续发展方向 [AI]
- 方向是**减少对 kubeflow 生态的编译期硬依赖**:ascend-operator 长期沿用 `kubeflow/common` + `kubeflow/training-operator` 作为 Job 控制器底座,本次先把 training-operator 的 util 层拆走,是往"自持训练作业控制器、少受上游 API 变动牵连"迈的一小步。证据只覆盖 `GetSchedulerName`/`FakeWorkQueue` 两处 util 的内联;`kubeflow/common`(commonv1、JobController)仍在用,未见进一步替换,不能推断已全面去 kubeflow 化。
- 对我们产品的启示:若自研昇腾训练作业控制器也依赖 training-operator,可留意其把"调度器名解析"这类小工具逐步私有化的做法——上游 training-operator 近年 API 变动频繁,收敛依赖能降低跟版成本。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓无新提交</summary>

- npu-operator — 无新提交
- npu-container-toolkit — 无新提交
- npu-driver-installer — 无新提交
- vNPU — 无新提交
- npu-node-provision — 无新提交
- npu-dra-plugin — 无新提交
- volcano-ext — 无新提交
- ub-network-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=7e5db1304bae5353bbf1adbe41b6b5038f37f996 tag=v26.1.0 scanned=2026-08-07 -->
<!-- ANCHOR repo=npu-operator sha=7cddacb58841f285c6f719e2d7a5cb235be32cdb tag=v26.6.0 scanned=2026-08-07 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-07 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-07 -->
<!-- ANCHOR repo=vNPU sha=f5869cd17c57b8392b97fc76a7879a1a9a1eb81f tag=v0.1.0 scanned=2026-08-07 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-07 -->
<!-- ANCHOR repo=npu-dra-plugin sha=ae80e4f176f0797ac9e38f043f6cc6cef87cc006 tag=v26.6.0 scanned=2026-08-07 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-07 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-07 -->
</content>
</invoke>
