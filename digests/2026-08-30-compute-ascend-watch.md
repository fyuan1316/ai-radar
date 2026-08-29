# 昇腾算力栈 diff 雷达 2026-08-30

## 摘要
- **npu-exporter 把 vNPU 指标采集从"仅 310P"扩到 310P/910B/910A3(A2/A3)**:新增公开 map `SupportedVnpuDevices` 替代硬编码 `devType == Ascend310P` 判断,910B/910A3 现在也能上报 vNPU 切分设备的算力/显存指标——昇腾监控侧对 A2/A3 大芯片的虚拟化观测正式补齐。
- **ascend-docker-runtime 翻转 UB 驱动挂载语义:环境变量从"禁用"(DisableUBMount)改成"启用"(AscendUBDrvMount),且默认值(空)现在=挂载**。这是一个默认行为翻转的运行时契约变更,升级需留意。
- ascend-for-volcano 修重调度 grace 删除场景的 pod 数据竞争(删掉往共享 pod 写 Condition 的逻辑 + build 期给 volcano Evict 打 DeepCopy 补丁);noded IPMI 监控改懒加载支持 BMC 临时掉线自愈。

## 当日重要改变
- mind-cluster [新能力] npu-exporter vNPU 指标设备白名单从 `{310P}` 扩到 `{310P,910B,910A3}`,910B/910A3 补齐 vNPU 监控。证据:`component/npu-exporter/collector/common/npu_collector.go` 新增 `SupportedVnpuDevices`。 https://gitcode.com/Ascend/mind-cluster/commit/78655a79e2f9ff09e88df45c29706c6b1d6c2689
- mind-cluster [架构方向] ascend-docker-runtime UB 驱动文件挂载环境变量语义翻转(默认从不挂载变为挂载),`DisableUBMountEnv`→`AscendUBDrvMountEnv`、`DisableUBMounts` 字段→`MountUBDrv`。证据:`component/ascend-docker-runtime/hook/process/process.go`、`runtime/process/process.go`。 https://gitcode.com/Ascend/mind-cluster/compare/ee074e93d83ccdf32dd3a734621f4b61ad0f5e1a...78655a79e2f9ff09e88df45c29706c6b1d6c2689
- ub-network-device-plugin [新能力] 新增 `utils/errors.go`(`PluginErrorTag`/`LabeledPluginError`)+ gRPC 服务端拦截器,统一给回给 kubelet 的错误打插件标签;运行时 sock 挂载从文件改为 `/run/containerd` 目录(只读)以扛运行时重启。 https://gitcode.com/openFuyao/ub-network-device-plugin/commit/475aefcdd1c522d10ca4b9cfdb0acc1c07606171

## mind-cluster: ee074e93 -> 78655a79
- 比较: ee074e93...78655a79 | tag: v26.2.0.beta.1 | commits=24 | truncated=false
- 源:https://gitcode.com/Ascend/mind-cluster/compare/ee074e93d83ccdf32dd3a734621f4b61ad0f5e1a...78655a79e2f9ff09e88df45c29706c6b1d6c2689

### AI 总结重点(源码 diff 为据)
- **npu-exporter:vNPU 指标采集设备白名单从单一 310P 扩到 310P/910B/910A3**。原来 `assemblevNPUInfo`/`GetChipListWithVNPU` 都硬编码 `devType == api.Ascend310P` 才处理 vNPU;现在抽出公开 `SupportedVnpuDevices` map(310P/910B/910A3=true),两处判断改查 map,`collector_for_vnpu.go` 也删掉自己那份只含 310P 的 `supportedVnpuDevices` 局部变量、改引用 `colcommon.SupportedVnpuDevices`。同时把 `GetVirtualDeviceInfo` 失败日志改为 `ErrorfWithLimit`+成功后 `ResetErrCnt`(限流刷屏)。**净效果:A2/A3(910B/910A3)芯片现在也上报 vNPU 切分设备的活跃度/算力指标**。
  <details><summary>代码依据 component/npu-exporter/collector/common/npu_collector.go</summary>

  ```diff
  +// SupportedVnpuDevices device types that support vnpu metrics collection
  +var SupportedVnpuDevices = map[string]bool{
  +	api.Ascend310P:  true,
  +	api.Ascend910B:  true,
  +	api.Ascend910A3: true,
  +}
  ...
   func assemblevNPUInfo(...) {
  -	if devType != api.Ascend310P {
  +	if !SupportedVnpuDevices[devType] {
   		return
  	}
  ...
  -		isNeedHandleVnpu := devType == api.Ascend310P && chipInfo.VDevInfos != nil &&
  +		isNeedHandleVnpu := SupportedVnpuDevices[devType] && chipInfo.VDevInfos != nil &&
  ```
  </details>

- **ascend-docker-runtime:UB 驱动挂载的环境变量名与布尔语义整体翻转**。旧接口 `parseDisableUBMount` 读 `DisableUBMountEnv`,`"True"`=禁用、空/`"False"`=不禁用;`shouldMountUBDriverFiles(disableUBMount)` 里 `if disableUBMount { return false }`。新接口 `parseUBDrvMount`/`parseUBDrvMountOption` 读 `AscendUBDrvMountEnv`,`EnableUBDrvMount` 或**空字符串**=挂载(true)、`DisableUBDrvMount`=不挂载;函数参数改名 `mountUBDrv`,判断改 `if !mountUBDrv`。CDI 路径 `MountConfig` 的字段也从 `DisableUBMounts` 改成 `MountUBDrv`。**这是一次默认行为翻转:未显式配置时,旧版不挂 UB 驱动、新版默认挂**。
  <details><summary>代码依据 component/ascend-docker-runtime/hook/process/process.go</summary>

  ```diff
  -func parseDisableUBMount(disableUBMount string) (bool, error) {
  -	if disableUBMount == "True" {
  +func parseUBDrvMount(value string) (bool, error) {
  +	if value == api.EnableUBDrvMount || value == "" {
   		return true, nil
   	}
  -	if disableUBMount == "" || disableUBMount == "False" {
  +	if value == api.DisableUBDrvMount {
   		return false, nil
   	}
  ...
  -func shouldMountUBDriverFiles(disableUBMount bool) bool {
  -	if disableUBMount {
  +func shouldMountUBDriverFiles(mountUBDrv bool) bool {
  +	if !mountUBDrv {
   		return false
   	}
  ```
  </details>
  <details><summary>代码依据 component/ascend-docker-runtime/runtime/process/process.go(CDI 路径)</summary>

  ```diff
  -		disableUBMount, err := parseBoolOption(getValueByKey(spec.Process.Env, api.DisableUBMountEnv))
  +		mountUBDrv, err := parseUBDrvMountOption(getValueByKey(spec.Process.Env, api.AscendUBDrvMountEnv))
  ...
  -			DisableUBMounts:       disableUBMount,
  +			MountUBDrv:            mountUBDrv,
  ```
  </details>

- **ascend-for-volcano:修重调度 grace 删除场景的 pod 数据竞争**。`EvictJobByTask` 里删除了对 `UpdatePodPendingReason` 的两处调用,并**整个删掉** `UpdatePodPendingReason` 方法——该方法直接 append 到 `taskInfo.Pod.Status.Conditions`(共享 pod 对象),与调度器 goroutine 并发写导致 race;同时 `GetTaskInfoByNameFromSSN` 取失败现在直接 `return getErr`(原来只打日志继续用 nil taskInfo)。配套在 `build/build.sh` 新增源码补丁:给 volcano 上游 `SchedulerCache.Evict` 把 `p := task.Pod` 改成 `p := task.Pod.DeepCopy()` 再交给异步 evictor,从根上断开共享。
  <details><summary>代码依据 component/ascend-for-volcano/build/build.sh(给 volcano Evict 打 DeepCopy 补丁)</summary>

  ```diff
  +    # Evict data race patch: SchedulerCache.Evict hands the shared pod object
  +    # to an async evictor goroutine, which races with the scheduler goroutine.
  +    REPLACE_FILE="${GOPATH}/src/volcano.sh/volcano/pkg/scheduler/cache/cache.go"
  +    if ! grep -q "p := task.Pod.DeepCopy()" "$REPLACE_FILE"; then
  +      sed -i '/func (sc \*SchedulerCache) Evict/,/^}/s/^\([[:space:]]*\)p := task.Pod$/\1p := task.Pod.DeepCopy()/' "$REPLACE_FILE"
  ```
  </details>

- **noded:IPMI 故障监控改懒加载,支持 BMC 临时不可用自愈**。`NewIpmiEventMonitor` 把 `ipmiTool` 初值从 `&ipmi.IPMI{}` 改为 `nil`;`Init()` 不再在启动时 `ipmi.Open(0)`+拉故障列表(启动即失败会阻断),改为空实现,把打开推迟到 `Monitoring` 循环里的 `UpdateFaultDevList`——若 `ipmiTool==nil` 才 `Open`,且 `GetCurrentAlarmFaultEvents` 失败时 `Close`+置 nil 以便下轮重开。`Stop()` 加 nil 守卫。**净效果:BMC 短暂不可用不再需要重启 noded 才能恢复采集**。
  <details><summary>代码依据 component/noded/pkg/monitoring/ipmimonitor/ipmi_monitor.go</summary>

  ```diff
  -// Init initialize ipmi tool and get fault device list
  +// Init initialize ipmi monitor, the ipmi device is opened lazily in the Monitoring loop
  +// so that a temporarily unavailable BMC can be recovered without restarting noded.
   func (i *IpmiEventMonitor) Init() error {
  -	ipmiTool, err := ipmi.Open(0)
  -	if err != nil { ... return err }
  -	i.ipmiTool = ipmiTool
  -	if err := i.UpdateFaultDevList(); err != nil { ... return err }
   	return nil
   }
  ...
   func (i *IpmiEventMonitor) UpdateFaultDevList() error {
  +	if i.ipmiTool == nil {
  +		ipmiTool, err := ipmi.Open(0)
  +		if err != nil { ... return err }
  +		i.ipmiTool = ipmiTool
  +	}
  ```
  </details>

- **构建:非 UB(统一总线)场景不再强装 umdk 包**。`npu-exporter`/`noded`/`ascend-device-plugin` 的 `Dockerfile.openeuler` 里,原来"未提供 umdk 包就 `yum install umdk-urma-*`"改为只打印 note 跳过——umdk 仅 UB/统一总线场景需要,非 UB 镜像不再拉这套依赖。
  <details><summary>代码依据 component/npu-exporter/build/Dockerfile.openeuler</summary>

  ```diff
  -        echo "warning: umdk package not provided, install from yum"; \
  -        yum install -y umdk-urma-bin umdk-urma-devel umdk-urma-lib umdk-urma-tools; \
  +        echo "note: umdk package not provided, it is necessary for unified bus scenario only"; \
  ```
  </details>

### 后续发展方向 [AI]
- vNPU 监控从 310P 扩到 910B/910A3(A2/A3),叠加上面 UB 驱动默认挂载翻转 + umdk 仅 UB 场景装,方向指向**为 A2/A3 + 统一总线(UB/UMDK)超节点形态做运行时/监控适配**。证据只覆盖 npu-exporter 白名单与 docker-runtime env 语义两处 diff,未见 vNPU 切分 quota 或调度侧的对应改动。
- volcano 侧连续两次围绕重调度/Evict 收敛并发安全(本期删共享 pod 写 Condition + DeepCopy 补丁),说明昇腾对 volcano 重调度路径的稳定性还在补;证据仅 `task.go`+`build.sh`,未见重调度策略本身的功能变更。

## ub-network-device-plugin: 263d6387 -> 475aefcd
- 比较: 263d6387...475aefcd | tag: 1.0.2 | commits=5 | truncated=false
- 源:https://gitcode.com/openFuyao/ub-network-device-plugin/compare/263d6387fef13dbf534d0063803d810ef723a43a...475aefcdd1c522d10ca4b9cfdb0acc1c07606171

### AI 总结重点(源码 diff 为据)
- **新增统一错误标签机制,回给 kubelet 的错误都带 `[ub-network-device-plugin]` 前缀**。新增 `utils/errors.go`:常量 `PluginErrorTag` + `LabeledPluginError(err)`(用 `%w` 保留错误链,`errors.Is/As` 仍可用);`server.go` 里 `initialize()` 的 `grpc.NewServer` 加了 `ChainUnaryInterceptor(labeledUnaryInterceptor())`+`ChainStreamInterceptor(labeledStreamInterceptor)`,在服务端出口一处统一包装,新增 RPC 方法无需感知。**动机:一个节点部署多个 device plugin 时,kubelet 日志能区分错误来源**。
  <details><summary>代码依据 plugin/server.go + utils/errors.go</summary>

  ```diff
  +func labeledUnaryInterceptor() grpc.UnaryServerInterceptor {
  +	return func(ctx context.Context, req interface{}, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
  +		resp, err := handler(ctx, req)
  +		return resp, utils.LabeledPluginError(err)
  +	}
  +}
  ...
  -	p.server = grpc.NewServer([]grpc.ServerOption{}...)
  +	p.server = grpc.NewServer(
  +		grpc.ChainUnaryInterceptor(labeledUnaryInterceptor()),
  +		grpc.ChainStreamInterceptor(labeledStreamInterceptor),
  +	)
  ```
  </details>

- **运行时 sock 挂载从"挂 sock 文件"改成"挂 `/run/containerd` 目录(只读)",扛容器运行时重启**。`example/ub-network-device-plugin.yaml` 与文档同步:volume 从 `hostPath{path:/run/containerd/containerd.sock, type:Socket}` 改为 `{path:/run/containerd, type:Directory}` + `readOnly:true`,连接地址仍是 `.../containerd.sock`。原因:containerd 重启会删并重建 sock 文件,直接挂文件会让 Pod 内 CRI 访问失效,挂目录则新 sock 仍可见。
  <details><summary>代码依据 example/ub-network-device-plugin.yaml</summary>

  ```diff
  -        - name: runtime-sock
  +        - name: runtime-sock-dir
           hostPath:
  -            path: /run/containerd/containerd.sock
  -            type: Socket
  +            path: /run/containerd
  +            type: Directory
  ```
  </details>

- **两个健壮性修复**:①`utils.EnsureDevicePermission(path, perm)` 原来 chmod/日志全硬编码 `TidDevicePath`(忽略传入 path),现改为 honor 传入的 `path` 参数;②`server.go` 的 `Serve()` 启动时 `os.Remove(p.socket)` 改为容忍 socket 不存在(仅 `!os.IsNotExist` 才返错),避免首次启动无残留 sock 时报错。
  <details><summary>代码依据 utils/utils.go + plugin/server.go</summary>

  ```diff
  -	if err = os.Chmod(TidDevicePath, os.FileMode(perm)); err != nil {
  -		return fmt.Errorf("failed to chmod %s to %o: %w", TidDevicePath, perm, err)
  +	if err = os.Chmod(path, os.FileMode(perm)); err != nil {
  +		return fmt.Errorf("failed to chmod %s to %o: %w", path, perm, err)
  ...
  -	os.Remove(p.socket)
  +	if err := os.Remove(p.socket); err != nil && !os.IsNotExist(err) {
  +		return err
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- 本期全是可运维性打磨(错误来源标签、sock 目录挂载抗重启、路径参数化),无 UB fabric/分配逻辑的功能改动;信号指向该 plugin 正从"能跑"往"多插件共存节点上可诊断、抗运行时抖动"收敛。证据仅覆盖 `server.go`/`utils` 与 example manifest,未见 URMA 设备分配或拓扑侧变化。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo(仅保锚点)</summary>

- npu-operator(无新提交,tag v26.6.0)
- npu-container-toolkit(无新提交,tag v26.6.0)
- npu-driver-installer(无新提交,tag v26.6.0)
- vNPU(无新提交,tag v0.1.0)
- npu-node-provision(无新提交,tag v26.6.0)
- npu-dra-plugin(无新提交,tag v26.6.0)
- volcano-ext(无新提交,tag v1.9.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=78655a79e2f9ff09e88df45c29706c6b1d6c2689 tag=v26.2.0.beta.1 scanned=2026-08-30 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=npu-dra-plugin sha=1084df7c16dbb60173b0dbc8e4cd561dd45b430d tag=v26.6.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-30 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=475aefcdd1c522d10ca4b9cfdb0acc1c07606171 tag=1.0.2 scanned=2026-08-30 -->
