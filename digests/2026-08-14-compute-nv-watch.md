# NVIDIA 算力栈 diff 雷达 2026-08-14

## 摘要
- **KAI-Scheduler 做了一轮 RBAC 最小权限收紧**:kai-admission/queuecontroller/podgroup-controller/node-scale-adjuster 四个控制器**彻底移除 ConfigMap 读写权限**;同时 podgrouper 新增 `WorkloadRunner` 包装类型识别与 NVIDIA Dynamo `DynamoGraphDeployment` 分组支持,把"跳过顶层 owner"的分组逻辑从静态 map 改为动态 resolver 闭包。
- **驱动容器就绪链闭环**:gpu-operator 的 driver 校验脚本开始消费 `.driver-daemons-status` sentinel 文件——daemons 未 Ready 就直接 fail,承接前几日 gpu-driver-container 侧写该 sentinel 的改动。
- 一次 NVIDIA 全家桶级的**开源合规基建铺开**:gpu-operator / container-toolkit / k8s-device-plugin / mig-parted 五仓同期落地 `THIRD_PARTY_NOTICES.md` 生成器 + CI 校验 + OCI 标准镜像标签,属工程治理而非功能。

## 当日重要改变
- KAI-Scheduler [架构方向] podgrouper 分组解析从 `customPlugins` 静态 map 改为 `GrouperResolver` 闭包,新增 `WorkloadRunner`(run.ai)与 `nvidia.com/DynamoGraphDeployment` 分组路由 + 对应 RBAC。证据 `pkg/podgrouper/podgrouper/hub/hub.go`、`skiptopowner.go`。https://github.com/kai-scheduler/KAI-Scheduler/pull/2067
- KAI-Scheduler [弃用/移除] 四控制器 ClusterRole 全量删除 ConfigMap 动词 + admission 删掉 `ReconcilerParams`。证据 `deployments/kai-scheduler/templates/rbac/*.yaml`、`cmd/admission/app/app.go`。https://github.com/kai-scheduler/KAI-Scheduler/pull/2061
- gpu-operator [新能力] driver 校验新增 `.driver-daemons-status` sentinel 门禁,非 `Ready` 即退出 1。证据 `manifests/state-driver/0400_configmap.yaml`。https://github.com/NVIDIA/gpu-operator/compare/b12fc294e72736be0e554828eba645deb0e45a80...248cabb6a717d75dceb022ea98079968f9572ffd
- dra-driver-nvidia-gpu [新能力] MPS checkpoint 序列化修正:`MpsControlDaemonID` 去掉 `omitempty` 防空值 marshal 损坏;并首次成文化软件/硬件支持矩阵(含 VFIO passthrough、ComputeDomains 需 GB200/GB300 NVL72)。证据 `cmd/gpu-kubelet-plugin/device_state.go`、`site/content/docs/prerequisites.md`。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/3f13e8e5aea58d44a7d161800829787d447afdae...acdc10f11753a2686f24ba07fcadccad0073de0e
- nvidia-container-toolkit [新能力] v1.20.0 CHANGELOG 声明新增 `enable-cuda-compat` 与 `update-application-profile`(EGL/Vulkan)两个 CDI hook(hook 代码本窗口未见,仅 CHANGELOG 为据)。https://github.com/NVIDIA/nvidia-container-toolkit/compare/a996390117806acd2a73fd0e5b3e6a17755f3ae4...02ccb62b0d828daaf3f4714f5d636773bfcf06aa

## kai-scheduler/KAI-Scheduler: 2f782392 -> cea080fe
- 比较: 2f782392ffd43efeccc7fb463cb6371c1144ee17 -> cea080fe | ahead=3 | Release: v0.17.0
- 比较链接:https://github.com/kai-scheduler/KAI-Scheduler/compare/2f782392ffd43efeccc7fb463cb6371c1144ee17...cea080fe6f7674f669bea907c8a92b5edeaa31b7

### AI 总结重点(源码 diff 为据)
- **podgrouper 分组插件解析改为运行期动态查找**。`skipTopOwnerGrouper` 原持有一份静态 `customPlugins map[GVK]Grouper`,现改为持有 `GrouperResolver` 闭包(`func(gvk) grouper.Grouper`),运行时回调 `hub.GetPodGrouperPlugin(gvk)`。作用:skip-top-owner 分组器能看到在它构造之后才注册进 table 的插件条目与 Karta fallback,消除构造顺序耦合。

  <details><summary>代码依据 pkg/podgrouper/podgrouper/plugins/skiptopowner/skiptopowner.go</summary>

  ```diff
  +// GrouperResolver resolves the grouper handling a GVK, or nil when none matches.
  +type GrouperResolver func(gvk metav1.GroupVersionKind) grouper.Grouper
  +
   type skipTopOwnerGrouper struct {
  -	customPlugins map[metav1.GroupVersionKind]grouper.Grouper
  +	resolveGrouper GrouperResolver
   }
  ...
  -	if grouper, found := sk.customPlugins[ownerKind]; found {
  -		return grouper.GetPodGroupMetadata(lastOwner, pod, otherOwners...)
  +	if sk.resolveGrouper != nil {
  +		if resolved := sk.resolveGrouper(ownerKind); resolved != nil {
  +			return resolved.GetPodGroupMetadata(lastOwner, pod, otherOwners...)
  +		}
   }
  ```
  </details>

- **新增 `WorkloadRunner` 包装类型的"跳过"路由 + Dynamo 集成**。hub 里新增常量 `kindWorkloadRunner = "WorkloadRunner"`,把 `run.ai/WorkloadRunner`(Version `*`)注册到 `skipTopOwnerGrouper`——因为它是对任意 workload 模板的 kind-agnostic 包装器,跳过后由被包装 kind 的插件决定分组。同步新增 `run.ai/workloadrunners` 与 `nvidia.com/dynamographdeployments` 的 RBAC watch 权限。

  <details><summary>代码依据 pkg/podgrouper/podgrouper/hub/hub.go</summary>

  ```diff
  +	kindWorkloadRunner               = "WorkloadRunner"
  ...
  +// +kubebuilder:rbac:groups=run.ai,resources=workloadrunners,verbs=get;list;watch
  +// +kubebuilder:rbac:groups=nvidia.com,resources=dynamographdeployments,verbs=get;list;watch
  ...
  +	// WorkloadRunner is a kind-agnostic wrapper around an arbitrary workload template.
  +	// Skip it so the wrapped kind's plugin decides the grouping.
  +	table[metav1.GroupVersionKind{
  +		Group:   apiGroupRunai,
  +		Version: "*",
  +		Kind:    kindWorkloadRunner,
  +	}] = skipTopOwnerGrouper
  ```
  </details>

- **四个控制器 ClusterRole 全量剥除 ConfigMap 权限**(create/delete/get/list/patch/update/watch 整段删除),涉及 queuecontroller、kai-podgroup-controller、node-scale-adjuster、admission。admission 侧连带删除 `ReconcilerParams`(限流参数)与 `+kubebuilder:rbac:...configmaps...` 注解。属最小权限收敛,缩小 RBAC 攻击面。

  <details><summary>代码依据 deployments/.../rbac/queuecontroller.yaml + cmd/admission/app/app.go</summary>

  ```diff
  # queuecontroller.yaml(podgroupcontroller.yaml 同样删除)
  -- apiGroups:
  -  - ""
  -  resources:
  -  - configmaps
  -  verbs:
  -  - create
  -  - delete
  -  - get
  ...
  # cmd/admission/app/app.go
  -	reconcilerParams := &controllers.ReconcilerParams{
  -		RateLimiterBaseDelaySeconds: options.RateLimiterBaseDelaySeconds,
  -		RateLimiterMaxDelaySeconds:  options.RateLimiterMaxDelaySeconds,
  -	}
  -// +kubebuilder:rbac:groups=core,resources=configmaps,verbs=get;list;watch;create;update;patch;delete
  ```
  </details>

### 后续发展方向 [AI]
- podgrouper 明确在为 **NVIDIA Dynamo(`DynamoGraphDeployment`)与 run.ai WorkloadRunner** 做原生分组接入——KAI 正把自己坐实为 NVIDIA 推理/训练编排栈(Dynamo)的默认 gang-scheduler。证据只覆盖分组路由 + RBAC 注册,未见 Dynamo 侧具体 podgroup 元数据映射逻辑。
- RBAC 去 ConfigMap 化说明这些控制器已不再用 ConfigMap 存状态(疑似转向 CRD/Lease);对我们产品的启示:若对标做多租户调度器,leader 选举与状态存储应走 Lease/CRD 而非 ConfigMap,便于按 controller 精细授权。

## kubernetes-sigs/dra-driver-nvidia-gpu: 3f13e8e5 -> acdc10f1
- 比较: 3f13e8e5aea58d44a7d161800829787d447afdae -> acdc10f1 | ahead=13 | Release: v0.4.1
- 比较链接:https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/3f13e8e5aea58d44a7d161800829787d447afdae...acdc10f11753a2686f24ba07fcadccad0073de0e

### AI 总结重点(源码 diff 为据)
- **MPS checkpoint 序列化健壮性修复**。`DeviceConfigState.MpsControlDaemonID` 的 json tag 从 `omitempty` 改为始终序列化。原因:空值被 `omitempty` 省略后再反序列化会导致 checkpoint 记录损坏(commit 标题:marshal empty mpsControlDaemonID to avoid corruption)。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  -	MpsControlDaemonID string              `json:"mpsControlDaemonID,omitempty"`
  +	MpsControlDaemonID string              `json:"mpsControlDaemonID"`
  ```
  </details>

- **FabricManager 打开失败时给出 FABRIC_MODE 诊断提示**。`fabricmanager.Open()` 里 `GetSupportedFabricPartitions()` 失败的错误信息追加 "Ensure Fabric Manager is running and FABRIC_MODE is correctly set"——面向 GB200/GB300 NVLink fabric 场景的可运维性改进。

  <details><summary>代码依据 pkg/fabricmanager/manager.go</summary>

  ```diff
  -		return nil, fmt.Errorf("fabricmanager: fmGetSupportedFabricPartitions: %w", err)
  +		return nil, fmt.Errorf("fabricmanager: fmGetSupportedFabricPartitions: %w. Ensure Fabric Manager is running and FABRIC_MODE is correctly set", err)
  ```
  </details>

- **成文化软件/硬件支持矩阵**(docs)。`prerequisites.md` 把 GPU allocation 与 ComputeDomains 拆成两条独立可开关的能力,并列硬件要求:MPS 需 V100+、MIG 需 Ampere+、ComputeDomains 需 Grace Blackwell Multi-Node NVLink(GB200/GB300 NVL72),并首次列出 "Full GPU allocation, time-slicing, or **VFIO passthrough**" 一档。K8s 版本要求 GPU allocation 需 v1.34.2+,ComputeDomains 最低 v1.32(需开 `DynamicResourceAllocation` gate)。

  <details><summary>代码依据 site/content/docs/prerequisites.md</summary>

  ```diff
  +| Resource or feature | Hardware requirement |
  +| Full GPU allocation, time-slicing, or VFIO passthrough | NVIDIA Data Center GPUs |
  +| MPS multi-user mode | NVIDIA V100 or newer. ... `multiUser: true` ... |
  +| MIG | A MIG-capable data center GPU ... Ampere ... |
  +| ComputeDomains | Grace Blackwell GPUs with Multi-Node NVLink, such as NVIDIA HGX GB200 NVL72 or GB300 NVL72. |
  ```
  </details>

### 后续发展方向 [AI]
- DRA driver 明确把能力矩阵切成 **GPU allocation(含 time-slicing / VFIO passthrough)** 与 **ComputeDomains(GB200/GB300 NVLink fabric)** 两条正交线——VFIO passthrough 进入官方支持档,意味着 DRA 路径要覆盖直通虚拟化,不再只是 CDI 注入。证据仅为 docs 矩阵,未见 VFIO passthrough 的 device_state 实现代码。
- 其余 11 个文件是 CI checkout action SHA 统一升 v7.0.1,无功能含义。

## NVIDIA/gpu-operator: b12fc294 -> 248cabb6
- 比较: b12fc294e72736be0e554828eba645deb0e45a80 -> 248cabb6 | ahead=12 | Release: v26.3.3
- 比较链接:https://github.com/NVIDIA/gpu-operator/compare/b12fc294e72736be0e554828eba645deb0e45a80...248cabb6a717d75dceb022ea98079968f9572ffd

### AI 总结重点(源码 diff 为据)
- **driver 就绪校验新增 daemons sentinel 门禁**。state-driver 校验脚本读取 `${VALIDATIONS_DIR}/.driver-daemons-status`,若存在且内容非 `Ready` 则打印状态并 `exit 1`。这与前期 gpu-driver-container 侧新增写 `.driver-daemons-status`(FabricManager fail-fast)配对,形成"驱动 daemon 未就绪 → validation 卡住 → 上层不 Ready"的闭环。

  <details><summary>代码依据 manifests/state-driver/0400_configmap.yaml</summary>

  ```diff
  +    DAEMONS_STATUS_FILE="${VALIDATIONS_DIR}/.driver-daemons-status"
  ...
  +    if [ -f "$DAEMONS_STATUS_FILE" ]; then
  +      daemons_status=$(cat "$DAEMONS_STATUS_FILE")
  +      if [ "$daemons_status" != "Ready" ]; then
  +        echo "NVIDIA driver daemons are not ready; Current status: $daemons_status"
  +        exit 1
  +      fi
  +    fi
  ```
  </details>

- **distroless 镜像运行用户从 65532 改为 1000**(commit: fix user to an existing user in distroless image),规避 distroless/cc 里 65532 用户不存在的问题;同时补齐 OCI 标准镜像标签(`org.opencontainers.image.*`)。

  <details><summary>代码依据 docker/Dockerfile</summary>

  ```diff
  -USER 65532:65532
  +USER 1000:1000
  +LABEL org.opencontainers.image.source="https://github.com/NVIDIA/gpu-operator.git"
  +LABEL org.opencontainers.image.revision="${GIT_COMMIT_SHA_FULL}"
  ```
  </details>

- 其余为 container-toolkit 镜像 bump 到 v1.20.0、THIRD_PARTY_NOTICES 合规工具(见文末统一说明)。**本窗口无 ClusterPolicy/`*_types.go` CRD 字段增删**。

### 后续发展方向 [AI]
- driver 容器就绪判定正从"内核模块 loaded + nvidia-smi 通"细化到"daemon 级状态机"(FabricManager 等 daemon 就绪才放行),对 GB200 这类依赖 fabric 分区的机型尤为关键。证据只覆盖 validation 脚本消费端,未见 sentinel 写入端在本仓的实现。

## NVIDIA/mig-parted: eba1d1a8 -> a113e7d6
- 比较: eba1d1a8a5feccff5e7f226d572a0eb08825d17f -> a113e7d6 | ahead=6 | Release: v0.14.5(上期 v0.14.4)
- 比较链接:https://github.com/NVIDIA/mig-parted/compare/eba1d1a8a5feccff5e7f226d572a0eb08825d17f...a113e7d6621bfbaf78dd434d2dee1f6c58bf6d05

### AI 总结重点(源码 diff 为据)
- **发布 v0.14.5,核心是 systemd 死锁规避 + 480s 启动超时**。CHANGELOG 声明:hook 内跳过 container runtime 调用以避免死锁、给 `nvidia-mig-manager.service` 加 480 秒启动超时。另 `versions.mk` 清理了 `vVERSION := v$(VERSION:v%=%)` 冗余间接层,build-arg 直接用 `$(VERSION)`。

  <details><summary>代码依据 CHANGELOG.md + versions.mk</summary>

  ```diff
  +## v0.14.5
  +- Skip container runtime calls in hooks to avoid deadlocks
  +- Add a start timeout of 480 seconds to nvidia-mig-manager.service
  +- Bump k8s golang dependencies to v0.36.3
  ...
  -VERSION ?= v0.14.4
  -vVERSION := v$(VERSION:v%=%)
  +VERSION ?= v0.14.5
  ```
  </details>

### 后续发展方向 [AI]
- MIG 静态切分器持续硬化 systemd oneshot 生命周期(--no-block → 480s 超时),说明大机型上 MIG 重配置耗时确有超 default 超时风险。证据为 CHANGELOG + versions.mk,service unit 具体改动文件未在信号文件 top 内。

## 本期无实质改动 / 仅合规基建(折叠)
<details><summary>展开</summary>

- **NVIDIA/gpu-driver-container** — ahead=6,仅 RHEL UBI8/9/10 base image digest 版本号 bump(如 ubi8 8.10-1785749648 → 8.10-1786322297),无功能变化。
- **NVIDIA/k8s-device-plugin** — ahead=6,仅新增 `THIRD_PARTY_NOTICES.md` + 生成器 + CI 校验(#1950),无 device-plugin 功能改动。
- **NVIDIA/dcgm-exporter** — 无新提交(EMPTY)。
- **NVIDIA/DCGM** — 无新提交(EMPTY,分支 master)。

**跨仓统一说明——开源合规基建**:gpu-operator / nvidia-container-toolkit / k8s-device-plugin / mig-parted 本期同期落地 `THIRD_PARTY_NOTICES.md`(go-licenses 生成)+ `check-third-party-notices` CI 门禁 + OCI 标准镜像标签(`org.opencontainers.image.*`)。属 NVIDIA 全家桶级供应链/合规治理,非产品功能;不逐仓展开。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=248cabb6a717d75dceb022ea98079968f9572ffd branch=main release=v26.3.3 scanned=2026-08-14 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=02ccb62b0d828daaf3f4714f5d636773bfcf06aa branch=main release=v1.20.0-rc.1 scanned=2026-08-14 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=eb48f7e2f8e59e7b65bff29537c442efacdb75a9 branch=main release=— scanned=2026-08-14 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=93ebcb6ad05dcb7309fa255a9ee8cff8fcc72d88 branch=main release=v0.19.3 scanned=2026-08-14 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=acdc10f11753a2686f24ba07fcadccad0073de0e branch=main release=v0.4.1 scanned=2026-08-14 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-14 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-14 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=a113e7d6621bfbaf78dd434d2dee1f6c58bf6d05 branch=main release=v0.14.5 scanned=2026-08-14 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=cea080fe6f7674f669bea907c8a92b5edeaa31b7 branch=main release=v0.17.0 scanned=2026-08-14 -->
</content>
</invoke>
