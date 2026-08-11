# NVIDIA 算力栈 diff 雷达 2026-08-12

## 摘要
- gpu-operator 给 dcgm-exporter 增加"按 env 自动判定是否需要访问 K8s API"的一整套逻辑:用户直接设 `DCGM_EXPORTER_CONFIGMAP_DATA`(自定义指标 ConfigMap)或原生 pod-metadata env 时,operator 自动挂 SA token、放行 ConfigMap 读权限;同时给 DRA kubeletplugin ClusterRole 补 node `patch` 权限,并把 dcgm-exporter 读 pods 权限从 Role 收敛。
- gpu-driver-container 把 FabricManager/nvlsm 启动改成 fail-fast(失败即 `return 1`),并为 **B200+/NVLink5+** 场景在 `FABRIC_MODE=1` 后 `nvidia-smi -r` 复位 GPU 清 stale fabric 分区;新增 `.driver-daemons-status` 状态文件供上层探测 daemon 就绪。
- dra-driver-nvidia-gpu 大区间(15 提交 / 300 文件,含 k8s libs v0.37.0-rc.0 bump)概览:主线在 NUMA 拓扑属性上报 + GPU passthrough(VFIO)驱动切换的超时/在途处理硬化。mig-parted 仅给 systemd oneshot 服务加 480s 启动超时。其余 5 仓无新提交,无 ClusterPolicy CRD 字段增删。

## 当日重要改变
- NVIDIA/gpu-operator [新能力] dcgm-exporter 支持"裸 env 驱动"的自定义指标 ConfigMap 与 pod-metadata:operator 从 `DCGMExporter.Env` 里探测出需要 API 访问就自动挂 SA token + 授 ConfigMap 读权限,不再要求走 typed spec 字段。证据 `controllers/object_controls.go` 新增 `dcgmExporterEnvRequiresAPIAccess`/`dcgmExporterEnvEnablesPodMetadata`。https://github.com/NVIDIA/gpu-operator/compare/599e2836...b12fc294
- NVIDIA/gpu-driver-container [新能力] B200+/NVLink5+ 系统在 `FABRIC_MODE=1` 启动后自动 `nvidia-smi -r` 复位 GPU 清残留 fabric 分区状态,FabricManager 启动失败改为 fail-fast。证据 `*/nvidia-driver` 的 `_start_daemons`。https://github.com/NVIDIA/gpu-driver-container/compare/1aedf993...a891f5f5
- 未命中 API/CRD/proposal 路径(两条均为运行时行为/RBAC 变化,ClusterPolicy schema 本期未动)。

## NVIDIA/gpu-operator: 599e2836 -> b12fc294
- 比较: 599e28368646116dc56a8018a068fbac6334cce1 -> b12fc294 | ahead=10 | files=14 | Release: v26.3.3
- 提交: Mount ServiceAccount token when dcgm-exporter env needs API access / Grant the dcgm-exporter DRA role read access to ConfigMaps / add node patch permission as well to kubeletplugin-clusterrole / [state-dcgm-exporter][clusterpolicy] remove pods from Role
- https://github.com/NVIDIA/gpu-operator/compare/599e2836...b12fc294

### AI 总结重点(源码 diff 为据)
- **新增按 env 判定"是否需要 K8s API 访问"的开关,并据此挂 SA token**:`TransformDCGMExporter` 里 `AutomountServiceAccountToken=true` 的条件从"仅 `IsKubernetesPodMetadataEnabled()`(typed spec 字段)"扩为"或 `dcgmExporterEnvRequiresAPIAccess(config.DCGMExporter.Env)`"。新 helper 判定:用户在 `DCGMExporter.Env` 里设了 `DCGM_EXPORTER_CONFIGMAP_DATA` 且值不是 `""`/`none`(即指向一个自定义指标 ConfigMap),或设了 pod-metadata 相关 env,就认为 exporter 会去读 API,需要 client-go 凭证。含义:此前只有走 ClusterPolicy 的 typed 字段(EnablePodLabels/EnablePodUID)才会挂 token,现在直接透传裸 env 也能触发。

  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
  -	// Override the base asset's automountServiceAccountToken=false when
  -	// enrichment is on so the pod informer has client-go credentials.
  -	if config.DCGMExporter.IsKubernetesPodMetadataEnabled() {
  +	// Override the base asset's automountServiceAccountToken=false when the
  +	// configuration reads from the Kubernetes API.
  +	if config.DCGMExporter.IsKubernetesPodMetadataEnabled() || dcgmExporterEnvRequiresAPIAccess(config.DCGMExporter.Env) {
   		obj.Spec.Template.Spec.AutomountServiceAccountToken = ptr.To(true)
   	}
  ...
  +func dcgmExporterEnvRequiresAPIAccess(envs []gpuv1.EnvVar) bool {
  +	if dcgmExporterEnvEnablesPodMetadata(envs) { return true }
  +	for _, env := range envs {
  +		if env.Name == DCGMExporterConfigMapDataEnvName {
  +			// the exporter treats "none" and "" as no ConfigMap read
  +			if env.Value != "" && env.Value != DCGMExporterUndefinedConfigMapData { return true }
  +		}
  +	}
  +	return false
  +}
  ```
  </details>

- **RBAC gate 同步扩到裸 env**:`rbacGates["nvidia-dcgm-exporter-read-pods"]` 从只看 `IsKubernetesPodMetadataEnabled()` 改为"或 `dcgmExporterEnvEnablesPodMetadata(env)`"——用户用裸 env 打开 pod 元数据富化时,pod 读取用的 ClusterRole/Binding 也会被 provision,避免"挂了 token 却没权限"。新增一批 env 名常量(`DCGM_EXPORTER_CONFIGMAP_DATA` / `..._ENABLE_POD_LABELS` / `..._ENABLE_POD_UID` / `..._POD_LABEL_ALLOWLIST_REGEX`)替换原先散落的硬编码字符串。

  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
   var rbacGates = map[string]func(*gpuv1.ClusterPolicySpec) bool{
   	"nvidia-dcgm-exporter-read-pods": func(config *gpuv1.ClusterPolicySpec) bool {
  -		return config.DCGMExporter.IsKubernetesPodMetadataEnabled()
  +		return config.DCGMExporter.IsKubernetesPodMetadataEnabled() ||
  +			dcgmExporterEnvEnablesPodMetadata(config.DCGMExporter.Env)
   	},
   }
  ```
  </details>

- **权限清单侧配套:dcgm-exporter Role 加 configmaps 读、去 pods;DRA kubeletplugin ClusterRole 加 node `patch`**:`state-dcgm-exporter/0200_role.yaml` 加 `configmaps get/list`(读自定义指标 CM),`assets/state-dcgm-exporter/0200_role.yaml` 从 namespaced Role 里删掉 `pods`(pods 读走 ClusterRole,权限边界收敛);`state-dra-driver/0200_kubeletplugin-clusterrole.yaml` 在 node 资源上补 `patch`(kubelet plugin 需要 patch node,如打拓扑/分配标注)。

  <details><summary>代码依据 manifests/state-dcgm-exporter/0200_role.yaml + state-dra-driver/0200_kubeletplugin-clusterrole.yaml</summary>

  ```diff
  # state-dcgm-exporter/0200_role.yaml
  +- apiGroups: [""]
  +  resources: [configmaps]
  +  verbs: [get, list]
  # state-dra-driver/0200_kubeletplugin-clusterrole.yaml (node 资源)
     - update
  +  - patch
  ```
  </details>

- **打包脚本 `generate-image-list.py` 支持 GHCR token 端点 + 纳入 DRA driver 镜像**:`_registry_token` 从只认 `nvcr.io` 扩到分支处理 `ghcr.io`(标准 `/token?service=...` 端点),其余 registry 抛错;`add_os_variants` 新增把 `draDriver`(repo/image/version)加进镜像清单。属发布制品清单完善,非算力语义。

### 后续发展方向 [AI]
- gpu-operator 这轮把 dcgm-exporter 的"是否访问 K8s API"从"看 typed spec 字段"下沉到"看实际 env",本质是让高级用户用裸 env 定制(自定义指标 CM、pod 富化)时,token 挂载与 RBAC 自动跟上,避免运维手动补权限。方向是 operator 对 dcgm-exporter 配置面的**声明式自洽**收口。证据只覆盖 object_controls.go 的 env 探测 + 三个 RBAC 清单 + 单测,**未新增/删除 ClusterPolicy CRD 字段**(API 路径命中为 0),即这是运行时行为增强而非 schema 扩展。DRA node `patch` 权限是 kubelet-plugin 侧独立小改,未见对应控制器逻辑 diff。

## NVIDIA/gpu-driver-container: 1aedf993 -> a891f5f5
- 比较: 1aedf993074e945dd73b1f9b0d3b3303d160db31 -> a891f5f5 | ahead=10 | files=14 | Release: —
- 提交: fail fast when FabricManager fails to come up / [B200+][NVLink5+] reset GPUs after FABRIC_MODE=1 is set / add new status file to signal daemons startup
- https://github.com/NVIDIA/gpu-driver-container/compare/1aedf993...a891f5f5

### AI 总结重点(源码 diff 为据)
- **FabricManager / nvlsm 启动改 fail-fast**:六套 OS 脚本(ubuntu22/24/26.04、rhel8/9/10 及 precompiled 变体)里,`_start_daemons` 的 `nv-fabricmanager ... --nvlsm-pid-file $nvlsm_pid_file` 与非 NVLink5 分支的 `nv-fabricmanager -c .../fabricmanager.cfg` 都加了 `|| return 1`;`_load_driver` 里 `_start_daemons` 也从"调用后无条件 `return 0`"改成 `_start_daemons || return 1`。含义:fabric manager 起不来不再被静默吞掉当成功,而是让驱动容器 init 失败暴露出来。

  <details><summary>代码依据 ubuntu22.04/nvidia-driver(其余 OS 同构)</summary>

  ```diff
   _load_driver() {
  ...
  -    _start_daemons
  -
  -    return 0
  +    _start_daemons || return 1
   }
  ...
   _start_daemons() {
       nv-fabricmanager ... \
  -                                               --nvlsm-pid-file $nvlsm_pid_file
  +                                               --nvlsm-pid-file $nvlsm_pid_file || return 1
  ```
  </details>

- **B200+/NVLink5+ 在 `FABRIC_MODE=1` 后复位 GPU 清 stale fabric 分区**:NVLink5+ 交换机分支里,fabric manager 起来后若 `NVFM_CONFIG_FABRIC_MODE == "1"`,执行 `nvidia-smi -r` 复位 GPU,清掉设 fabric 模式前遗留的分区状态。这是 GB200/NVL 机架类系统的 fabric 初始化正确性补丁——避免带着 stale partition 数据继续跑。

  <details><summary>代码依据 ubuntu22.04/nvidia-driver 的 _start_daemons</summary>

  ```diff
                                                  --nvlsm-pid-file $nvlsm_pid_file || return 1
  +        if [ ! -z "${NVFM_CONFIG_FABRIC_MODE:-}" ] && [ "${NVFM_CONFIG_FABRIC_MODE}" == "1" ]; then
  +            # We reset the GPU devices after Fabric Manager startup to clear stale FM
  +            # partition data after setting FABRIC_MODE=1
  +            echo "Resetting GPUs to clear stale fabric partition states..."
  +            nvidia-smi -r
  +        fi
  ```
  </details>

- **新增 `.driver-daemons-status` 状态文件供上层探测**:`_set_daemons_status()` 写 `/run/nvidia/validations/.driver-daemons-status`;`init()` 开头写 `NotReady`,`_start_daemons` 成功尾部写 `Ready`。给 operator/validator 一个明确的 daemon 就绪信号,不用去猜进程状态。

  <details><summary>代码依据 ubuntu22.04/nvidia-driver</summary>

  ```diff
  +_set_daemons_status() {
  +    mkdir -p /run/nvidia/validations
  +    echo "${1}" > /run/nvidia/validations/.driver-daemons-status
  +}
  ...
   init() {
  ...
  +    _set_daemons_status "NotReady"
  ...
   _start_daemons() {
  ...
  +    _set_daemons_status "Ready"
  ```
  </details>

### 后续发展方向 [AI]
- 三条都指向**驱动容器启动的可观测性与 fabric 正确性**:fail-fast + Ready/NotReady 状态文件让 operator 侧能可靠判定 driver daemon 就绪,B200/NVLink5 的 GPU 复位是 GB200 机架级 fabric 初始化的硬需求。这与 NVIDIA 把 NVL72/fabric-attached 大系统纳入 GPU operator 生命周期管理的趋势一致。证据只覆盖各 OS 的 `nvidia-driver` 启动脚本,**未见对应 operator/validator 端读取该状态文件的 diff**(本仓不含控制器代码),即消费侧改动需在 gpu-operator 侧另行确认。

## kubernetes-sigs/dra-driver-nvidia-gpu: 95932046 -> 3f13e8e5(概览)
- 比较: 95932046683719c43b6a0dd9613c2e5aad5d6703 -> 3f13e8e5 | ahead=15 | files=300(已被 API 截断)| Release: v0.4.1
- **大区间概览,未逐文件读 hunk**(300 文件多为 k8s libs v0.37.0-rc.0 bump 带出的 vendor/generated)
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/95932046...3f13e8e5

### 方向主题(从实质提交聚类,非逐 hunk)
- **NUMA 拓扑属性上报**:`Publish standard NUMA node list attribute`、`Add mock NUMA SLIT coverage`、`fix: flaky gpu selection in numa test`——DRA device 属性里开始标准化上报 NUMA node list 与 SLIT(NUMA 距离矩阵),让调度器按 GPU-NUMA 亲和做分配。
- **GPU passthrough(VFIO)驱动切换硬化**:`passthrough: handle inflight driver switch operations`、`passthrough: enforce timeout for gpu driver switch`、`readability: re-organize vfio kernel module check`——给"host driver ↔ vfio-pci"在途切换加超时与并发处理,提升裸机直通路径鲁棒性。
- **sysfs 发现灵活性**:`Honor alternate sysfs root in GPU discovery`、`fix: use addDeviceAttribute everywhere and drop custom sysfs config`——GPU 发现支持非默认 sysfs 根(利于测试/容器化环境)。
- 依赖:`fix: update Kubernetes libs to v0.37.0-rc.0`(截断的 300 文件主因)。改动热点目录:`cmd/gpu-kubelet-plugin`(10)、`tests/bats`(5)、`hack/ci`(4)、`pkg/featuregates`(1)。
- 边界:release 仍 v0.4.1(上期同版),release note 为已发布内容非本区间新增;概览未读 hunk,NUMA/passthrough 具体符号级改动需点开 compare 核实。

## NVIDIA/mig-parted: f35ad98c -> eba1d1a8
- 比较: f35ad98cc3718a432fd5d1e49d20dbc28fcaedcd -> eba1d1a8 | ahead=2 | files=1 | Release: v0.14.4
- 提交: add oneshot services timeout
- https://github.com/NVIDIA/mig-parted/compare/f35ad98c...eba1d1a8

### AI 总结重点(源码 diff 为据)
- **systemd oneshot 服务加 480s 启动超时**:`nvidia-mig-manager.service` 在 `[Service] Type=oneshot` 下加 `TimeoutStartSec=480`。防止 MIG 重配置(涉及 GPU reset)在慢硬件上被 systemd 默认超时误杀。纯部署健壮性,无 MIG 切分逻辑/API 变化。

  <details><summary>代码依据 deployments/systemd/nvidia-mig-manager.service</summary>

  ```diff
   [Service]
   Type=oneshot
  +TimeoutStartSec=480
   ExecStart=/bin/bash /etc/nvidia-mig-manager/service.sh
  ```
  </details>

### 后续发展方向 [AI]
- 仅超时调参,无风向意义;MIG 静态切分逻辑本期未动。

## 本期无实质改动(折叠)
<details>

- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交(分支 master)
- kai-scheduler/KAI-Scheduler — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=b12fc294e72736be0e554828eba645deb0e45a80 branch=main release=v26.3.3 scanned=2026-08-12 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a996390117806acd2a73fd0e5b3e6a17755f3ae4 branch=main release=v1.20.0-rc.1 scanned=2026-08-12 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=a891f5f599345a6c9bb767c52f761bc9932d1cb1 branch=main release=— scanned=2026-08-12 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=04fc23c27961f42346bcba90e7d00fc2ed818fa0 branch=main release=v0.19.3 scanned=2026-08-12 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=3f13e8e5aea58d44a7d161800829787d447afdae branch=main release=v0.4.1 scanned=2026-08-12 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-12 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-12 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=eba1d1a8a5feccff5e7f226d572a0eb08825d17f branch=main release=v0.14.4 scanned=2026-08-12 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=2f782392ffd43efeccc7fb463cb6371c1144ee17 branch=main release=v0.17.0 scanned=2026-08-12 -->
</content>
</invoke>
