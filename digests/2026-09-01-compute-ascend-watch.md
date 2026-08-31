# 昇腾算力栈 diff 雷达 2026-09-01

## 摘要
- **mind-cluster 出现本周期最大动作:DPU/UB fabric 直通栈成型**——RDMA device-plugin 新增"独占模式"(NPU↔DPU 一一绑定 + 设备级隔离),并落地全新 CNI 插件 `ub-host-device-cni`(把宿主 UB/DPU 网卡直通进 Pod 网络命名空间、可继承宿主 IP)。这是昇腾多机训练 RoCE/UB 高速网络的"device-plugin 分配 + CNI 挂载"闭环,对标 NVIDIA GPUDirect RDMA + host-device/SR-IOV 直通。
- 值得留意的设计取舍:独占分配**不走 apiserver watch,而是查本地 kubelet `/pods` 端点**(降 apiserver 压力,代价是需要 `nodes/proxy` RBAC + 对 kubelet `InsecureSkipVerify` 的 TLS);分配次序绑定 Volcano 的 `predicate-time` 注解。发现一处发货配置 JSON 全角逗号 bug。
- 8 个 openFuyao NPU 仓相对 08-31 锚点**全部无新提交**。仅 mind-cluster 非空。

## 当日重要改变
- **mind-cluster [新能力] RDMA device-plugin 新增独占模式(`--ub-excl-mode`)**:默认共享模式按 `rdmaHcaMax` 造虚拟设备;独占模式上报节点真实 UB 设备、按 NPU-NIC 映射把 NPU 对应的 DPU 一一挂给 Pod,实现设备级隔离。证据:`component/k8s-rdma-shared-dev-plugin/pkg/resources/ub_device/server.go`、新增 `npu_allocate.go`(462 行)。提交 "k8s rdma exclusive mode code"。 https://gitcode.com/Ascend/mind-cluster/commit/61fdac5097b681e450353a46e346a01bb15fe5d6
- **mind-cluster [新能力] 新增独立 CNI 组件 `component/ub-host-device-cni`**:在 CNI host-device 基础上扩展华为 DPU(UB 总线)直通,新增 `ubMode`/`inheritHostIP` 参数、`/sys/bus/ub/devices` 总线路径;配合 Multus `capabilities.deviceID` + `k8s.v1.cni.cncf.io/resourceName: huawei.com/ub_rdma` 把 device-plugin 分配结果注入 CNI 挂载。证据:`component/ub-host-device-cni/cmd/main.go`(+789)、新增 README。 https://gitcode.com/Ascend/mind-cluster/commit/61fdac5097b681e450353a46e346a01bb15fe5d6
- **mind-cluster [架构方向] 独占分配走 kubelet `/pods` 而非 apiserver**:`npu_allocate.go` 用 in-cluster token 直连本地 kubelet `/pods`(自签证书 `InsecureSkipVerify`),RBAC 相应收窄——pods 仅留 `patch`、新增 `nodes/proxy get`(k8s 1.33+ 细粒度 authz 映射 /pods)、configmaps 从 get/list/watch/delete 收到只剩 create/update。证据:`build/k8s-rdma-shared-dp.yaml`。 https://gitcode.com/Ascend/mind-cluster/commit/61fdac5097b681e450353a46e346a01bb15fe5d6
- **mind-cluster [潜在 bug] 发货的 NAD 示例 JSON 有全角逗号**:`build/nad-cni-inherit-config.yaml` 里 `"inheritHostIP": true，`(中文 `，`)是非法 JSON,而同组件 README 内示例用的是正确 ASCII 逗号,直接 apply 该文件会解析失败。 https://gitcode.com/Ascend/mind-cluster/commit/61fdac5097b681e450353a46e346a01bb15fe5d6

## mind-cluster: 78655a79 -> 61fdac50
- 比较: 78655a79..61fdac50 | tag: v26.2.0.beta.1 | commits=10 | truncated=false
- 命中信号目录(component/ 限定):`k8s-rdma-shared-dev-plugin`(13 文件)、`ub-host-device-cni`(8 文件)、`ascend-dynamic-resource-allocation`(2 文件,纯 UT)。注:改动落在 PATHPREFIX 之外的新 component 子目录,本篇已按实际路径补读。

### AI 总结重点(源码 diff 为据)

- **独占模式的设备上报语义反转**:共享模式用 `createUbVirtualDevices` 按 `rdmaHcaMax` 造 N 个虚拟设备;独占模式改用新函数 `createUbExclDevices`,`ID=dev.GetName()`、数量=节点真实 DPU 数,并把 `GetPreferredAllocationAvailable` 置为 `exclMode`(让 kubelet 走首选分配)。`UpdateDevices` 里设备变更也按模式分流。
  <details><summary>代码依据 component/k8s-rdma-shared-dev-plugin/pkg/resources/ub_device/server.go</summary>

  ```diff
  +	var devs []*pluginapi.Device
  +	if exclMode {
  +		devs = createUbExclDevices(devices)
  +	} else {
  +		devs = createUbVirtualDevices(len(devices), deviceSpec, config.ResourceName)
  +	}
  ...
  +func createUbExclDevices(devices []types.Device) []*pluginapi.Device {
  +	for _, dev := range devices {
  +		devs = append(devs, &pluginapi.Device{ID: dev.GetName(), Health: pluginapi.Healthy})
  +	}
  ...
  -		PreStartRequired: false,
  +		PreStartRequired:                false,
  +		GetPreferredAllocationAvailable: rs.exclMode,
  ```
  </details>

- **Allocate 由 RLock 升级为写锁 + 校验先行**:独占分支先校验 kubelet 指派的每个 deviceID 都在本地设备表内(不在则报错、失败不留残状态),再 `allocateByNpu` 记录分配,最后按 kubelet 指派挂载;共享分支才走"挂载全部设备"。写锁是为了和 `allocateByNpu` 的注解回写互斥。
  <details><summary>代码依据 server.go Allocate()</summary>

  ```diff
  -	rs.mutex.RLock()
  -	defer rs.mutex.RUnlock()
  -	for _, _ = range reqs.ContainerRequests { response.Devices = append(response.Devices, rs.deviceSpec...) }
  +	rs.mutex.Lock()
  +	defer rs.mutex.Unlock()
  +	if rs.exclMode {
  +		for ... id := range container.DevicesIDs {
  +			if _, ok := rs.deviceSpecByID(id); !ok { return nil, fmt.Errorf("device %q not found ...") }
  +		}
  +		if err := rs.allocateByNpu(ctx, allRequestedDeviceIDs(reqs)); err != nil { return nil, err }
  ```
  </details>

- **分配落盘方式:查 kubelet /pods + patch pod 注解**。`npu_allocate.go` 用 in-cluster bearer token 直连本地 kubelet `https://$HOST_IP:10250/pods`(自签证书 `InsecureSkipVerify`),过滤本节点、非终态、申请了该资源的 Pod;按 `predicate-time` 注解排序(取不到再回退 CreationTimestamp、UID,保证确定性 oldest-first),把分到的 DPU ID 以 `k8s.v1.cni.cncf.io/device-status` 注解 StrategicMergePatch 回写 Pod。`predicate-time` 是 Volcano NPU 调度产物——即独占分配由调度器驱动。
  <details><summary>代码依据 component/k8s-rdma-shared-dev-plugin/pkg/resources/ub_device/npu_allocate.go(新增)</summary>

  ```go
  kubeletClient = &http.Client{Transport: &http.Transport{
      TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}} // #nosec
  // ...
  return "https://" + net.JoinHostPort(hostIP, port) + "/pods", nil
  // ...
  annotations := map[string]string{
      podPredicateTimeAnnotation: strconv.FormatUint(math.MaxUint64, 10),
      deviceStatusAnnotation:     string(status)}
  _, err = rs.k8sClient.CoreV1().Pods(pod.Namespace).Patch(ctx, pod.Name,
      apitypes.StrategicMergePatchType, patchBytes, metav1.PatchOptions{})
  ```
  </details>

- **RBAC 收窄 + 新增 kubelet 访问权**:configmaps 从 `get/create/update/delete/list/watch` 收到只剩 `create/update`;新增 ClusterRole 只给 pods `patch`;nodes 从 `get/patch/update` 收到只剩 `patch` 并新增 `nodes/proxy get`(webhook authz 下访问 kubelet /pods 所需);DaemonSet 注入 `HOST_IP`(status.hostIP)。注释明确写"pod discovery uses the local kubelet /pods endpoint, so no get/list/watch"——刻意规避 apiserver watch 负载。
  <details><summary>代码依据 component/k8s-rdma-shared-dev-plugin/build/k8s-rdma-shared-dp.yaml</summary>

  ```diff
  -    verbs: ["get", "create", "update", "delete", "list", "watch"]   # configmaps
  +    verbs: ["create", "update"]
  +  - apiGroups: [""]
  +    resources: ["nodes/proxy"]
  +    verbs: ["get"]
  +            - name: HOST_IP
  +              valueFrom: { fieldRef: { fieldPath: status.hostIP } }
  ```
  </details>

- **ub-host-device-cni:UB 直通挂载 + 宿主 IP 继承**。新增 `UBMode`(设备来源优先级 NAD `device` > kubelet/Multus 注入的 `runtimeConfig.deviceID`)与 `InheritHostIP`(挂载后保留宿主 IP、不再走 IPAM);UB 模式下跳过 PCI/DPDK 检测与"必须指定 device/hwaddr"的校验,新增 `/sys/bus/ub/devices` 总线扫描路径。定位:二进制放 `/opt/cni/bin`,性能无损直通。
  <details><summary>代码依据 component/ub-host-device-cni/cmd/main.go</summary>

  ```diff
  +	sysBusUb        = "/sys/bus/ub/devices"
  +	// UBMode enables DPU (UB) mounting; devices come from the NAD "device"
  +	// or the kubelet-injected runtimeConfig.deviceID.
  +	UBMode bool `json:"ubMode,omitempty"`
  +	InheritHostIP bool `json:"inheritHostIP,omitempty"`
  -	if n.Device == "" && n.HWAddr == "" && n.KernelPath == "" && n.PCIAddr == "" && n.auxDevice == "" {
  +	if !n.UBMode && n.Device == "" && ... {
  ```
  </details>

- **npu_nic_mapping.go 重构 + 安全读取器被换掉(留意)**:抽出 `loadNpuNicMapping`(同时兼容"按机型分组 ProductMapping"经 `machineType()` 选型 与 扁平 `NpuNicMapping`),新增 `GetNicNames(npuId)` 正向反查、带 `sync.Once` 缓存。但读取从加固过的 `RealFileChecker`/`ReadLimitBytesWithSymlink`(限长+符号链接校验)换成了普通 `os.ReadFile`/`utils.LoadFile`——放宽了对 npu-nic-mapping 配置文件的路径/大小防护,值得关注。
  <details><summary>代码依据 component/k8s-rdma-shared-dev-plugin/pkg/utils/npu_nic_mapping.go</summary>

  ```diff
  -		data, err := ascutils.ReadLimitBytesWithSymlink(path, 1024, validateSysfsPath)
  +		data, err := os.ReadFile(path)
  ...
  +func loadNpuNicMapping() (*NpuNicMapping, error) {
  +	data, err := utils.LoadFile(npuNicMappingConfigPath)
  +func GetNicNames(npuId int) ([]string, error) { ... }
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾在补齐"多机训练高速网络"的 K8s 原语**:device-plugin 独占分配(NPU↔DPU 绑定)+ host-device CNI 直通 + 宿主 IP 继承,是把 DPU/UB fabric 变成可调度可隔离资源的一整套动作,方向对标 NVIDIA 的 RDMA/GPUDirect 网络直通。证据覆盖 device-plugin 与 CNI 两侧代码,但**未见** IPAM 侧与 Volcano 侧如何生成 `predicate-time`/`npu-nic-mapping` 的写入路径(只见消费端),端到端编排链尚未在本区间暴露。
- **"绕开 apiserver、直连 kubelet /pods"** 的分配范式若推广,对我们自家产品的启示是双面的:规模化下确实省 apiserver watch,但引入了 kubelet 直连(`InsecureSkipVerify` + `nodes/proxy` 提权)的安全面,多租户场景需评估。证据仅限本组件 RBAC 与 http.Client 配置。
- 证据边界:仅读了 mind-cluster 本次 10 个提交的 diff,`ascend-dynamic-resource-allocation` 本区间只新增 UT(flags 的 kubeclient/hwlogging 测试),未见 DRA 生产代码变化。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo(仅保锚点,相对 08-31 无新提交)</summary>

- npu-operator(无新提交,tag v26.6.0)
- npu-container-toolkit(无新提交,tag v26.6.0)
- npu-driver-installer(无新提交,tag v26.6.0)
- vNPU(无新提交,tag v0.1.0)
- npu-node-provision(无新提交,tag v26.6.0)
- npu-dra-plugin(无新提交,tag v26.6.0)
- volcano-ext(无新提交,tag v1.9.0)
- ub-network-device-plugin(无新提交,tag 1.0.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=61fdac5097b681e450353a46e346a01bb15fe5d6 tag=v26.2.0.beta.1 scanned=2026-09-01 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=npu-dra-plugin sha=1084df7c16dbb60173b0dbc8e4cd561dd45b430d tag=v26.6.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-09-01 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=475aefcdd1c522d10ca4b9cfdb0acc1c07606171 tag=1.0.2 scanned=2026-09-01 -->
