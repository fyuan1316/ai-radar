# 昇腾算力栈 diff 雷达 2026-06-13

## 摘要(3 条内)
- **ascend-for-volcano 软切分校验放宽,适配"整卡 NPU 请求为 0"的软切分场景。** `chip1softsharedev/job.go` 的 `checkSoftShareDevResource` 删除了 `ReqNPUNum/NPUTaskNum == aicoreQuota` 这条强校验,使作业可以只申请 aicore 软配额(MinResource 中整卡 NPU=0)而不再被"整卡数 / 任务数必须等于 aicore 配额"卡住。对应提交 `<Feature>[volcano]支持MinResource中NPU为0适配软切分场景`。
- **为对接增强版 Volcano predicate 接口做前置适配。** 构建期补丁脚本 `build.sh` 的 `replace_node_predicate` 扩充:把上游 ascend-volcano-plugin 的 `convertToNPUFitError` 与 predicate 闭包返回类型从 `error` 改造成 `([]*api.Status, error)`,RBAC(`volcano-v1.12.0.yaml`)同步给 `queues/status`、`podgroups` 加 `patch` 动词并新增 `podgroups/status` 子资源。对应提交 `【Volcano】volcano action增强需求前置适配`。
- openFuyao 8 仓本期全部无新提交(SHA 与上期一致)。mind-cluster 其余实质提交(k8s-rdma-shared-dev-plugin 加存活探针、npu_info 诊断支持 IPv4/IPv6、mindio tft 扫描整改、多篇 docs)落在本 task 限定 component 之外或属文档噪声,不展开。

## 当日重要改变(命中信号才列)
- mind-cluster `[新能力]` ascend-for-volcano 软切分校验放宽:删除 aicoreQuota 与整卡数耦合校验,支持 MinResource 中 NPU=0 的纯软配额申请。证据见下。 https://gitcode.com/Ascend/mind-cluster
- mind-cluster `[架构方向]` ascend-for-volcano 为对接增强版 Volcano predicate(返回 `[]*api.Status`)做构建补丁 + RBAC(podgroups/status patch)前置适配。证据见下。 https://gitcode.com/Ascend/mind-cluster

## mind-cluster: b7790ce9 -> d0d8491b
- 比较:b7790ce9300210248d47f75856bee8f87d1c3231..d0d8491b | tag: v26.0.1 | commits=18 | truncated=false
- 源:https://gitcode.com/Ascend/mind-cluster

### AI 总结重点(源码 diff 为据)

- **软切分作业校验:删除"整卡 NPU 数 / 任务数 必须等于 aicore 配额"的强约束,解耦软配额与整卡数。** `chip1softsharedev/job.go` 的 `checkSoftShareDevResource` 原本在 aicoreQuota 落在 [1,100] 后,还要求 `tp.ReqNPUNum/tp.NPUTaskNum == reqResource.aicoreQuota`,否则报错。本期整段删除。配合提交标题"支持 MinResource 中 NPU 为 0 适配软切分场景":纯软切分作业在 MinResource 里整卡 NPU 申请为 0 时,`ReqNPUNum/NPUTaskNum` 恒为 0、永远不等于 aicoreQuota,这条校验会误杀,故移除;校验只保留 aicoreQuota∈[1,100] 与 hbmQuota≥MinHbmQuota 两条。对应测试用例 `aicore quota not match ReqNPUNum/NPUTaskNum`(job_test.go)同步删除。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip1softsharedev/job.go (modified)</summary>

  ```diff
   	if reqResource.aicoreQuota ... not in range [1,100] { return err }
  -	if tp.ReqNPUNum/tp.NPUTaskNum != reqResource.aicoreQuota {
  -		return fmt.Errorf("%s check share device job(%s) valid failed, aicoreQuota: %v not equal to "+
  -			"tp.ReqNPUNum/tp.NPUTaskNum: %v", tp.GetPluginName(), tp.Name, reqResource.aicoreQuota,
  -			tp.ReqNPUNum/tp.NPUTaskNum)
  -	}
   	if reqResource.hbmQuota < util.MinHbmQuota { return err }
  ```
  </details>

- **构建期补丁适配增强版 Volcano predicate 接口:闭包/错误转换函数返回值从 `error` 升为 `([]*api.Status, error)`。** ascend-for-volcano 通过 `build.sh` 在构建时 sed 改写上游 `ascend-volcano-plugin/npu.go`。本期 `replace_node_predicate` 在原有"闭包签名 `error`→`([]*api.Status, error)`"基础上,新增三处改写:① `convertToNPUFitError` 返回类型 `predicateErr error) error` → `(predicateErr error) ([]*api.Status, error)`;② 其 `return predicateErr` → `return []*api.Status{}, predicateErr`;③ predicateFn 通过分支里的 `return nil` → `return nil, nil`。说明 ascend 调度插件正跟随 Volcano predicate 函数签名升级(返回 `[]*api.Status` 以携带更丰富的预筛状态),属"action 增强前置适配"。
  <details><summary>代码依据 component/ascend-for-volcano/build/build.sh (modified)</summary>

  ```diff
   function replace_node_predicate() {
  -    sed -i "s/api.NodeInfo) error {/api.NodeInfo) (\[\]\*api.Status, error) {/g" "$REPLACE_FILE"
  -    sed -i "s/return predicateErr/return \[\]\*api.Status{}, predicateErr/g" "$REPLACE_FILE"
  +    sed -i "s/api.NodeInfo) error {/api.NodeInfo) (\[\]\*api.Status, error) {/g" "$REPLACE_FILE"
  +    # Change convertToNPUFitError return type from error to ([]*api.Status, error)
  +    sed -i "s/predicateErr error) error {/predicateErr error) (\[\]\*api.Status, error) {/g" "$REPLACE_FILE"
  +    sed -i "s/return predicateErr/return \[\]\*api.Status{}, predicateErr/g" "$REPLACE_FILE"
  +    # Change return nil to return nil, nil in the addPredicateFn closure
  +    sed -i '/predicateFn.*passed/,/return nil/s/return nil/return nil, nil/' "$REPLACE_FILE"
  + }
  ```
  </details>

- **RBAC 随之放权:scheduler 可 patch podgroups 及其 status 子资源;附带修一处部署 YAML 重复键 bug。** `volcano-v1.12.0.yaml` 给 `queues/status` 加 `patch`、`podgroups` 由 `[list,watch,update]` 扩为含 `patch` 且新增 `podgroups/status` 资源——支撑增强版 action 直接 patch PodGroup 状态(回写更细的调度状态)。同文件删掉了 Deployment `volumes:` 下重复嵌套的一行 `volumes:`(原会导致 YAML 结构异常),属修正。
  <details><summary>代码依据 component/ascend-for-volcano/build/volcano-v1.12.0.yaml (modified)</summary>

  ```diff
     - apiGroups: ["scheduling.incubator.k8s.io", "scheduling.volcano.sh"]
       resources: ["queues/status"]
  -    verbs: ["update"]
  +    verbs: ["update", "patch"]
     - apiGroups: [...]
  -    resources: ["podgroups"]
  -    verbs: ["list", "watch", "update"]
  +    resources: ["podgroups", "podgroups/status"]
  +    verbs: ["list", "watch", "update", "patch"]
     ...
         volumes:
  -        volumes:
           - name: scheduler-config
  ```
  </details>

### 后续发展方向 [AI]
- 软切分(chip1softsharedev / vNPU 软配额)主线是**让作业可以"只要 aicore + hbm 配额、不占整卡"**:本期删掉整卡数与 aicore 配额的耦合校验,使 MinResource 中 NPU=0 的纯软配额申请合法化。证据仅覆盖 `checkSoftShareDevResource` 校验删除与对应测试删除;**未见** Allocate/资源记账侧如何处理 NPU=0 的整卡维度(那部分 hunk 不在本期信号文件里),需后续区间确认软配额作业的节点选择与 deviceinfo 上报链路。
- 调度插件正**跟随 Volcano predicate 接口升级到返回 `[]*api.Status`** 的形态(更丰富的预筛/PreFilter 状态语义),并相应放开 RBAC 让 scheduler patch podgroups/status。证据是构建补丁脚本与 RBAC 两处,属"action 增强前置适配"——即上游 Volcano 行为变更先在 ascend 侧打补丁兜住;**本区间未见**真正用到 `[]*api.Status` 返回值的业务逻辑改动,实质 action 增强应在后续提交。

## 本期无实质改动(折叠)
<details><summary>openFuyao 8 仓本期均无新提交</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:全部 `无新提交`(SHA 与上期一致)。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=d0d8491bdfd04ff035e776ab1bbb3dae1a06c1c3 tag=v26.0.1 scanned=2026-06-13 -->
<!-- ANCHOR repo=npu-operator sha=83270337c25487948cbf56685561e273730f9bbf tag=1.2.0 scanned=2026-06-13 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-13 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-13 -->
<!-- ANCHOR repo=vNPU sha=8eb5e3c8e3f1a29f4f2e4c246fb3c00538b132af tag=v0.1.0 scanned=2026-06-13 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-13 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-13 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-13 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-13 -->
</content>
</invoke>
