# 昇腾算力栈 diff 雷达 2026-07-12

## 摘要
- **ascend-device-plugin 把"重复设备检测"里的 containerd/OCI 解析下沉到组件内、自带 NPU 设备识别**:新增 `duplicatedetector/containerruntime/device_filter.go`,`getNPUMajorID()` 读 `/proc/devices` 用正则 `^[0-9]{1,3}\s[v]?devdrv-cdev$` 抓昇腾字符设备主设备号(物理 `devdrv-cdev` + 虚拟 `vdevdrv-cdev` 都收),`sync.Once` 缓存;`filterNPUDevices()` 遍历 OCI spec 的 cgroup 设备表返回 NPU minor 号。`interface.go` 由调外部 `parser.FilterNPUDevices` 改调本地 `filterNPUDevices`——即提交"将containerd依赖移动到device-plugin组件内",组件自包含化。属 `[架构方向]`。
- **npu-exporter 容器运行时探测默认路径由 v1alpha2-first 翻转为 v1-first,并缓存 CRI 版本**:`runtime_ops.go` 新增 `criVersion` 字段与 `getContainerdContainers()`,现在先走 CRI v1、仅在 v1 返回 Unimplemented 时回落 v1alpha2,并把探测到的版本缓存下来避免每次重探;顺带把 `ListContainers` 失败日志从 Error 降为 Warn(修"容器运行时版本告警日志刷屏")。属 `[行为变更]`。
- **clusterd 构建加固与版本对齐**:build.sh/test.sh 钉 `GOTOOLCHAIN=go1.21.13`("回滚golang版本修复OOM"),链接参数由 `-bindnow` 升为完整 `-Wl,-z,relro,-z,now,-z,noexecstack`(RELRO+BIND_NOW+不可执行栈),build_version `v6.0.0`→`v26.1.0`。其余 8 个 openFuyao 仓本期零新提交。

## 当日重要改变
- mind-cluster/ascend-device-plugin [架构方向] 重复设备检测组件自包含:新增 device_filter.go 自带 `getNPUMajorID`(读 /proc/devices 认 `devdrv-cdev`/`vdevdrv-cdev` 主设备号)+ `filterNPUDevices`,interface.go 从外部 parser 切到本地实现,去掉对外部 parser 包的 containerd 依赖。证据 component/ascend-device-plugin/pkg/duplicatedetector/containerruntime/device_filter.go、interface.go。https://gitcode.com/Ascend/mind-cluster/compare/524bacd2a8001c65c1b351f0d581bd5e9f676403...6d681a1a5ed5e369285f5f3c37ccd1ec4d319f79
- mind-cluster/npu-exporter [行为变更] 容器运行时 CRI 探测默认改 v1-first + 版本缓存 + Unimplemented 回落 v1alpha2,原本是 v1alpha2-first;并降噪版本告警日志。证据 component/npu-exporter/collector/container/runtime_ops.go。同上 compare 链接
- mind-cluster/clusterd [健壮性/安全] 钉 GOTOOLCHAIN=go1.21.13 修 OOM、链接加固 relro/now/noexecstack。证据 component/clusterd/build/build.sh。同上 compare 链接

## mind-cluster: 524bacd2 -> 6d681a1a
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/524bacd2a8001c65c1b351f0d581bd5e9f676403...6d681a1a5ed5e369285f5f3c37ccd1ec4d319f79 | tag: v26.1.0.beta.2 | commits=22(component/ 前缀过滤后有效代码改动集中在 ascend-device-plugin / npu-exporter / clusterd)| truncated=false

### AI 总结重点(源码 diff 为据)

- **ascend-device-plugin 重复设备检测新增自带的 NPU 设备识别层,去除对外部 parser 包的依赖**。新文件 `device_filter.go` 在 `containerruntime` 包内实现两件事:①`getNPUMajorID()` 打开 `/proc/devices`,逐行(上限 512 行)用正则 `^[0-9]{1,3}\s[v]?devdrv-cdev$` 匹配昇腾字符设备驱动行,取首字段作为主设备号插入 `sets.String`——正则里 `[v]?` 让物理 `devdrv-cdev` 与虚拟 `vdevdrv-cdev`(vNPU)两类主设备号都被收集;`sync.Once`(`npuMajorFetchCtrl`)保证进程内只探测一次并缓存。②`filterNPUDevices(spec *oci.Spec)` 遍历 `spec.Linux.Resources.Devices`,`dev.Major`/`dev.Minor` 任一为 nil 即跳过(注释明说"不监控特权容器"),对 `Type=="c"` 且主设备号命中 NPU 主设备号集合的项收集其 minor 号返回。`interface.go` 的 `ociClient.ParseSingleContainer` 相应把 `info.Devices = parser.FilterNPUDevices(spec)` 改成本地 `filterNPUDevices(spec)`。整批对应提交标题"将containerd依赖移动到device-plugin组件内"——把 containerd/oci 解析逻辑内聚进 device-plugin 组件、不再跨包借用。
  <details><summary>代码依据 device_filter.go(getNPUMajorID 正则 + filterNPUDevices)</summary>

  ```diff
  +func getNPUMajorID() (sets.String, error) {
  +	...
  +	for s.Scan() {
  +		if count > maxSearchLine { break }
  +		count++
  +		text := s.Text()
  +		matched, err := regexp.MatchString("^[0-9]{1,3}\\s[v]?devdrv-cdev$", text)
  +		...
  +		fields := strings.Fields(text)
  +		majorID.Insert(fields[0])
  +	}
  +}
  +func filterNPUDevices(spec *oci.Spec) []int {
  +	if spec == nil || spec.Linux == nil || spec.Linux.Resources == nil { return nil }
  +	majorIDs := npuMajor()
  +	for _, dev := range spec.Linux.Resources.Devices {
  +		if dev.Minor == nil || dev.Major == nil { continue } // do not monitor privileged container
  +		major := strconv.FormatInt(*dev.Major, formatIntBase)
  +		if dev.Type == "c" && majorIDs.Has(major) { devIDs = append(devIDs, int(*dev.Minor)) }
  +	}
  +}
  ```
  </details>
  <details><summary>代码依据 interface.go(切到本地实现)</summary>

  ```diff
  -	info.Devices = parser.FilterNPUDevices(spec)
  +	info.Devices = filterNPUDevices(spec)
  ```
  </details>

- **npu-exporter 把 containerd 容器枚举的 CRI 版本策略从"v1alpha2 优先、失败回落 v1"翻转为"v1 优先、Unimplemented 回落 v1alpha2",并缓存探测结果**。新增常量 `criVersionV1alpha2/criVersionV1/criV1` 与 `RuntimeOperatorTool.criVersion` 字段;`GetContainers` 里 containerd 分支抽出 `getContainerdContainers()`:若已缓存为 v1alpha2 直接走老接口,否则先建 `criv1.NewRuntimeServiceClient` 走 v1;仅当 v1 报 `Unimplemented`(服务名 `runtime.v1.RuntimeService`)时打一条 Info 日志、把 `criVersion` 记为 v1alpha2 并回落;v1 成功且版本未定则记为 v1。这与旧代码相反——旧版 `getContainersByContainerdV1alpha2` 先行、`isUnimplementedError(..., criV1alpha2)` 才升到 v1。含义:昇腾监控对新版 containerd 默认走 CRI v1,对老运行时保留兼容,且每进程只探测一次。同时 `getContainersByContainerdV1` 里 `ListContainers` 出错日志 `hwlog.RunLog.Error`→`Warn`,对应"版本告警日志刷屏修复"。
  <details><summary>代码依据 runtime_ops.go(v1-first + 缓存 + 回落)</summary>

  ```diff
  -	if client, ok := operator.criClient.(v1alpha2.RuntimeServiceClient); ok {
  -		containers, err := getContainersByContainerdV1alpha2(ctx, client)
  -		if isUnimplementedError(err, criV1alpha2) {
  -			v1Client := criv1.NewRuntimeServiceClient(operator.criConn)
  -			return getContainersByContainerdV1(ctx, v1Client)
  -		}
  -		return containers, err
  +	if client, ok := operator.criClient.(v1alpha2.RuntimeServiceClient); ok {
  +		return operator.getContainerdContainers(ctx, client)
  +	}
  ...
  +func (operator *RuntimeOperatorTool) getContainerdContainers(ctx, client) (...) {
  +	if operator.criVersion == criVersionV1alpha2 { return getContainersByContainerdV1alpha2(ctx, client) }
  +	v1Client := criv1.NewRuntimeServiceClient(operator.criConn)
  +	containers, err := getContainersByContainerdV1(ctx, v1Client)
  +	if isUnimplementedError(err, criV1) { operator.criVersion = criVersionV1alpha2; return getContainersByContainerdV1alpha2(ctx, client) }
  +	if err == nil && operator.criVersion == "" { operator.criVersion = criVersionV1 }
  +	return containers, err
  +}
  ```
  </details>

- **clusterd 构建加固:钉工具链版本 + 链接期安全强化 + 版本号对齐 26.x**。build.sh/test.sh 均加 `export GOTOOLCHAIN="go1.21.13"`(对应"回滚golang版本修复OOM"——把编译工具链锁死到该版本避免高版本 go 引入的 OOM);链接参数由旧的 `-bindnow` 改为 `-extldflags=-Wl,-z,relro,-z,now,-z,noexecstack`(完整 RELRO + 立即绑定 + 不可执行栈,交由外部链接器);`build_version` 由 `v6.0.0` 升到 `v26.1.0` 与仓库 26 系日历版本对齐。
  <details><summary>代码依据 clusterd/build/build.sh</summary>

  ```diff
  +export GOTOOLCHAIN="go1.21.13"
  -build_version="v6.0.0"
  +build_version="v26.1.0"
  ...
  -              -bindnow" \
  +              -extldflags=-Wl,-z,relro,-z,now,-z,noexecstack" \
  ```
  </details>

### 后续发展方向 [AI]
- **device-plugin 的"重复设备检测"正在自给自足化**:自带 `/proc/devices` 主设备号发现意味着重复检测不再依赖外部 parser/驱动库来认 NPU 设备,只要节点有昇腾字符设备驱动登记即可工作;`[v]?devdrv-cdev` 一次性把物理 NPU 与 vNPU 虚拟设备都纳入检测面,说明该路径要同时覆盖整卡与切分场景的"同一设备被多容器重复挂载"防护。证据仅覆盖 device_filter.go 的发现/过滤与 interface.go 的调用切换,未见 duplicatedetector 上层如何消费 `filterNPUDevices` 返回的 minor 列表做去重判定。
- **npu-exporter 转向 CRI v1 为默认**,是跟随 containerd 弃用 v1alpha2 的既定趋势(新集群默认无 v1alpha2),缓存机制避免每次采集重复探测;老运行时仍有回落,短期不构成兼容性断裂。证据仅 runtime_ops.go 一处策略翻转 + 缓存字段,未见 isulad/docker 等其他运行时路径同步调整。
- 本期无 CRD/API 字段变更、无 vNPU 切分或驱动容器化诸仓(npu-operator/npu-driver-installer/vNPU 等)增量,变更集中在 device-plugin 探测面与构建加固,属工程健壮性批次而非能力扩张。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓无新提交</summary>

- npu-operator(335bc283,无新提交)
- npu-container-toolkit(d54256e0,无新提交)
- npu-driver-installer(9f400f3c,无新提交)
- vNPU(34f7965b,无新提交)
- npu-node-provision(717ef777,无新提交)
- npu-dra-plugin(98f8fa5e,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=6d681a1a5ed5e369285f5f3c37ccd1ec4d319f79 tag=v26.1.0.beta.2 scanned=2026-07-12 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=v26.6.0 scanned=2026-07-12 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-12 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=v26.6.0 scanned=2026-07-12 -->
<!-- ANCHOR repo=vNPU sha=34f7965bb9e94b031b7afb2329fe3ff611e8c303 tag=v0.1.0 scanned=2026-07-12 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-12 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-12 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-12 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-12 -->
