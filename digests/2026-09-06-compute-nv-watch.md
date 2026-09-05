# NVIDIA 算力栈 diff 雷达 2026-09-06

## 摘要
- **gpu-operator** 把 ComputeDomain CRD 对齐到 DRA driver v0.5.0:`numNodes` 从必填降级为可选(加 `default:0`/`minimum:0`、移出 `required`),并重申该字段已 deprecated、下一 API 版本移除——IMEX 多节点内存共享正从"手填节点数"转向"DNS 名自动发现"。
- **k8s-device-plugin** 硬化 vGPU vendor capability 记录解析(#1994):对截断/零长/越界记录一律返回错误,不再静默读越界内存;`VGPUCapabilityRecordStart` 去掉 `uint8` 类型避免 offset 溢出。
- 其余 7 仓无实质改动(container-toolkit 仅 cdi v1.1.1 bump;driver-container/dra-driver/dcgm-exporter/DCGM/mig-parted/KAI-Scheduler 无新提交)。

## 当日重要改变
- **NVIDIA/gpu-operator** [API/CRD变更] ComputeDomain 的 `numNodes` 由必填字段降级为带默认值 `0` 的可选字段并移出 `required`,配合 `featureGates.IMEXDaemonsWithDNSNames=true`(已是默认)推进 IMEX 由静态节点数向 DNS 名自动发现迁移。证据:`deployments/gpu-operator/crds/resource.nvidia.com_computedomains.yaml`。https://github.com/NVIDIA/gpu-operator/commit/08c40bc479192e3d5a82b7fd41d7e85a7197741f
- **NVIDIA/k8s-device-plugin** [健壮性/行为变更] vGPU host driver version 记录解析全面加边界校验,遇畸形 PCI vendor capability 从"静默继续/可能越界"改为显式报错。证据:`internal/vgpu/vgpu.go`。https://github.com/NVIDIA/k8s-device-plugin/commit/4edf2b66ec53db87c36e035f82e5629b676893e3

## NVIDIA/gpu-operator: df32e7e6 -> 08c40bc4
- 比较: df32e7e6 -> 08c40bc4 | ahead=2 | files=15 | Release: v26.7.0
- 提交:Sync ComputeDomain CRD with DRA driver v0.5.0 schema (#2858) https://github.com/NVIDIA/gpu-operator/commit/08c40bc479192e3d5a82b7fd41d7e85a7197741f

### AI 总结重点(源码 diff 为据)
- ComputeDomain CRD 的 `spec.numNodes`(IMEX daemon/计算节点数)由**必填**改为**可选、默认 0**:新增 `default: 0`、`minimum: 0`,并从 `required` 列表移除(原先与 `channel` 并列必填)。语义上从"必须显式声明多少个 IMEX daemon"变为"不填即 0,由 workload 自行判定在线 worker 数"。deprecation 说明保留:该字段将在下一 API 版本删除。这是对齐 DRA driver v0.5.0 schema 的一步,方向是让 `IMEXDaemonsWithDNSNames=true`(默认)路径不再依赖手填节点数。
  <details><summary>代码依据 deployments/gpu-operator/crds/resource.nvidia.com_computedomains.yaml</summary>

  ```diff
                numNodes:
  +                default: 0
                   description: |-
                     Intended number of IMEX daemons (i.e., individual compute nodes) in the
                     ComputeDomain. Must be zero or greater.
                     With `featureGates.IMEXDaemonsWithDNSNames=true` (the default), this is
  -                  recommended to be set to zero. Workload must implement and consult its
  +                  recommended to be set to zero (default). Workload must implement and consult its
                     ...
                     The `numNodes` parameter is deprecated and will be removed in the next
                     API version.
  +                minimum: 0
                   type: integer
               required:
               - channel
  -            - numNodes
               type: object
  ```
  </details>
- 三个 nvidia.com CRD(nvidiadrivers/gpuclusters/clusterpolicies)仅 controller-gen 版本注解从 v0.21.0 bump 到 v0.22.0,无字段变化;ClusterPolicy schema 本身未动(本期无新增/删除字段)。属工具链升级噪声。
  <details><summary>代码依据 config/crd/bases/nvidia.com_clusterpolicies.yaml</summary>

  ```diff
     annotations:
  -    controller-gen.kubebuilder.io/version: v0.21.0
  +    controller-gen.kubebuilder.io/version: v0.22.0
  ```
  </details>

### 后续发展方向 [AI]
- 证据落在 ComputeDomain(DRA IMEX 多 GPU 内存共享域)的 API 收敛:`numNodes` 的"可选化 + deprecation 重申"表明下一个 API 版本很可能彻底删除它,IMEX daemon 数量交由 DNS 名发现动态决定。对标 OAI 侧若要接 GB200/NVL 这类跨节点 NVLink 域,ComputeDomain 是 NVIDIA 主推的抽象,值得跟其 API 稳定化节奏。证据只覆盖 CRD schema diff,未见对应 controller/reconcile 代码改动(本期未命中 controllers/)。

## NVIDIA/k8s-device-plugin: ad5bc6cc -> 4edf2b66
- 比较: ad5bc6cc -> 4edf2b66 | ahead=1 | files=2 | Release: v0.20.0
- 提交:validate vGPU capability record lengths (#1994) https://github.com/NVIDIA/k8s-device-plugin/commit/4edf2b66ec53db87c36e035f82e5629b676893e3

### AI 总结重点(源码 diff 为据)
- `Device.GetInfo()` 遍历 vGPU vendor capability 记录链的逻辑重写为逐步边界校验:每次读记录头前先判 `pos >= len` 与"剩余 < 2 字节"(截断头),读到记录长度后判 `recordLength < 2`(非法/零长)与 `recordLength > 剩余`(越界),定位到 driver version 记录(id=0)后再判 `recordLength < 2+HostDriverVersionLength+HostDriverBranchLength`(载荷不足)。原逻辑用 `GetByte` 辅助读取、越界返回 0 并静默继续,只在末尾粗判一次总长度;新逻辑在每一步对畸形数据返回具名错误(如 `truncated vendor capability record`、`invalid vendor capability record length`、`vendor capability record exceeds capability bounds`),不再有越界读风险。
  <details><summary>代码依据 internal/vgpu/vgpu.go</summary>

  ```diff
  -	VGPUCapabilityRecordStart uint8 = 5
  +	VGPUCapabilityRecordStart = 5
  ...
  -	var hostDriverVersion string
  -	foundDriverVersionRecord := false
  	pos := VGPUCapabilityRecordStart
  -	record := GetByte(d.vGPUCapability, VGPUCapabilityRecordStart)
  -	for record != 0 && int(pos) < len(d.vGPUCapability) {
  -		recordLength := GetByte(d.vGPUCapability, pos+1)
  -		pos += recordLength
  -		record = GetByte(d.vGPUCapability, pos)
  -	}
  +	for {
  +		if pos >= len(d.vGPUCapability) {
  +			return nil, fmt.Errorf("cannot find driver version record ... %s", d.pci.Address)
  +		}
  +		record := d.vGPUCapability[pos]
  +		if record == 0 { break }
  +		if len(d.vGPUCapability)-pos < 2 {
  +			return nil, fmt.Errorf("truncated vendor capability record ...")
  +		}
  +		recordLength := int(d.vGPUCapability[pos+1])
  +		if recordLength < 2 { return nil, fmt.Errorf("invalid vendor capability record length %d ...", recordLength) }
  +		if recordLength > len(d.vGPUCapability)-pos { return nil, fmt.Errorf("... exceeds capability bounds ...") }
  +		pos += recordLength
  +	}
  ```
  </details>
- 把常量 `VGPUCapabilityRecordStart` 从 `uint8` 改为无类型常量,使 `pos` 推断为 `int`,消除偏移量在 `uint8`(≤255)上累加溢出的可能——vendor capability 区若较长,原 `uint8 pos` 会回绕。配套新增 8 个畸形输入用例 + 1 个"跳过未知记录"用例的单测。
  <details><summary>代码依据 internal/vgpu/vgpu_test.go</summary>

  ```diff
  +func TestVGPUGetInfoRejectsMalformedRecords(t *testing.T) {
  +	// missing record / truncated header / zero-length / exceeds bounds ... 共 8 例
  +}
  +func TestVGPUGetInfoSkipsUnknownRecords(t *testing.T) { ... }
  ```
  </details>

### 后续发展方向 [AI]
- 这是经典 device-plugin(非 DRA)vGPU 路径的健壮性/安全加固,针对 SR-IOV vGPU 从 PCI vendor-specific capability 读取 host driver version/branch 的解析面。信号是 NVIDIA 在把 legacy device-plugin 的边缘输入处理往"畸形即拒绝"收敛,而非扩能力。对我们产品的启示:若自研 device-plugin 复用了类似 PCI capability 解析,同样应做逐记录边界校验。证据只覆盖 `internal/vgpu` 解析函数,未涉及 DRA/time-slicing/MPS 配置面(本期这些目录无改动)。

## 本期无实质改动(折叠)
- NVIDIA/nvidia-container-toolkit — 仅 `chore(deps): bump cdi to v1.1.1`(#2047),111 文件多为 vendor 目录
- NVIDIA/gpu-driver-container — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(仍 v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
- kai-scheduler/KAI-Scheduler — 无新提交(仍 v0.17.1)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=08c40bc479192e3d5a82b7fd41d7e85a7197741f branch=main release=v26.7.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=752e1e571bdfda0a5e0e3f5804c4c556796ab0eb branch=main release=v1.20.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9ac64592151369a93da35b831322f193c03b13f5 branch=main release=— scanned=2026-09-06 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=4edf2b66ec53db87c36e035f82e5629b676893e3 branch=main release=v0.20.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=8ad4e66f1367b852c36e1f405d50055b7b3bbe66 branch=main release=v0.5.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-09-06 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-06 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=2098686586250d28c472aaa821643a069f8464ec branch=main release=v0.15.0 scanned=2026-09-06 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=da8e4a0d4f2eb0ca7dca13140ac1dc2e4186dff5 branch=main release=v0.17.1 scanned=2026-09-06 -->
