# NVIDIA 算力栈 diff 雷达 2026-07-20

## 摘要
- 本日 8/9 仓无实质改动;唯一有新提交的 kai-scheduler/KAI-Scheduler(ahead=1)是**纯文档提交**——新增 KAI × Karpenter 交互说明,未触碰代码/API/CRD。无任何"重要改变"信号,视同安静日:仅归档保锚点链,不推飞书。

## 当日重要改变
无

## kai-scheduler/KAI-Scheduler: 64f3e37d -> 7ca4ca72
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/64f3e37d336f0751e31ffe39fc6c4076beb7b60e...7ca4ca72b88a2780a6418189e1a5c3bd27d75cb9 | Release: v0.16.4
### AI 总结重点(源码 diff 为据)
- 本期唯一改动是**文档**,非代码:新增 `docs/gpu-sharing/autoscaling/karpenter.md`(+41)并在 autoscaling `README.md` 追加一节链接(+3)。内容说明 KAI 在使用 Karpenter 做节点供给/回收的集群里如何协作——**未改任何调度/绑定逻辑**,`node-scale-adjuster`、binder 等实现文件均未动,无 API/CRD 路径命中。
- 文档披露的既有机制(非本期新增能力,只是首次成文):① 分数 GPU 负载会在 `kai-resource-reservation` 命名空间创建持有整卡 `nvidia.com/gpu` 请求的**预留 pod** 防止重复占卡;② KAI 给这些预留 pod 打上 Karpenter 的 `karpenter.sh/do-not-disrupt` 注解,阻止常规自愿式节点回收(consolidation);③ 明确职责边界——Karpenter 只做容量模拟与节点增删,**实际 pod 落点归 KAI Scheduler/Binder**,Karpenter 不给 KAI pod 设 `spec.nodeName`。
  <details><summary>代码依据 docs/gpu-sharing/autoscaling/karpenter.md(纯新增文档)</summary>

  ```diff
  +## Gpu Fractional Pods
  +For fractional GPU workloads, KAI creates GPU reservation pods in the `kai-resource-reservation` namespace.
  +These reservation pods have a normal `nvidia.com/gpu` request and are used by KAI to "reserve" gpus consumed by the fractional pods. ... KAI annotates these reservation pods with Karpenter's `karpenter.sh/do-not-disrupt` annotation.
  +...
  +Actual pod placement is still owned by the scheduler and binder path:
  +* Karpenter models whether capacity can exist for the pods.
  +* KAI Scheduler chooses the node for KAI-managed workloads.
  +* KAI Binder creates and binds fractional GPU reservation pods and then binds the workload pod.
  ```
  </details>
- 来源提交/PR:https://github.com/kai-scheduler/KAI-Scheduler/pull/1941
### 后续发展方向 [AI]
- 证据仅覆盖文档,未见任何代码/接口改动,不构成能力或架构演进信号。可留意的边界信息:KAI 对整卡预留 + `do-not-disrupt` 注解这套"分数 GPU 防回收"机制正在被显式文档化,说明其与外部 autoscaler(Cluster Autoscaler / Karpenter)的协作正走向稳定;但本期无法判断是否有配套代码变更(证据只覆盖 docs,未见 `cmd/nodescaleadjuster`、binder 实现)。

## 本期无实质改动(折叠)
- NVIDIA/gpu-operator(无新提交;Release v26.3.3)
- NVIDIA/nvidia-container-toolkit(无新提交;Release v1.20.0-rc.1)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交;Release v0.19.3)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交;Release v0.4.1)
- NVIDIA/dcgm-exporter(无新提交;Release 4.6.0-4.8.3)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交;Release v0.14.4)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7f838266952433b07a705ffd3aceebf411d463ad branch=main release=v26.3.3 scanned=2026-07-20 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1cddfb0dc179136cd720090f0a13e6ce0de611ed branch=main release=v1.20.0-rc.1 scanned=2026-07-20 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=b7d88d64c402759134ad0ed7475ec9bc4fb4fe60 branch=main release=— scanned=2026-07-20 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=248164727d5d8bac7024a8e12a13e69246cf0969 branch=main release=v0.19.3 scanned=2026-07-20 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=e254b82a98621f81483554746cab1983860a6490 branch=main release=v0.4.1 scanned=2026-07-20 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-20 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-20 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=567b93739cda8a9d2bad51286171daab25d107f5 branch=main release=v0.14.4 scanned=2026-07-20 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=7ca4ca72b88a2780a6418189e1a5c3bd27d75cb9 branch=main release=v0.16.4 scanned=2026-07-20 -->
