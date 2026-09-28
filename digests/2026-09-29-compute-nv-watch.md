# NVIDIA 算力栈 diff 雷达 2026-09-29

## 摘要
- 仅 KAI-Scheduler 有实质更新(12 commit),其余 8 仓无新提交。三个方向信号:①GPU 资源识别从"后缀匹配"改为"精确名匹配",顺带显式纳入 AMD GPU → 调度器向多厂商 GPU 扩;②新增 FIPS-only 模式,给所有 KAI 容器注入 `GODEBUG=fips140=only` → 面向合规/政企;③大规模 scale test 首次覆盖"分离式推理(prefill/decode)"与"拓扑感知(zone/block/rack 512+节点)"场景。
- 版本:KAI 由 v0.18.0 → v0.18.1(patch),SUPPORT.md 将 v0.18 正式列为新 LTS 线(Sep 2026–Sep 2027),v0.17 转 EOL。非 major/minor 跨档。
- 对我们产品的启示:通用调度器(KAI/原 Run:ai)正把"分离式推理调度 + 拓扑对齐 + 多厂商 GPU + 合规"打包进企业能力,与 OAI 的模型服务栈是同一竞争面,值得跟其 API(v2alpha2 PodGroup 的 SubGroup/TopologyConstraint)演进。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [新能力/多厂商] `isGpuResource` 由 `HasSuffix(name,"gpu")` 收紧为精确匹配 nvidia/amd GPU 资源名,修正 `nvidia.com/vgpu`、`example.com/mygpu` 等被误并入 GPU 维度的账目错误;并首次把 AMD GPU 资源名纳入。证据 `pkg/scheduler/api/resource_info/resource_vector.go`。https://github.com/kai-scheduler/KAI-Scheduler/pull/2195
- kai-scheduler/KAI-Scheduler [企业级/合规] 新增 `pkg/common/fips/fips.go`,`OnlyEnv(true)` 向所有 KAI 容器注入 `GODEBUG=fips140=only,tlsmlkem=0`,进入 FIPS-only 密码学模式。https://github.com/kai-scheduler/KAI-Scheduler/pull/2240
- kai-scheduler/KAI-Scheduler [集成] 当 GPU Operator 启用 NRI 时,禁用分数 GPU 的 RuntimeClass 注入(避免与 NRI 路径冲突);本期 diff 未含该文件 hunk,结论仅据提交标题。https://github.com/kai-scheduler/KAI-Scheduler/pull/2211

## kai-scheduler/KAI-Scheduler: b4486893 -> 52155f61
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/b44868939553e64c67b43467b8e0cc4939495d32...52155f61 | ahead=12 | files=66 | Release: v0.18.1

### AI 总结重点(源码 diff 为据)
- **GPU 资源识别改为精确匹配,并显式支持 AMD GPU**:旧逻辑用后缀 `gpu` 判定,任何以 gpu 结尾的资源名(如 `nvidia.com/vgpu`)都会被当成整卡 GPU 计入资源向量;新逻辑改为 switch 精确匹配 `GpuResource`/`GPUResourceName`(nvidia)/`amdGpuResourceName`。含义:一是修正显存分片/vGPU 类资源被误算的账目 bug,二是把 AMD GPU 纳入 GPU 维度,调度器不再是纯 NVIDIA 单厂商。
  <details><summary>代码依据 pkg/scheduler/api/resource_info/resource_vector.go</summary>

  ```diff
   func isGpuResource(resourceName v1.ResourceName) bool {
  -	return strings.HasSuffix(string(resourceName), constants.GpuResource)
  +	switch string(resourceName) {
  +	case constants.GpuResource, GPUResourceName, amdGpuResourceName:
  +		return true
  +	}
  +	return false
   }
  ```
  测试佐证(`resource_vector_test.go`):新增用例断言 `nvidia.com/vgpu`、`example.com/mygpu` 不再映射到 GPU index,而 amd/nvidia 精确名映射到 GPUIndex。
  </details>
- **FIPS-only 密码学模式**:新增 fips 包,`OnlyEnv` 在 enabled 时返回一个 `GODEBUG=fips140=only,tlsmlkem=0` 环境变量,由 operator 注入所有 KAI 容器(禁用非 FIPS 算法与 ML-KEM 后量子 TLS)。企业/政企合规信号。
  <details><summary>代码依据 pkg/common/fips/fips.go(新增)</summary>

  ```diff
  +const (
  +	GODEBUGEnvName   = "GODEBUG"
  +	OnlyGODEBUGValue = "fips140=only,tlsmlkem=0"
  +)
  +func OnlyEnv(enabled bool) []v1.EnvVar {
  +	if !enabled {
  +		return nil
  +	}
  +	return []v1.EnvVar{{Name: GODEBUGEnvName, Value: OnlyGODEBUGValue}}
  +}
  ```
  </details>
- **大规模 scale test 引入分离式推理与拓扑感知场景**:新增 `kwok_workload_scenarios.go`(+588)与 `kwok_subgroups.go`(+88),用 KWOK 模拟 512+ 节点的三级拓扑(zone/block/rack),定义"分离式推理"工作负载(prefill 2 pod / decode 4 pod×4 GPU / frontend 2 pod)、弹性回收、zone 约束 hero job。子组通过 `PodGroup.Spec.MinSubGroup` + `SubGroups[].TopologyConstraint` 表达,说明拓扑约束已下沉到 subgroup 粒度。虽是测试代码,但揭示 KAI 把"拓扑对齐 + 分离式推理"作为规模验证的一等场景。
  <details><summary>代码依据 test/e2e/scale/kwok_subgroups.go(新增)</summary>

  ```diff
  +	podGroup.Spec.MinMember = nil
  +	podGroup.Spec.MinSubGroup = ptr.To(int32(len(subGroups)))
  +	...
  +		podGroup.Spec.SubGroups = append(podGroup.Spec.SubGroups, v2alpha2.SubGroup{
  +			Name:               subGroup.name,
  +			MinMember:          ptr.To(int32(subGroup.pods)),
  +			TopologyConstraint: subGroup.topology,
  +		})
  ```
  配套 `docs/scale-tests/metrics-data.js` 新增 4 张图表:inference-allocation / inference-reclaim / hero-job-reclaim / elastic-job-reclaim,并给拓扑图加 `detailLabels: { nodes: 'topology KWOK nodes' }`。
  </details>
- **v0.18 转正为 LTS**:`SUPPORT.md` 把 v0.18 标为 LTS(Sep 2026–Sep 2027),v0.17 由 Active 转 End of Life,v0.9 LTS 到期 EOL;K8s 验证矩阵 v0.16–v0.18 覆盖 v1.28.13–v1.36.1(含 dra-enabled)。
  <details><summary>代码依据 SUPPORT.md</summary>

  ```diff
  -| **v0.17** | Standard | Aug 2026 | *Until v0.18* | **Active** |
  -| **v0.16** | **LTS** | Jun 2026 | Jun 2027 | **Active** |
  +| **v0.18** | **LTS** | Sep 2026 | Sep 2027 | **Active** |
  +| **v0.17** | Standard | Aug 2026 | *Until v0.18* | **End of Life** |
  +| **v0.16** | **LTS** | Jun 2026 | Jun 2027 | **Maintenance** |
  ```
  </details>

### 后续发展方向 [AI]
- 多厂商 GPU:AMD GPU 资源名已进入核心资源向量判定,证据只覆盖 `isGpuResource` 一处,未见 AMD 的完整调度/绑定路径,是否成体系待后续 diff 验证。
- 分离式推理调度:PodGroup 的 subgroup 级 TopologyConstraint 已被 scale test 大量使用,方向是"prefill/decode 分离 + 拓扑对齐"的大规模验证;证据为 test 代码,核心调度器对 subgroup 拓扑的实现逻辑本期未直接出现在 hunk 中。
- 合规:FIPS-only 是显式合规能力落地,证据止于环境变量注入,未见证书/镜像层面的完整 FIPS 构建链。

## 本期无实质改动(折叠)
<details><summary>8 个仓无新提交</summary>

- NVIDIA/gpu-operator — 无新提交(release v26.7.1)
- NVIDIA/nvidia-container-toolkit — 无新提交(release v1.20.1)
- NVIDIA/gpu-driver-container — 无新提交(release —)
- NVIDIA/k8s-device-plugin — 无新提交(release v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(release v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(release 4.8.4)
- NVIDIA/DCGM — 无新提交(release —,分支 master)
- NVIDIA/mig-parted — 无新提交(release v0.15.1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=60526e35efeeedef584d8f40db0bac8864f98f26 branch=main release=v26.7.1 scanned=2026-09-29 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=84e2c2c182bfa0b2edab4fdca27e5197faba0ca7 branch=main release=v1.20.1 scanned=2026-09-29 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=39e0cfd337a0cac8d272412b8fa16343c973afe9 branch=main release=— scanned=2026-09-29 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=86142cf1a93fb68a99c5927b9599e13392e27e15 branch=main release=v0.20.1 scanned=2026-09-29 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=495bf4c59b9423080aa1fe2163955f44a495012c branch=main release=v0.5.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-09-29 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-29 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=626a3f6a2c8597705f42b4be27a822f561fef706 branch=main release=v0.15.1 scanned=2026-09-29 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=52155f6189bda3d46f4011fa1ce328fd74e25a95 branch=main release=v0.18.1 scanned=2026-09-29 -->
