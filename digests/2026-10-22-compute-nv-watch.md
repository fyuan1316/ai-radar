# NVIDIA 算力栈 diff 雷达 2026-10-22

## 摘要
- gpu-operator 修了一处 DaemonSet 就绪误判:在 `isDaemonSetReady` 里加 `ObservedGeneration < Generation` 门槛,避免 operator 在 DaemonSet 控制器尚未 reconcile 新 spec 时就把组件判为 Ready——对滚动升级/OnDelete 场景的状态准确性有直接影响。
- KAI-Scheduler podgrouper 给 controller-runtime cache 加上 `TransformStripManagedFields()`,从源头砍掉缓存对象里的 managedFields,降大规模集群下 podgrouper 常驻内存。
- DCGM 合入 4.7.0(大区间概览,未逐文件读代码);其余 6 仓无实质改动。

## 当日重要改变
- NVIDIA/DCGM [版本跨档] 单次 squash 提交 "DCGM 4.7.0 (#319)" 落地新 minor 版本,改动面广(files 被 API 截断到 300,热点集中在 common/CudaWorker、common/test-utils、dcgmbuild 等底层库与构建),但仓库未打 release tag、无 release body,具体 breaking/指标语义变化无法从 diff 判定。证据:https://github.com/NVIDIA/DCGM/commit/9fae2867e6e5264fa0fca22a07dc898d591baa21

## NVIDIA/gpu-operator: dbb11e85 -> 932f9068
- 比较 / 最新 Release:dbb11e85 -> 932f9068 | ahead=5 | files=6 | Release: v26.7.2
- https://github.com/NVIDIA/gpu-operator/compare/dbb11e85129b601afe9fb502ac25b062ad094abd...932f9068433d031244b986ed253e14263aa22e8e

### AI 总结重点(源码 diff 为据)
- `controllers/object_controls.go` 的 `isDaemonSetReady` 新增一道代际门槛:当 `ds.Status.ObservedGeneration < ds.Generation` 时直接返回 `NotReady`。此前该函数在拉到 DaemonSet 后紧接着就看 `DesiredNumberScheduled==0` 等运行态字段,若 DaemonSet 控制器还没观测到最新 spec(刚改完 generation 自增、status 仍是旧值),operator 可能把一个其实没开始滚动的组件误判为 Ready。改后强制等 status 代际追平 spec 代际再做后续判断。配套测试覆盖了"generation 未追平→NotReady""追平且无 Pod→Ready"以及 OnDelete 升级策略两种路径。
  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
  	if ds.Status.DesiredNumberScheduled == 0 {
  		n.logger.V(2).Info("Daemonset has desired pods of 0", "name", name)
  ```
  改为在该判断之前插入:
  ```diff
  +	if ds.Status.ObservedGeneration < ds.Generation {
  +		n.logger.V(2).Info("daemonset controller has not observed latest generation", "name", name)
  +		return gpuv1.NotReady
  +	}
  ```
  提交:https://github.com/NVIDIA/gpu-operator/commit/96f0ba29 (PR #3079)
  </details>
- Helm values 给内嵌的 node-feature-discovery `gc` 组件暴露 `tolerations` 字段(默认 `[]`),使 nfd 的 garbage-collector 可以被调度到带污点的节点上。纯编排/可配置性增强,非算力路径逻辑改动。
  <details><summary>代码依据 deployments/gpu-operator/values.yaml</summary>

  ```diff
   node-feature-discovery:
     gc:
       enable: true
       replicaCount: 1
  +    tolerations: []
  ```
  提交:https://github.com/NVIDIA/gpu-operator/commit/49e93d96 (PR #3090)
  </details>
- 其余为 go toolchain 1.27.2→1.27.3 的例行 bump(versions.mk + 两个 Dockerfile),不计入功能信号。

### 后续发展方向 [AI]
- DaemonSet 就绪判定收紧属于 operator 状态机健壮性修补,方向上是让 ClusterPolicy 的 `State` 汇报更贴近真实 reconcile 进度;证据只覆盖 `isDaemonSetReady` 一个函数,未见对 ClusterPolicy CRD 字段或整体 reconcile 流程的改动。本期无 `api/nvidia/v1/clusterpolicy_types.go` 命中,CRD 契约未变。

## kai-scheduler/KAI-Scheduler: 9f621776 -> 4b90eacd
- 比较 / 最新 Release:9f621776 -> 4b90eacd | ahead=1 | files=2 | Release: v0.16.12
- https://github.com/kai-scheduler/KAI-Scheduler/compare/9f621776ee65ebdf8b2ef9d36093946292c251e7...4b90eacd8f8f7bc1155fd078f55b895408a84234

### AI 总结重点(源码 diff 为据)
- `cmd/podgrouper/app/app.go` 的 `getCacheOptions` 把原本空的 `cache.Options{}` 改为带 `DefaultTransform: cache.TransformStripManagedFields()`。效果是 podgrouper 用 controller-runtime 建 informer cache 时,对所有缓存对象统一剥掉 `metadata.managedFields`(server-side-apply 累积的字段级 owner 元数据,往往占对象体积相当比例)。这是针对大规模集群下 podgrouper 内存占用的源头优化,不改调度语义。
  <details><summary>代码依据 cmd/podgrouper/app/app.go</summary>

  ```diff
  -	cacheOptions := cache.Options{}
  +	cacheOptions := cache.Options{
  +		DefaultTransform: cache.TransformStripManagedFields(),
  +	}
  	cacheOptions.ByObject = map[client.Object]cache.ByObject{
  		&corev1.Pod{}: podByObject,
  	}
  ```
  提交:https://github.com/kai-scheduler/KAI-Scheduler/commit/4b90eacd8f8f7bc1155fd078f55b895408a84234 (PR #2431)
  </details>

### 后续发展方向 [AI]
- KAI 持续做 controller 层的内存/伸缩性打磨(此前多次围绕 cache/informer),方向是把 podgrouper 推向更大规模集群可用;证据仅覆盖 podgrouper 一处 cache 配置,未见调度算法或 PodGroup CRD 变化。

## NVIDIA/DCGM: 64df9f89 -> 9fae2867(大区间概览,未逐文件读代码)
- 比较 / 最新 Release:64df9f89 -> 9fae2867 | ahead=1 | files=300(已被 API 截断) | Release: —
- https://github.com/NVIDIA/DCGM/compare/64df9f894541e426e416131a9820cae97aa4dd81...9fae2867e6e5264fa0fca22a07dc898d591baa21

### 概览(聚类,未逐文件读 hunk)
- 单次 squash 提交 "DCGM 4.7.0 (#319)" 一次性落地整条 4.7.0 分支,因此 ahead 虽只有 1 但改动面极大,files 被 GitHub compare API 截断到 300,无法完整枚举。
- 改动热点目录(top):common/test-utils(32)、common/tests(25)、common/CudaWorker(24)、common/ChildProcess(13)、dcgmbuild/container-images(11)、common/DcgmOps(10)、common/CudaLib(10)、common/RemoteConn/CudaOps/CublasOps 等——集中在底层 CUDA worker、子进程/远程连接框架、构建镜像与测试工具,偏健康检查/profiling 内核与工程基建,未见明确的指标语义或对外 API 文件。
- 仓库未打 release tag、release body 为空,无法从 diff 判定是否含 breaking 或新增/变更指标。需要判读具体指标变化时,以 dcgm-exporter 侧为准(本期 dcgm-exporter EMPTY)。

## 本期无实质改动(折叠)
<details><summary>6 仓 EMPTY</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交(Release v1.20.1)
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交(Release v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(Release v0.5.1)
- NVIDIA/dcgm-exporter — 无新提交(Release 4.8.4)
- NVIDIA/mig-parted — 无新提交(Release v0.15.1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=932f9068433d031244b986ed253e14263aa22e8e branch=main release=v26.7.2 scanned=2026-10-22 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=44f1c6ef98c9f82ee53c6018086a40b436260f9e branch=main release=v1.20.1 scanned=2026-10-22 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d6d82abedb448b8f67992f1b59c86f163df24772 branch=main release=— scanned=2026-10-22 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-22 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=63e98d305bb66cb9f2a07a0669661329d320ee3f branch=main release=v0.5.1 scanned=2026-10-22 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-22 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-22 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-22 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=4b90eacd8f8f7bc1155fd078f55b895408a84234 branch=main release=v0.16.12 scanned=2026-10-22 -->
</content>
</invoke>
