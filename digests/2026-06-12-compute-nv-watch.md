# NVIDIA 算力栈 diff 雷达 2026-06-12

## 摘要
- **DRA 驱动**:修非 SR-IOV GPU(如 T400)在 VFIO 解绑前因 `PhysicalFunction == nil` 触发的空指针 panic;并彻底删掉旧组件标签 `nvidia-dra-driver-gpu-component`,完成向 `dra-driver-nvidia-gpu-component` 的命名迁移收尾。
- **k8s-device-plugin**:跟随 go-nvml 0.13.1,`PciInfo.BusId` 由 `uint8` 改为 `int8`,把字符串转换重构成泛型 `nullTerminatedIntSliceToString[int8|uint8]` 以兼容新 ABI——纯适配,无能力变化。
- 其余多为 CI/release 管线与文档:gpu-operator 加 helm chart OCI 发布流水、KAI 加调度快照调试 skill、container-toolkit 改 SECURITY.md;dcgm-exporter/DCGM/mig-parted/gpu-driver-container 本期无实质改动。

## 当日重要改变
- 无硬信号命中(本期无 API/CRD 字段增删、无弃用/移除已有 flag、无版本跨档)。当日实质代码改动均为缺陷修复与 ABI 适配,逐条见下。

## kubernetes-sigs/dra-driver-nvidia-gpu: d4dd8600 -> 749a743c
- 比较 / Release:d4dd8600 -> 749a743c | ahead=4 | files=6 | Release v0.4.0
### AI 总结重点(源码 diff 为据)
- **`verifyDisabledVFs` 增加两道空值防护**:`cmd/gpu-kubelet-plugin/vfio-device.go` 中,解绑 GPU 前先判 `gpu == nil`(找不到则报错返回),再判 `gpu.SriovInfo.PhysicalFunction == nil`——对不支持 SR-IOV 的卡(注释举例 T400)直接 `return nil` 放行,而非沿用旧逻辑直接解引用 `PhysicalFunction.NumVFs` 导致 panic。即:VFIO 透传路径现在能在非 SR-IOV 卡上安全跳过 VF 校验。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/vfio-device.go</summary>

  ```diff
   func (vm *VfioPciManager) verifyDisabledVFs(pciBusID string) error {
   	if err != nil {
   		return err
   	}
  +	if gpu == nil {
  +		return fmt.Errorf("no GPU found at PCI bus ID %q", pciBusID)
  +	}
  +	// PhysicalFunction is nil for GPUs that do not support SR-IOV (e.g. T400).
  +	// A nil PhysicalFunction means no VFs can exist, so it is safe to proceed.
  +	if gpu.SriovInfo.PhysicalFunction == nil {
  +		return nil
  +	}
   	numVFs := gpu.SriovInfo.PhysicalFunction.NumVFs
  ```
  </details>
- **删除为升级兼容保留的冗余组件标签**:kubelet-plugin 与 controller 两个 Deployment 模板里写死的 `nvidia-dra-driver-gpu-component: <name>` 标签被删,统一只留 `selectorLabels` helper 注入的 `dra-driver-nvidia-gpu-component`;bats 升降级测试与 `helpers.sh` 的 `kubectl wait -l` 选择器同步从旧 key 切到新 key,旁注的 TODO("等 last stable 同时支持新旧 label 再改")也一并清掉。说明 `nvidia-*` 旧标签的过渡期已结束。
  <details><summary>代码依据 deployments/helm/.../kubeletplugin.yaml + tests/bats/helpers.sh</summary>

  ```diff
   labels:
     {{- include "dra-driver-nvidia-gpu.templateLabels" . | nindent 8 }}
     {{- include "dra-driver-nvidia-gpu.selectorLabels" (...) | nindent 8 }}
  -  nvidia-dra-driver-gpu-component: kubelet-plugin
  ```
  ```diff
  -  # TODO: change `nvidia-dra-driver-gpu-component` when last stable supports both...
  -  kubectl wait --for=condition=READY pods -A -l nvidia-dra-driver-gpu-component=kubelet-plugin --timeout=15s
  +  kubectl wait --for=condition=READY pods -A -l dra-driver-nvidia-gpu-component=kubelet-plugin --timeout=15s
  ```
  </details>
- **升降级测试基线指向正式 registry**:`tests/bats/Makefile` 的 last-stable chart 源从迁移前的 `oci://ghcr.io/nvidia/k8s-dra-driver-gpu`(版本 `25.12.0-...-chart`)改为 `oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu` 版本 `0.4.0`——印证仓库迁 kubernetes-sigs 后发布渠道也搬到了 registry.k8s.io。
  <details><summary>代码依据 tests/bats/Makefile</summary>

  ```diff
  -TEST_CHART_LASTSTABLE_REPO ?= "oci://ghcr.io/nvidia/k8s-dra-driver-gpu"
  -TEST_CHART_LASTSTABLE_VERSION ?= "25.12.0-0882da87-chart"
  +TEST_CHART_LASTSTABLE_REPO ?= "oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu"
  +TEST_CHART_LASTSTABLE_VERSION ?= "0.4.0"
  ```
  </details>
### 后续发展方向 [AI]
- VFIO 透传(整卡直通虚机/CDI 路径)正在补齐对不支持 SR-IOV 的低端/老卡的兼容,是把 DRA 驱动从"数据中心 SR-IOV 卡"扩到更广硬件矩阵的工程化收尾。证据只覆盖 `verifyDisabledVFs` 这一处空指针修复,未见 VF 创建/绑定主流程的对应改动。
- 标签命名与 chart 发布渠道两处迁移均已落到 registry.k8s.io,迁仓收尾基本完成;证据仅来自测试与模板文件,未见运行时 Go 主逻辑随之变更。
- 修复来自外部贡献者(PR #1186 Miaoxiang-philips、#1187 shivamerla),社区参与度可作旁证。
- 提交:nil panic 修复 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/ba3170b95440c22e77dcc9a7e7d3315c7846b531 ;标签清理 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/af356f9e1ac7bb645c8239512b8782bb91d3e9b0

## NVIDIA/k8s-device-plugin: 8d844dca -> 86889491
- 比较 / Release:8d844dca -> 86889491 | ahead=3 | files=14 | Release v0.19.2
### AI 总结重点(源码 diff 为据)
- **跟随 go-nvml 0.13.1 的 PciInfo ABI 变更**:伴随 dependabot 把 `go-nvml` 升到 0.13.1(PR #1839),`PciInfo.BusId` 的元素类型由 `uint8` 变为 `int8`。`internal/rm/helper.go` 把原来只吃 `[]uint8` 的 `uint8Slice.String()` 重构为泛型 `nullTerminatedIntSliceToString[T int8 | uint8]`(遇 0 截断、逐字节 `byte(c)` 拼接),并新增 `int8Slice` 类型复用该泛型;`nvml_devices.go` 里 `GetNumaNode` 读 NUMA 拓扑时,把 `uint8Slice(info.BusId[:])` 换成 `int8Slice(info.BusId[:])`。纯 ABI 适配,NUMA 亲和/总线 ID 解析行为不变。
  <details><summary>代码依据 internal/rm/helper.go + nvml_devices.go</summary>

  ```diff
  -// uint8Slice wraps an []uint8 with more functions.
  -type uint8Slice []uint8
  -func (s uint8Slice) String() string {
  +func nullTerminatedIntSliceToString[T int8 | uint8](s []T) string {
   	var b []byte
   	for _, c := range s {
   		if c == 0 { break }
  -		b = append(b, c)
  +		b = append(b, byte(c))
   	}
   	return string(b)
   }
  +type int8Slice []int8
  +func (s int8Slice) String() string { return nullTerminatedIntSliceToString(s) }
  ```
  ```diff
  -	busID := strings.ToLower(strings.TrimPrefix(uint8Slice(info.BusId[:]).String(), "0000"))
  +	busID := strings.ToLower(strings.TrimPrefix(int8Slice(info.BusId[:]).String(), "0000"))
  ```
  </details>
### 后续发展方向 [AI]
- 这是被动跟 NVML Go 绑定的类型签名走,无功能/配置面变化;唯一启示是 device-plugin 仍紧贴 go-nvml 上游 ABI,升级 NVML 时需留意 PciInfo 这类底层结构体的有符号/无符号翻转。证据只覆盖 helper/nvml_devices 两处,time-slicing/MPS 配置面本期未动。
- 提交:https://github.com/NVIDIA/k8s-device-plugin/commit/2b572473798c1c005975018d8d874e773634b6e7

## kai-scheduler/KAI-Scheduler: 26e50a96 -> 363ebfb0
- 比较 / Release:26e50a96 -> 363ebfb0 | ahead=1 | files=8 | Release v0.15.2
### AI 总结重点(源码 diff 为据)
- **新增 `.agents/skills/snapshots` 调度快照调试 skill(非调度能力变更)**:PR #1659 在 `.agents/skills/snapshots/` 下加四个 bash 脚本 + SKILL.md,围绕 scheduler 的 snapshot 插件端点做调试:`capture-snapshot.sh` 经 `kubectl port-forward` 拉 `/get-snapshot`(插件端口 8081,非 `--listen-address` 端口)、`inspect-snapshot.sh` 校验归档含 `snapshot.json`、`run-snapshot.sh` 用 `snapshot-tool` 在指定 git ref 上回放调度决策、`compare-snapshot-refs.sh` 跨多个 ref 对比。SKILL.md 还记录了实测观察(如 `v0.14.4` 在 reclaim 阶段疑似 stall、`v0.14.0` reclaim 比 `v0.13.0` 明显快)。这是面向 agent/维护者的可复现调试工具链,调度算法本身未改。
  <details><summary>代码依据 .agents/skills/snapshots/SKILL.md</summary>

  ```text
  - The snapshot endpoint is `/get-snapshot` on plugin port `8081`, not the scheduler `--listen-address` port.
  - `cmd/snapshot-tool/main.go` rebuilds fake clients from `snapshot.json` and replays the configured scheduler actions.
  - Replay is a simulation of scheduler behavior, not a full cluster reproduction.
  ```
  </details>
### 后续发展方向 [AI]
- 把"抓真实集群调度快照 → 在任意 ref 回放 → 跨版本对比时序"固化成仓内 skill,意味着 KAI 在用快照回放做调度回归/性能取证(SKILL.md 直接引用了性能回归 issue #1517)。对我们的启示:调度器侧建立可复现的 snapshot 回放基线,是定位 reclaim/抢占类时序回归的实用手段。证据仅覆盖脚本与文档,`cmd/snapshot-tool` 主逻辑本期 diff 未含(为既有代码)。
- 提交:https://github.com/kai-scheduler/KAI-Scheduler/commit/363ebfb0f75297401d0d3a979321a2bac39773bb

## NVIDIA/gpu-operator: 27b9f650 -> 64714d6f
- 比较 / Release:27b9f650 -> 64714d6f | ahead=2 | files=3 | Release v26.3.2
### AI 总结重点(源码 diff 为据)
- **仅 CI/release 管线变更,无算子代码/CRD 改动**:新增 `.github/workflows/publish-helm-oci-chart.yaml`,在 test/merge-to-main 时把 gpu-operator helm chart 打成 OCI artifact 推到 ghcr.io;chart 版本用 `0.0.0-git-<ver>` 形式以满足 SemVer(注释解释:避免带前导 0 的短 SHA 破坏 prerelease 合法性),并用 yq 把 `values.yaml` 的 `operator.repository`/`validator.repository` 改写为当前镜像仓库。`e2e-tests.yaml`/`ci.yaml` 串入该 job 并加 `packages: write` 权限。`api/nvidia/v1/clusterpolicy_types.go` 等 CRD 文件未动。
  <details><summary>代码依据 .github/workflows/publish-helm-oci-chart.yaml</summary>

  ```yaml
  # Helm chart versions must be SemVer. Prefix the image version so a
  # numeric short SHA with a leading zero remains a valid prerelease.
  CHART_VERSION="0.0.0-git-${OPERATOR_VERSION}"
  helm package --version "${CHART_VERSION}" --app-version "${OPERATOR_VERSION}" ...
  ```
  </details>
### 后续发展方向 [AI]
- gpu-operator 正把 helm chart 的 OCI 分发纳入 CI(测试期即发布 ghcr 制品),为后续以 OCI registry 作为 chart 标准分发渠道铺路。证据仅覆盖三个 workflow 文件,ClusterPolicy 字段与算子状态机本期无变化。
- 提交:https://github.com/NVIDIA/gpu-operator/commit/add306d34ae8588f1e50a0e9575b5ae6d5c1a0d1

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- **NVIDIA/nvidia-container-toolkit**:仅改 SECURITY.md——漏洞上报从"无 bug bounty"改为接入 Intigriti 公开 bug bounty 计划。文档变更,无运行时改动。
- **NVIDIA/gpu-driver-container**:无新提交。
- **NVIDIA/dcgm-exporter**:无新提交。
- **NVIDIA/DCGM**(master):无新提交。
- **NVIDIA/mig-parted**:ahead=2/files=18,但实质提交仅 bump/CI/merge,无 MIG 切分逻辑改动。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=64714d6f3f0eaca538b809382efbc3672b39558f branch=main release=v26.3.2 scanned=2026-06-12 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=59c042086ec213caba72dc7570facffc911f38dd branch=main release=v1.19.1 scanned=2026-06-12 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=0dbfbb9cfab989f59f1960ac4554fc54dc61c529 branch=main release=— scanned=2026-06-12 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=8688949193c14245d06660ab15c6275d0d6740af branch=main release=v0.19.2 scanned=2026-06-12 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=749a743cea793f08688f871b69596c253374b0b6 branch=main release=v0.4.0 scanned=2026-06-12 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-12 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=0869351a7d89ff24e68c93b92a50d981cea15580 branch=master release=— scanned=2026-06-12 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=d1ee809607b28fbc2f193dd408c477e4826c2c58 branch=main release=v0.14.2 scanned=2026-06-12 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=363ebfb0f75297401d0d3a979321a2bac39773bb branch=main release=v0.15.2 scanned=2026-06-12 -->
