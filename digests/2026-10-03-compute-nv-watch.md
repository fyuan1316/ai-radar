# NVIDIA 算力栈 diff 雷达 2026-10-03

## 摘要
- gpu-operator 给 DCGM ServiceMonitor 加了 `metricRelabelings` CRD 字段([API/CRD变更]),可在采样入库前做二次标签改写,监控可定制度再上一档。
- gpu-driver-container 打通 Arm(Ubuntu 26.04)数据中心预编译驱动镜像:新增 LTS kernel 7.0、arm64 走 sbsa CUDA 源、QEMU 升到 v10.1.3——驱动容器化的 OS/架构矩阵正式把 arm64+26.04 纳入。
- dra-driver-nvidia-gpu 修了动态 MIG 设备 UUID 解析的真实性 bug(原来返回的是父 GPU 的 UUID),DRA 动态切 MIG 的正确性补齐。

## 当日重要改变
- NVIDIA/gpu-operator [API/CRD变更] `ServiceMonitorConfig` 新增 `MetricRelabelings []*promv1.RelabelConfig`(JSON `metricRelabelings`),ClusterPolicy / GPUCluster CRD 同步长出该字段。证据:`api/nvidia/v1/clusterpolicy_types.go`、`config/crd/bases/nvidia.com_clusterpolicies.yaml` https://github.com/NVIDIA/gpu-operator/commit/1c179f1e7bb116fedea4bf448384f4a00770092f

## NVIDIA/gpu-operator: 8587e97f -> 3e1873a2
- 比较: https://github.com/NVIDIA/gpu-operator/compare/8587e97f9df8e0ae12937548619543f74f19612f...3e1873a25ef46219f9b2db6f19a0b90818729586 | ahead=4 | Release: v26.7.1
### AI 总结重点(源码 diff 为据)
- **ServiceMonitor 新增 metricRelabelings(scrape 后、入库前的指标标签改写)**:`ServiceMonitorConfig` 结构体在原有 `Relabelings` 之后新增 `MetricRelabelings` 字段;二者语义不同——`relabelings`(映射到 Prometheus `RelabelConfigs`)作用于抓取目标发现阶段,`metricRelabelings`(映射到 `MetricRelabelConfigs`)作用于样本抓取后、写入 TSDB 前。CRD(clusterpolicies/gpuclusters)同步长出完整的 `RelabelConfig` schema(action/regex/replacement/sourceLabels 等)。这是面向用户的 DCGM 指标治理能力:可在 operator 侧直接裁剪/改写高基数 GPU 指标标签,降 TSDB 压力。
  <details><summary>代码依据 api/nvidia/v1/clusterpolicy_types.go</summary>

  ```diff
   	Relabelings []*promv1.RelabelConfig `json:"relabelings,omitempty"`
  +
  +	// MetricRelabelings allows to rewrite labels on samples scraped from the target,
  +	// applied after the scrape and before ingestion
  +	MetricRelabelings []*promv1.RelabelConfig `json:"metricRelabelings,omitempty"`
   }
  ```
  </details>
- **应用逻辑抽出 derefRelabelConfigs 复用**:`applyServiceMonitorCustomEdits` 把原先内联的 `[]*RelabelConfig -> []RelabelConfig` 解引用循环抽成 `derefRelabelConfigs` 辅助函数,`Relabelings`、`MetricRelabelings` 两条分别写入 `Endpoints[0].RelabelConfigs` 与 `Endpoints[0].MetricRelabelConfigs`。
  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
  -	if desiredState.Relabelings != nil {
  -		relabelConfigs := make([]promv1.RelabelConfig, len(desiredState.Relabelings))
  -		...
  -	}
  +	if desiredState.Relabelings != nil {
  +		currentState.Spec.Endpoints[0].RelabelConfigs = derefRelabelConfigs(desiredState.Relabelings)
  +	}
  +	if desiredState.MetricRelabelings != nil {
  +		currentState.Spec.Endpoints[0].MetricRelabelConfigs = derefRelabelConfigs(desiredState.MetricRelabelings)
  +	}
  ```
  </details>
- **GPUCluster readiness 诊断增强**:新增 "Report which GPUCluster operands are blocking readiness"(commit 087d5fbb / PR #2988),把阻塞就绪的 operand 名称回报到 status,运维定位卡点更直接。(hunk 未纳入 patch 节选,基于 commit+信号文件 `controllers/gpucluster_controller.go` 判断,未读到具体字段)
### 后续发展方向 [AI]
- 监控面(ServiceMonitor)的可定制度持续加厚:`relabelings` 之后再补 `metricRelabelings`,说明 operator 把"GPU 指标标签治理"当成一等能力在做,后续大概率继续对齐 prometheus-operator 的 endpoint 级配置项。证据只覆盖 ServiceMonitor 字段扩展,未见 dcgm-exporter 侧指标语义改动(今日 dcgm-exporter 仓 EMPTY)。

## NVIDIA/gpu-driver-container: 73b03d85 -> 46f292d3
- 比较: https://github.com/NVIDIA/gpu-driver-container/compare/73b03d850b0d2468a75341e5054315aee49f966d...46f292d300b2affd6202d45a1422e41bfedd8fd0 | ahead=2 | Release: —
### AI 总结重点(源码 diff 为据)
- **预编译驱动矩阵纳入 Arm + Ubuntu 26.04**:`precompiled.sh` 把原先写死的单一多架构判断抽成 `targetPlatforms()`——`signed_ubuntu24.04` / `signed_ubuntu26.04` 且非 `azure-fde` 时输出 `linux/amd64 linux/arm64`,否则仅 amd64(因 `linux-objects-nvidia-*-azure-fde` 只发 amd64)。CI 矩阵(image.yaml)新增 `ubuntu26.04` 与 LTS kernel `"7.0"`,并排除 580 驱动×26.04 等无效组合。
  <details><summary>代码依据 scripts/precompiled.sh</summary>

  ```diff
  +function targetPlatforms(){
  +    if [[ "$DIST" == "signed_ubuntu24.04" || "$DIST" == "signed_ubuntu26.04" ]] \
  +       && [[ "$KERNEL_FLAVOR" != "azure-fde" ]]; then
  +        echo "linux/amd64 linux/arm64"
  +    else
  +        echo "linux/amd64"
  +    fi
  +}
  ```
  </details>
- **arm64 CUDA 源走 sbsa、推送前逐平台校验**:26.04 预编译 Dockerfile 按 `TARGETARCH` 选 CUDA 仓(arm64→`sbsa`,否则 `x86_64`);`pushImage` 把 `imageExists` 换成 `imageExistsForAllTargetPlatforms`——对每个目标平台用 `regctl image config --platform` 比对 OS/Arch,避免把只含 amd64 的单 manifest 误判为"arm64 也已存在"而跳过构建。
  <details><summary>代码依据 ubuntu26.04/precompiled/Dockerfile</summary>

  ```diff
  -RUN rm -f /etc/apt/sources.list.d/cuda* && \
  -    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/cuda-keyring_1.1-1_all.deb ...
  +RUN CUDA_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "sbsa" || echo "x86_64") && \
  +    rm -f /etc/apt/sources.list.d/cuda* && \
  +    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/${CUDA_ARCH}/cuda-keyring_1.1-1_all.deb ...
  ```
  </details>
- **QEMU 模拟器为 26.04 arm64 单独升档**:precompiled.yaml 把 binfmt 镜像由全局 `qemu-v6.2.0` 改为 `ubuntu26.04 ? qemu-v10.1.3 : qemu-v6.2.0`;注释说明 resolute userland 上 v6.2.0 挂起、v8.1.5 报 ENOSYS、v9.2.2 报 EINVAL,故钉死 v10.1.3。`.common-ci.yml` 里 26.04 也改用 `tonistiigi/binfmt:qemu-v10.1.3` 先卸载再装全量 handler。
  <details><summary>代码依据 .github/workflows/precompiled.yaml</summary>

  ```diff
  -          image: tonistiigi/binfmt:qemu-v6.2.0
  +          image: tonistiigi/binfmt:${{ matrix.dist == 'ubuntu26.04' && 'qemu-v10.1.3' || 'qemu-v6.2.0' }}
  ```
  </details>
### 后续发展方向 [AI]
- Arm(SBSA/GB200 类)数据中心场景被正式纳入预编译驱动供给——这是 NVIDIA 对 GH/GB 超节点 arm64 主机落地的直接工程信号:预编译镜像免去节点侧编译,利好大规模 arm64 GPU 集群的开机即用。证据覆盖构建/CI/模拟器链路,未见运行时(device-plugin)侧 arm64 专属改动。

## NVIDIA/k8s-device-plugin: 3b2b89ec -> d7265fdc
- 比较: https://github.com/NVIDIA/k8s-device-plugin/compare/3b2b89ecd543ec84f6681aa97569467b1af058a1...d7265fdcf89f571e70b5eb6724ba78a3398bc03e | ahead=4 | Release: v0.20.1
### AI 总结重点(源码 diff 为据)
- **Helm 支持组件级 resources 覆盖**:原先所有 daemonset 共用顶层 `.Values.resources`,现改为 `(.Values.devicePlugin.resources | default .Values.resources)` / `gfd.resources` / `mps.resources` 各自覆盖;并为 config-manager 的 init/sidecar 容器单列 `.Values.configManager.resources`(这些容器不继承顶层 resources)。企业部署可对 device-plugin / GFD / MPS / configManager 分别限额。
  <details><summary>代码依据 deployments/helm/nvidia-device-plugin/templates/daemonset-device-plugin.yml</summary>

  ```diff
  -        {{- with .Values.resources }}
  +        {{- with (.Values.devicePlugin.resources | default .Values.resources) }}
           resources:
             {{- toYaml . | nindent 10 }}
           {{- end }}
  +        {{- with (default (dict) .Values.configManager).resources }}
  +        resources:
  +          {{- toYaml . | nindent 10 }}
  +        {{- end }}
  ```
  </details>
- **NVIDIA_DRIVER_CAPABILITIES 可经 Helm 配置,不再写死**:新增 `.Values.nvidiaDriverCapabilities`(默认 `"compute,utility"`),模板改为仅在非空时注入该环境变量;validation.yml 增一条校验——该值必须是 string(或 null),否则 `fail`。用户可开 `all` 等能力面(如需 graphics/video)。
  <details><summary>代码依据 deployments/helm/nvidia-device-plugin/templates/daemonset-device-plugin.yml</summary>

  ```diff
  +        {{- if .Values.nvidiaDriverCapabilities }}
            - name: NVIDIA_DRIVER_CAPABILITIES
  -            value: compute,utility
  +            value: {{ .Values.nvidiaDriverCapabilities }}
  +        {{- end }}
  ```
  </details>
### 后续发展方向 [AI]
- 两项都是部署面可运维性/可配置性打磨(资源配额精细化 + 驱动能力面放开),非调度内核变化。信号指向 device-plugin 在企业多租场景的落地细节收敛,未见 time-slicing/MPS→DRA 的迁移动作。

## kubernetes-sigs/dra-driver-nvidia-gpu: 495bf4c5 -> 0a3b1b43
- 比较: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/495bf4c59b9423080aa1fe2163955f44a495012c...0a3b1b43faceba80fee63f6fa3f753adfce5b145 | ahead=4 | Release: v0.5.0
### AI 总结重点(源码 diff 为据)
- **动态 MIG 设备 UUID 解析修正(正确性 bug)**:`createMigDevice` 原来对 `ciInfo.Device` 调 `GetUUID()` 取新建 MIG 设备的 UUID——但 NVML 文档里 `ComputeInstanceInfo.device` 是**父 GPU** 句柄,取到的是父 GPU UUID 而非 MIG 设备 UUID。新实现引入 `getMigDeviceUUID(parent, giID, ciID)`:遍历父 GPU 的 MIG 设备句柄(上限 `GetMaxMigDeviceCount()`,如 7),按 GI/CI ID 匹配后再取 UUID。这直接影响 DRA 动态切 MIG 时上报给 ResourceSlice 的设备标识正确性。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/nvlib.go</summary>

  ```diff
  -	uuid, ret := ciInfo.Device.GetUUID()
  -	if ret != nvml.SUCCESS {
  -		return nil, fmt.Errorf("error getting UUID from CI info/device for CI %d: %w", ciInfo.Id, ret)
  +	uuid, err := getMigDeviceUUID(device, int(giInfo.Id), int(ciInfo.Id))
  +	if err != nil {
  +		return nil, fmt.Errorf("error getting MIG device UUID for GI %d / CI %d: %w", giInfo.Id, ciInfo.Id, err)
   	}
  ```
  </details>
- **ValidatingAdmissionPolicy 锁定正确的 kubelet-plugin SA**:VAP 的 `isRestrictedUser` matchCondition 里 service account 名加了 `-kubeletplugin` 后缀,使准入策略精确匹配 kubelet-plugin 的 SA(原先匹配的是不带后缀的名字)。并新增 `hack/test-helm-policy-service-account.sh` + `make helm-test` 守护:校验 chart 渲染出的 kubelet-plugin SA 与 VAP 里引用的一致。
  <details><summary>代码依据 deployments/helm/dra-driver-nvidia-gpu/templates/validatingadmissionpolicy.yaml</summary>

  ```diff
  -      request.userInfo.username == "system:serviceaccount:{{ ...namespace... }}:{{ ...serviceAccountName... }}"
  +      request.userInfo.username == "system:serviceaccount:{{ ...namespace... }}:{{ ...serviceAccountName... }}-kubeletplugin"
  ```
  </details>
### 后续发展方向 [AI]
- 两条都是把"动态 MIG via DRA"从能跑推向生产可信:一修设备标识正确性、一补准入策略精确性 + CI 守护。证据表明动态 MIG 路径(`enableDynamicMIGForTest`)仍在活跃打磨,是 DRA 原生共享的主攻方向,区别于 HAMi 的 hook/时分软切。

## NVIDIA/nvidia-container-toolkit: faef9c9e -> a672e378
- 比较: https://github.com/NVIDIA/nvidia-container-toolkit/compare/faef9c9e6770a59001c9e5f7a9c7adbde9f79685...a672e378ef91bea7dfe92c0ed274847fa1cb9236 | ahead=8 | Release: v1.20.1
### AI 总结重点(源码 diff 为据)
- **NewSorter 不再返回 nil(panic bug 修复)**:`transform.NewSorter()` 原来 `return nil`,而 nil 的 `Transformer` 一旦被调用就 panic;改为 `return sorter{}`。这是 CDI spec 生成里排序 transformer 的构造器,影响容器 edits 排序的稳定性。
  <details><summary>代码依据 pkg/nvcdi/transform/sorter.go</summary>

  ```diff
   func NewSorter() Transformer {
  -	return nil
  +	return sorter{}
   }
  ```
  </details>
- **config set 路径校验:拒绝下钻到非 struct 字段**:`getStruct` 在遍历 toml 路径时,若当前类型已非 struct 仍被要求继续下钻(如 `disable-require.extra=true`),现直接返回 `errUndefinedField`,修掉 `nvidia-ctk config --set` 对 bool/string/slice/pointer 叶子字段再加子路径时的 panic(PR #2107)。
  <details><summary>代码依据 cmd/nvidia-ctk/config/config.go</summary>

  ```diff
   	tomlField := paths[0]
  +	if current.Kind() != reflect.Struct {
  +		return reflect.StructField{}, fmt.Errorf("%w: %q", errUndefinedField, tomlField)
  +	}
  ```
  </details>
- **错误信息修正(真实报错不再被吞)**:lib-csv 里 host CUDA 版本读取失败原来 `%v, ret`(把 NVML 返回码当格式错对象)改为 `%w, err` 正确包裹;update-ldcache 把 container root 判断拆成"err 非空"与"root 为空/为 /"两段,并用 `%w` 包裹原始 err。
  <details><summary>代码依据 pkg/nvcdi/lib-csv.go</summary>

  ```diff
  -		return nil, fmt.Errorf("failed to get host CUDA version: %v", ret)
  +		return nil, fmt.Errorf("failed to get host CUDA version: %w", err)
  ```
  </details>
### 后续发展方向 [AI]
- 本期全是健壮性/错误可诊断性修复(nil transformer、config 下钻 panic、错误包裹),无新能力或 CDI 行为语义变化。说明 container-toolkit 当前处于 bug 收敛期,CDI 生成链路在补边界。

## 本期无实质改动(折叠)
- NVIDIA/dcgm-exporter — 无新提交(Release 4.8.4)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — ahead=4 但仅 bump/CI/merge,无实质代码改动(Release v0.15.1)
- kai-scheduler/KAI-Scheduler — 无新提交(Release v0.18.2)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=3e1873a25ef46219f9b2db6f19a0b90818729586 branch=main release=v26.7.1 scanned=2026-10-03 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-03 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=46f292d300b2affd6202d45a1422e41bfedd8fd0 branch=main release=— scanned=2026-10-03 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d7265fdcf89f571e70b5eb6724ba78a3398bc03e branch=main release=v0.20.1 scanned=2026-10-03 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=0a3b1b43faceba80fee63f6fa3f753adfce5b145 branch=main release=v0.5.0 scanned=2026-10-03 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-03 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-03 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9a831d5d84770d6d976c6499572425eddc88ee7a branch=main release=v0.15.1 scanned=2026-10-03 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=5982e4bf5559120d1fb5650ebec7fe400e85bc95 branch=main release=v0.18.2 scanned=2026-10-03 -->
