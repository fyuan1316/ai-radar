# NVIDIA 算力栈 diff 雷达 2026-09-13

## 摘要
- gpu-operator 给 operator 自身 Deployment 及三个 CRD 生命周期辅助 Job 补齐"受限安全上下文"默认(runAsNonRoot/seccompRuntimeDefault + 容器级 drop ALL/只读根/禁提权),并暴露可配 securityContext/dnsPolicy/dnsConfig;有意不钉死 UID 以兼容 OpenShift SCC。
- gpu-driver-container 把已 EOL 的 610.57.04 从全 OS 驱动矩阵剔除,当前活跃分支收敛为 580.178.04 / 595.91.07 / 615.71.09。
- DRA 驱动修一处空指针:GetNonAdminDevices 把 `Status.Allocation==nil` 判断挪到解引用之前,防未分配 claim 触发 panic;两个 kubelet-plugin 同步修。

## 当日重要改变
- NVIDIA/gpu-driver-container [弃用/移除] 从 DRIVER_VERSIONS 与各 OS 构建矩阵删除 610.57.04(标注 EOL),驱动容器可选版本收窄。证据 .common-ci.yml / versions.mk / .github/workflows/image.yaml。 https://github.com/NVIDIA/gpu-driver-container/commit/dcbb9031dbb95da2e449fbb632e4b69e5c3d1ba1
- NVIDIA/gpu-operator [新能力] operator 及辅助 Job 引入受限安全上下文默认 + 可配 securityContext/dnsConfig,收紧控制面 Pod 安全基线。证据 deployments/gpu-operator/templates/operator.yaml、values.yaml。 https://github.com/NVIDIA/gpu-operator/commit/3fc63e234ea12cd1de83d0ef698d438805f86aa7

## NVIDIA/gpu-operator: 9f85a2ad -> 3fc63e23
- 比较: 9f85a2ad08afc43b220cf368543fc2735244df13 -> 3fc63e23 | ahead=2 | files=5 | Release: v26.7.0
### AI 总结重点(源码 diff 为据)
- operator 的 Deployment 与三个 CRD 生命周期 Job(upgrade-crd/cleanup-crd/cleanup-gpucluster)统一加两级安全上下文:**Pod 级**通过 `{{- with .Values.operator.securityContext }}` 渲染(默认值见下),**容器级**硬编码 `allowPrivilegeEscalation: false` + `readOnlyRootFilesystem: true` + `capabilities.drop: [ALL]`。此前这些容器无任何 securityContext 声明。
  <details><summary>代码依据 deployments/gpu-operator/templates/operator.yaml</summary>

  ```diff
  +      {{- with .Values.operator.securityContext }}
  +      securityContext:
  +        {{- toYaml . | nindent 8 }}
  +      {{- end }}
         containers:
         - name: gpu-operator
  ...
  +        securityContext:
  +          allowPrivilegeEscalation: false
  +          readOnlyRootFilesystem: true
  +          capabilities:
  +            drop:
  +              - ALL
  ```
  </details>
- Pod 级默认只给 `runAsNonRoot: true` + `seccompProfile.type: RuntimeDefault`,**刻意不钉 runAsUser/runAsGroup/fsGroup**——注释说明镜像已 `USER 1000:1000`,而 OpenShift restricted-readonly SCC 是 MustRunAsRange,硬编码 1000 会在分配区间不含 1000 的 namespace 里失败。这是为多平台(vanilla K8s + OpenShift)兼容做的取舍。
  <details><summary>代码依据 deployments/gpu-operator/values.yaml</summary>

  ```diff
  +  # Do not pin runAsUser/runAsGroup/fsGroup: the image already uses USER 1000:1000
  +  # on vanilla Kubernetes, and a hardcoded UID fails OpenShift namespaces whose
  +  # allocated range does not include 1000 (restricted-readonly SCC is MustRunAsRange).
  +  securityContext:
  +    runAsNonRoot: true
  +    seccompProfile:
  +      type: RuntimeDefault
  +  dnsPolicy: ""
  +  dnsConfig: {}
  ```
  </details>
- 顺带把 `dnsPolicy`/`dnsConfig` 做成可配(空 dnsPolicy 保持集群默认 ClusterFirst),满足需自定义 DNS 的受限网络环境。改动仅限控制面(operator Deployment 与辅助 Job),**operand DaemonSet(driver/toolkit/dcgm 等)安全上下文未动**——注释明确 "not operand DaemonSets"。
### 后续发展方向 [AI]
- 方向是把 gpu-operator 控制面向 Pod Security Standards restricted / OpenShift SCC 对齐,降低企业合规门槛。证据只覆盖控制面 Deployment 与 CRD 辅助 Job 的 helm 模板,未见对 operand(driver-daemonset、container-toolkit、dcgm-exporter 等特权 DaemonSet)的安全上下文调整——后者因需特权访问设备,短期难同样收紧。

## NVIDIA/gpu-driver-container: 6357f520 -> dcbb9031
- 比较: 6357f5208edce4c8eda53446ad2cb68e03940349 -> dcbb9031 | ahead=2 | files=3 | Release: —
### AI 总结重点(源码 diff 为据)
- 把 610.57.04 从 `DRIVER_VERSIONS`(versions.mk 与 .common-ci.yml)及 GitHub Actions 构建矩阵(image.yaml)全部删除,理由为该分支 EOL。删除后 CI 覆盖的活跃数据中心分支为 580.178.04 / 595.91.07 / 615.71.09;ubuntu26.04 矩阵此前不含 580,删 610 后为 595/615。
  <details><summary>代码依据 .common-ci.yml / versions.mk</summary>

  ```diff
  -  DRIVER_VERSIONS: 580.178.04 595.91.07 610.57.04 615.71.09
  +  DRIVER_VERSIONS: 580.178.04 595.91.07 615.71.09
  ...
  -DRIVER_VERSIONS ?= 580.178.04 595.91.07 610.57.04 615.71.09
  +DRIVER_VERSIONS ?= 580.178.04 595.91.07 615.71.09
  ```
  </details>
### 后续发展方向 [AI]
- 单纯 EOL 版本清退,驱动矩阵持续瘦身。证据仅覆盖 CI/版本清单三文件,未见新分支引入或预编译(precompiled)矩阵结构变化;615.71.09 作为最新分支保留,可推断后续默认将进一步向 615+ 靠拢(与前日 615+ 默认切 -open 开源内核模块的走向一致)。

## kubernetes-sigs/dra-driver-nvidia-gpu: c3963bcf -> 5baf08f6
- 比较: c3963bcff8a3127da4530f1ace490ba6ed13e8e3 -> 5baf08f6 | ahead=2 | files=2 | Release: v0.5.0
### AI 总结重点(源码 diff 为据)
- 修 `PreparedClaim.GetNonAdminDevices` 的空指针缺陷:原代码先 `make(map, len(c.Status.Allocation.Devices.Results))` 再判 `c.Status.Allocation == nil`——当 claim 未分配时,构造 map 那步已解引用 nil 触发 panic。修复把 nil 判断前置并直接返回空 map 字面量。gpu-kubelet-plugin 与 compute-domain-kubelet-plugin 两处同型修复。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/prepared.go</summary>

  ```diff
  -	requested := make(map[string]struct{}, len(c.Status.Allocation.Devices.Results))
  -
  	if c.Status.Allocation == nil {
  -		return requested
  +		return map[string]struct{}{}
  	}
  +
  +	requested := make(map[string]struct{}, len(c.Status.Allocation.Devices.Results))
  ```
  </details>
### 后续发展方向 [AI]
- 纯健壮性修复,无功能/API 变化。证据仅两文件的 nil 保护;涉及 "NonAdmin devices" 路径,说明 DRA 驱动的 admin/non-admin 设备访问区分逻辑仍在打磨,但本次未见该语义本身的扩展。

## 本期无实质改动(折叠)
<details><summary>6 个 repo EMPTY</summary>

- NVIDIA/nvidia-container-toolkit(ahead=2,50 文件均为 bump/CI/merge)
- NVIDIA/k8s-device-plugin(ahead=1,仅 bump/CI/merge)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
- kai-scheduler/KAI-Scheduler(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=3fc63e234ea12cd1de83d0ef698d438805f86aa7 branch=main release=v26.7.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=bd0ff886d762c642e02f22b87d46bc756f37bd2a branch=main release=v1.20.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=dcbb9031dbb95da2e449fbb632e4b69e5c3d1ba1 branch=main release=— scanned=2026-09-13 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=7444480b4a1eab446342fb5fd71229b1cdd5d78b branch=main release=v0.20.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=5baf08f63bd266129dbdd27b28e77bb0ad91fd28 branch=main release=v0.5.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-13 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-13 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=377f931e2d64f1a7e716d57e4084257f4cc09757 branch=main release=v0.15.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=30c25346ee013e67d2e14df0429bec52f1885131 branch=main release=v0.17.1 scanned=2026-09-13 -->
