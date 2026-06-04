# NVIDIA 算力栈 diff 雷达 2026-06-05

> 区间:6/03 基线锚点 → 今日 HEAD(基线后首个增量,实际覆盖 6/03–6/05 两日)。

## 摘要
- **KAI-Scheduler 出现两处能力级改动**:① RuntimeClass 注入从"所有 GPU pod"收窄为"仅 GPU 分片 pod"(新字段 `GPUFractionRuntimeClassName`,弃用 `GPUPodRuntimeClassName`);② 接入 NodeResourceTopology(NRT)做 NUMA 拓扑感知调度(新 feature gate + NodeInfo 挂 NRT 对象)。
- nvidia-container-toolkit 修了 CDI 自动刷新(nvidia-cdi-refresh)的 systemd 打包,把 unit 从 `/etc/systemd/system` 迁到规范的 `/lib/systemd/system`,并清理旧的残留 enablement 软链——影响驱动变更后 CDI 规格自动重生的可靠性。
- 其余 7 仓本期无实质代码改动(EMPTY 或仅文档站脚手架),见末尾折叠区。

## 当日重要改变
- KAI-Scheduler [API/CRD变更][架构方向] 新增 CRD 字段 `gpuFractionRuntimeClassName`,弃用 `gpuPodRuntimeClassName`;runtime class 只对 gpu-fraction/gpu-memory 注解的分片 pod 生效,整卡 pod 不再注入 nvidia runtime。证据 `pkg/apis/kai/v1/admission/admission.go`、`deployments/kai-scheduler/crds/kai.scheduler_configs.yaml`、commit "fix: Inject the nvidia runtime by default only to fractional pods (#1636)" https://github.com/kai-scheduler/KAI-Scheduler/commit/71c61d07daf217d2b4324ca74d3fef917c9ae107
- KAI-Scheduler [新能力][架构方向] 接入 NodeResourceTopology(`topology.node.k8s.io`)做 NUMA 感知:新 feature gate `NodeResourceTopologyEnabled`、`NodeInfo.NodeResourceTopology` 字段、cluster_info 注入 NRT informer。证据 `pkg/common/feature_gates/feature_gates.go`、`pkg/scheduler/cache/cluster_info/cluster_info.go`、commit "feat: Numa plugin info objects (#1666)" 同上 compare。

## kai-scheduler/KAI-Scheduler: 3247e211 -> 71c61d07
- 比较 3247e211 -> 71c61d07 | ahead=5 | files=46 | Release: v0.14.5
- 比较页 https://github.com/kai-scheduler/KAI-Scheduler/compare/3247e2114aa2ed60c2ac61d49580a306cb9b98d7...71c61d07daf217d2b4324ca74d3fef917c9ae107

### AI 总结重点(源码 diff 为据)
- **RuntimeClass 注入语义收窄 + 字段弃用**:`Admission` 结构体把单一的 `GPUPodRuntimeClassName`(语义为"所有 GPU pod 都设 runtime class")拆成新字段 `GPUFractionRuntimeClassName`(仅作用于按 `gpu-fraction`/`gpu-memory` 注解申请的分片 pod,整卡 pod 不受影响)。默认值逻辑改为:仅当用户没设弃用字段时,才给新字段填默认 runtime class;两者都设时新字段优先。配套 `ResourceReservation.RuntimeClassName` 取消了默认值(原来强制 `DefaultRuntimeClassName`,现默认空=不设 runtime class)。这等于把"为了显存分片要走 nvidia runtime"的副作用限制在真正需要它的分片场景,整卡直通路径不再被无谓注入。
  <details><summary>代码依据 pkg/apis/kai/v1/admission/admission.go</summary>

  ```diff
  -	// GPUPodRuntimeClassName specifies the runtime class to be set for GPU pods
  -	// set to empty string to disable
  +	// GPUPodRuntimeClassName ...
  +	// Deprecated: use GPUFractionRuntimeClassName. If both are set,
  +	// GPUFractionRuntimeClassName wins.
   	GPUPodRuntimeClassName *string `json:"gpuPodRuntimeClassName,omitempty"`
  +	// GPUFractionRuntimeClassName specifies the runtime class to be set for
  +	// GPU fraction pods (those requesting GPU via the gpu-fraction or
  +	// gpu-memory annotations). Whole-GPU pods are not affected.
  +	GPUFractionRuntimeClassName *string `json:"gpuFractionRuntimeClassName,omitempty"`
   ...
  -	b.GPUPodRuntimeClassName = common.SetDefault(b.GPUPodRuntimeClassName, ptr.To(constants.DefaultRuntimeClassName))
  +	if b.GPUFractionRuntimeClassName == nil {
  +		if b.GPUPodRuntimeClassName == nil {
  +			b.GPUFractionRuntimeClassName = ptr.To(constants.DefaultRuntimeClassName)
  +		}
  +	}
  ```
  </details>
  <details><summary>代码依据 deployments/kai-scheduler/crds/kai.scheduler_configs.yaml(CRD 同步)</summary>

  ```diff
  +                  gpuFractionRuntimeClassName:
  +                    description: |-
  +                      ... runtime class ... for GPU fraction pods ...
  +                      Whole-GPU pods are not affected.
                     gpuPodRuntimeClassName:
  -                      ... runtime class to be set for GPU pods
  +                      Deprecated: use GPUFractionRuntimeClassName. If both are set,
  +                      GPUFractionRuntimeClassName wins.
  ```
  </details>
- **接入 NodeResourceTopology(NUMA 拓扑感知)**:新增进程级 feature gate `NodeResourceTopologyEnabled`,通过 discovery 探测集群是否提供 `topology.node.k8s.io` API 组(即 NRT CRD,通常由 NFD/RTE 产出)来决定开关;`NodeInfo` 新增 `NodeResourceTopology *nrtv1alpha2.NodeResourceTopology` 字段,快照节点时 `populateNodeResourceTopologies` 把每个节点的 NRT 对象挂上去(CRD 未安装时 no-op),`ClusterInfo.New` 多接一个 NRT informer factory。这是把每节点 NUMA/per-zone 资源拓扑喂进调度器的地基,为后续 NUMA 对齐的 GPU/CPU 协同放置铺路。
  <details><summary>代码依据 pkg/common/feature_gates/feature_gates.go</summary>

  ```diff
  +	nodeResourceTopologyGroup = "topology.node.k8s.io"
  +var nodeResourceTopologyEnabled atomic.Bool
  +func IsNodeResourceTopologyEnabled(discoveryClient discovery.DiscoveryInterface) bool {
  +	for _, group := range serverGroups.Groups {
  +		if group.Name == nodeResourceTopologyGroup { return true }
  +	}
  +	return false
  +}
  ```
  </details>
  <details><summary>代码依据 pkg/scheduler/cache/cluster_info/cluster_info.go + node_info.go</summary>

  ```diff
  +	NodeResourceTopology *nrtv1alpha2.NodeResourceTopology   // node_info.go
   ...
   	c.populateDRAGPUs(resultNodes)
  +	c.populateNodeResourceTopologies(resultNodes)
  +func (c *ClusterInfo) populateNodeResourceTopologies(nodes map[string]*node_info.NodeInfo) {
  +	nrts, err := c.dataLister.ListNodeResourceTopologies()
  +	for _, nrt := range nrts {
  +		if nodeInfo, found := nodes[nrt.Name]; found { nodeInfo.NodeResourceTopology = nrt }
  +	}
  +}
  ```
  </details>
- 其余改动为工程化:e2e 加 `runPreflight` 守卫(检测 kubeconfig 是否指向含非测试 Queue 的真实集群,拒绝跑 e2e 防误伤),preempt 场景构造器补 nil 防护,Helm chart 暴露 security/resources 配置——均非能力面,不展开。

### 后续发展方向 [AI]
- NRT 接入目前只到"采集并挂载到 NodeInfo"这一层(`feat: Numa plugin info objects`),**证据未见**任何打分/过滤插件真正消费 `NodeInfo.NodeResourceTopology`——下一步应出现 NUMA 对齐的 predicate/score 逻辑。值得盯 `pkg/scheduler` 下是否新增 numa plugin 的 Allocate 决策。
- RuntimeClass 拆分明确把 KAI 的 GPU 分片(fraction/memory 注解)与整卡直通在注入路径上彻底分开,方向是减少整卡场景对自定义 nvidia runtime 的依赖;但证据只覆盖 admission 默认值与字段,未见 binder/webhook 实际下发 runtime class 的调用点改动。

## 本期无实质改动
<details><summary>EMPTY / 非功能改动的 8 仓(保留锚点,详见末尾)</summary>

- NVIDIA/gpu-operator — ahead=2,仅 bump/CI/merge,无实质提交。
- NVIDIA/gpu-driver-container — 无新提交。
- NVIDIA/k8s-device-plugin — 无新提交(仍 v0.19.2)。
- NVIDIA/dcgm-exporter — 无新提交。
- NVIDIA/DCGM — 无新提交(master)。
- NVIDIA/mig-parted — ahead=4,仅 bump/CI/merge,无实质代码。
- kubernetes-sigs/dra-driver-nvidia-gpu — ahead=4,仅"Add hugo and docsy site" + 修符号链接,纯文档站脚手架(package-lock.json / hugo.toml / 概念&指南 md),**无功能性 GPU 代码改动**;新增文档含 gpu-allocation/compute-domains/gpu-sharing/feature-gates 等参考页,后续可作能力索引,但本期不计入代码趋势。
- NVIDIA/nvidia-container-toolkit — 见下,有一笔打包修复(非 API)。

</details>

## NVIDIA/nvidia-container-toolkit: fc098e74 -> 1f7480c8(打包修复,非 API)
- 比较 fc098e74 -> 1f7480c8 | ahead=2 | files=11 | Release: v1.19.1
- 比较页 https://github.com/NVIDIA/nvidia-container-toolkit/compare/fc098e74b35202ff85925c415d4bcbbeb8065ae4...1f7480c8c9f6f2e31d35dad753f77b56c95d2dd4

### AI 总结重点(源码 diff 为据)
- **nvidia-cdi-refresh 的 systemd 单元改用规范打包**:原先 RPM/DEB 把 `nvidia-cdi-refresh.service`/`.path` 装进 `/etc/systemd/system` 并在 postinst 里手动 `systemctl enable --now`;现改为装进 `%{_unitdir}`(`/lib/systemd/system`)+ 加 preset 文件,RPM 用 `%systemd_post/%preun/%postun` 宏管理生命周期,DEB 用 `dh --with systemd`。并新增 `%posttrans` 清理逻辑:升级时检测 `/etc/systemd/system/...wants/` 下仍指向旧路径的残留 enablement 软链并删除/重建。CDI 自动刷新(驱动/设备变化时重生 CDI 规格)是容器内 GPU 可见性的关键自动化,这笔修复直接影响其在升级后能否被正确 enable。
  <details><summary>代码依据 packaging/debian/nvidia-container-toolkit-base.install + rpm spec</summary>

  ```diff
  -nvidia-cdi-refresh.service /etc/systemd/system/
  -nvidia-cdi-refresh.path /etc/systemd/system/
  +nvidia-cdi-refresh.service /lib/systemd/system/
  +nvidia-cdi-refresh.path /lib/systemd/system/
  ```
  ```diff
  +%systemd_post nvidia-cdi-refresh.path nvidia-cdi-refresh.service
  +%posttrans base
  +# remove unowned enablement links still pointing at the old /etc location
  ```
  </details>

### 后续发展方向 [AI]
- 纯打包/部署修复,无 runtime hook 或 CDI 生成逻辑改动;证据只覆盖 spec/postinst/rules,未见 `nvidia-ctk`/cdi 包的 Go 代码变化。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=32bd22c788693321f4f395599eb859a2ee666241 branch=main release=v26.3.2 scanned=2026-06-05 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1f7480c8c9f6f2e31d35dad753f77b56c95d2dd4 branch=main release=v1.19.1 scanned=2026-06-05 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=880c6dc19ca620fd0011de056829798b83a63c77 branch=main release=— scanned=2026-06-05 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=db1ea9481054448d97ae43bd082147e7d6ba5501 branch=main release=v0.19.2 scanned=2026-06-05 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=1dd7b11b349231a3061aee24f103d6fb4eefe900 branch=main release=v0.4.0 scanned=2026-06-05 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-05 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=0869351a7d89ff24e68c93b92a50d981cea15580 branch=master release=— scanned=2026-06-05 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=b24528651efb64b358e7fc169d4cb18d9ac06347 branch=main release=v0.14.2 scanned=2026-06-05 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=71c61d07daf217d2b4324ca74d3fef917c9ae107 branch=main release=v0.14.5 scanned=2026-06-05 -->
