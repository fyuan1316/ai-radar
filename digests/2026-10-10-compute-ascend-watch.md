# 昇腾算力栈 diff 雷达 2026-10-10

## 摘要
- 仅 **mind-cluster** 有实质增量(区间 965fd82c..eed2442f,14 commit,未截断),且集中在 **clusterd 故障管理链路**;openFuyao 全部 8 仓自 10-09 锚点零新提交,HEAD 逐仓一致。
- 头条是一条真修复:clusterd 取"Pod 占用的设备 ID 列表"时新增注解兜底——`GetPodUsedDev` 原先只读 `Pod910DeviceAnno`,现若缺失则回退读 `PodNPUDeviceAnno`,修 **A5 场景下该列表恒为空**导致的"故障设备→作业"映射失效。配套在增量故障处理器里补了三处 Debug 日志(无功能改动,纯可观测)。
- 其余为文档:infer-operator README 大改版(新增 mermaid 架构图、CRD 说明),以及驱逐/示例镜像等资料订正——均非运行时能力。
- 非空日,按约定推飞书。

## 当日重要改变

### mind-cluster · clusterd 新增 NPU 设备注解兜底,修 A5 场景设备列表为空(故障管理链路)
对应 commit「A5场景clusterd获取pod使用的设备id列表为空问题修复」。

信号文件 `component/clusterd/pkg/domain/pod/pod_util.go`,`GetPodUsedDev` 读 Pod 注解处:

```go
 devInfo, exist := pod.Annotations[api.Pod910DeviceAnno]
+if !exist {
+    devInfo, exist = pod.Annotations[api.PodNPUDeviceAnno]
+}
 if !exist {
     return nil
 }
```

- 语义:clusterd 判断一个 Pod 占用了哪些 NPU 设备,过去**只认 910 专用注解 `Pod910DeviceAnno`**;A5 场景下设备插件写的是**通用 NPU 注解 `PodNPUDeviceAnno`**,于是该函数命中第二个 `return nil`、返回空列表。
- 影响面:clusterd 的故障管理依赖"节点上故障设备 → 占用该设备的作业"这条映射(`CreateDevNameJobMap` / `GetJobIdByDev`),源头 Pod→设备列表为空则整条链路断裂——即 A5 硬件上设备故障无法正确定位到作业、驱逐/续训不触发。此 patch 用注解兜底把 A5 纳入同一故障管理路径。
- 单测同步新增一条 case(`pod_util_test.go`:删掉 910 注解、只留 `PodNPUDeviceAnno` 仍能解析出设备),锁住兜底行为。

### mind-cluster · 增量故障处理器补 Debug 日志(仅可观测)
`component/clusterd/pkg/application/faultmanager/cmprocess/incrementfault/increment_fault_processor.go`:在"首次处理节点""无增量故障""节点增量故障明细"三个分支各加一行 `hwlog.RunLog.Debugf`,外加一处注释措辞订正(`fault have no changed`→`has no change`)。无逻辑改动,属 A5 故障排障的配套日志加固,与上条同批。

## 本期无实质改动 / 仅文档(折叠)
<details><summary>展开</summary>

- mind-cluster 其余改动均为文档/构建:infer-operator README 从旧版改为带目录+mermaid 架构图的新版(156 行,阐述 InferServiceSet/InferService/InstanceSet 三 CRD 及与 Volcano/Ascend Device Plugin 的上下游);另有驱逐资料、示例镜像名、`reset-config-<job-name>` ConfigMap 说明等资料订正——无代码信号。
- 旁注(超出 `component/` 跟踪范围,仅见于 commit 列表,未读 diff):「Add clusterops-agent in build_all.sh」把一个新组件 `clusterops-agent` 纳入构建脚本,疑似昇腾在孵化新的集群运维 agent 组件,后续若落到 `component/` 下再纳入正式跟踪。
- openFuyao 8 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)无新提交,HEAD 与 10-09 锚点逐仓一致。
</details>

## 对我们产品的启示
- 昇腾在把故障管理/驱逐链路向新硬件代次(A5)拉齐:关键不在算法而在**设备归属的注解契约**——910 专用注解与通用 NPU 注解并存,消费侧(clusterd)需两者都认。我们若自研 NPU 故障感知/驱逐,要把"Pod→设备"映射做成对多注解键兼容,避免绑死单一芯片代次的注解。
- `clusterops-agent` 这个新构建目标值得盯——可能是昇腾把集群级运维(故障处置/续训编排)从 clusterd 里拆分出独立 agent 的信号,下期确认。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=eed2442f9061cf6fe5ab1ef86926fa3bbc7bdf48 tag=v26.1.1 scanned=2026-10-10 -->
<!-- ANCHOR repo=npu-operator sha=c806e3c8e0ef6a8a271293497d08fdf848dd0e1a tag=v26.6.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-10-10 -->
