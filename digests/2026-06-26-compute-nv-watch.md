# NVIDIA 算力栈 diff 雷达 2026-06-26

## 摘要
- KAI-Scheduler 给 NUMA placement exporter 加了**默认节点选择器** `feature.node.kubernetes.io/memory-numa=true`:不显式配 NodeSelector 时,exporter DaemonSet 默认只投到 NFD 识别出有 NUMA 内存拓扑的节点,把"哪些节点跑 NUMA 观测"从手工配置收敛成开箱即用——NUMA 感知调度链路又往生产可用靠近一步。
- nvidia-container-toolkit 把 `OpenCL/vendors/nvidia.icd` 补进图形挂载发现器,补齐容器内 OpenCL 工作负载的 GPU 可见性(此前只挂 OptiX/X11 相关文件)。
- 其余 6 仓(gpu-operator/gpu-driver-container/k8s-device-plugin/dcgm-exporter/mig-parted/DCGM)本期无实质改动。

## 当日重要改变
- KAI-Scheduler [行为默认变更] NUMA placement exporter 新增默认 NodeSelector,空值时落 `feature.node.kubernetes.io/memory-numa=true`,改变了 exporter 的默认投放面。证据:`pkg/apis/kai/v1/numa_placement_exporter/numa_placement_exporter.go` https://github.com/kai-scheduler/KAI-Scheduler/pull/1767
- nvidia-container-toolkit [新能力] 容器内 OpenCL ICD 挂载补齐。证据:`internal/discover/graphics.go` https://github.com/NVIDIA/nvidia-container-toolkit/compare/6fe425a59d0f...d0bf15cb

## kai-scheduler/KAI-Scheduler: 181e80d2 -> 0e2df72c
- 比较: 181e80d2d4f2856c140a7d4dcde11f003c7c6573 -> 0e2df72c | ahead=1 | files=4 | Release: v0.16.0
- https://github.com/kai-scheduler/KAI-Scheduler/pull/1767

### AI 总结重点(源码 diff 为据)
- `NumaPlacementExporter.SetDefaultsWhereNeeded()` 现在会在 `NodeSelector` 为空(nil 或长度 0)时,写入默认值 `{"feature.node.kubernetes.io/memory-numa": "true"}`;新增包级常量 `defaultNodeSelectorKey`。前:不配 NodeSelector 时 exporter DaemonSet 没有节点过滤,会铺到全部节点;后:默认只投到 NFD 打了 `feature.node.kubernetes.io/memory-numa` 标签(即检出 NUMA 内存拓扑)的节点。语义上把"NUMA 观测只在有 NUMA 的节点跑"变成默认行为,减少在单 NUMA / 无拓扑节点上空跑 DaemonSet。显式配置的 NodeSelector 被原样保留(测试 "preserves an explicit ... node selector" 覆盖)。

  <details><summary>代码依据 pkg/apis/kai/v1/numa_placement_exporter/numa_placement_exporter.go</summary>

  ```diff
   const imageName = "numa-placement-exporter"

  +const defaultNodeSelectorKey = "feature.node.kubernetes.io/memory-numa"
  +
   func (n *NumaPlacementExporter) SetDefaultsWhereNeeded() {
   	n.Service = common.SetDefault(n.Service, &common.Service{})
  +	if len(n.NodeSelector) == 0 {
  +		n.NodeSelector = map[string]string{defaultNodeSelectorKey: "true"}
  +	}
  ```
  </details>

- 配套:operator 侧 `numa_placement_exporter_test.go` 断言生成的 DaemonSet `Spec.Template.Spec.NodeSelector` 等于该默认 map,证明默认值确实贯通到了实际下发的 DaemonSet PodSpec(不止停在 config 默认化层);`config_types_test.go` 三个新用例分别覆盖 nil、空 map、显式值三态。`.github/workflows/validate-pr-title.yaml` 把 `numa-placement-exporter` 加进合法 PR scope 列表(纯流程)。

  <details><summary>代码依据 pkg/operator/operands/numa_placement_exporter/numa_placement_exporter_test.go</summary>

  ```diff
   		Expect(ds).ToNot(BeNil())
  +		Expect(ds.Spec.Template.Spec.NodeSelector).To(Equal(map[string]string{
  +			"feature.node.kubernetes.io/memory-numa": "true",
  +		}))
  ```
  </details>

### 后续发展方向 [AI]
- 该默认值把 KAI 的 NUMA 感知调度与 NFD 标签体系硬绑定:依赖 NFD 已在集群部署且开启 memory NUMA source。生产部署 KAI NUMA 调度时需把 NFD 列为前置依赖,否则默认 selector 会让 exporter 投不到任何节点(无标签 = 不调度),反而比之前"全节点铺"更易踩"exporter 一个都没起来"的坑。证据只覆盖 exporter 的默认 NodeSelector 与 DaemonSet 下发,未见 numa scheduler plugin 消费侧或 NFD 依赖文档的改动。

## nvidia-container-toolkit: 6fe425a5 -> d0bf15cb
- 比较: 6fe425a59d0f722fd4ee29777f0714407bfeb909 -> d0bf15cb | ahead=2 | files=1 | Release: v1.19.1
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/6fe425a59d0f...d0bf15cb

### AI 总结重点(源码 diff 为据)
- `NewGraphicsMountsDiscoverer` 的挂载文件清单新增一项 `OpenCL/vendors/nvidia.icd`。该 ICD(Installable Client Driver)文件是 OpenCL runtime 在容器内定位 NVIDIA OpenCL 实现的入口;此前清单只含 OptiX(`nvidia/nvoptix.bin`)和 X11 配置,缺这条会导致容器内 OpenCL 应用枚举不到 NVIDIA 设备。属于图形/计算可见性补齐,不涉及 CUDA 主路径。

  <details><summary>代码依据 internal/discover/graphics.go</summary>

  ```diff
   			"nvidia/nvoptix.bin",
   			"X11/xorg.conf.d/10-nvidia.conf",
   			"X11/xorg.conf.d/nvidia-drm-outputclass.conf",
  +			"OpenCL/vendors/nvidia.icd",
   		},
  ```
  </details>

### 后续发展方向 [AI]
- 纯能力补齐,无架构信号。证据仅 1 文件 1 行,未见对 CDI spec 生成或其他 runtime hook 的连带改动。

## dra-driver-nvidia-gpu: 65a7e283 -> 74b77854
- 比较: 65a7e283b7826333e20578bebb98bbbf9246a2df -> 74b77854 | ahead=2 | files=1 | Release: v0.4.1-rc.1
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/65a7e283b782...74b77854

### AI 总结重点(源码 diff 为据)
- 删除 `hack/package-helm-charts.sh`(原用于 release/Prow 把 Helm chart 打成 OCI 推 staging registry)。属 release 工具链调整,无 DRA 运行时/API 改动;推测 chart 打包已迁到统一构建流程(Makefile/CI),但本期 diff 只见删除、未见替代脚本落地。

  <details><summary>代码依据 hack/package-helm-charts.sh(removed)</summary>

  ```diff
  -# Packages the Helm chart for release or for Prow / Cloud Build jobs that push
  -# OCI charts to staging/promotion registries.
  -helm package deployments/helm/dra-driver-nvidia-gpu/ --version $VERSION --app-version $VERSION
  ```
  </details>

### 后续发展方向 [AI]
- 无功能/架构信号,仅打包脚本清理。证据未覆盖替代打包路径。

## 本期无实质改动(折叠)
<details><summary>6 仓 EMPTY</summary>

- NVIDIA/gpu-operator(无新提交,Release v26.3.3)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交,Release v0.19.3)
- NVIDIA/dcgm-exporter(无新提交,Release 4.5.3-4.8.2)
- NVIDIA/mig-parted(无新提交,Release v0.14.2)
- NVIDIA/DCGM(无新提交,branch master)
</details>

## 对我们产品的启示
- KAI 把"NUMA 观测只在 NUMA 节点跑"做成默认,且实现上强依赖 NFD 标签——若我们产品也走 NUMA 感知调度,需把 NFD(及其 memory-numa source)作为显式前置依赖纳入安装编排,并在默认 selector 投不到节点时给出可诊断信号,避免静默"exporter 零副本"。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9e35d5d4d2b30ca123aae53176ad9b8dfa6342f7 branch=main release=v26.3.3 scanned=2026-06-26 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d0bf15cb4bc7a6ad527752adb05df6e096d95a4f branch=main release=v1.19.1 scanned=2026-06-26 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d13e99f038cf9943c73e53e2b17af34883ae3ae3 branch=main release=— scanned=2026-06-26 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.3 scanned=2026-06-26 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=74b778541393353adbc6bd33b6a9839b04e077e4 branch=main release=v0.4.1-rc.1 scanned=2026-06-26 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-26 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5dc3caa478807fec0fc6a2160ef9e8f056300e4e branch=main release=v0.14.2 scanned=2026-06-26 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=0e2df72c76d60c4180cb7f0cd1dd184d72191372 branch=main release=v0.16.0 scanned=2026-06-26 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-26 -->
